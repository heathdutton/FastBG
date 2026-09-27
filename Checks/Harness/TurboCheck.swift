import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// Turbo's pacer, fed in real time by a camera that's fallen to 22.8 fps: a head-sized oval of a portrait swaying
/// over a still background, as a dim BRIO sends it. Every frame out is scored against the true picture at its moment,
/// beside what repeating the nearest camera frame would have shown.
@MainActor
enum TurboCheck {
    static let fps = 22.8

    /// Everything the pacer sent, with when.
    final class Recorder: FrameSink, @unchecked Sendable {
        private let lock = NSLock()
        private var got: [(pixels: CVPixelBuffer, time: Double, sent: Double)] = []
        func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
            let sent = CACurrentMediaTime()
            lock.withLock { got.append((pixelBuffer, time.seconds, sent)) }
        }
        var frames: [(pixels: CVPixelBuffer, time: Double, sent: Double)] { lock.withLock { got } }
    }

    static func run() async -> Bool {
        guard let scene = Scene() else { return expect(false, "turbo: couldn't load the fixtures") }
        var ok = await passThrough(scene)
        ok = await paced(scene) && ok
        return ok
    }

    /// A camera at 30 fps goes straight out, with no delay.
    static func passThrough(_ scene: Scene) async -> Bool {
        let recorder = Recorder()
        let pacer = Pacer(sink: recorder)
        pacer.setOn(true)
        let sent = await feed(pacer, scene: scene, fps: 30, seconds: 1.5)
        let frames = recorder.frames
        let late = frames.map { $0.sent - $0.time }.max() ?? 1
        return expect(frames.count == sent && late < 0.03,
                      "turbo: a 30 fps camera goes straight out, \(frames.count) of \(sent), at most "
                      + "\(Int(late * 1000)) ms after capture")
    }

    static func paced(_ scene: Scene) async -> Bool {
        let recorder = Recorder()
        let pacer = Pacer(sink: recorder)
        pacer.setOn(true)
        let inputs = await feed(pacer, scene: scene, fps: fps, seconds: 6)
        let timing = pacer.timing()
        print(String(format: "      %.0f ms behind, %.1f ms a fill-in, %d late", timing.delay * 1000,
                     timing.fill * 1000, timing.late))
        pacer.setOn(false)
        // The last 3 s, well after the session to fill frames has started.
        let all = recorder.frames
        guard let end = all.last?.sent else { return expect(false, "turbo: nothing came out") }
        let steady = all.filter { $0.sent > end - 3 }
        let gaps = zip(steady.dropFirst(), steady).map { $0.sent - $1.sent }
        let rate = Double(gaps.count) / gaps.reduce(0, +)
        let jitter = gaps.map { abs($0 - 1 / 30) }.max() ?? 1
        let behind = steady.map { $0.sent - $0.time }.reduce(0, +) / Double(max(steady.count, 1))
        var ok = expect(abs(rate - 30) < 0.5 && jitter < 0.006,
                        String(format: "turbo: %.1f fps out of %.1f, gaps within %.1f ms of 33.3", rate, fps,
                               jitter * 1000))
        ok = expect(behind < 0.12, "turbo: frames go out \(Int(behind * 1000)) ms after their moment") && ok

        // Each filled-in frame against the truth at its moment, beside the camera frame repeating would have sent.
        var filled = 0, error = 0.0, repeated = 0.0, scored = 0
        for frame in steady where !scene.sent.contains(where: { $0 === frame.pixels }) {
            filled += 1
            guard filled % 2 == 0, let truth = scene.frame(at: frame.time),
                  let camera = scene.frame(at: scene.inputTime(nearest: frame.time)) else { continue }
            let t = Scene.greens(truth)
            error += Scene.difference(Scene.greens(frame.pixels), t)
            repeated += Scene.difference(Scene.greens(camera), t)
            scored += 1
        }
        let share = Double(filled) / Double(max(steady.count, 1))
        ok = expect(share > 0.5, "turbo: \(filled) of \(steady.count) frames filled in, from \(inputs) camera frames")
            && ok
        let (e, r) = (error / Double(max(scored, 1)), repeated / Double(max(scored, 1)))
        ok = expect(e < r / 3, String(format: "turbo: filled-in frames off the true picture by %.2f, against %.2f "
                                         + "repeating frames", e, r)) && ok
        return ok
    }

    /// Sends the scene as a camera would, each frame a few ms after its capture time. Returns how many it sent.
    static func feed(_ pacer: Pacer, scene: Scene, fps: Double, seconds: Double) async -> Int {
        let start = CACurrentMediaTime() + 0.05
        scene.start = start
        scene.fps = fps
        var i = 0
        while Double(i) / fps < seconds {
            let at = start + Double(i) / fps
            guard let frame = scene.frame(at: at) else { break }
            let wait = at + 0.008 - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            scene.sent.append(frame)
            pacer.send(frame, time: CMTime(seconds: at, preferredTimescale: 1_000_000_000))
            i += 1
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return i
    }

    /// A portrait's head-sized oval swaying 300 px either side over a studio, drawn at any moment.
    final class Scene {
        let background: CIImage, person: CIImage, oval: CIImage
        let context = CIContext()
        var transfer: VTPixelTransferSession?
        var start = 0.0, fps = 30.0
        var sent: [CVPixelBuffer] = []
        static let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        init?() {
            func fill(_ name: String) -> CIImage? {
                guard let url = Paths.fixture(name), let image = CIImage(contentsOf: url) else { return nil }
                let s = max(1920 / image.extent.width, 1080 / image.extent.height)
                let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
                return scaled.transformed(by: CGAffineTransform(translationX: -(scaled.extent.width - 1920) / 2,
                                                                y: -(scaled.extent.height - 1080) / 2))
                    .cropped(to: Self.full)
            }
            guard let background = fill("studio.jpg"), let person = fill("portrait-brick.jpg"),
                  let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 330, "inputRadius1": 336,
                    "inputColor0": CIColor.white, "inputColor1": CIColor.clear])?.outputImage else { return nil }
            (self.background, self.person) = (background, person)
            oval = gradient.transformed(by: CGAffineTransform(scaleX: 0.8, y: 1.2))
                .transformed(by: CGAffineTransform(translationX: 960, y: 540))
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        }

        func x(_ t: Double) -> Double { 300 * sin(2 * .pi * (t - start) / 1.5) }

        func inputTime(nearest t: Double) -> Double {
            start + ((t - start) * fps).rounded() / fps
        }

        /// In the camera's own format, as the compositor sends it.
        func frame(at t: Double) -> CVPixelBuffer? {
            let move = CGAffineTransform(translationX: x(t), y: 0)
            let image = person.transformed(by: move).applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": background, "inputMaskImage": oval.transformed(by: move),
            ]).cropped(to: Self.full)
            var bgra: CVPixelBuffer?, out: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, attrs, &bgra)
            CVPixelBufferCreate(nil, 1920, 1080, FastbgCamera.pixelFormat, attrs, &out)
            guard let bgra, let out, let transfer else { return nil }
            context.render(image, to: bgra, bounds: Self.full, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return VTPixelTransferSessionTransferImage(transfer, from: bgra, to: out) == noErr ? out : nil
        }

        /// Every fourth pixel's green, 0 to 1023.
        static func greens(_ pixels: CVPixelBuffer) -> [Float] {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
            let row = CVPixelBufferGetBytesPerRow(pixels)
            var out: [Float] = []
            out.reserveCapacity(480 * 270)
            for y in stride(from: 0, to: 1080, by: 4) {
                for x in stride(from: 0, to: 1920, by: 4) {
                    out.append(Float((base.load(fromByteOffset: y * row + x * 4, as: UInt32.self) >> 10) & 0x3FF))
                }
            }
            return out
        }

        /// Mean difference, in 8-bit steps.
        static func difference(_ a: [Float], _ b: [Float]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            return Double(zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(a.count) / 4
        }
    }
}
