import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// fastbg against macOS's own Background effect and a basic Vision app, on sequences with a known true alpha.
///
/// - Each person is cut out twice, by Vision at `.accurate` and by the native effect, and composited over a real
///   office, chair and all. Each side has home advantage against its own cut-out, so only a result on both counts.
/// - Green screen scenes and flicker, change where the truth didn't change, favour neither.
@MainActor
enum Matchup {
    nonisolated static let w = 1920, h = 1080, step = 2

    struct Person {
        let name: String
        let photo: CVPixelBuffer
        let truths: [(String, [UInt8])]
    }

    struct Sequence {
        enum Path { case sway, leave, enter }
        let name: String
        let person: CVPixelBuffer
        let alpha: [UInt8]
        let room: CVPixelBuffer
        var sway = 0
        var noise = 3
        var frames = 90
        var path = Path.sway
        /// Frames per sway, there and back.
        var period = 60
        /// From this frame on, everything is brighter by `gain`, the way auto-exposure steps.
        var exposure: (frame: Int, gain: Float)?
        /// A second person behind the first, `offset` px across, and the first moved the other way by as much.
        var second: (person: CVPixelBuffer, alpha: [UInt8], offset: Int)?
        /// The camera's frame height, when it's smaller than 1080: frames are made at 1080p and scaled down.
        var cameraHeight: Int?

        /// How far the person is across the room at frame `i`. Leaving, they're still for a second, walk off over
        /// one, and the room is empty after; entering is the reverse, with the empty room first.
        func shift(_ i: Int) -> Int {
            switch path {
            case .sway: return Int((Double(sway) * sin(2 * .pi * Double(i) / Double(period))).rounded())
            case .leave: return i < 30 ? 0 : min(Matchup.w, (i - 30) * Matchup.w / 30)
            case .enter: return i < 45 ? Matchup.w : max(0, Matchup.w - (i - 45) * Matchup.w / 30)
            }
        }

        func gain(_ i: Int) -> Float { exposure.map { i >= $0.frame ? $0.gain : 1 } ?? 1 }
    }

    struct Score {
        var edge = 0.0, full = 0.0, flicker = 0.0, frames = 0
        mutating func add(_ other: Score) {
            (edge, full, flicker, frames) = (edge + other.edge, full + other.full, flicker + other.flicker,
                                             frames + 1)
        }
        var line: String {
            let n = Double(max(frames, 1))
            return String(format: "%5.2f %5.2f %5.2f", edge / n * 100, full / n * 100, flicker / n * 100)
        }
    }

    /// `FASTBG_MATCHUP_SEQ` and `FASTBG_MATCHUP_ONLY` take comma lists that narrow the sequences (by substring) and
    /// the contenders. `FASTBG_SET` leans fastbg's auto picks to fixed values, as in `edgeSoftness=0.3,refine=3`.
    static let env = ProcessInfo.processInfo.environment
    static func list(_ name: String) -> [String]? {
        env[name].map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
    }

