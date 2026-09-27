import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// The page captured through ScreenCaptureKit, the alternative to snapshots, kept for comparing the two.
///
/// Since macOS 14.4 an app can capture its own windows through the current-process shareable content with no Screen
/// Recording prompt. The system still shows its capture indicator in the menu bar while the stream runs. Frames only
/// arrive when the page changes, so a static page costs nothing once it has painted.
final class SCKWebSource: NSObject, BackgroundSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var firstFrame: (@Sendable (Bool) -> Void)?
    @MainActor private var page: WebPage?
    @MainActor private var stream: SCStream?
    @MainActor private var restarts = 0
    private let captureQueue = DispatchQueue(label: "fastbg.web", qos: .userInteractive)

    @MainActor
    init(target: WebTarget, ready: @escaping @Sendable (Bool) -> Void) {
        firstFrame = ready
        super.init()
        let page = WebPage(target: target)
        self.page = page
        Task { @MainActor in
            guard await page.load() else { return self.fail() }
            await self.startCapture()
        }
    }

    @MainActor
    private func startCapture() async {
        guard let page else { return }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(page.window.windowNumber) }),
                  self.page != nil else { return fail() }
            let config = SCStreamConfiguration()
            config.width = Int(WebPage.pixelSize.width)
            config.height = Int(WebPage.pixelSize.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = false
            config.scalesToFit = true
            config.ignoreShadowsSingleWindow = true
            config.queueDepth = 4
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config,
                                  delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            guard self.page != nil else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            // A window the window server hasn't tied to a display starts a stream that never sends a frame.
            try? await Task.sleep(for: .seconds(3))
            if lock.withLock({ latest == nil }) { fail() }
        } catch {
            fail()
        }
    }

    private func fail() {
        let notify = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            defer { firstFrame = nil }
            return firstFrame
        }
        notify?(false)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // An unchanged page sends idle samples with no pixels; the last complete frame stays current.
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete || status == .started,
              let pixels = sample.imageBuffer else { return }
        let notify = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            latest = pixels
            defer { firstFrame = nil }
            return firstFrame
        }
        notify?(true)
    }

    /// Before the first frame that's a failed switch. After it, the page would freeze on its last frame, so the
    /// capture starts again, a few times at most.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fail()
        let stopped = ObjectIdentifier(stream)
        Task { @MainActor in
            guard self.stream.map(ObjectIdentifier.init) == stopped, self.page != nil, self.restarts < 3 else { return }
            self.restarts += 1
            self.stream = nil
            await self.startCapture()
        }
    }

    func frame(at hostTime: CFTimeInterval) -> BackgroundFrame? {
        lock.withLock { latest.map(BackgroundFrame.buffer) }
    }

    @MainActor func close() {
        lock.withLock {
            firstFrame = nil
            latest = nil
        }
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        page?.close()
        page = nil
    }
}
