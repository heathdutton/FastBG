import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// Turbo's steady 30 fps. A camera short of light slows down, a BRIO in a dim room to 22.8 fps, and a call then shows
/// one frame in four twice. While that lasts, frames go out on the pacer's own 30 fps clock instead, about a camera
/// frame late, and the gaps get frames macOS's frame rate conversion makes from the real ones either side, at full
/// resolution. A camera that keeps up, or Turbo off, passes straight through.
final class Pacer: FrameSink, @unchecked Sendable {
    static let rate = 30.0
    private static let period = 1 / rate
    /// Apart, so a camera hovering around 28 fps doesn't flip pacing on and off.
    private static let slowInterval = 1 / 27.0, fastInterval = 1 / 29.0
    /// A fill-in closer than this, as a share of the gap, to a real frame gets the real frame.
    private static let snap = 0.1
    private static let maxDelay = 0.2

    private let sink: FrameSink
    private let queue = DispatchQueue(label: "fastbg.pacer", qos: .userInteractive)
    /// Read on the sending thread, so frames skip the queue altogether with Turbo off.
    private let lock = NSLock()
    private var enabled = false

    private struct Held {
        let pixels: CVPixelBuffer
        let at: Double
        let look: [UInt16]
        var half: CVPixelBuffer?
    }

    // Touched only on `queue`.
    private var on = false
    private var filler: AnyObject?
    private var starting = false
    private var unavailable = false
    private var tooSlow = false
    private var interval: Double?
    /// From a frame's capture to its arrival here, camera and compositing both.
    private var latency: Double?
    private var fillTime = 0.025
    private var delay = 0.09
    private var pacing = false
    private var timer: DispatchSourceTimer?
    private var tickBase = 0.0
    private var held: [Held] = []
    private var filled: [(at: Double, pixels: CVPixelBuffer)] = []
    private var filling = false
    private var stats = (sent: 0, fills: 0, still: 0, late: 0, since: 0.0)

    /// The camera's frame rate while frames are being filled in, nil when they go straight out. Set before frames
    /// arrive; called on the pacer's queue.
    var onFilling: (@Sendable (Double?) -> Void)?

    init(sink: FrameSink) {
        self.sink = sink
    }

    /// Any thread.
    func setOn(_ on: Bool) {
        lock.withLock { enabled = on }
        queue.async { [self] in
            guard on != self.on else { return }
            self.on = on
            if !on {
                stopPacing()
                held.removeAll()
                (interval, latency) = (nil, nil)
                filler = nil
            }
        }
    }

    /// The camera closed. The session to fill frames stays for the next call while Turbo's on.
    func reset() {
        queue.async { [self] in
            stopPacing()
            held.removeAll()
            (interval, latency) = (nil, nil)
        }
    }

