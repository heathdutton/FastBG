import CoreVideo
import Foundation
import Metal

/// The key alone over the full green screen fixture, with fresh noise in every frame the way a webcam's sensor adds
/// it. Pixels along the hair edge should hold still with the key's denoise and smoothing on, and the key should stay
/// as clean as it is without them.
@MainActor
enum KeyJitterCheck {
    static func run() async -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let photo = Paths.fixture("green-full.png").flatMap(Pixels.image),
              let alphaURL = Paths.fixture("green-alpha.png"), let alpha = Pixels.gray(alphaURL),
              let background = try? StillSource.load(Pixels.solidPNG("magenta", r: 255, g: 0, b: 255), device: device)
        else { return false }
        let clean = Pixels.frame(photo)
        guard let key = GreenScreen.calibrate(frame: clean, mask: mask(alpha)) else {
            return expect(false, "key jitter: no key from the fixture")
        }
        // Part person, part screen: where the shimmer shows.
        var edge: [(Int, Int)] = []
        for y in stride(from: 0, to: alpha.height, by: 2) {
            for x in stride(from: 0, to: alpha.width, by: 2) {
                if (25...230).contains(alpha.values[y * alpha.width + x]) { edge.append((x, y)) }
            }
        }
        let frames = (0..<16).map { noisy(clean, seed: UInt64($0 + 1)) }

        func render(_ tuning: Tuning) async -> (swing: Double, last: CVPixelBuffer?) {
            guard let compositor = try? Compositor(device: device) else { return (0, nil) }
            var previous: [SIMD3<Int>]?
            var swings: [Double] = []
            var last: CVPixelBuffer?
            for (i, frame) in frames.enumerated() {
                let done = Flag()
                let out = OutBox()
                let job = Compositor.Job(camera: frame, mask: nil, key: key, from: .texture(background), to: nil,
                                         mix: 0, tuning: tuning)
                compositor.render(job) { pixels in
                    out.set(pixels)
                    done.set(true)
                }
                for _ in 0..<500 where done.value == nil { await sleep(0.002) }
                guard let pixels = out.value else { return (0, nil) }
                let values = colours(pixels, edge)
                if i >= 6, let previous {
                    let total = zip(values, previous).reduce(0) { sum, pair in
                        let d = pair.0 &- pair.1
                        return sum + abs(d.x) + abs(d.y) + abs(d.z)
                    }
                    swings.append(Double(total) / Double(values.count * 3))
                }
                previous = values
                last = pixels
            }
            return (swings.reduce(0, +) / Double(max(swings.count, 1)), last)
        }

