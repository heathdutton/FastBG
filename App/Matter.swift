import CoreVideo
import Vision

/// Apple Vision's person mask. The mask is 4:3 at a size fixed by the quality level (256x192 fast, 512x384
/// balanced, 2016x1512 accurate) whatever the input, stretched over the whole frame, so it's sampled with the frame's
/// own UVs. It comes back IOSurface-backed, so Metal wraps it with no copy.
final class Matter {
    enum Quality { case fast, balanced, accurate }

    private let handler = VNSequenceRequestHandler()
    private let balanced = Matter.request(.balanced)
    private lazy var accurate = Matter.request(.accurate)

    private static func request(_ level: VNGeneratePersonSegmentationRequest.QualityLevel)
        -> VNGeneratePersonSegmentationRequest {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = level
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }

    /// OneComponent8, or nil if Vision fails. Hold the buffer only until the GPU work reading it completes: Vision
    /// recycles masks from a small pool.
    func mask(for frame: CVPixelBuffer, quality: Quality) -> CVPixelBuffer? {
        let request: VNGeneratePersonSegmentationRequest
        switch quality {
        // A reused .fast request carries state, and after a hard cut it keeps a person-shaped blob for seconds.
        // A fresh one per frame costs the same.
        case .fast: request = Matter.request(.fast)
        case .balanced: request = balanced
        case .accurate: request = accurate
        }
        do {
            try handler.perform([request], on: frame, orientation: .up)
        } catch {
            return nil
        }
        return request.results?.first?.pixelBuffer
    }

    /// The first request of a level in a process costs 50-900 ms. Paying it off the frame path keeps the first
    /// masked frame from stalling the camera.
    static func warmUp(_ qualities: [Quality]) {
        DispatchQueue.global(qos: .utility).async {
            var pixels: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, attrs, &pixels)
            guard let pixels else { return }
            let matter = Matter()
            for quality in qualities { _ = matter.mask(for: pixels, quality: quality) }
        }
    }
}