    /// How far behind it runs, how long a fill-in takes and how many came back too late, for the harness.
    func timing() -> (delay: Double, fill: Double, late: Int) {
        queue.sync { (delay, fillTime, stats.late) }
    }

    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard lock.withLock({ enabled }) else { return sink.send(pixelBuffer, time: time) }
        let arrived = CACurrentMediaTime(), frame = Handoff(value: pixelBuffer)
        queue.async { [self] in arrive(frame.value, at: time.seconds, arrived: arrived, time: time) }
    }

    private func arrive(_ pixels: CVPixelBuffer, at: Double, arrived: Double, time: CMTime) {
        guard on else { return sink.send(pixels, time: time) }
        if let last = held.last?.at, at - last > 0.005, at - last < 0.25 {
            interval = interval.map { $0 + 0.1 * (at - last - $0) } ?? at - last
        }
        if arrived - at >= 0, arrived - at < 0.25 {
            latency = latency.map { $0 + 0.1 * (arrived - at - $0) } ?? arrived - at
        }
        held.append(Held(pixels: pixels, at: at, look: pacing ? Self.look(pixels) : []))
        if held.count > 4 { held.removeFirst(held.count - 4) }

        let interval = interval ?? Self.period
        if pacing, interval < Self.fastInterval {
            stopPacing()
            Log.engine.notice("turbo: camera keeping up, frames go straight out")
        }
        // A fill-in has to be back well inside a camera frame, or pacing only adds delay. On an older Mac it may not.
        if !pacing, interval > Self.slowInterval {
            if filler == nil {
                startFiller()
            } else if fillTime < 0.6 * interval {
                startPacing()
            } else if !tooSlow {
                tooSlow = true
                Log.engine.notice("turbo: a fill-in takes \(Int(self.fillTime * 1000)) ms, too long to keep up")
            }
        }
        guard pacing else { return sink.send(pixels, time: time) }
        planFill()
    }

    /// Starting the session loads a model, which can take longer than a frame, so it happens off the frame path and
    /// frames go straight out till it's up.
    private func startFiller() {
        guard !starting, !unavailable else { return }
        starting = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let built: AnyObject? = if #available(macOS 15.4, *) { Filler() } else { nil }
            let made = Handoff(value: built)
            queue.async { [self] in
                starting = false
                guard on else { return }
                filler = made.value
                if #available(macOS 15.4, *), let warm = (filler as? Filler)?.warm { fillTime = warm }
                if filler == nil {
                    unavailable = true
                    Log.engine.error("turbo: frame rate conversion isn't available, frames go straight out")
                }
            }
        }
    }

    /// The delay is set once, and only grows, when a fill-in comes back too late for its tick. Moving it would move
    /// every planned frame's moment off the one it was made for.
    private func startPacing() {
        pacing = true
        // A fill-in is never nearer the earlier frame than `snap` of the gap, so it can wait that long for the next.
        delay = min((1 - Self.snap) * (interval ?? Self.period) + (latency ?? 0.01) + fillTime + 0.005, Self.maxDelay)
        stats = (0, 0, 0, 0, CACurrentMediaTime())
        let fps = 1 / (interval ?? Self.period)
        Log.engine.notice("""
            turbo: camera at \(String(format: "%.1f", fps), privacy: .public) fps, filling in to 30, \
            \(Int(self.delay * 1000)) ms behind, \(Int(self.fillTime * 1000)) ms a fill
            """)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        tickBase = CACurrentMediaTime()
        t.schedule(deadline: .now() + Self.period, repeating: Self.period, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        onFilling?(fps)
    }

    private func stopPacing() {
        timer?.cancel()
        timer = nil
        if pacing { onFilling?(nil) }
        pacing = false
        filled.removeAll()
    }

    /// Ticks sit on an exact 30 fps grid, whenever the timer happens to fire.
    private func tickTime(_ now: Double) -> Double {
        tickBase + ((now - tickBase) / Self.period).rounded() * Self.period
    }

    private func nextTick(_ now: Double) -> Double {
        tickBase + ((now - tickBase) / Self.period).rounded(.up) * Self.period
    }

    /// Asks for every frame the coming ticks will want between the last two camera frames, in one call.
    private func planFill() {
        guard held.count >= 2, !filling, #available(macOS 15.4, *), let filler = filler as? Filler else { return }
        let a = held[held.count - 2], b = held[held.count - 1]
        let span = b.at - a.at
        guard span > 0.01 else { return }
        var targets: [Double] = []
        var tick = nextTick(CACurrentMediaTime())
        while tick - delay < b.at {
            let phase = (tick - delay - a.at) / span
            if phase > Self.snap, phase < 1 - Self.snap { targets.append(tick - delay) }
            tick += Self.period
        }
        guard !targets.isEmpty else { return }
        // Nothing moved, so every frame between is the same picture.
        if Self.isStill(a.look, b.look) {
            stats.still += targets.count
            return
        }
        guard let first = held[held.count - 2].half ?? filler.half(a.pixels), let second = filler.half(b.pixels)
        else { return }
        held[held.count - 2].half = first
        held[held.count - 1].half = second
        filling = true
        let started = CACurrentMediaTime()
        let phases = targets.map { Float(($0 - a.at) / span) }, planned = targets
        let context = Handoff(value: (filler: filler, tags: a.pixels))
        filler.fill(from: first, at: a.at, to: second, at: b.at, phases: phases, tags: a.pixels) { [self] halves in
            queue.async { [self] in
                filling = false
                guard pacing, let halves = halves?.value else { return }
                let frames = halves.compactMap { context.value.filler.output($0, tags: context.value.tags) }
                let now = CACurrentMediaTime()
                fillTime += 0.1 * (now - started - fillTime)
                if let first = planned.first, first + delay < now {
                    delay = min(delay + 0.005, Self.maxDelay)
                    stats.late += 1
                }
                guard frames.count == planned.count else { return }
                filled.append(contentsOf: zip(planned, frames).map { (at: $0, pixels: $1) })
            }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let t = tickTime(now) - delay
        // A camera that stopped sends nothing, the same as without Turbo.
        guard let newest = held.last, t - newest.at < 0.5 else { return }
        filled.removeAll { $0.at < t - 0.02 }
        let time = CMTime(seconds: t, preferredTimescale: 1_000_000_000)
        if let i = filled.firstIndex(where: { abs($0.at - t) < 0.001 }) {
            sink.send(filled.remove(at: i).pixels, time: time)
            stats.fills += 1
        } else if let nearest = held.min(by: { abs($0.at - t) < abs($1.at - t) }) {
            sink.send(nearest.pixels, time: time)
        }
        stats.sent += 1
        if now - stats.since >= 30 {
            let fps = 1 / (interval ?? Self.period)
            Log.engine.notice("""
                turbo: \(self.stats.sent) frames out in \(Int(now - self.stats.since)) s, \(self.stats.fills) filled \
                in, \(self.stats.still) still, \(self.stats.late) late, camera at \
                \(String(format: "%.1f", fps), privacy: .public) fps, \(Int(self.delay * 1000)) ms behind, \
                \(Int(self.fillTime * 1000)) ms a fill
                """)
            stats = (0, 0, 0, 0, now)
        }
    }

    /// 48x27 cells, each the mean green of four samples.
    static func look(_ pixels: CVPixelBuffer) -> [UInt16] {
        guard CVPixelBufferGetPixelFormatType(pixels) == FastbgCamera.pixelFormat,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        var out = [UInt16](repeating: 0, count: 48 * 27)
        for cy in 0..<27 {
            for cx in 0..<48 {
                var sum: UInt32 = 0
                for (dx, dy) in [(0.3, 0.3), (0.7, 0.3), (0.3, 0.7), (0.7, 0.7)] {
                    let x = Int((Double(cx) + dx) * Double(w) / 48), y = Int((Double(cy) + dy) * Double(h) / 27)
                    let word = base.load(fromByteOffset: y * row + x * 4, as: UInt32.self)
                    sum += (word >> 10) & 0x3FF
                }
                out[cy * 48 + cx] = UInt16(sum / 4)
            }
        }
        return out
    }

    /// Strict, since a miss costs a repeated frame where a fill-in belonged: at most two cells changed by more than
    /// about 1%, the camera's noise in good light.
    static func isStill(_ a: [UInt16], _ b: [UInt16]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).lazy.filter { abs(Int($0) - Int($1)) > 10 }.count <= 2
    }
}

