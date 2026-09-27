import QuartzCore
import CoreVideo
import Foundation

@MainActor
enum PipelineChecks {
    /// Live engine with no camera, a still behind the person, and the first frame through.
    static func start(camera: CVPixelBuffer, background: URL, greenScreen: Bool = false, sink: CaptureSink,
                      engine: Engine? = nil) async -> Engine? {
        let engine = engine ?? Engine(sink: sink, usesCamera: false)
        engine.setScreen(greenScreen ? .any : .off)
        engine.show(.image(id: "bg", url: background))
        engine.setLive(true)
        var t = 0.0
        for _ in 0..<150 where sink.count == 0 {
            await feed(engine, camera, at: t, sink: sink)
            t += 1.0 / 30
            await sleep(0.02)
        }
        return sink.count > 0 ? engine : nil
    }

    static func isMagenta(_ c: SIMD3<Int>) -> Bool { c.x > 200 && c.y < 70 && c.z > 200 }

    /// Scores an output frame against the fixture's true alpha: how much of the person survived and how much of
    /// the background was replaced. `screen` limits the background score to where the green screen is, or to where it
    /// isn't, beyond a halo around the person.
    struct Score {
        var personKept = 0.0
        var screenReplaced = 0.0
        var roomReplaced = 0.0
    }