    static func run() async -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let office = Paths.fixture("room-office.jpg").flatMap(Pixels.image) else { return false }
        let room = Pixels.frame(office)
        let magentaURL = Pixels.solidPNG("magenta", r: 255, g: 0, b: 255)
        let magenta = Pixels.frame(Pixels.image(magentaURL)!)
        var people: [Person] = []
        for name in ["portrait-home", "portrait-brick", "studio"] {
            guard let photo = Paths.fixture("\(name).jpg").flatMap(Pixels.image).map({ Pixels.frame($0) }),
                  let vision = Matter().mask(for: photo, quality: .accurate).map(resample),
                  let native = nativeAlpha(photo, device: device, magenta: magenta) else {
                return expect(false, "matchup: couldn't cut out \(name)")
            }
            people.append(Person(name: name, photo: photo, truths: [("vision", vision), ("native", native)]))
        }
        var sequences: [Sequence] = []
        for person in people {
            for (truth, alpha) in person.truths {
                sequences.append(Sequence(name: "\(person.name) \(truth) sway", person: person.photo, alpha: alpha,
                                          room: room, sway: 60))
            }
        }
        let home = people[0]
        for (truth, alpha) in home.truths {
            sequences.append(Sequence(name: "home \(truth) still", person: home.photo, alpha: alpha, room: room))
            sequences.append(Sequence(name: "home \(truth) dim", person: home.photo, alpha: alpha, room: room,
                                      sway: 60, noise: 12))
        }
        let green = screenRoom(room, SIMD3(36, 163, 69)), blue = screenRoom(room, SIMD3(30, 70, 200))
        let desk = Paths.fixture("room-desk.jpg").flatMap(Pixels.image).map { Pixels.frame($0) } ?? room
        let studio = people[2]
        for (truth, alpha) in home.truths {
            sequences.append(Sequence(name: "home \(truth) green", person: home.photo, alpha: alpha, room: green,
                                      sway: 60))
            sequences.append(Sequence(name: "home \(truth) blue", person: home.photo, alpha: alpha, room: blue,
                                      sway: 60))
            sequences.append(Sequence(name: "home \(truth) green wave", person: home.photo, alpha: alpha,
                                      room: green, sway: 60, period: 15))
            sequences.append(Sequence(name: "home \(truth) wave", person: home.photo, alpha: alpha, room: room,
                                      sway: 60, period: 15))
            sequences.append(Sequence(name: "home \(truth) leave", person: home.photo, alpha: alpha, room: room,
                                      path: .leave))
            sequences.append(Sequence(name: "home \(truth) exposure", person: home.photo, alpha: alpha, room: room,
                                      sway: 60, exposure: (45, 1.25)))
            sequences.append(Sequence(name: "home \(truth) dark room", person: home.photo, alpha: alpha, room: desk,
                                      sway: 60))
        }
        for (truth, alpha) in studio.truths {
            sequences.append(Sequence(name: "studio \(truth) enter", person: studio.photo, alpha: alpha, room: room,
                                      path: .enter))
        }
        let brick = people[1]
        for ((truth, alpha), (_, other)) in zip(home.truths, brick.truths) {
            sequences.append(Sequence(name: "home \(truth) 720p", person: home.photo, alpha: alpha, room: room,
                                      sway: 60, cameraHeight: 720))
            sequences.append(Sequence(name: "two \(truth) people", person: home.photo, alpha: alpha, room: room,
                                      sway: 30, second: (brick.photo, other, 480)))
        }