/// The frame rate conversion session and the buffers around it. Frames convert to half float and back losslessly.
@available(macOS 15.4, *)
private final class Filler {
    private let processor = VTFrameProcessor()
    private let transfer: VTPixelTransferSession
    private let halves: CVPixelBufferPool
    private let outputs: CVPixelBufferPool
    private var lastNext: Double?
    /// How long a fill-in took once the model was loaded, including the trip back to the camera's format.
    private(set) var warm: Double?

    init?() {
        guard VTFrameRateConversionConfiguration.isSupported,
              let config = VTFrameRateConversionConfiguration(
                frameWidth: Int(FastbgCamera.width), frameHeight: Int(FastbgCamera.height), usePrecomputedFlow: false,
                qualityPrioritization: .normal, revision: .revision1) else { return nil }
        do {
            try processor.startSession(configuration: config)
        } catch {
            Log.engine.error("turbo: frame rate conversion didn't start: \(error, privacy: .public)")
            return nil
        }
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        let output: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: FastbgCamera.pixelFormat,
            kCVPixelBufferWidthKey: FastbgCamera.width,
            kCVPixelBufferHeightKey: FastbgCamera.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var halves: CVPixelBufferPool?, outputs: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, config.sourcePixelBufferAttributes as CFDictionary, &halves)
        CVPixelBufferPoolCreate(nil, nil, output as CFDictionary, &outputs)
        guard let session, let halves, let outputs else { return nil }
        (transfer, self.halves, self.outputs) = (session, halves, outputs)
        warmUp()
    }

    /// Two fill-ins between blank frames, so the first real one doesn't also pay for loading the model, and the
    /// second one's time says how far behind the pacer has to run.
    private func warmUp() {
        var blank: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, outputs, &blank)
        guard let blank, let a = half(blank), let b = half(blank) else { return }
        for _ in 0..<2 {
            let started = CACurrentMediaTime(), finished = DispatchSemaphore(value: 0), made = Slot()
            fill(from: a, at: 0, to: b, at: 1 / Pacer.rate, phases: [0.5], tags: blank) {
                made.frames = $0?.value
                finished.signal()
            }
            finished.wait()
            guard let first = made.frames?.first, output(first, tags: blank) != nil else { return }
            warm = CACurrentMediaTime() - started
        }
        lastNext = nil
    }

    deinit {
        processor.endSession()
    }

    /// The same frame as half float, tagged alike so the transfer only changes the format.
    func half(_ pixels: CVPixelBuffer) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, halves, &out)
        guard let out else { return nil }
        CVBufferPropagateAttachments(pixels, out)
        return VTPixelTransferSessionTransferImage(transfer, from: pixels, to: out) == noErr ? out : nil
    }

    /// Back to the camera's format, tagged like `tags`.
    func output(_ half: CVPixelBuffer, tags: CVPixelBuffer) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, outputs, &out)
        guard let out else { return nil }
        CVBufferPropagateAttachments(tags, out)
        return VTPixelTransferSessionTransferImage(transfer, from: half, to: out) == noErr ? out : nil
    }

    /// The frames at `phases` of the way from the first to the second, still half float. `done` is called on the
    /// processor's own thread.
    func fill(from first: CVPixelBuffer, at a: Double, to second: CVPixelBuffer, at b: Double, phases: [Float],
              tags: CVPixelBuffer, done: @escaping @Sendable (Handoff<[CVPixelBuffer]>?) -> Void) {
        func time(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: 1_000_000_000) }
        var destinations: [CVPixelBuffer] = []
        for _ in phases {
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, halves, &out)
            guard let out else { return done(nil) }
            CVBufferPropagateAttachments(tags, out)
            destinations.append(out)
        }
        // Sequential lets it carry work over when this pair's first frame was the last pair's second.
        let mode: VTFrameRateConversionParameters.SubmissionMode = lastNext == a ? .sequential : .random
        lastNext = b
        guard let source = VTFrameProcessorFrame(buffer: first, presentationTimeStamp: time(a)),
              let next = VTFrameProcessorFrame(buffer: second, presentationTimeStamp: time(b)) else { return done(nil) }
        let frames = zip(destinations, phases).compactMap { buffer, phase in
            VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time(a + Double(phase) * (b - a)))
        }
        guard frames.count == phases.count, let parameters = VTFrameRateConversionParameters(
            sourceFrame: source, nextFrame: next, opticalFlow: nil, interpolationPhase: phases,
            submissionMode: mode, destinationFrames: frames) else { return done(nil) }
        let result = Handoff(value: destinations)
        processor.process(parameters: parameters) { _, error in
            if let error { Log.engine.error("turbo: a fill-in failed: \(error, privacy: .public)") }
            done(error == nil ? result : nil)
        }
    }
}

/// Carries buffers from one queue to another, for a sender that doesn't touch them again once they're handed over.
struct Handoff<T>: @unchecked Sendable {
    let value: T
}

/// Where a fill-in's frames land while the caller waits on them.
private final class Slot: @unchecked Sendable {
    var frames: [CVPixelBuffer]?
}
