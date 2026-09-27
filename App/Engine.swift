import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import simd

/// Where finished 1920x1080 frames go, in the camera's 10-bit format: the camera extension's sink, or a test harness.
protocol FrameSink: AnyObject, Sendable {
    /// Any thread. Must not block.
    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime)
}

enum GreenScreenStatus: Equatable, Sendable {
    case off
    /// On, waiting for the camera to open and a frame to measure.
    case waiting
    /// `rgb` is the screen's measured colour, which follows the light.
    case keyed(coverage: Double, rgb: SIMD3<Float>)
    case notFound
}

/// Runs the pipeline while someone reads fastbg, and nothing at all otherwise.
///
/// The main actor side decides what should be on screen and creates background sources. Everything per frame runs on
/// `queue`, paced by the camera: Vision, then one Metal pass, then the sink. Off with no dissolve running skips both
/// and hands camera buffers straight to the sink.
final class Engine: @unchecked Sendable {
    static let dissolveDuration: CFTimeInterval = 0.5
    /// Frames to let auto-exposure settle before measuring the green screen.
    static let calibrationDelay = 15

    let queue = DispatchQueue(label: "fastbg.engine", qos: .userInteractive)
    let device = MTLCreateSystemDefaultDevice()
    /// Frames go out through Turbo's pacer, which passes them straight to the real sink while it's off.
    private let sink: FrameSink
    private let pacer: Pacer
    private let calibrationQueue = DispatchQueue(label: "fastbg.calibration", qos: .userInitiated)

    @MainActor var onGreenScreenStatus: ((GreenScreenStatus) -> Void)?
    /// macOS's own Background effect is on for the camera fastbg reads.
    @MainActor var onSystemBackground: ((Bool) -> Void)?
    /// A web background's first frame, which doubles as its thumbnail rather than loading the page twice.
    @MainActor var onWebFrame: ((_ id: String, _ pixels: CVPixelBuffer) -> Void)?
    /// Auto's own pick, before the user's leanings, and what it picked it from, so the panel can show both.
    @MainActor var onAutoTuning: ((Tuning, AutoTune.Readings) -> Void)?
    /// A background failed to load: its id, the id of what stays on screen instead, and whether the user asked for
    /// it just now rather than it loading because a call started.
    @MainActor var onSwitchDropped: ((_ failed: String, _ showing: String, _ userInitiated: Bool) -> Void)?
    @MainActor private(set) var live = false
    @MainActor private var wanted = BackgroundSpec.off
    @MainActor private var shown = BackgroundSpec.off
    @MainActor private var token = 0
    @MainActor private var loading: [Int: (spec: BackgroundSpec, source: BackgroundSource, user: Bool)] = [:]
    @MainActor private var screenColor = ScreenColor.off
    @MainActor private var cameraID: String?
    @MainActor private var activity: NSObjectProtocol?
    @MainActor private var camera: Camera?

