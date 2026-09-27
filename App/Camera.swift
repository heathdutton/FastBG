import AVFoundation

/// The physical camera. Open only while someone reads fastbg, so the camera light means a call is on.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "fastbg.camera")
    private let frameQueue: DispatchQueue
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private var errorWatch: NSObjectProtocol?
    private var effectWatch: NSKeyValueObservation?
    /// macOS's own Background effect went on or off on the open camera. It's set per app from Control Center, and
    /// applied to fastbg's input it would put a second background under fastbg's.
    var onSystemBackground: (@Sendable (Bool) -> Void)?
    /// The size its frames will be, reported once it's open and before the first one arrives.
    var onOpened: (@Sendable (_ width: Int, _ height: Int) -> Void)?
    /// Touched only on sessionQueue.
    private var session: AVCaptureSession?
    private let lock = NSLock()
    private var wanted: String?
    /// Runtime errors in a row, with no long run between them, and when the session last opened. Session queue only.
    private var failures = 0
    private var openedAt: TimeInterval = 0

    /// `onFrame` runs on `frameQueue`.
    init(frameQueue: DispatchQueue, onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.frameQueue = frameQueue
        self.onFrame = onFrame
    }

    /// Physical cameras. Never fastbg itself, which would feed its own output back in, nor any other virtual camera.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.filter { !isFastbg($0) && $0.transportType != virtualTransport }
    }

    /// The FastBG camera as apps see it, once its extension is on.
    static func fastbg() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first(where: isFastbg)
    }

    /// Physical cameras some other app has open.
    static func inUseElsewhere() -> Bool {
        devices().contains { $0.isInUseByAnotherApplication }
    }

    /// kIOAudioDeviceTransportTypeVirtual, the transport camera extensions report, fastbg's relay included.
    private static let virtualTransport: Int32 = 0x7669_7274

    /// The camera being opened or open, set the moment `start` is called. Opening takes about a second, and a
    /// device notification in that window mustn't read as the wrong camera being open.
    var wantedID: String? { lock.withLock { wanted } }

    static func isFastbg(_ device: AVCaptureDevice) -> Bool {
        device.uniqueID == FastbgCamera.deviceUID
            || device.localizedName.caseInsensitiveCompare(FastbgCamera.name) == .orderedSame
    }

    /// The saved camera while it's connected, else the best one there. A camera that can't deliver frames, like a
    /// MacBook's with its lid shut, never counts.
    static func resolve(_ uniqueID: String?) -> AVCaptureDevice? {
        let all = devices().filter { !$0.isSuspended }
        if let uniqueID, let saved = all.first(where: { $0.uniqueID == uniqueID }) { return saved }
        return automatic(all)
    }

    /// An external webcam, then the built-in one, then an iPhone. A phone nearby turns up as a camera without anyone
    /// meaning to use it, so it only wins with the lid shut, and picking it in the menu is one click. Within a kind,
    /// the system's preferred camera goes first. It follows what video apps pick, which can be fastbg itself, so it
    /// only ever breaks a tie.
    static func automatic(_ all: [AVCaptureDevice]) -> AVCaptureDevice? {
        let preferred = AVCaptureDevice.systemPreferredCamera?.uniqueID
        func best(_ type: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
            let kind = all.filter { $0.deviceType == type }
            return kind.first { $0.uniqueID == preferred } ?? kind.first
        }
        return best(.external) ?? best(.builtInWideAngleCamera) ?? best(.continuityCamera) ?? all.first
    }

    func start(uniqueID: String?) {
        let device = Self.resolve(uniqueID)?.uniqueID
        lock.withLock { wanted = device }
        sessionQueue.async { [self] in
            teardown()
            guard let device = Self.resolve(uniqueID), let input = try? AVCaptureDeviceInput(device: device) else {
                Log.camera.error("no camera to open")
                return
            }
            let session = AVCaptureSession()
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            session.addOutput(output)
            // Set after the input joins, or the session preset overrides it.
            configure(device)
            session.commitConfiguration()
            // A daemon restart or a USB hiccup stops the session, and reopening picks the same camera or the next
            // best. A camera that fails every time it opens, say one another app holds, backs off to a try every
            // 30 s rather than reopening as fast as it fails.
            let opened = ObjectIdentifier(session)
            errorWatch = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                sessionQueue.async { [self] in
                    guard self.session.map(ObjectIdentifier.init) == opened, wantedID != nil else { return }
                    if ProcessInfo.processInfo.systemUptime - openedAt > 10 { failures = 0 }
                    failures += 1
                    let delay = failures == 1 ? 0.25 : min(pow(2, Double(failures - 2)), 30)
                    Log.camera.error("session failed, reopening in \(delay, privacy: .public) s")
                    sessionQueue.asyncAfter(deadline: .now() + delay) { [self] in
                        guard self.session.map(ObjectIdentifier.init) == opened, wantedID != nil else { return }
                        start(uniqueID: uniqueID)
                    }
                }
            }
            session.startRunning()
            self.session = session
            openedAt = ProcessInfo.processInfo.systemUptime
            if #available(macOS 15, *) {
                let report = onSystemBackground
                effectWatch = device.observe(\.isBackgroundReplacementActive, options: [.initial, .new]) { device, _ in
                    report?(device.isBackgroundReplacementActive)
                }
            }
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            Log.camera.notice("opened \(device.localizedName, privacy: .public) at \(size.width)x\(size.height)")
            onOpened?(Int(size.width), Int(size.height))
        }
    }

    func stop() {
        lock.withLock { wanted = nil }
        sessionQueue.async { [self] in
            failures = 0
            teardown()
        }
    }

    private func teardown() {
        if session != nil { Log.camera.notice("closed") }
        if let errorWatch { NotificationCenter.default.removeObserver(errorWatch) }
        errorWatch = nil
        if effectWatch != nil { onSystemBackground?(false) }
        effectWatch = nil
        guard let session else { return }
        session.stopRunning()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        self.session = nil
    }

    /// The smallest format that covers the output size at the output rate, since anything bigger is pixels the
    /// composite throws away. A camera that tops out lower gets its largest format and is upscaled in the composite.
    /// Cameras state 30 fps loosely: a BRIO's range is exactly 30.00003, which excludes 30 itself, and setting a
    /// frame duration outside a range throws. So a range within half a frame of 30 counts, and its own duration is
    /// what gets set.
    private static func thirty(_ format: AVCaptureDevice.Format) -> AVFrameRateRange? {
        format.videoSupportedFrameRateRanges.first {
            ($0.minFrameRate - 0.5...$0.maxFrameRate + 0.5).contains(Double(FastbgCamera.fps))
        }
    }

    private func configure(_ device: AVCaptureDevice) {
        func area(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        func covers(_ f: AVCaptureDevice.Format) -> Bool {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width >= FastbgCamera.width && d.height >= FastbgCamera.height
        }
        let thirty = device.formats.filter { Self.thirty($0) != nil }
        let pick = thirty.filter(covers).min { area($0) < area($1) } ?? thirty.max { area($0) < area($1) }
        guard let pick, let range = Self.thirty(pick), (try? device.lockForConfiguration()) != nil else {
            return Log.camera.notice("no 30 fps format on \(device.localizedName, privacy: .public), left as is")
        }
        defer { device.unlockForConfiguration() }
        device.activeFormat = pick
        let wanted = CMTime(value: 1, timescale: FastbgCamera.fps)
        let frame = range.minFrameRate <= 30 && range.maxFrameRate >= 30 ? wanted : range.minFrameDuration
        device.activeVideoMinFrameDuration = frame
        device.activeVideoMaxFrameDuration = frame
        let d = CMVideoFormatDescriptionGetDimensions(pick.formatDescription)
        let fps = String(format: "%.2f", 1 / frame.seconds)
        let name = device.localizedName
        Log.camera.notice("\(name, privacy: .public) set to \(d.width)x\(d.height) at \(fps, privacy: .public) fps")
    }

    /// A frame the camera dropped, and why, on `frameQueue`.
    var onDrop: ((String) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String ?? "unknown"
        onDrop?(reason)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = sampleBuffer.imageBuffer else { return }
        onFrame(pixels, sampleBuffer.presentationTimeStamp)
    }
}