    static func score(_ out: CVPixelBuffer, alpha: URL, screen: URL?, halo: Int) -> Score? {
        guard let gt = Pixels.gray(alpha), gt.width == 1920, gt.height == 1080 else { return nil }
        let scr = screen.flatMap(Pixels.gray)
        let step = 4
        let gw = 1920 / step, gh = 1080 / step
        // The person grown by `halo` px on a coarse grid: room inside it may legitimately show.
        var near = [Bool](repeating: false, count: gw * gh)
        let r = halo / step
        var rows = [Bool](repeating: false, count: gw * gh)
        for y in 0..<gh {
            for x in 0..<gw where gt.values[(y * step) * 1920 + x * step] > 0 {
                for dx in max(0, x - r)...min(gw - 1, x + r) { rows[y * gw + dx] = true }
            }
        }
        for y in 0..<gh {
            for x in 0..<gw where rows[y * gw + x] {
                for dy in max(0, y - r)...min(gh - 1, y + r) { near[dy * gw + x] = true }
            }
        }
        var person = (0, 0), onScreen = (0, 0), room = (0, 0)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(out)
        let format = CVPixelBufferGetPixelFormatType(out)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let x = gx * step, y = gy * step
                let a = gt.values[y * 1920 + x]
                let magenta = isMagenta(Pixels.pixel(base, row, format, x, y))
                if a >= 250 {
                    person.1 += 1
                    if !magenta { person.0 += 1 }
                } else if a == 0 {
                    let behindScreen = scr.map { $0.values[y * $0.width + x] > 128 } ?? true
                    if behindScreen {
                        onScreen.1 += 1
                        if magenta { onScreen.0 += 1 }
                    } else if !near[gy * gw + gx] {
                        room.1 += 1
                        if magenta { room.0 += 1 }
                    }
                }
            }
        }
        func share(_ p: (Int, Int)) -> Double { p.1 == 0 ? 1 : Double(p.0) / Double(p.1) }
        return Score(personKept: share(person), screenReplaced: share(onScreen), roomReplaced: share(room))
    }

    static func composite() async -> Bool {
        guard let photo = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image),
              let alpha = Paths.fixture("green-alpha.png") else { return false }
        let sink = CaptureSink()
        let bg = Pixels.solidPNG("magenta", r: 255, g: 0, b: 255)
        guard let engine = await start(camera: Pixels.frame(photo), background: bg, sink: sink) else {
            return expect(false, "composite: no output frame")
        }
        for i in 0..<5 { await feed(engine, Pixels.frame(photo), at: Double(10 + i) / 30, sink: sink) }
        engine.setLive(false)
        guard let out = sink.last, let score = score(out, alpha: alpha, screen: nil, halo: 24) else {
            return expect(false, "composite: no frame to score")
        }
        Pixels.save(out, "composite.png")
        let size = expect(CVPixelBufferGetWidth(out) == 1920 && CVPixelBufferGetHeight(out) == 1080,
                          "composite: output is 1920x1080")
        let kept = expect(score.personKept > 0.95, String(format: "composite: %.1f%% of the person kept",
                                                          score.personKept * 100))
        let replaced = expect(score.screenReplaced > 0.97, String(format: "composite: %.1f%% of the room replaced",
                                                                  score.screenReplaced * 100))
        return size && kept && replaced
    }

    static func green() async -> Bool {
        guard let alpha = Paths.fixture("green-alpha.png"), let screen = Paths.fixture("green-screen.png") else {
            return false
        }
        var ok = true
        for (name, partial) in [("green-partial.png", true), ("green-full.png", false)] {
            guard let photo = Paths.fixture(name).flatMap(Pixels.image) else { return false }
            let frame = Pixels.frame(photo)
            let sink = CaptureSink()
            var status = GreenScreenStatus.off
            let bg = Pixels.solidPNG("magenta", r: 255, g: 0, b: 255)
            guard let engine = await start(camera: frame, background: bg, greenScreen: true, sink: sink) else {
                return expect(false, "green: no output frame")
            }
            engine.onGreenScreenStatus = { status = $0 }
            var t = 1.0
            for _ in 0..<120 {
                if case .keyed = status { break }
                if status == .notFound { break }
                await feed(engine, frame, at: t, sink: sink)
                t += 1.0 / 30
                await sleep(0.02)
            }
            for _ in 0..<3 {
                await feed(engine, frame, at: t, sink: sink)
                t += 1.0 / 30
            }
            engine.setLive(false)
            guard case .keyed(let coverage, _) = status else {
                ok = expect(false, "green \(name): calibration gave \(status)") && ok
                continue
            }
            guard let out = sink.last,
                  let s = score(out, alpha: alpha, screen: partial ? screen : nil, halo: 16) else { return false }
            Pixels.save(out, "green-\(partial ? "partial" : "full").png")
            let pct = { (v: Double) in String(format: "%.1f%%", v * 100) }
            if partial {
                ok = expect(coverage < GreenScreen.fullCoverage,
                            "green partial: coverage \(pct(coverage)) keeps Vision on as the garbage matte") && ok
                ok = expect(s.roomReplaced > 0.97,
                            "green partial: \(pct(s.roomReplaced)) of the uncovered room replaced past 16 px") && ok
            } else {
                ok = expect(coverage >= GreenScreen.fullCoverage,
                            "green full: coverage \(pct(coverage)) turns Vision off") && ok
            }
            ok = expect(s.personKept > 0.95, "green \(partial ? "partial" : "full"): \(pct(s.personKept)) of the "
                        + "person kept") && ok
            ok = expect(s.screenReplaced > 0.97, "green \(partial ? "partial" : "full"): \(pct(s.screenReplaced)) "
                        + "of the screen keyed out") && ok
        }
        return ok
    }

    /// Red, then blue, then green half way through the blue dissolve. A background pixel's colour is sampled as
    /// each frame lands, on a clock the check advances by exactly one frame per frame.
    static func dissolve() async -> Bool {
        guard let photo = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image) else { return false }
        let frame = Pixels.frame(photo)
        let samples = SampleLog()
        let sink = CaptureSink { pixels, time in samples.add(time.seconds, Pixels.rgb(pixels, 40, 40)) }
        let clock = FakeClock()
        let red = Pixels.solidPNG("red", r: 230, g: 20, b: 20)
        let blue = Pixels.solidPNG("blue", r: 20, g: 20, b: 230)
        let green = Pixels.solidPNG("green", r: 20, g: 230, b: 20)
        let engine = Engine(sink: sink, usesCamera: false)
        engine.clock = { clock.now }
        engine.show(.image(id: "red", url: red))
        engine.setLive(true)
        for _ in 0..<150 where sink.count == 0 {
            await feed(engine, frame, at: clock.now, sink: sink)
            await sleep(0.02)
        }
        func frames(_ n: Int) async {
            for _ in 0..<n {
                clock.advance(1.0 / 30)
                await feed(engine, frame, at: clock.now, sink: sink)
            }
        }
        await frames(5)
        engine.show(.image(id: "blue", url: blue))
        await sleep(0.3)
        await frames(7)
        engine.show(.image(id: "green", url: green))
        await sleep(0.3)
        let greenStart = clock.now
        await frames(24)
        engine.setLive(false)

        let log = samples.sorted()
        guard log.count > 30 else { return expect(false, "dissolve: only \(log.count) frames") }
        var worst = 0
        for (a, b) in zip(log, log.dropFirst()) {
            worst = max(worst, abs(a.1.x - b.1.x), abs(a.1.y - b.1.y), abs(a.1.z - b.1.z))
        }
        let beforeSwitch = log.last { $0.0 < greenStart }?.1 ?? .zero
        let afterSwitch = log.first { $0.0 > greenStart }?.1 ?? .zero
        let end = log.last!.1
        let doneAt = log.first { $0.0 >= greenStart + Engine.dissolveDuration - 1e-6 }?.1 ?? .zero
        let stillGoing = log.last { $0.0 < greenStart + Engine.dissolveDuration - 3.0 / 30 }?.1 ?? .zero
        var ok = expect(beforeSwitch.y < 60 && beforeSwitch.z > 60 && beforeSwitch.x < 200,
                        "dissolve: red to blue was mid-way at the switch, \(beforeSwitch)")
        ok = expect(worst <= 40, "dissolve: largest step between frames is \(worst) levels") && ok
        ok = expect(maxDiff(beforeSwitch, afterSwitch) <= 26,
                    "dissolve: the switch mid-dissolve didn't jump, \(beforeSwitch) then \(afterSwitch)") && ok
        ok = expect(maxDiff(doneAt, SIMD3(20, 230, 20)) <= 3,
                    "dissolve: green complete 500 ms after the switch, \(doneAt)") && ok
        ok = expect(maxDiff(stillGoing, SIMD3(20, 230, 20)) > 3,
                    "dissolve: still dissolving 100 ms before that, \(stillGoing)") && ok
        ok = expect(maxDiff(end, SIMD3(20, 230, 20)) <= 3, "dissolve: ends on green, \(end)") && ok
        return await dissolveFromOff() && ok
    }

    /// Off, then red, then blue a fifth of a second into the red dissolve, with the camera changing right after.
    /// The camera's share of the frozen blend has to follow the live camera, or a still of the room (and of you)
    /// hangs in the background while it fades.
    static func dissolveFromOff() async -> Bool {
        guard let first = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image),
              let second = Paths.fixture("portrait-brick.jpg").flatMap(Pixels.image) else { return false }
        let cam1 = Pixels.frame(first), cam2 = Pixels.frame(second)
        let p = (x: 40, y: 40)
        let samples = SampleLog()
        let sink = CaptureSink { pixels, time in samples.add(time.seconds, Pixels.rgb(pixels, p.x, p.y)) }
        let clock = FakeClock()
        let engine = Engine(sink: sink, usesCamera: false)
        engine.clock = { clock.now }
        engine.setLive(true)
        await feed(engine, cam1, at: clock.now, sink: sink)
        engine.show(.image(id: "red", url: Pixels.solidPNG("red", r: 230, g: 20, b: 20)))
        await sleep(0.3)
        for _ in 0..<6 {
            clock.advance(1.0 / 30)
            await feed(engine, cam1, at: clock.now, sink: sink)
        }
        engine.show(.image(id: "blue", url: Pixels.solidPNG("blue", r: 20, g: 20, b: 230)))
        await sleep(0.3)
        clock.advance(1.0 / 30)
        let at = clock.now
        await feed(engine, cam2, at: at, sink: sink)
        engine.setLive(false)
        guard let got = samples.sorted().last(where: { abs($0.0 - at) < 1e-6 })?.1 else {
            return expect(false, "dissolve from Off: no frame after the switch")
        }
        let e = Double(Engine.ease(0.2 / Engine.dissolveDuration)), t = Double(Engine.ease(1.0 / 30 / 0.5))
        let room = Pixels.rgb(cam2, p.x, p.y), red = SIMD3(230.0, 20, 20), blue = SIMD3(20.0, 20, 230)
        let from = SIMD3(Double(room.x), Double(room.y), Double(room.z)) * (1 - e) + red * e
        let want = from * (1 - t) + blue * t
        let expected = SIMD3(Int(want.x.rounded()), Int(want.y.rounded()), Int(want.z.rounded()))
        return expect(maxDiff(got, expected) <= 6,
                      "dissolve from Off: the camera's share stays live across a mid-dissolve switch, \(got) vs "
                      + "\(expected)")
    }

    static func maxDiff(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
        max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
    }

    /// Per-frame CPU of the whole pipeline at 30 fps: the person matte over a still, then a green screen that fills
    /// the background (key alone, no matte).
    static func bench() async -> Bool {
        guard let photo = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image),
              let full = Paths.fixture("green-full.png").flatMap(Pixels.image) else { return false }
        let bg = Pixels.solidPNG("magenta", r: 255, g: 0, b: 255)
        var ok = true
        let matte = NativeMatter.inVirtualMachine ? "Vision" : "macOS matte"
        for (label, image, green) in [("still, \(matte)", photo, false), ("green screen fills", full, true)] {
            let frame = Pixels.frame(image)
            let sink = CaptureSink()
            var status = GreenScreenStatus.off
            guard let engine = await start(camera: frame, background: bg, greenScreen: green, sink: sink) else {
                return expect(false, "bench: no output")
            }
            engine.onGreenScreenStatus = { status = $0 }
            if green {
                for _ in 0..<90 {
                    if case .keyed = status { break }
                    await feed(engine, frame, at: 0, sink: sink)
                    await sleep(0.03)
                }
            }
            let n = 90
            let cpu0 = cpuSeconds(), wall0 = CFAbsoluteTimeGetCurrent()
            for i in 0..<n {
                let due = wall0 + Double(i) / 30
                let wait = due - CFAbsoluteTimeGetCurrent()
                if wait > 0 { await sleep(wait) }
                await feed(engine, frame, at: due, sink: sink)
            }
            let cpu = (cpuSeconds() - cpu0) / Double(n) * 1000
            engine.setLive(false)
            print(String(format: "      %@: %.2f ms CPU per frame, %.1f%% of a core at 30 fps", label, cpu, cpu * 3))
            ok = expectRate(cpu < 15, "bench: \(label) under 15 ms CPU per frame") && ok
        }
        return ok
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let u = usage.ru_utime, s = usage.ru_stime
        return Double(u.tv_sec + s.tv_sec) + Double(u.tv_usec + s.tv_usec) / 1e6
    }
}

