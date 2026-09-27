import CoreVideo
import Foundation
import Metal
import Vision

/// Vision's subject lifting on the fixtures: what it costs and what it takes in. Vision's person mask drops anything
/// the person holds or has in front of them, like a mic on a boom arm, which the native effect keeps. Dev-only.
@MainActor
enum SubjectProbe {
    static func run() async -> Bool {
        guard let studio = Paths.fixture("studio.jpg").flatMap(Pixels.image).map({ Pixels.frame($0) }),
              let office = Paths.fixture("room-office.jpg").flatMap(Pixels.image).map({ Pixels.frame($0) }),
              let home = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image).map({ Pixels.frame($0) }),
              let alpha = Paths.fixture("green-alpha.png").flatMap(Pixels.gray) else { return false }
        // The home portrait in front of the office chair, the way the matchup builds it.
        let seat = Matchup.compose(Matchup.Sequence(name: "", person: home, alpha: alpha.values, room: office),
                                   shift: 0, seed: 1).0
        for (name, frame) in [("studio", studio), ("home-in-office", seat)] {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
            var times: [Double] = []
            var mask: CVPixelBuffer?
            for _ in 0..<4 {
                let start = CFAbsoluteTimeGetCurrent()
                try? handler.perform([request])
                if let result = request.results?.first {
                    mask = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                }
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let size = mask.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none"
            print(String(format: "      %@: %@ mask, %.0f ms first, %.0f ms after", name, size, times[0],
                         times.dropFirst().reduce(0, +) / 3))
            if let mask { save(mask, "subject-\(name).png") }
        }
        // Vision's own levels on changing frames, so nothing is served from a cache.
        let frames = (0..<6).map { Matchup.compose(Matchup.Sequence(name: "", person: home, alpha: alpha.values,
                                                                    room: office), shift: $0 * 7, seed: 1).0 }
        for quality in [Matter.Quality.balanced, .accurate] {
            let matter = Matter()
            _ = matter.mask(for: frames[0], quality: quality)
            let cpu0 = PipelineChecks.cpuSeconds(), start = CFAbsoluteTimeGetCurrent()
            for frame in frames.dropFirst() { _ = matter.mask(for: frame, quality: quality) }
            let wall = (CFAbsoluteTimeGetCurrent() - start) / 5 * 1000
            let cpu = (PipelineChecks.cpuSeconds() - cpu0) / 5 * 1000
            print(String(format: "      Vision %@: %.1f ms a frame, %.1f ms of it CPU", "\(quality)", wall, cpu))
        }
        for lean in [false, true] {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let native = NativeEffect(device: device, background: frames[0], type: 64, lean: lean) else {
                print("      native lean \(lean): didn't start")
                continue
            }
            _ = native.render(frames[0], at: 0)
            let cpu0 = PipelineChecks.cpuSeconds(), start = CFAbsoluteTimeGetCurrent()
            for (i, frame) in frames.dropFirst().enumerated() { _ = native.render(frame, at: Double(i + 1) / 30) }
            let wall = (CFAbsoluteTimeGetCurrent() - start) / 5 * 1000
            let cpu = (PipelineChecks.cpuSeconds() - cpu0) / 5 * 1000
            var mean = 0.0
            if let matte = native.matte {
                CVPixelBufferLockBaseAddress(matte, .readOnly)
                let base = CVPixelBufferGetBaseAddress(matte)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(matte)
                for y in stride(from: 0, to: 1080, by: 8) { for x in stride(from: 0, to: 1920, by: 8) {
                    mean += Double(base[y * row + x]) } }
                CVPixelBufferUnlockBaseAddress(matte, .readOnly)
                let samples: Double = (1080 / 8) * (1920 / 8)
                mean /= samples * 255
            }
            print(String(format: "      native lean %@: %.1f ms a frame, %.1f ms of it CPU, matte covers %.0f%%",
                         "\(lean)", wall, cpu, mean * 100))
        }
        return true
    }

    /// A OneComponent32Float or 8-bit mask as a grayscale PNG.
    static func save(_ mask: CVPixelBuffer, _ name: String) {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        let base = CVPixelBufferGetBaseAddress(mask)!
        let type = CVPixelBufferGetPixelFormatType(mask)
        var bytes = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float
                switch type {
                case kCVPixelFormatType_OneComponent32Float:
                    v = base.load(fromByteOffset: y * row + x * 4, as: Float.self)
                case kCVPixelFormatType_OneComponent16Half:
                    v = Float(Float16(bitPattern: base.load(fromByteOffset: y * row + x * 2, as: UInt16.self)))
                default: v = Float(base.load(fromByteOffset: y * row + x, as: UInt8.self)) / 255
                }
                bytes[y * w + x] = UInt8(min(max(v, 0), 1) * 255)
            }
        }
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let image = ctx?.makeImage() else { return }
        Pixels.writePNG(image, to: Paths.output(name))
        print("      wrote \(Paths.output(name).path)")
    }
}