        if let only = list("FASTBG_MATCHUP_SEQ") {
            sequences = sequences.filter { s in only.contains { s.name.contains($0) } }
        }
        let contenders = list("FASTBG_MATCHUP_ONLY") ?? ["native", "fastbg", "fastbg-vision", "basic"]
        var totals: [String: Score] = [:]
        print("      sequence                     | " + contenders.map { "\($0) edge full flicker" }
            .joined(separator: " | "))
        for sequence in sequences {
            var line = sequence.name.padding(toLength: 28, withPad: " ", startingAt: 0) + " |"
            for contender in contenders {
                let score = await run(sequence, contender, device: device, magenta: magenta, magentaURL: magentaURL)
                line += " " + score.line + " |"
                var total = totals[contender] ?? Score()
                total.edge += score.edge / Double(max(score.frames, 1))
                total.full += score.full / Double(max(score.frames, 1))
                total.flicker += score.flicker / Double(max(score.frames, 1))
                total.frames += 1
                totals[contender] = total
            }
            print("      " + line)
        }
        print("      " + "mean".padding(toLength: 28, withPad: " ", startingAt: 0) + " | "
              + contenders.map { totals[$0]!.line }.joined(separator: " | "))
        guard let native = totals["native"], let fastbg = totals["fastbg"] else { return true }
        return expect(fastbg.edge <= native.edge && fastbg.flicker <= native.flicker,
                      "matchup: fastbg's edges and flicker at or under native's")
    }

    /// One contender through one sequence, scored from frame 30 on, once both have settled.
    /// One contender over one plain background. Each sequence runs through two of them, over magenta and over
    /// green, and alpha comes from how far apart the two outputs are: exact whatever a contender does to the
    /// person's colours, which a key's unmix and despill, and the native effect's own touches, both do.
    final class Runner {
        let engine: Engine?
        let native: NativeEffect?
        let sink = CaptureSink()
        let clock = FakeClock()

        @MainActor
        init(_ contender: String, device: MTLDevice, background: CVPixelBuffer, url: URL) {
            if contender == "native" {
                native = NativeEffect(device: device, background: background, type: 64)
                engine = nil
                return
            }
            native = nil
            let e = Engine(sink: sink, usesCamera: false)
            let clock = clock
            e.clock = { clock.now }
            e.setSystemMatte(contender == "fastbg")
            if contender.hasPrefix("fastbg") {
                var offsets: [String: Float] = [:]
                for pair in Matchup.list("FASTBG_SET") ?? [] {
                    let parts = pair.split(separator: "=")
                    guard parts.count == 2, let v = Float(parts[1]), let knob = Tuning.knobs.first(where: {
                        $0.key == "tuning.\(parts[0])" }) else { continue }
                    offsets[knob.key] = v - Tuning()[keyPath: knob.path]
                }
                e.setOffsets(offsets)
                e.setAuto(true)
                e.setScreen(.any)
            } else {
                var t = Tuning()
                (t.smoothing, t.refine) = (0, 0)
                e.setAuto(false)
                e.setTuning(t)
                e.setScreen(.off)
            }
            e.show(.image(id: "bg", url: url))
            e.setLive(true)
            engine = e
        }

        @MainActor
        func render(_ frame: CVPixelBuffer, _ i: Int) async -> CVPixelBuffer? {
            if let native { return native.render(frame, at: Double(i) / 30) }
            guard let engine else { return nil }
            let before = sink.count
            await feed(engine, frame, at: Double(i) / 30, sink: sink)
            clock.advance(1.0 / 30)
            return sink.count > before ? sink.last : nil
        }
    }

    static let backgrounds = (a: SIMD3<Float>(255, 0, 255), b: SIMD3<Float>(0, 255, 0))

    /// `pixels` at another size, as BGRA, or itself when it's that size already.
    static func scaled(_ pixels: CVPixelBuffer, _ width: Int, _ height: Int) -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(pixels) != width || CVPixelBufferGetHeight(pixels) != height else { return pixels }
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, Pixels.pool(width, height), &out)
        guard let session, let out, VTPixelTransferSessionTransferImage(session, from: pixels, to: out) == noErr
        else { return pixels }
        return out
    }

    /// One contender through one sequence, scored from frame 30 on, once both have settled.
    static func run(_ s: Sequence, _ contender: String, device: MTLDevice, magenta: CVPixelBuffer,
                    magentaURL: URL) async -> Score {
        var score = Score()
        var previous: [Float]?
        var previousTruth: [UInt8]?
        var heat = [Float](repeating: 0, count: (w / step) * (h / step))
        let greenURL = Pixels.solidPNG("green", r: 0, g: 255, b: 0)
        let height = s.cameraHeight ?? h, width = height * 16 / 9
        let a = Runner(contender, device: device, background: scaled(magenta, width, height), url: magentaURL)
        let b = Runner(contender, device: device,
                       background: scaled(Pixels.frame(Pixels.image(greenURL)!), width, height), url: greenURL)
        for i in 0..<s.frames {
            let (full, truth) = compose(s, shift: s.shift(i), seed: UInt64(i + 1), gain: s.gain(i))
            let frame = scaled(full, width, height)
            guard let rawA = await a.render(frame, i), let rawB = await b.render(frame, i) else { continue }
            // Scored at 1080p, the size FastBG sends, so a contender working at the camera's size is scaled up.
            let (outA, outB) = (scaled(rawA, w, h), scaled(rawB, w, h))
            let alpha = triangulate(outA, outB, sampled: true)
            if i >= 30 {
                score.add(compare(alpha, truth, previous: previous, previousTruth: previousTruth))
                if let previous { for k in heat.indices { heat[k] += abs(alpha[k] - previous[k]) } }
            }
            if i == s.frames - 1, env["FASTBG_MATCHUP_HEAT"] != nil {
                let slug = s.name.replacingOccurrences(of: " ", with: "-")
                saveGray(alpha, w / step, h / step, "alpha-\(slug)-\(contender).png")
                saveGray(truth.enumerated().compactMap { k, v in
                    (k / w) % step == 0 && (k % w) % step == 0 ? Float(v) / 255 : nil
                }, w / step, h / step, "truth-\(s.name.replacingOccurrences(of: " ", with: "-")).png")
            }
            if i == s.frames - 1, s.name.hasPrefix("home") || s.name.contains("sway") {
                Pixels.save(outA, "matchup-\(s.name.replacingOccurrences(of: " ", with: "-"))-\(contender).png")
            }
            (previous, previousTruth) = (alpha, truth)
        }
        a.engine?.setLive(false)
        b.engine?.setLive(false)
        if env["FASTBG_MATCHUP_HEAT"] != nil {
            saveGray(heat.map { min($0 / 3, 1) }, w / step, h / step,
                     "heat-\(s.name.replacingOccurrences(of: " ", with: "-"))-\(contender).png")
        }
        return score
    }

    /// Edge error within 8 px of the true outline, error over the whole frame, and change between frames where
    /// the truth didn't change.
    static func compare(_ alpha: [Float], _ truth: [UInt8], previous: [Float]?, previousTruth: [UInt8]?) -> Score {
        let gw = w / step, gh = h / step
        var edge = 0.0, edgeN = 0, full = 0.0, flicker = 0.0, flickerN = 0
        for gy in 0..<gh {
            for gx in 0..<gw {
                let i = gy * gw + gx
                let t = Float(truth[(gy * step) * w + gx * step]) / 255
                let error = Double(abs(alpha[i] - t))
                full += error
                if nearOutline(truth, gx * step, gy * step) {
                    edge += error
                    edgeN += 1
                }
                if let previous, let previousTruth,
                   previousTruth[(gy * step) * w + gx * step] == truth[(gy * step) * w + gx * step] {
                    flicker += Double(abs(alpha[i] - previous[i]))
                    flickerN += 1
                }
            }
        }
        return Score(edge: edge / Double(max(edgeN, 1)), full: full / Double(gw * gh),
                     flicker: flicker / Double(max(flickerN, 1)), frames: 1)
    }

    static func nearOutline(_ truth: [UInt8], _ x: Int, _ y: Int) -> Bool {
        func person(_ x: Int, _ y: Int) -> Bool { truth[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))] >= 128 }
        let p = person(x, y)
        return person(x - 8, y) != p || person(x + 8, y) != p || person(x, y - 8) != p || person(x, y + 8) != p
    }

    /// Alpha from a frame composited over magenta: how far each pixel went from magenta toward the camera's own
    /// colour there. Exact for fastbg, which puts camera pixels over the background as they are.
    static func estimate(_ out: CVPixelBuffer, camera: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(out, .readOnly)
        CVPixelBufferLockBaseAddress(camera, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(camera, .readOnly)
            CVPixelBufferUnlockBaseAddress(out, .readOnly)
        }
        let o = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let c = CVPixelBufferGetBaseAddress(camera)!.assumingMemoryBound(to: UInt8.self)
        let oRow = CVPixelBufferGetBytesPerRow(out), cRow = CVPixelBufferGetBytesPerRow(camera)
        var alpha = [Float](repeating: 0, count: (w / step) * (h / step))
        let m = SIMD3<Float>(255, 0, 255)
        let of = CVPixelBufferGetPixelFormatType(out), cf = CVPixelBufferGetPixelFormatType(camera)
        for gy in 0..<(h / step) {
            for gx in 0..<(w / step) {
                let got = SIMD3<Float>(Pixels.pixel(o, oRow, of, gx * step, gy * step)) - m
                let cam = SIMD3<Float>(Pixels.pixel(c, cRow, cf, gx * step, gy * step)) - m
                let d = (cam * cam).sum()
                alpha[gy * (w / step) + gx] = d < 900 ? 1 : min(max((got * cam).sum() / d, 0), 1)
            }
        }
        return alpha
    }

    /// The person moved `shift` px across the room, with noise of up to ±`noise` levels, and their true alpha.
    static func compose(_ s: Sequence, shift: Int, seed: UInt64, gain: Float = 1) -> (CVPixelBuffer, [UInt8]) {
        let out = Pixels.pool(w, h)
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, out, &pb)
        let frame = pb!
        var truth = [UInt8](repeating: 0, count: w * h)
        let buffers = [frame, s.person, s.room] + (s.second.map { [$0.person] } ?? [])
        for b in buffers { CVPixelBufferLockBaseAddress(b, b === frame ? [] : .readOnly) }
        defer { for b in buffers { CVPixelBufferUnlockBaseAddress(b, b === frame ? [] : .readOnly) } }
        let f = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let p = CVPixelBufferGetBaseAddress(s.person)!.assumingMemoryBound(to: UInt8.self)
        let r = CVPixelBufferGetBaseAddress(s.room)!.assumingMemoryBound(to: UInt8.self)
        let fRow = CVPixelBufferGetBytesPerRow(frame), pRow = CVPixelBufferGetBytesPerRow(s.person)
        let rRow = CVPixelBufferGetBytesPerRow(s.room)
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        let span = UInt64(2 * s.noise + 1)
        for y in 0..<h {
            for x in 0..<w {
                let sx = x - shift + (s.second?.offset ?? 0) * -1
                let a = (0..<w).contains(sx) ? Int(s.alpha[y * w + sx]) : 0
                var a2 = 0, sx2 = 0
                if let second = s.second {
                    sx2 = x - second.offset
                    a2 = (0..<w).contains(sx2) ? Int(second.alpha[y * w + sx2]) : 0
                }
                truth[y * w + x] = UInt8(a + (255 - a) * a2 / 255)
                for ch in 0..<3 {
                    let fg = (0..<w).contains(sx) ? Int(p[y * pRow + sx * 4 + ch]) : 0
                    var bg = Int(r[y * rRow + x * 4 + ch])
                    if let second = s.second, a2 > 0 {
                        let sp = CVPixelBufferGetBaseAddress(second.person)!.assumingMemoryBound(to: UInt8.self)
                        let fg2 = Int(sp[y * CVPixelBufferGetBytesPerRow(second.person) + sx2 * 4 + ch])
                        bg = (fg2 * a2 + bg * (255 - a2)) / 255
                    }
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    let v = Int(Float((fg * a + bg * (255 - a)) / 255) * gain) + Int(state % span) - s.noise
                    f[y * fRow + x * 4 + ch] = UInt8(max(0, min(255, v)))
                }
                f[y * fRow + x * 4 + 3] = 255
            }
        }
        return (frame, truth)
    }

    static func saveGray(_ values: [Float], _ width: Int, _ height: Int, _ name: String) {
        var bytes = values.map { UInt8(min(max($0, 0), 1) * 255) }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let image = ctx?.makeImage() else { return }
        Pixels.writePNG(image, to: Paths.output(name))
    }

    /// Vision's 4:3 mask stretched over the 16:9 frame, as it's used.
    static func resample(_ mask: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = (Float(y) + 0.5) * Float(mh) / Float(h) - 0.5
            let y0 = max(0, min(mh - 1, Int(fy.rounded(.down)))), y1 = min(mh - 1, y0 + 1)
            let ty = min(max(fy - Float(y0), 0), 1)
            for x in 0..<w {
                let fx = (Float(x) + 0.5) * Float(mw) / Float(w) - 0.5
                let x0 = max(0, min(mw - 1, Int(fx.rounded(.down)))), x1 = min(mw - 1, x0 + 1)
                let tx = min(max(fx - Float(x0), 0), 1)
                let top = Float(base[y0 * row + x0]) * (1 - tx) + Float(base[y0 * row + x1]) * tx
                let bottom = Float(base[y1 * row + x0]) * (1 - tx) + Float(base[y1 * row + x1]) * tx
                out[y * w + x] = UInt8((top * (1 - ty) + bottom * ty).rounded())
            }
        }
        return out
    }

    /// The native effect's cut-out of a still, triangulated from two runs of it after they've settled.
    static func nativeAlpha(_ photo: CVPixelBuffer, device: MTLDevice, magenta: CVPixelBuffer) -> [UInt8]? {
        let green = Pixels.frame(Pixels.image(Pixels.solidPNG("green", r: 0, g: 255, b: 0))!)
        guard let a = NativeEffect(device: device, background: magenta, type: 64),
              let b = NativeEffect(device: device, background: green, type: 64) else { return nil }
        var outA: CVPixelBuffer?, outB: CVPixelBuffer?
        for i in 0..<20 {
            outA = a.render(photo, at: Double(i) / 30)
            outB = b.render(photo, at: Double(i) / 30)
        }
        guard let outA, let outB else { return nil }
        return triangulate(outA, outB, sampled: false).map { UInt8(($0 * 255).rounded()) }
    }

    /// Alpha from the same frame composited over the two backgrounds: the output moves with the background only
    /// where the background shows, by exactly 1 - alpha of the gap between them.
    static func triangulate(_ a: CVPixelBuffer, _ b: CVPixelBuffer, sampled: Bool) -> [Float] {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
        }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        let by = sampled ? step : 1
        let gap = backgrounds.a - backgrounds.b, norm = (gap * gap).sum()
        var alpha = [Float](repeating: 0, count: (w / by) * (h / by))
        let fa = CVPixelBufferGetPixelFormatType(a), fb = CVPixelBufferGetPixelFormatType(b)
        for gy in 0..<(h / by) {
            for gx in 0..<(w / by) {
                let d = SIMD3<Float>(Pixels.pixel(pa, ra, fa, gx * by, gy * by)
                                     &- Pixels.pixel(pb, rb, fb, gx * by, gy * by))
                alpha[gy * (w / by) + gx] = min(max(1 - (d * gap).sum() / norm, 0), 1)
            }
        }
        return alpha
    }

    /// The office with a chroma screen of `colour` hung behind the person, lit brighter in the middle, and the room
    /// showing past its edges.
    static func screenRoom(_ room: CVPixelBuffer, _ colour: SIMD3<Float>) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, Pixels.pool(w, h), &pb)
        let out = pb!
        CVPixelBufferLockBaseAddress(out, [])
        CVPixelBufferLockBaseAddress(room, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(room, .readOnly)
            CVPixelBufferUnlockBaseAddress(out, [])
        }
        let o = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let r = CVPixelBufferGetBaseAddress(room)!.assumingMemoryBound(to: UInt8.self)
        let oRow = CVPixelBufferGetBytesPerRow(out), rRow = CVPixelBufferGetBytesPerRow(room)
        for y in 0..<h {
            for x in 0..<w {
                let inScreen = x > w / 5 && x < w * 4 / 5 && y > h / 20
                let dx = Float(x - w / 2) / Float(w), dy = Float(y - h / 2) / Float(h)
                let light = 1.05 - 0.6 * (dx * dx + dy * dy)
                let lit = colour * light
                for ch in 0..<3 {
                    let v = inScreen ? [lit.z, lit.y, lit.x][ch] : Float(r[y * rRow + x * 4 + ch])
                    o[y * oRow + x * 4 + ch] = UInt8(max(0, min(255, v)))
                }
                o[y * oRow + x * 4 + 3] = 255
            }
        }
        return out
    }
}