    // Touched only on `queue`.
    private var running = false
    private var wantedToken = 0
    /// Going live with a background selected sends nothing until it's ready, rather than flash the room.
    private var awaitingFirst = false
    private var compositor: Compositor?
    private var compositing = false
    private var matter = Matter()
    /// Where masks come from instead of Vision, if set. Queue only.
    var maskSource: ((CVPixelBuffer) -> CVPixelBuffer?)?
    /// The harness's stand-in for a broken macOS matte, which runs but comes back empty. Queue only.
    var blanksNative = false
    private var blank: CVPixelBuffer?
    /// Use macOS's own matte when it's there. Queue only.
    private var systemMatte = true
    /// The system matte for the camera's frame size, or nil once it failed to start for that size.
    private var native: (width: Int, height: Int, matter: NativeMatter?)?
    private var nativeStarting = false
    /// macOS's matte ran but came back empty while Vision saw someone, so Vision stands in till the call ends.
    private var nativeDistrusted = false
    /// The last matte from macOS's, checked a frame later once its GPU work is surely done, and since when they've
    /// been empty.
    private var lastNative: (matte: CVPixelBuffer, ready: GPUWait)?
    private var nativeFrames = 0
    private var nativeEmptySince: CFTimeInterval?
    /// How far behind the clock the camera's capture times run, averaged over a couple of seconds.
    private var captureLag: Double?
    /// The camera's frame interval, averaged, and the last capture time it was measured from.
    private var cameraInterval: Double?
    private var lastCaptured: Double?
    /// Arrival by `clock`, how the steady clock tells a camera that stopped sending.
    private var lastCameraFrame: CFTimeInterval = 0
    /// The steady 30 fps clock, while it runs, the grid its ticks sit on, and the camera frame it reuses.
    private var steadyClock: DispatchSourceTimer?
    private var clockBase: CFTimeInterval = 0
    private var held: Held?
    /// Set with each of macOS's mattes, whose GPU work is still running when it's handed over.
    private var maskReady: GPUWait?
    /// A harness feeds frames as fast as it can, so its frames wait for the matte, and its results don't depend on
    /// how many Vision covered.
    private let waitsForMatte: Bool
    /// Bumped whenever the matte is dropped, so a setup still running for the old one lands nowhere.
    private var nativeGeneration = 0
    private let nativeQueue = DispatchQueue(label: "fastbg.matte-setup", qos: .userInitiated)
    /// Whether the last mask came from macOS rather than Vision.
    @MainActor var onMatteSource: ((_ system: Bool) -> Void)?
    /// The camera's frame rate while Turbo fills in frames to 30 fps, nil otherwise.
    @MainActor var onTurboFill: ((Double?) -> Void)?
    private var reportedSystem: Bool?
    /// What's on screen, or dissolving in.
    private var steady = Shown.camera
    private var dissolve: (from: Shown, start: CFTimeInterval)?
    private var tuning = Tuning()
    private var auto = false
    private var turbo = false
    private var autoBase = Tuning()
    /// The user's leanings on auto's picks, by knob key.
    private var offsets: [String: Float] = [:]
    private var noise: AutoTune.Noise?
    /// Vision's flicker, per mille: still spots whose mask crossed the detection level between two masks in a row.
    private var flicker: Float?
    private var flickerCounts = (crossed: 0, still: 0)
    private var flickerSample: (mask: [UInt8], luma: [Float])?
    private var screen = ScreenColor.off
    /// When a screen that was being keyed stopped being found. Auto looks again sooner for a while after.
    private var keyLostAt: CFTimeInterval = -.infinity
    private var reportedRGB = SIMD3<Float>(repeating: -1)
    /// The first of two frames in a row that auto measures noise from.
    private var noiseProbe: [SIMD3<Float>]?
    private var lastNoiseCheck: CFTimeInterval = 0
    /// Re-measures in a row that found too little screen. A screen that came down reads the same way.
    private var balanceMisses = 0
    private var keyEnabled = false
    private var key: Key?
    private var calibrationDue = false
    private var calibrating = false
    /// Bumped whenever a running calibration's result would no longer apply: new camera, toggle, idle.
    private var calibrationGeneration = 0
    /// When the key was last re-measured, or calibration last tried and found no screen.
    private var lastBalance: CFTimeInterval = 0
    private var balancing = false
    private var framesSinceOpen = 0
    private var sentSinceLive = 0
    /// The last Vision mask and what the frame looked like when it was made, for reuse while nothing moves.
    private var lastMask: CVPixelBuffer?
    private var lastMaskLook: [UInt8] = []
    private var maskReuses = 0
    private var visionRuns = 0, maskedFrames = 0
    /// Where a frame's time goes, and the frames the camera dropped, logged every 30 s.
    private var maskTime: CFTimeInterval = 0, frameTime: CFTimeInterval = 0
    private var drops: [String: Int] = [:]
    private var statsSince: CFTimeInterval = 0
    /// Dissolve timing reads this, so a harness can drive it.
    var clock: @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }

    private enum Shown {
        case camera
        case source(BackgroundSource)
        /// A dissolve frozen mid-way, so a new one can start from exactly what was on screen. Only its backgrounds
        /// are frozen: the camera's share of it, when Off was one side, stays live, or it would freeze you in too.
        case frozen(MTLTexture, camera: Float)
    }

    /// `usesCamera` false leaves the physical camera closed, for a harness that feeds `process` itself.
    @MainActor
    init(sink: FrameSink, usesCamera: Bool = true) {
        waitsForMatte = !usesCamera
        pacer = Pacer(sink: sink)
        self.sink = pacer
        pacer.onFilling = { [weak self] fps in Task { @MainActor in self?.onTurboFill?(fps) } }
        if usesCamera {
            camera = Camera(frameQueue: queue, onFrame: { [unowned self] pixels, time in
                self.process(camera: pixels, time: time)
            })
            camera?.onDrop = { [unowned self] reason in self.drops[reason, default: 0] += 1 }
            // The matte's set up while the camera is still starting, so it's usually ready for the first frame.
            camera?.onOpened = { [weak self] width, height in
                guard let self else { return }
                queue.async { [self] in
                    if running, systemMatte, maskSource == nil { startNative(width: width, height: height) }
                }
            }
            camera?.onSystemBackground = { [weak self] on in
                Log.camera.notice("macOS Background effect on this camera: \(on)")
                Task { @MainActor in self?.onSystemBackground?(on) }
            }
        }
    }

    @MainActor
    func setLive(_ on: Bool) {
        guard on != live else { return }
        live = on
        if on {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "FastBG is being read")
            Matter.warmUp(screenColor != .off ? [.balanced, .accurate] : [.balanced])
            let waitForBackground = wanted != .off
            queue.async { [self] in
                running = true
                framesSinceOpen = 0
                sentSinceLive = 0
                awaitingFirst = waitForBackground
                calibrationDue = keyEnabled
                if keyEnabled { status(.waiting) }
            }
            shown = .off
            camera?.start(uniqueID: cameraID)
            load(wanted, userInitiated: false)
        } else {
            camera?.stop()
            for (_, load) in loading { load.source.close() }
            loading = [:]
            queue.async { [self] in goIdle() }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    /// Asking again for what's wanted but isn't showing, because it failed to load as a call started, retries it.
    @MainActor
    func show(_ spec: BackgroundSpec) {
        guard spec != wanted || (live && spec != shown && loading.isEmpty) else { return }
        wanted = spec
        if live { load(spec, userInitiated: true) }
    }

    /// Ignored while auto picks the tuning.
    @MainActor
    func setTuning(_ tuning: Tuning) {
        queue.async { [self] in
            guard !auto else { return }
            self.tuning = tuning
        }
    }

    /// Auto tunes from the camera's noise and Vision's flicker, every 2 s.
    @MainActor
    func setAuto(_ on: Bool) {
        queue.async { [self] in
            auto = on
            noiseProbe = nil
            lastNoiseCheck = 0
            if on { applyAuto(AutoTune.tuning(for: noise ?? .typical, flicker: flicker ?? 0, matte: matteInUse)) }
        }
    }

    /// Turbo: a slow camera's frames are filled in to a steady 30 fps, Vision runs on every frame rather than
    /// reusing a still frame's mask, and a green screen's colour is re-measured three times as often.
    @MainActor
    func setTurbo(_ on: Bool) {
        pacer.setOn(on)
        queue.async { [self] in turbo = on }
    }

    /// macOS's own matte or Vision's. A switch starts the effect afresh.
    @MainActor
    func setSystemMatte(_ on: Bool) {
        queue.async { [self] in
            systemMatte = on
            native = nil
            nativeGeneration += 1
            reportedSystem = nil
            forgetNative()
            if auto { applyAuto(AutoTune.tuning(for: noise ?? .typical, flicker: flicker ?? 0, matte: on)) }
        }
    }

    @MainActor
    func setOffsets(_ offsets: [String: Float]) {
        queue.async { [self] in
            self.offsets = offsets
            if auto { tuning = autoBase.nudged(offsets) }
        }
    }

    @MainActor
    func setScreen(_ color: ScreenColor) {
        guard color != screenColor else { return }
        screenColor = color
        if color != .off, live { Matter.warmUp([.accurate]) }
        queue.async { [self] in
            // Narrowing to the colour already being keyed, as Auto hands back to the menu, keeps the key.
            if let key, color == .green && key.spill == 1 || color == .blue && key.spill == 2 {
                screen = color
                return
            }
            screen = color
            keyEnabled = color != .off
            key = nil
            calibrationDue = keyEnabled && running
            calibrationGeneration += 1
            calibrating = false
            status(keyEnabled ? .waiting : .off)
        }
    }

    /// Changing the screen colour, or reopening the camera, measures the screen again.
    @MainActor
    func setCamera(_ uniqueID: String?) {
        guard uniqueID != cameraID else { return }
        cameraID = uniqueID
        reopenCamera()
    }

    /// A camera was plugged in or out. Mid-call, the one that should be open may have changed: the saved camera came
    /// back, or the open one vanished and its frames stopped.
    @MainActor
    func camerasChanged() {
        guard live, Camera.resolve(cameraID)?.uniqueID != camera?.wantedID else { return }
        reopenCamera()
    }

    @MainActor
    private func reopenCamera() {
        guard live else { return }
        camera?.start(uniqueID: cameraID)
        queue.async { [self] in
            framesSinceOpen = 0
            matter = Matter()
            native = nil
            nativeGeneration += 1
            forgetNative()
            (lastMask, lastMaskLook) = (nil, [])
            (noise, flicker, flickerSample, flickerCounts) = (nil, nil, nil, (0, 0))
            key = nil
            calibrationDue = keyEnabled
            calibrationGeneration += 1
            calibrating = false
            if keyEnabled { status(.waiting) }
        }
    }

    @MainActor
    private func load(_ spec: BackgroundSpec, userInitiated: Bool) {
        token += 1
        let token = token
        for (_, load) in loading { load.source.close() }
        loading = [:]
        queue.async { [self] in wantedToken = token }
        // Back to what's already on screen: cancelling the pending load is the whole switch.
        guard spec != shown || spec == .off else { return }
        let ready: @Sendable (Bool) -> Void = { [weak self] ok in
            Task { @MainActor in self?.loaded(token, ok) }
        }
        let source: BackgroundSource
        switch spec {
        case .off:
            shown = .off
            queue.async { [self] in arrive(.camera, token: token) }
            return
        case .image(_, let url):
            guard let device else { return dropped(spec, userInitiated: userInitiated) }
            source = StillSource(url: url, device: device, ready: ready)
        case .video(_, let url):
            source = VideoSource(url: url, ready: ready)
        case .web(_, let target):
            source = WebSource(target: target, ready: ready)
        }
        loading[token] = (spec, source, userInitiated)
    }

    @MainActor
    private func loaded(_ token: Int, _ ok: Bool) {
        // Superseded loads were closed and forgotten already.
        guard let load = loading.removeValue(forKey: token) else { return }
        Log.engine.notice("background \(load.spec.id, privacy: .public) ready: \(ok)")
        guard ok else {
            load.source.close()
            return dropped(load.spec, userInitiated: load.user)
        }
        shown = load.spec
        let source = load.source
        if case .web(let id, _) = load.spec, case .buffer(let pixels)? = source.frame(at: 0) { onWebFrame?(id, pixels) }
        queue.async { [self] in arrive(.source(source), token: token) }
    }

    /// The switch is dropped and what's on screen stays. Going live with nothing on screen yet falls back to Off for
    /// that call, and the selection stays wanted so the next call tries it again.
    @MainActor
    private func dropped(_ spec: BackgroundSpec, userInitiated: Bool) {
        if userInitiated { wanted = shown }
        onSwitchDropped?(spec.id, shown.id, userInitiated)
        if shown == .off {
            let token = token
            queue.async { [self] in arrive(.camera, token: token) }
        }
    }

    // Everything below runs on `queue`.

    private func status(_ status: GreenScreenStatus) {
        Task { @MainActor [weak self] in self?.onGreenScreenStatus?(status) }
    }

    private func arrive(_ next: Shown, token: Int) {
        guard running, token == wantedToken else { return release(next) }
        if awaitingFirst {
            awaitingFirst = false
            release(steady)
            steady = next
            return
        }
        // Already on Off, or dissolving to it.
        if case .camera = steady, case .camera = next { return }
        let now = clock()
        if let d = dissolve {
            // Mid-dissolve: freeze the blend on screen and dissolve from that, so nothing jumps.
            dissolve = (freeze(d.from, steady, mix: Self.ease((now - d.start) / Self.dissolveDuration), now), now)
            release(d.from)
            release(steady)
        } else {
            dissolve = (steady, now)
        }
        steady = next
    }

    /// mix(a, b, t) as one Shown: the backgrounds baked into a texture, the camera's share kept as a weight. Falls
    /// back to the camera alone when there's nothing but camera in the blend, or nothing to freeze with.
    private func freeze(_ a: Shown, _ b: Shown, mix t: Float, _ now: CFTimeInterval) -> Shown {
        func split(_ shown: Shown) -> (Layer?, Float) {
            switch shown {
            case .camera: (nil, 1)
            case .frozen(let texture, let camera): (.texture(texture), camera)
            case .source: (layer(shown, now), 0)
            }
        }
        let (la, ca) = split(a), (lb, cb) = split(b)
        let camera = (1 - t) * ca + t * cb
        let wa = (1 - t) * (1 - ca), wb = t * (1 - cb)
        guard wa + wb > 0.001, let x = la ?? lb, let y = lb ?? la,
              let texture = compositor?.freeze(from: x, to: y, mix: wb / (wa + wb)) else { return .camera }
        return .frozen(texture, camera: camera)
    }

    /// Per camera frame, on `queue`.
    func process(camera pixels: CVPixelBuffer, time: CMTime) {
        guard running else { return }
        let began = CACurrentMediaTime()
        defer { frameTime += CACurrentMediaTime() - began }
        framesSinceOpen += 1
        if framesSinceOpen == 1 {
            let size = "\(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels))"
            let waiting = awaitingFirst
            Log.engine.notice("first camera frame \(size, privacy: .public), awaiting background: \(waiting)")
        }
        guard !awaitingFirst else { return }
        calibrateIfDue(pixels)
        balanceIfDue(pixels)
        autoTuneIfDue(pixels)

        let now = clock()
        let at = sampleTime(time, now)
        lastCameraFrame = now
        let mix = advanceDissolve(now)
        if dissolve == nil, case .camera = steady {
            stopClock()
            if compositing {
                compositing = false
                compositor?.idle()
            }
            return passThrough(pixels, time)
        }
        guard makeCompositor() != nil else { return passThrough(pixels, time) }
        compositing = true

        let key = keyEnabled ? self.key : nil
        var mask: CVPixelBuffer?
        maskReady = nil
        if key?.fillsBackground != true {
            mask = personMask(pixels, now)
            if mask == nil {
                Log.engine.error("Vision returned no mask, frame dropped")
                return
            }
        }
        let frame = Held(pixels: pixels, mask: mask, maskReady: maskReady, key: key)
        if usesSteadyClock() {
            held = frame
            return startClock()
        }
        stopClock()
        composite(frame, at: at, mix: mix, time: time)
    }

    /// What a composite needs from one camera frame, kept for the steady clock to reuse till the next arrives.
    private struct Held {
        let pixels: CVPixelBuffer
        let mask: CVPixelBuffer?
        let maskReady: GPUWait?
        let key: Key?
    }

    private func composite(_ frame: Held, at: CFTimeInterval, mix: Float, time: CMTime) {
        guard let compositor, let from = layer(dissolve?.from ?? steady, at) else { return }
        let to = dissolve == nil ? nil : layer(steady, at)
        if dissolve != nil, to == nil { return }
        let sink = sink
        let job = Compositor.Job(camera: frame.pixels, mask: frame.mask, maskReady: frame.maskReady, key: frame.key,
                                 from: from, to: to, mix: mix, tuning: tuning)
        compositor.render(job) { out in
            sink.send(out, time: time)
        }
        noteSent("composited")
    }

    /// The eased dissolve progress at `now`, and the dissolve dropped once it's done.
    private func advanceDissolve(_ now: CFTimeInterval) -> Float {
        guard let d = dissolve else { return 0 }
        let progress = (now - d.start) / Self.dissolveDuration
        guard progress < 1 else {
            release(d.from)
            dissolve = nil
            return 0
        }
        return Self.ease(progress)
    }

    /// When a moving background is sampled for this camera frame: on the camera's capture times, which are evenly
    /// spaced, rather than when each frame got here, which wobbles by a few ms. With the two frame rates in step,
    /// that wobble alone would repeat a frame and skip the next wherever their frame edges line up. Shifted by the
    /// camera's average lag, since a video won't hand back a frame from 40 ms ago. A harness's made-up times use
    /// the clock. Also where the camera's frame rate is measured.
    private func sampleTime(_ time: CMTime, _ now: CFTimeInterval) -> CFTimeInterval {
        let captured = time.seconds
        guard captured.isFinite, abs(now - captured) < 1 else { return now }
        // A near-zero gap is a repeated frame and a long one a pause, like the wait for a background to load.
        // Neither is the camera's rate.
        if let last = lastCaptured, captured - last > 0.005, captured - last < 0.1 {
            cameraInterval = cameraInterval.map { $0 + 0.1 * (captured - last - $0) } ?? captured - last
        }
        lastCaptured = captured
        let lag = now - captured
        captureLag = captureLag.map { $0 + 0.02 * (lag - $0) } ?? lag
        return captured + (captureLag ?? lag)
    }

    /// A camera that's fallen under about 27 fps, as one does in dim light, would take a moving background down
    /// with it: a 30 fps clip sampled 23 times a second steps one frame, one, then two, and hesitates. So while it
    /// does, frames go out on a steady 30 fps clock instead, each the newest camera frame and its mask over the
    /// background as it is at that tick. Turbo fills in whole frames instead, so this is for when it's off.
    private func usesSteadyClock() -> Bool {
        guard !turbo, let interval = cameraInterval else { return false }
        var moving = dissolve != nil
        if case .source(let source) = steady, !(source is StillSource) { moving = true }
        guard moving else { return false }
        // Apart, so a camera hovering around 28 fps doesn't flip between the two.
        return interval > (steadyClock == nil ? 1 / 27.0 : 1 / 29.0)
    }

    private func startClock() {
        guard steadyClock == nil else { return }
        let fps = String(format: "%.1f", 1 / (cameraInterval ?? 1 / 30.0))
        Log.engine.notice("camera at \(fps, privacy: .public) fps, the background goes out on a steady 30 fps clock")
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        clockBase = CACurrentMediaTime()
        timer.schedule(deadline: .now() + 1.0 / 30, repeating: 1.0 / 30, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        steadyClock = timer
    }

    private func stopClock() {
        guard let steadyClock else { return }
        steadyClock.cancel()
        self.steadyClock = nil
        held = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // A camera that stopped sends nothing, the same as without the clock.
        guard running, let held, clock() - lastCameraFrame < 0.5 else { return }
        // Snapped to the grid, however late the timer fired.
        let at = clockBase + ((now - clockBase) * 30).rounded() / 30
        let mix = advanceDissolve(clock())
        if dissolve == nil, case .camera = steady { return stopClock() }
        composite(held, at: at, mix: mix, time: CMTime(seconds: at, preferredTimescale: 1_000_000_000))
    }

    /// Vision is most of a frame's CPU. While nothing in the frame has moved since the last mask was made, that mask
    /// still fits, so it's reused, at most `maxMaskReuse` frames running so Vision never falls under 10 fps.
    static let maxMaskReuse = 2

    private func personMask(_ pixels: CVPixelBuffer, _ now: CFTimeInterval) -> CVPixelBuffer? {
        maskedFrames += 1
        if now - statsSince >= 30 {
            if maskedFrames > 1 {
                let frames = maskedFrames - 1, restTime = frameTime - maskTime
                let dropped = drops.map { "\($0.value) \($0.key)" }.sorted().joined(separator: ", ")
                Log.engine.notice("""
                    \(frames) frames in \(Int(now - self.statsSince)) s, Vision on \(self.visionRuns), mask \
                    \(String(format: "%.1f", self.maskTime / Double(frames) * 1000), privacy: .public) ms and the rest \
                    \(String(format: "%.1f", restTime / Double(frames) * 1000), privacy: .public) ms a frame, dropped: \
                    \(dropped.isEmpty ? "none" : dropped, privacy: .public)
                    """)
            }
            (visionRuns, maskedFrames, statsSince, maskTime, frameTime, drops) = (0, 1, now, 0, 0, [:])
        }
        let started = CACurrentMediaTime()
        defer { maskTime += CACurrentMediaTime() - started }
        if let maskSource { return maskSource(pixels) }
        if systemMatte, !nativeDistrusted {
            // Before this frame's matte replaces the last one, whose GPU work is done by now.
            if auto { watchNative(pixels) }
            if !nativeDistrusted, let mask = systemMask(pixels) {
                noteNeural()
                return mask
            }
        }
        // Not while macOS's is still setting up, or the panel would say it isn't available for a moment.
        if !(systemMatte && nativeStarting) { noteSource(false) }
        let look = Self.look(pixels)
        if !turbo, let lastMask, maskReuses < Self.maxMaskReuse, Self.isStill(look, lastMaskLook) {
            maskReuses += 1
            return lastMask
        }
        guard let fresh = matter.mask(for: pixels, quality: .balanced) else { return nil }
        noteNeural()
        visionRuns += 1
        if auto { trackFlicker(fresh, pixels) }
        (lastMask, lastMaskLook, maskReuses) = (fresh, look, 0)
        return fresh
    }

    /// Both mattes run on the Neural Engine, and macOS doesn't say how much of it an app uses, only which apps hold it
    /// open, which FastBG does even when idle. So the panel shows it as in use while masks are being made.
    private let neuralLock = NSLock()
    private var neuralAt: CFTimeInterval = -.infinity

    private func noteNeural() {
        let now = CACurrentMediaTime()
        neuralLock.withLock { neuralAt = now }
    }

    /// Whether masks are coming from the Neural Engine, forgiving a short stall so the panel's check doesn't blink.
    /// Any thread.
    func usesNeuralEngine() -> Bool {
        neuralLock.withLock { CACurrentMediaTime() - neuralAt < 1.5 }
    }

    /// macOS's matte, set up once per frame size. It's cheaper than Vision, so there's no reuse: every frame gets one.
    private func systemMask(_ pixels: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        if waitsForMatte, native?.width != width || native?.height != height, !nativeStarting {
            native = (width, height, makeNative(width: width, height: height))
        }
        guard native?.width == width, native?.height == height else {
            startNative(width: width, height: height)
            return nil
        }
        guard var made = native?.matter?.mask(for: pixels) else { return nil }
        if blanksNative, let blank = blankLike(made.matte) { made.matte = blank }
        maskReady = made.ready
        defer { lastNative = made }
        noteSource(true)
        return made.matte
    }

    /// Setting the matte up takes about 200 ms, so it happens off the frame path, and Vision, warmed as the call
    /// started, covers the frames meanwhile rather than the camera dropping them.
    private func startNative(width: Int, height: Int) {
        guard !nativeStarting, let device else { return }
        nativeStarting = true
        let generation = nativeGeneration
        nativeQueue.async { [self] in
            let made = Handoff(value: makeNative(width: width, height: height, device: device))
            queue.async { [self] in
                nativeStarting = false
                if generation == nativeGeneration { native = (width, height, made.value) }
            }
        }
    }

    private func makeNative(width: Int, height: Int, device: MTLDevice? = nil) -> NativeMatter? {
        guard let device = device ?? self.device else { return nil }
        let started = CACurrentMediaTime()
        let matter = NativeMatter(device: device, width: width, height: height)
        let ms = Int((CACurrentMediaTime() - started) * 1000)
        if matter == nil {
            Log.engine.error("macOS's matte didn't start at \(width)x\(height), using Vision")
        } else {
            Log.engine.notice("macOS's matte set up for \(width)x\(height) in \(ms) ms")
        }
        return matter
    }

    private func noteSource(_ system: Bool) {
        guard system != reportedSystem else { return }
        reportedSystem = system
        Log.engine.notice("masks from \(system ? "macOS" : "Vision", privacy: .public)")
        Task { @MainActor in self.onMatteSource?(system) }
        // Vision's coarse mask wants refinement that macOS's doesn't, so auto tunes for whichever is in use.
        if auto { applyAuto(AutoTune.tuning(for: noise ?? .typical, flicker: flicker ?? 0, matte: system)) }
    }

    /// Which matte the masks come from: the last one used, else the one asked for.
    private var matteInUse: Bool { reportedSystem ?? systemMatte }

    /// macOS's matte can run without an error and still come back empty, as it does in a virtual machine. Under
    /// Autocalibrate, twice a second, the last one is sampled. Empty for 2 s, it's checked against Vision on this
    /// frame, and if Vision sees someone, Vision takes over till the call ends.
    private func watchNative(_ pixels: CVPixelBuffer) {
        nativeFrames += 1
        guard nativeFrames % 15 == 0, let last = lastNative, last.ready.event.signaledValue >= last.ready.value
        else { return }
        let now = clock()
        guard Self.coverage(AutoTune.sampleMask(last.matte)) < 0.002 else { return nativeEmptySince = nil }
        guard let since = nativeEmptySince else { return nativeEmptySince = now }
        guard now - since >= 2 else { return }
        nativeEmptySince = nil
        guard let vision = matter.mask(for: pixels, quality: .balanced),
              Self.coverage(AutoTune.sampleMask(vision)) > 0.02 else { return }
        nativeDistrusted = true
        Log.engine.error("macOS's matte stayed empty while Vision sees someone, using Vision till the call ends")
    }

    private func blankLike(_ matte: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(matte), height = CVPixelBufferGetHeight(matte)
        if let blank, CVPixelBufferGetWidth(blank) == width, CVPixelBufferGetHeight(blank) == height { return blank }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, CVPixelBufferGetPixelFormatType(matte),
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        memset(CVPixelBufferGetBaseAddress(made), 0, CVPixelBufferGetDataSize(made))
        CVPixelBufferUnlockBaseAddress(made, [])
        blank = made
        return made
    }

    private func forgetNative() {
        (nativeDistrusted, lastNative, nativeFrames, nativeEmptySince) = (false, nil, 0, nil)
    }

    /// The share of a sampled mask that's the person.
    private static func coverage(_ samples: [UInt8]) -> Float {
        samples.isEmpty ? 0 : Float(samples.filter { $0 >= 128 }.count) / Float(samples.count)
    }

    /// The frame as 32x18 blocks of about 60 px, each the mean green of 16 samples, so sensor noise averages out
    /// and any real movement, even a blink or a moving mouth, shifts a block.
    static func look(_ pixels: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        var out = [UInt8](repeating: 0, count: 32 * 18)
        for by in 0..<18 {
            for bx in 0..<32 {
                var sum = 0
                for sy in 0..<4 {
                    let y = (by * 4 + sy) * h / 72 + h / 144
                    for sx in 0..<4 { sum += Int(base[y * row + ((bx * 4 + sx) * w / 128 + w / 256) * 4 + 1]) }
                }
                out[by * 32 + bx] = UInt8(sum / 16)
            }
        }
        return out
    }

    static func isStill(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).lazy.filter { abs(Int($0) - Int($1)) > 3 }.count <= 2
    }

    /// Logs the first frame out after going live, and which path it took.
    private func noteSent(_ path: StaticString) {
        sentSinceLive += 1
        if sentSinceLive == 1 { Log.engine.notice("first frame out, \(String(describing: path), privacy: .public)") }
    }

    /// One cheap GPU pass: the camera's BGRA becomes the output's 10-bit RGB, and a camera under 1080p gets scaled.
    private func passThrough(_ pixels: CVPixelBuffer, _ time: CMTime) {
        noteSent("passthrough")
        let sink = sink
        makeCompositor()?.scale(camera: pixels) { out in sink.send(out, time: time) }
    }

    private func makeCompositor() -> Compositor? {
        if compositor == nil, let device {
            do {
                compositor = try Compositor(device: device)
            } catch {
                Log.engine.error("Metal setup failed: \(error, privacy: .public)")
            }
        }
        return compositor
    }

    private func layer(_ shown: Shown, _ now: CFTimeInterval) -> Layer? {
        switch shown {
        case .camera: return .camera
        case .frozen(let texture, let camera): return .blend(texture, camera: camera)
        case .source(let source):
            switch source.frame(at: now) {
            case .texture(let texture): return .texture(texture)
            case .buffer(let pixels): return .buffer(pixels)
            case nil: return nil
            }
        }
    }

    private func release(_ shown: Shown) {
        guard case .source(let source) = shown else { return }
        Task { @MainActor in source.close() }
    }

    private func goIdle() {
        running = false
        awaitingFirst = false
        if let d = dissolve { release(d.from) }
        release(steady)
        dissolve = nil
        steady = .camera
        key = nil
        calibrating = false
        calibrationGeneration += 1
        matter = Matter()
        native = nil
        nativeGeneration += 1
        forgetNative()
        captureLag = nil
        (cameraInterval, lastCaptured) = (nil, nil)
        stopClock()
        reportedSystem = nil
        (lastMask, lastMaskLook) = (nil, [])
        (flickerSample, flickerCounts) = (nil, (0, 0))
        compositing = false
        // Pools and pipelines hold tens of MB; rebuilding them warm takes about a millisecond.
        compositor = nil
        pacer.reset()
        if keyEnabled { status(.waiting) }
    }

    /// One frame through Vision's `.accurate` level, off the frame path: it takes about a whole frame's budget.
    private func calibrateIfDue(_ pixels: CVPixelBuffer) {
        guard keyEnabled, calibrationDue, !calibrating, framesSinceOpen >= Self.calibrationDelay else { return }
        calibrationDue = false
        calibrating = true
        let frame = FrameBox(pixels)
        let generation = calibrationGeneration
        let want = screen
        calibrationQueue.async { [self] in
            let key = Matter().mask(for: frame.pixels, quality: .accurate)
                .flatMap { GreenScreen.calibrate(frame: frame.pixels, mask: $0, want: want) }
            queue.async { [self] in
                guard generation == calibrationGeneration else { return }
                calibrating = false
                guard keyEnabled else { return }
                if self.key != nil, key == nil { keyLostAt = clock() }
                self.key = key
                if let key {
                    let rgb = key.rgb * 255
                    Log.engine.notice("""
                        green screen: rgb \(Int(rgb.x)) \(Int(rgb.y)) \(Int(rgb.z)), tolerance \(key.near)-\(key.far), \
                        coverage \(Int(key.coverage * 100))%, map \(Int((key.screen?.share ?? 0) * 100))% of frame
                        """)
                } else {
                    Log.engine.notice("green screen: none found")
                }
                reportedRGB = key?.rgb ?? SIMD3(repeating: -1)
                status(key.map { .keyed(coverage: $0.coverage, rgb: $0.rgb) } ?? .notFound)
            }
        }
    }

    /// Every 2 s, samples one frame and the next, and picks the tuning from the noise between them.
    private func autoTuneIfDue(_ pixels: CVPixelBuffer) {
        guard auto else { return }
        if let probe = noiseProbe {
            noiseProbe = nil
            guard let measured = AutoTune.noise(probe, AutoTune.sample(pixels)) else { return }
            let eased = noise?.eased(to: measured, 0.5) ?? measured
            noise = eased
            if flickerCounts.still >= 300 {
                let rate = Float(flickerCounts.crossed) / Float(flickerCounts.still) * 1000
                flicker = flicker.map { $0 + (rate - $0) * 0.5 } ?? rate
            }
            flickerCounts = (0, 0)
            let tuned = AutoTune.tuning(for: eased, flicker: flicker ?? 0, matte: matteInUse)
            if tuned != autoBase {
                Log.engine.notice("""
                    auto: noise \(Int(eased.luma * 1000))/\(Int(eased.chroma * 1000)) per mille luma/chroma, \
                    flicker \(Int(self.flicker ?? 0)) per mille, smoothing \(tuned.smoothing), denoise \
                    \(tuned.keyDenoise), key smooth \(tuned.keySmoothing), motion \(tuned.motion), \
                    detail \(tuned.refineDetail)
                    """)
            }
            applyAuto(tuned)
        } else if clock() - lastNoiseCheck >= 2 {
            lastNoiseCheck = clock()
            noiseProbe = AutoTune.sample(pixels)
        }
    }

    private func applyAuto(_ base: Tuning) {
        autoBase = base
        tuning = base.nudged(offsets)
        let readings = AutoTune.Readings(noise: noise ?? .typical, flicker: flicker ?? 0)
        Task { @MainActor in self.onAutoTuning?(base, readings) }
    }

    /// Compares each fresh mask with the one before at spots the camera saw no change, since only a still spot's
    /// change is Vision's own indecision.
    private func trackFlicker(_ mask: CVPixelBuffer, _ pixels: CVPixelBuffer) {
        let now = (mask: AutoTune.sampleMask(mask), luma: AutoTune.sample(pixels).map(AutoTune.luma))
        defer { flickerSample = now }
        guard let before = flickerSample, before.mask.count == now.mask.count, before.luma.count == now.luma.count,
              !now.mask.isEmpty else { return }
        let edge = UInt8(min(max(tuning.detection, 0), 1) * 255)
        for i in now.mask.indices where abs(now.luma[i] - before.luma[i]) < tuning.motion {
            flickerCounts.still += 1
            if (now.mask[i] >= edge) != (before.mask[i] >= edge) { flickerCounts.crossed += 1 }
        }
    }

    /// Once a second, or three times under Turbo, the key follows the light, easing 40% of the way to the newly
    /// measured colour so it never jumps. With no screen found, calibration keeps trying in case the screen went up
    /// or the lights on. Five misses in a row measure again from scratch, which also notices a screen taken down.
    private func balanceIfDue(_ pixels: CVPixelBuffer) {
        guard keyEnabled, !calibrating, !calibrationDue, !balancing, running else { return }
        let now = clock()
        guard let key else {
            // Either colour means a room with no screen keeps looking, so it looks less often. Not for the first
            // two minutes after a screen went missing, though: it's likely only hidden.
            let retry: CFTimeInterval = screen == .any && now - keyLostAt > 120 ? 30 : 10
            if now - lastBalance >= retry {
                lastBalance = now
                calibrationDue = true
            }
            return
        }
        guard now - lastBalance >= (turbo ? 1.0 / 3 : 1) else { return }
        lastBalance = now
        balancing = true
        let frame = FrameBox(pixels)
        let generation = calibrationGeneration
        calibrationQueue.async { [self] in
            let measured = GreenScreen.rebalance(frame: frame.pixels, key: key)
            queue.async { [self] in
                balancing = false
                guard generation == calibrationGeneration, self.key != nil else { return }
                balanceMisses = measured == nil ? balanceMisses + 1 : 0
                if balanceMisses >= 5 {
                    balanceMisses = 0
                    calibrationDue = true
                    Log.engine.notice("green screen mostly out of view 5 times running, measuring again")
                }
                guard let measured, var current = self.key else { return }
                let t: Float = 0.4
                let shift = hypot(measured.cb - current.cb, measured.cr - current.cr)
                current.cb += (measured.cb - current.cb) * t
                current.cr += (measured.cr - current.cr) * t
                current.near += (measured.near - current.near) * t
                current.far += (measured.far - current.far) * t
                current.rgb += (measured.rgb - current.rgb) * t
                if let plate = measured.plate { current.plate = current.plate?.eased(to: plate, t) ?? plate }
                self.key = current
                if simd_distance(current.rgb, reportedRGB) > 0.03 {
                    reportedRGB = current.rgb
                    status(.keyed(coverage: current.coverage, rgb: current.rgb))
                }
                if shift > 0.02 { Log.engine.notice("green screen drifted \(shift), following the light") }
            }
        }
    }

    static func ease(_ t: Double) -> Float {
        let x = min(max(t, 0), 1)
        return Float(x * x * (3 - 2 * x))
    }
}

/// Carries a camera buffer to the calibration queue, which only reads it.
private struct FrameBox: @unchecked Sendable {
    let pixels: CVPixelBuffer
    init(_ pixels: CVPixelBuffer) { self.pixels = pixels }
}
