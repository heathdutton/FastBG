import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd

/// Auto's readings and picks where a camera makes them hard, and the blue screen path.
@MainActor
enum AutoCheck {
    static func run() async -> Bool {
        var ok = noise()
        ok = picks() && ok
        ok = persistence() && ok
        ok = await blue() && ok
        ok = await emptyMatte() && ok
        return ok
    }

    /// macOS's matte running but coming back empty, as it does in a virtual machine: Autocalibrate hands the
    /// frames to Vision within a few seconds, and the person comes back.
    static func emptyMatte() async -> Bool {
        guard let photo = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image),
              let alpha = Paths.fixture("green-alpha.png") else { return false }
        let frame = Pixels.frame(photo)
        let sink = CaptureSink()
        let engine = Engine(sink: sink, usesCamera: false)
        engine.queue.sync { engine.blanksNative = true }
        var sources: [Bool] = []
        engine.onMatteSource = { sources.append($0) }
        engine.setAuto(true)
        guard await PipelineChecks.start(camera: frame, background: Pixels.solidPNG("magenta", r: 255, g: 0, b: 255),
                                         sink: sink, engine: engine) != nil else {
            return expect(false, "empty matte: no output")
        }
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 5, sources.last != false {
            await feed(engine, frame, at: CACurrentMediaTime(), sink: sink)
            await sleep(1.0 / 30)
        }
        let handed = CACurrentMediaTime() - start
        for _ in 0..<5 { await feed(engine, frame, at: CACurrentMediaTime(), sink: sink) }
        engine.setLive(false)
        let score = sink.last.flatMap { PipelineChecks.score($0, alpha: alpha, screen: nil, halo: 24) }
        var ok = expect(sources.last == false, String(format: "empty matte: Vision took over after %.1f s", handed))
        ok = expect((score?.personKept ?? 0) > 0.9, String(format: "empty matte: %.1f%% of the person back",
                                                              (score?.personKept ?? 0) * 100)) && ok
        return await emptyRoom() && ok
    }

    /// An empty room, where macOS's matte is rightly empty and Vision agrees, keeps macOS's.
    static func emptyRoom() async -> Bool {
        guard !NativeMatter.inVirtualMachine else { return true }
        guard let room = Paths.fixture("room-office.jpg").flatMap(Pixels.image) else { return false }
        let frame = Pixels.frame(room)
        let sink = CaptureSink()
        let engine = Engine(sink: sink, usesCamera: false)
        var sources: [Bool] = []
        engine.onMatteSource = { sources.append($0) }
        engine.setAuto(true)
        guard await PipelineChecks.start(camera: frame, background: Pixels.solidPNG("magenta", r: 255, g: 0, b: 255),
                                         sink: sink, engine: engine) != nil else {
            return expect(false, "empty room: no output")
        }
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 4 {
            await feed(engine, frame, at: CACurrentMediaTime(), sink: sink)
            await sleep(1.0 / 30)
        }
        engine.setLive(false)
        return expect(sources.last == true, "empty room: macOS's matte kept, masks from \(sources)")
    }

    /// Noise read through an exposure step, 40% of the frame moving, and noise under one 8-bit level.
    static func noise() -> Bool {
        var rng = SystemRandomNumberGenerator()
        let base = (0..<(96 * 54)).map { _ in SIMD3<Float>(Float.random(in: 0.1...0.9, using: &rng),
                                                            Float.random(in: 0.1...0.9, using: &rng),
                                                            Float.random(in: 0.1...0.9, using: &rng)) }
        func frame(_ levels: Int, exposure: Float = 0, moving: Double = 0) -> [SIMD3<Float>] {
            base.map { c in
                if Double.random(in: 0..<1, using: &rng) < moving {
                    return SIMD3(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng),
                                 Float.random(in: 0...1, using: &rng))
                }
                let n = SIMD3<Float>(Float(Int.random(in: -levels...levels, using: &rng)),
                                     Float(Int.random(in: -levels...levels, using: &rng)),
                                     Float(Int.random(in: -levels...levels, using: &rng)))
                return ((c * 255).rounded(.toNearestOrAwayFromZero) + n) / 255 + exposure
            }
        }
        // Uniform noise of ±n levels has a standard deviation of sqrt(n(n+1)/3) levels. Luma sums three channels of
        // it with the 0.299, 0.587, 0.114 weights, whose root sum of squares is 0.669.
        func truth(_ n: Int) -> Float { (Float(n * (n + 1)) / 3).squareRoot() * 0.669 / 255 }
        var ok = true
        for (name, n, exposure, moving) in [("plain", 8, Float(0), 0.0), ("exposure step", 8, 4 / 255, 0),
                                            ("40% moving", 8, 0, 0.4), ("under a level", 1, 0, 0)] {
            guard let got = AutoTune.noise(frame(n), frame(n, exposure: exposure, moving: moving)) else {
                return expect(false, "auto noise \(name): no reading")
            }
            let error = abs(got.luma - truth(n)) / truth(n)
            ok = expect(error < 0.25, String(format: "auto noise, %@: %.4f read, %.4f true", name, got.luma, truth(n)))
                && ok
        }
        return ok
    }

    /// Every setting the window changes comes back after a relaunch: a second model reads what the first saved.
    static func persistence() -> Bool {
        let root = Paths.temp("persist-library")
        try? FileManager.default.removeItem(at: root)
        func launch() -> AppModel {
            AppModel(library: Library(root: root), engine: Engine(sink: CaptureSink(), usesCamera: false),
                     virtualCamera: VirtualCamera())
        }
        let first = launch()
        let before = (first.auto, first.systemMatte, first.tuning.detection)
        first.setAuto(true)
        first.set(\.despill, Tuning().despill + 0.4)
        first.setAuto(false)
        first.set(\.detection, 0.37)
        first.setScreen(.blue)
        first.setSystemMatte(false)
        first.setCamera("camera-uid")
        let second = launch()
        var ok = expect(!second.auto && !second.systemMatte && abs(second.tuning.detection - 0.37) < 0.001,
                        "relaunch: autocalibrate, matting and a slider survive")
        ok = expect(second.library.screen == .blue && second.cameraChoice == "camera-uid",
                    "relaunch: screen and camera survive") && ok
        ok = expect(second.offsets["tuning.despill"].map { abs($0 - 0.4) < 0.001 } == true,
                    "relaunch: a lean on autocalibrate's pick survives") && ok
        // Put the harness's own defaults back.
        second.setSystemMatte(before.1)
        second.set(\.detection, before.2)
        second.setAuto(before.0)
        second.resetOffsets()
        return ok
    }

    /// Flicker drives smoothing, and a user's lean stays inside each knob's range.
    static func picks() -> Bool {
        let calm = AutoTune.tuning(for: .typical, flicker: 0), chair = AutoTune.tuning(for: .typical, flicker: 10)
        var ok = expect(calm.smoothing <= 0.6 && chair.smoothing >= 0.85,
                        "auto: smoothing \(calm.smoothing) with no flicker, \(chair.smoothing) with a flickering chair")
        let leaned = Tuning().nudged(["tuning.detection": 0.5, "tuning.keyHue": -45, "tuning.motion": 0.01])
        ok = expect(leaned.detection == 0.8 && leaned.keyHue == -30 && abs(leaned.motion - 0.04) < 0.0001,
                    "auto: leans clamp to each knob's range") && ok
        return ok
    }

    /// A blue screen keys, Green refuses it, and the shade comes from right around the person: the screen here is
    /// darker near them, the way a person's shadow falls on it.
    static func blue() async -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let photo = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image),
              let alphaURL = Paths.fixture("green-alpha.png"), let alpha = Pixels.gray(alphaURL),
              let background = try? StillSource.load(Pixels.solidPNG("magenta", r: 255, g: 0, b: 255), device: device)
        else { return false }
        let near = SIMD3<Float>(20, 60, 170), far = SIMD3<Float>(50, 110, 240)
        func shade(_ r: Float) -> SIMD3<Float> { near + (far - near) * min(1, r / 0.8) }
        var screenRadii: [Float] = []
        let frame = Pixels.frame(photo)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<alpha.height {
            for x in 0..<alpha.width {
                let a = Float(alpha.values[y * alpha.width + x]) / 255
                let dx = Float(x - alpha.width / 2) / Float(alpha.height), dy = Float(y - alpha.height / 2)
                    / Float(alpha.height)
                let r = (dx * dx + dy * dy).squareRoot()
                let screen = shade(r)
                if a < 0.5, x % 4 == 0, y % 4 == 0 { screenRadii.append(r) }
                let p = base + y * row + x * 4
                let person = SIMD3<Float>(Float(p[2]), Float(p[1]), Float(p[0]))
                let c = person * a + screen * (1 - a)
                (p[2], p[1], p[0]) = (UInt8(c.x.rounded()), UInt8(c.y.rounded()), UInt8(c.z.rounded()))
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let mask = KeyJitterCheck.mask(alpha)
        var ok = expect(GreenScreen.calibrate(frame: frame, mask: mask, want: .green) == nil,
                        "blue: Green finds no screen in front of a blue one")
        guard let key = GreenScreen.calibrate(frame: frame, mask: mask, want: .any) else {
            return expect(false, "blue: Either finds no screen")
        }
        // The shade just around the person against a plain median of the whole screen. The gradient is monotonic,
        // so the median shade is the shade at the median distance.
        let rgb = key.rgb * 255
        let around = shade(0.3), median = shade(screenRadii.sorted()[screenRadii.count / 2])
        print(String(format: "      blue key rgb %.0f %.0f %.0f, around the person %.0f %.0f %.0f, whole-screen median "
                     + "%.0f %.0f %.0f", rgb.x, rgb.y, rgb.z, around.x, around.y, around.z, median.x, median.y,
                     median.z))
        ok = expect(key.spill == 2, "blue: despills blue") && ok
        ok = expect(simd_distance(rgb, around) < simd_distance(median, around),
                    "blue: the shade leans to the screen around the person") && ok

        guard let compositor = try? Compositor(device: device) else { return false }
        let done = Flag()
        let out = OutBox()
        let job = Compositor.Job(camera: frame, mask: nil, key: key, from: .texture(background), to: nil, mix: 0)
        compositor.render(job) { pixels in
            out.set(pixels)
            done.set(true)
        }
        for _ in 0..<500 where done.value == nil { await sleep(0.002) }
        guard let pixels = out.value, let s = PipelineChecks.score(pixels, alpha: alphaURL, screen: nil, halo: 16)
        else { return expect(false, "blue: no output") }
        Pixels.save(pixels, "blue.png")
        ok = expect(s.personKept > 0.95, String(format: "blue: %.1f%% of the person kept", s.personKept * 100)) && ok
        ok = expect(s.screenReplaced > 0.97, String(format: "blue: %.1f%% of the screen keyed out",
                                                    s.screenReplaced * 100)) && ok
        return ok
    }
}