final class SampleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Double, SIMD3<Int>)] = []
    func add(_ t: Double, _ c: SIMD3<Int>) { lock.withLock { entries.append((t, c)) } }
    func sorted() -> [(Double, SIMD3<Int>)] { lock.withLock { entries.sorted { $0.0 < $1.0 } } }
}

/// A video background moves in the camera's output, fed as the camera feeds it: 30 frames a second in real time,
/// stamped with host-clock capture times a little behind when they arrive.
@MainActor
enum VideoPlayCheck {
    static func run() async -> Bool {
        let fast = await play(fps: 30)
        let slow = await play(fps: 22.8)
        return fast && slow
    }

    /// A camera slower than 27 fps puts the output on its own steady 30 fps clock, so a 30 fps clip still plays
    /// every frame, evenly.
    static func play(fps: Double) async -> Bool {
        guard let photo = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image) else { return false }
        let frame = Pixels.frame(photo)
        let samples = SampleLog()
        // Around the edges, where the room shows, summed so a change anywhere counts.
        let spots = [(40, 540), (1880, 540), (960, 40), (300, 1000), (1600, 200)]
        let sink = CaptureSink { pixels, time in
            samples.add(time.seconds, spots.map { Pixels.rgb(pixels, $0.0, $0.1) }.reduce(.zero, &+))
        }
        let engine = Engine(sink: sink, usesCamera: false)
        let name = ProcessInfo.processInfo.environment["FASTBG_CLIP"] ?? "lava"
        let clip = Paths.repo.appendingPathComponent("Stock/\(name).mp4")
        engine.show(.video(id: "lava", url: clip))
        engine.setLive(true)
        let start = CACurrentMediaTime()
        var due = start
        while CACurrentMediaTime() - start < 5 {
            if due > CACurrentMediaTime() { await sleep(due - CACurrentMediaTime()) }
            await feed(engine, frame, at: CACurrentMediaTime() - 0.04, sink: sink)
            // A camera that falls behind drops frames. Sending the missed ones in a burst would double the rate.
            due += 1 / fps
            if due < CACurrentMediaTime() { due += ((CACurrentMediaTime() - due) * fps).rounded(.up) / fps }
        }
        engine.setLive(false)
        // The last 2 s, once the camera's rate has been measured.
        let sorted = samples.sorted().filter { $0.0 > start + 3 }
        let log = sorted.map(\.1)
        let changes = zip(log, log.dropFirst()).filter { $0 != $1 }.count
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.0 - $0.0 }
        let rate = Double(gaps.count) / max(gaps.reduce(0, +), 0.001)
        let label = String(format: "video play, %.1f fps camera:", fps)
        var ok = expectRate(log.count > 35 && changes > log.count * 2 / 3,
                            "\(label) the background changed on \(changes) of \(log.count) frames")
        ok = expectRate(abs(rate - 30) < 1, String(format: "%@ %.1f fps out", label, rate)) && ok
        return ok
    }
}
