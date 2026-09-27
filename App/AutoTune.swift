import CoreVideo
import Foundation
import simd

/// Auto mode's tuning, picked from what the camera shows. The rest of the knobs sit at the values the harness found
/// best.
///
/// - Noise rises as the light drops. It makes edges shimmer, and the smoothers have to tell it from movement.
/// - Flicker is Vision changing its mind about something that isn't moving, like a chair.
enum AutoTune {
    /// Frame-to-frame noise of one pixel, 0...1: in brightness, and in chroma as the key measures it.
    struct Noise: Equatable, Sendable {
        var luma: Float
        var chroma: Float

        /// About what a webcam shows indoors, used till the first measurement.
        static let typical = Noise(luma: 0.015, chroma: 0.01)

        func eased(to other: Noise, _ t: Float) -> Noise {
            Noise(luma: luma + (other.luma - luma) * t, chroma: chroma + (other.chroma - chroma) * t)
        }
    }

    /// What auto picked from, for the panel to show.
    struct Readings: Equatable, Sendable {
        var noise: Noise
        /// Per mille of still spots whose mask crossed the detection level between two masks in a row.
        var flicker: Float
    }

    /// The knobs `tuning(for:flicker:matte:)` sets, from its readings or for macOS's matte, rather than leaving at
    /// their defaults. The panel shows them as Autocalibrate's.
    static let steered: Set<String> = ["tuning.smoothing", "tuning.motion", "tuning.refine", "tuning.refineDetail",
                                       "tuning.edgeSoftness", "tuning.roomTolerance", "tuning.keyDenoise",
                                       "tuning.keySmoothing", "tuning.keySoftness"]

    /// The keyjitter fixture's chroma noise, where a 1.5 px denoise and 0.5 smoothing tested best.
    static let referenceChroma: Float = 0.0125

    /// `matte` is macOS's true matte rather than Vision's coarse mask: it needs no refinement, and goes through the
    /// edge fade at its widest, which leaves it as it is.
    static func tuning(for noise: Noise, flicker: Float, matte: Bool = false) -> Tuning {
        var t = Tuning()
        if matte { (t.refine, t.edgeSoftness) = (0, 0.5) }
        // A chair flipping every other mask reads about 10 per mille; that takes smoothing near its top. macOS's
        // matte is steady already, and the matchup found more smoothing only drags its edges when someone moves.
        let floor: Float = matte ? 0.2 : 0.6
        t.smoothing = step(min(max(floor + 0.03 * flicker, floor), 1), 0.05)
        let n = noise.chroma / referenceChroma
        // Floored, because a clean camera's hair edges still crawl: breathing, and the camera's own processing,
        // move them too. Neither costs anything to leave on.
        t.keyDenoise = step(min(max(1 + 0.5 * n, 1), 2.5), 0.25)
        t.keySmoothing = step(min(max(0.4 + 0.1 * n, 0.4), 0.7), 0.05)
        t.keySoftness = step(min(max(n, 1), 1.5), 0.05)
        // Clears three times the noise the mask pass sees, which averages four taps and so halves it.
        t.motion = step(min(max(1.5 * noise.luma, 0.02), 0.08), 0.005)
        // The guided filter's epsilon has to sit above the noise's variance, or it copies noise into the edge. Past
        // 0.01 the matchup found softer fits land nearer the true edge anyway, so that's the ceiling on detail.
        t.refineDetail = step(min(max(-log10(max(3 * noise.luma * noise.luma, 0.01)), 1.5), 2), 0.25)
        // The room is compared at the mask's size, where each spot averages about 16 pixels, a quarter the noise.
        t.roomTolerance = step(min(max(noise.luma, 0.015), 0.08), 0.005)
        return t
    }

    private static func step(_ v: Float, _ size: Float) -> Float { (v / size).rounded() * size }

    static func luma(_ rgb: SIMD3<Float>) -> Float { dot(rgb, SIMD3(0.299, 0.587, 0.114)) }

    /// The same 96x54 grid in Vision's mask, which spans the frame whatever its own size.
    static func sampleMask(_ mask: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else { return [] }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        var out: [UInt8] = []
        out.reserveCapacity(96 * 54)
        for gy in 0..<54 {
            for gx in 0..<96 { out.append(base[((gy * 2 + 1) * h / 108) * row + (gx * 2 + 1) * w / 192]) }
        }
        return out
    }

    /// A 96x54 grid of the frame's pixels, 0...1 RGB.
    static func sample(_ pixels: CVPixelBuffer) -> [SIMD3<Float>] {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return [] }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(96 * 54)
        for gy in 0..<54 {
            for gx in 0..<96 {
                let p = base + ((gy * 2 + 1) * h / 108) * row + ((gx * 2 + 1) * w / 192) * 4
                out.append(SIMD3(Float(p[2]), Float(p[1]), Float(p[0])) / 255)
            }
        }
        return out
    }

    /// Noise from the same points in two frames in a row. Nil if the samples don't line up.
    ///
    /// - An exposure step moves every point the same way, so the typical difference comes off first.
    /// - The quietest quarter gives a first scale, too big when a lot moved but never too small.
    /// - Then the root mean square of what's within two scales, divided by 0.88 for the tails that cut off, gives
    ///   the next, till it settles. Movement makes big differences, and few land inside the band. A root mean
    ///   square still reads noise under one 8-bit level, which rounds each difference to 0 or 1 and a quantile to
    ///   a step.
    static func noise(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Noise? {
        guard a.count == b.count, a.count >= 100 else { return nil }
        var luma: [Float] = [], cb: [Float] = [], cr: [Float] = []
        for (x, y) in zip(a, b) {
            let d = y - x
            luma.append(dot(d, SIMD3(0.299, 0.587, 0.114)))
            cb.append(dot(d, GreenScreen.cbWeights))
            cr.append(dot(d, GreenScreen.crWeights))
        }
        func sigma(_ d: [Float]) -> Float {
            let offset = d.sorted()[d.count / 2]
            let spread = d.map { abs($0 - offset) }
            // Turns the lower quartile of distance from the middle into a standard deviation, for normal noise.
            var scale = max(spread.sorted()[spread.count / 4] / 0.3186, 1 / 255)
            for _ in 0..<6 {
                let kept = spread.filter { $0 <= 2 * scale }
                let rms = (kept.reduce(0) { $0 + $1 * $1 } / Float(max(kept.count, 1))).squareRoot()
                scale = max(rms / 0.88, 0.5 / 255)
            }
            // The difference of two frames carries the noise of both.
            return scale / Float(2).squareRoot()
        }
        let (sb, sr) = (sigma(cb), sigma(cr))
        return Noise(luma: sigma(luma), chroma: ((sb * sb + sr * sr) / 2).squareRoot())
    }
}
