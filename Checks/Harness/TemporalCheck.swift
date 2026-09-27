import CoreVideo
import Foundation
import Metal

/// The temporal mask filter on its own: a patch of mask that flips between person and background every frame, the
/// way a chair back does, over a camera image that doesn't change. Then the same with the camera changing there.
@MainActor
enum TemporalCheck {
    static func run() async -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(), let photo = Paths.fixture("portrait-home.jpg")
                .flatMap(Pixels.image) else { return false }
        let still = Pixels.frame(photo)
        let bg = Pixels.solidPNG("magenta", r: 255, g: 0, b: 255)
        let texture = try? StillSource.load(bg, device: device)
        guard let texture else { return expect(false, "temporal: no background texture") }
        // The patch sits over the top-left background, where the real mask is 0: a chair Vision can't decide on.
        let on = mask(patch: 255), off = mask(patch: 0)
        func run(smoothing: Float, frames: [CVPixelBuffer]) async -> [Int] {
            guard let compositor = try? Compositor(device: device) else { return [] }
            var reds: [Int] = []
            for (i, frame) in frames.enumerated() {
                let done = Flag()
                let out = OutBox()
                var tuning = Tuning()
                tuning.smoothing = smoothing
                let job = Compositor.Job(camera: frame, mask: i % 2 == 0 ? on : off, key: nil,
                                         from: .texture(texture), to: nil, mix: 0, tuning: tuning)
                compositor.render(job) { pixels in
                    out.set(pixels)
                    done.set(true)
                }
                for _ in 0..<200 where done.value == nil { await sleep(0.002) }
                // Red at the patch: 255 is magenta (background), lower is the camera showing through.
                if let pixels = out.value { reds.append(Pixels.rgb(pixels, 200, 150).x) }
            }
            return reds
        }
        let flicker = await run(smoothing: 0, frames: Array(repeating: still, count: 12))
        let smoothed = await run(smoothing: 0.75, frames: Array(repeating: still, count: 12))
        // Real movement: the camera image changes at the patch every frame, so the mask should be taken as is.
        let shifted = Pixels.frame(photo, shift: 200)
        let moving = (0..<12).map { $0 % 2 == 0 ? still : shifted }
        let followed = await run(smoothing: 0.75, frames: moving)
        func swing(_ reds: [Int]) -> Int { zip(reds.dropFirst(4), reds.dropFirst(5)).map { abs($0 - $1) }.max() ?? 0 }
        print("      smoothing off: \(flicker.suffix(6))")
        print("      smoothing 0.75, still: \(smoothed.suffix(6))")
        print("      smoothing 0.75, moving: \(followed.suffix(6))")
        var ok = expect(swing(flicker) > 60, "temporal: with smoothing off the patch flickers, swing \(swing(flicker))")
        ok = expect(swing(smoothed) < 10, "temporal: smoothed over a still image it settles, swing \(swing(smoothed))")
            && ok
        ok = expect(swing(followed) > 60, "temporal: where the image moves it follows at once, swing "
                    + "\(swing(followed))") && ok
        return ok
    }

    /// A 512x384 OneComponent8 mask, 0 everywhere but a 64x48 patch near the top left.
    static func mask(patch: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 512, 384, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        let pixels = pb!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<384 {
            for x in 0..<512 { base[y * row + x] = (32..<96).contains(x) && (32..<80).contains(y) ? patch : 0 }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }
}

final class OutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: CVPixelBuffer?
    var value: CVPixelBuffer? { lock.withLock { pixels } }
    func set(_ p: CVPixelBuffer) { lock.withLock { pixels = p } }
}