        var off = Tuning()
        off.keyDenoise = 0
        off.keySmoothing = 0
        let before = await render(off)
        let after = await render(Tuning())
        print(String(format: "      %d edge pixels, mean swing per frame: %.2f levels off, %.2f with the defaults",
                     edge.count, before.swing, after.swing))
        for denoise: Float in [0, 0.5, 1.5] {
            var line = "      denoise \(denoise):"
            for smoothing: Float in [0, 0.5, 0.8] {
                var t = Tuning()
                t.keyDenoise = denoise
                t.keySmoothing = smoothing
                line += String(format: "  smooth %.1f %.2f", smoothing, await render(t).swing)
            }
            print(line)
        }
        // Auto's noise reading off two of the noisy frames. Uniform noise of ±8 levels per channel is a standard
        // deviation of about 4.9 levels, 0.0128 in luma and 0.0127 in chroma.
        guard let noise = AutoTune.noise(AutoTune.sample(frames[0]), AutoTune.sample(frames[1])) else {
            return expect(false, "key jitter: no noise reading")
        }
        let auto = AutoTune.tuning(for: noise, flicker: 0)
        let tuned = await render(auto)
        print(String(format: "      auto: noise %.4f luma, %.4f chroma; denoise %.2f, key smooth %.2f, motion %.3f, "
                     + "detail %.2f, swing %.2f", noise.luma, noise.chroma, auto.keyDenoise, auto.keySmoothing,
                     auto.motion, auto.refineDetail, tuned.swing))
        guard let out = after.last, let s = PipelineChecks.score(out, alpha: alphaURL, screen: nil, halo: 16) else {
            return expect(false, "key jitter: no output")
        }
        Pixels.save(out, "key-jitter.png")
        var ok = expect(after.swing < before.swing * 0.5, String(format: "key jitter: edges swing %.0f%% as much",
                                                                  after.swing / before.swing * 100))
        ok = expect(abs(noise.luma - 0.0128) < 0.003 && abs(noise.chroma - 0.0127) < 0.003,
                    "key jitter: auto reads the noise it was given") && ok
        ok = expect(tuned.swing <= after.swing * 1.1, String(format: "key jitter: auto's tuning swings %.2f",
                                                             tuned.swing)) && ok
        ok = expect(s.personKept > 0.95, String(format: "key jitter: %.1f%% of the person kept", s.personKept * 100))
            && ok
        ok = expect(s.screenReplaced > 0.97, String(format: "key jitter: %.1f%% of the screen keyed out",
                                                    s.screenReplaced * 100)) && ok
        return ok
    }

    /// Green left on the person, by despill setting, on the fixture with spill baked into their edges: how far green
    /// rises above the brighter of red and blue, which the gentle half takes out, and above their average, which
    /// the strong half goes after.
    static func despill() async -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let photo = Paths.fixture("green-full.png").flatMap(Pixels.image),
              let alpha = Paths.fixture("green-alpha.png").flatMap(Pixels.gray),
              let background = try? StillSource.load(Pixels.solidPNG("magenta", r: 255, g: 0, b: 255), device: device)
        else { return false }
        let frame = Pixels.frame(photo)
        guard let key = GreenScreen.calibrate(frame: frame, mask: mask(alpha)) else { return expect(false, "no key") }
        var points: [(Int, Int)] = []
        for y in stride(from: 0, to: alpha.height, by: 3) {
            for x in stride(from: 0, to: alpha.width, by: 3) where alpha.values[y * alpha.width + x] > 128 {
                points.append((x, y))
            }
        }
        var spill: [Float: Double] = [:], strong: [Float: Double] = [:]
        for amount: Float in [0, 1, 2] {
            guard let compositor = try? Compositor(device: device) else { return false }
            var t = Tuning()
            t.despill = amount
            let done = Flag(), out = OutBox()
            compositor.render(Compositor.Job(camera: frame, mask: nil, key: key, from: .texture(background), to: nil,
                                             mix: 0, tuning: t)) { out.set($0); done.set(true) }
            for _ in 0..<500 where done.value == nil { await sleep(0.002) }
            guard let pixels = out.value else { return false }
            let c = colours(pixels, points)
            spill[amount] = c.reduce(0.0) { $0 + Double(max(0, $1.y - max($1.x, $1.z))) } / Double(c.count)
            strong[amount] = c.reduce(0.0) { $0 + Double(max(0, 2 * $1.y - $1.x - $1.z)) / 2 } / Double(c.count)
            Pixels.save(pixels, "despill-\(Int(amount)).png")
        }
        print(String(format: "      green above the brighter of red and blue: %.2f off, %.2f at 1, %.2f at 2",
                     spill[0]!, spill[1]!, spill[2]!))
        print(String(format: "      green above their average: %.2f off, %.2f at 1, %.2f at 2", strong[0]!, strong[1]!,
                     strong[2]!))
        return expect(spill[1]! < spill[0]! && strong[2]! < strong[1]!, "despill: each step takes more green out")
    }

    /// A Vision-sized mask from the fixture's true alpha, for calibration to tell screen from person.
    static func mask(_ alpha: (width: Int, height: Int, values: [UInt8])) -> CVPixelBuffer {
        let w = 512, h = 384
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        let pixels = pb!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<h {
            for x in 0..<w {
                base[y * row + x] = alpha.values[(y * alpha.height / h) * alpha.width + x * alpha.width / w]
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// A copy of `frame` with up to ±8 levels of noise per channel, about what a webcam shows indoors.
    static func noisy(_ frame: CVPixelBuffer, seed: UInt64) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, Pixels.pool(w, h), &pb)
        let out = pb!
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        let src = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let dst = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let srcRow = CVPixelBufferGetBytesPerRow(frame), dstRow = CVPixelBufferGetBytesPerRow(out)
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    let v = Int(src[y * srcRow + x * 4 + c]) + Int(state % 17) - 8
                    dst[y * dstRow + x * 4 + c] = UInt8(max(0, min(255, v)))
                }
                dst[y * dstRow + x * 4 + 3] = 255
            }
        }
        return out
    }

    static func colours(_ pixels: CVPixelBuffer, _ points: [(Int, Int)]) -> [SIMD3<Int>] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let format = CVPixelBufferGetPixelFormatType(pixels)
        return points.map { x, y in Pixels.pixel(base, row, format, x, y) }
    }
}
