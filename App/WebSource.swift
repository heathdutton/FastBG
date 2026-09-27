import AppKit
import CoreVideo
import WebKit

/// A live web page, copied out of WebKit one snapshot at a time, ~2 ms of CPU each. A ScreenCaptureKit stream would
/// skip the copy but shows macOS's screen-sharing indicator while it runs.
///
/// Snapshots follow the engine: each frame it takes asks for the next one, so every camera frame finds a snapshot of
/// about the same age. On the page's own clock they beat against the camera's, and a frame now and then showed twice
/// while the next was skipped. The page says when it has changed, so a static page is copied once.
final class WebSource: NSObject, BackgroundSource, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var firstFrame: (@Sendable (Bool) -> Void)?
    private var shots = 0
    @MainActor private var page: WebPage?
    @MainActor private var pool: CVPixelBufferPool?
    @MainActor private var inFlight = false
    @MainActor private var dirty = false
    @MainActor private var lastShot: CFTimeInterval = 0
    /// The engine took the last snapshot, or there hasn't been one yet.
    @MainActor private var wanted = true
    @MainActor private var waiting = false
    /// The output's own rate caps it, whoever asks, less a little for a camera's timing to wobble.
    private static let minGap = 1.0 / 30 - 0.004

    @MainActor
    init(target: WebTarget, ready: @escaping @Sendable (Bool) -> Void) {
        firstFrame = ready
        super.init()
        let page = WebPage(target: target)
        self.page = page
        page.onChange = { [weak self] in self?.changed() }
        Task { @MainActor in
            guard await page.load() else { return self.fail() }
            self.changed()
        }
    }

    /// Snapshots taken so far, for measuring what a page costs.
    var snapshots: Int { lock.withLock { shots } }

    @MainActor
    private func changed() {
        dirty = true
        shootIfDue()
    }

    @MainActor
    private func pulled() {
        wanted = true
        shootIfDue()
    }

    /// One snapshot at a time, of a page that changed, once the engine has taken the last one.
    @MainActor
    private func shootIfDue() {
        guard dirty, wanted, !inFlight, !waiting, page != nil else { return }
        let wait = lastShot + Self.minGap - CACurrentMediaTime()
        guard wait <= 0 else {
            waiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.waiting = false
                    self?.shootIfDue()
                }
            }
            return
        }
        shoot()
    }

    @MainActor
    private func shoot() {
        guard let page else { return }
        inFlight = true
        dirty = false
        wanted = false
        lastShot = CACurrentMediaTime()
        let config = WKSnapshotConfiguration()
        // Waits for the paint the change report came ahead of, so the snapshot isn't a frame behind.
        config.afterScreenUpdates = true
        page.webView.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight = false
                if let pixels = image.flatMap(self.pixels) { self.deliver(pixels) }
                self.shootIfDue()
            }
        }
    }

    /// Draws the snapshot into a 1920x1080 BGRA IOSurface buffer that the compositor wraps with no further copy.
    @MainActor
    private func pixels(_ image: NSImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(WebPage.pixelSize.width),
                kCVPixelBufferHeightKey: Int(WebPage.pixelSize.height),
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out
        else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let width = CVPixelBufferGetWidth(out), height = CVPixelBufferGetHeight(out)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return out
    }

    private func deliver(_ pixels: CVPixelBuffer) {
        let notify = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            latest = pixels
            shots += 1
            defer { firstFrame = nil }
            return firstFrame
        }
        notify?(true)
    }

    private func fail() {
        let notify = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            defer { firstFrame = nil }
            return firstFrame
        }
        notify?(false)
    }

    func frame(at hostTime: CFTimeInterval) -> BackgroundFrame? {
        let frame = lock.withLock { latest.map(BackgroundFrame.buffer) }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pulled() } }
        return frame
    }

    @MainActor func close() {
        lock.withLock {
            firstFrame = nil
            latest = nil
        }
        page?.close()
        page = nil
        pool = nil
    }
}
