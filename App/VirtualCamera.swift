import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

/// The app's side of the fastbg camera: finds the extension's device, reports how many apps read it, and feeds
/// finished frames into its sink stream. Readers come from the extension's custom property, with two fallbacks in
/// case the DAL doesn't forward its changes:
///
/// - the device's running flag wakes the app while its sink is stopped
/// - a sink queue that stays full for a second means nobody is reading
final class VirtualCamera: FrameSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fastbg.virtualcamera", qos: .userInteractive)
    /// Readers of the fastbg camera, on `queue`. Nil means the count is unreadable while the sink runs.
    var onReaders: (@Sendable (Int?) -> Void)?
    private let presence = NSLock()
    private var present = false

    /// Still no camera after a device change and all the retries that follow it.
    var onMissing: (@Sendable () -> Void)?

    /// Whether `start` has run, after which a missing camera means something.
    var isStarted: Bool { queue.sync { started } }

    /// The camera's device is published. An extension can be enabled and still missing: after an update replaces
    /// it, launchd can drop its service until it's toggled off and on.
    var isPresent: Bool { presence.withLock { present } }

    // Touched only on `queue`.
    private var device: CMIODeviceID = 0
    private var source: CMIOStreamID = 0
    private var sink: CMIOStreamID = 0
    private var listeners: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    private var generation = 0
    /// The sink should run: set while someone reads, so a start that fails gets retried.
    private var wantSink = false
    /// One retry waiting at most, however many reader reports and rescans ask for a start meanwhile.
    private var sinkRetryPending = false
    private var rescanGeneration = 0
    private var started = false
    private var announcedMissing = false
    private var polling = false

    /// The devices notification doesn't reliably reach this process when the extension comes back, so while the
    /// camera is missing the list is read again every 2 s. About a millisecond each, and nothing once it's found.
    private func pollWhileMissing() {
        guard !polling else { return }
        polling = true
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            polling = false
            if device == 0 { rescan() }
        }
    }

    // Touched under `lock`, since frames arrive from Metal's threads.
    private let lock = NSLock()
    private var sinkQueue: CMSimpleQueue?
    private var format: CMVideoFormatDescription?
    private var fullSince: UInt64?
    private var sentSinceStart = 0

    /// The device can show up after launch (first approval) or come back with a new ID (reinstall), so the device
    /// list is watched for good.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            listen(CMIOObjectID(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices)) { $0.rescanSoon() }
            rescan()
        }
    }

    /// The devices notification can land while a replaced extension's new device isn't published yet, and nothing
    /// fires again once it is. So a change is followed by a few more looks over ~8 s, stopping once the camera's
    /// found. AVFoundation's camera-connected notification calls this too.
    func rescanSoon() {
        queue.async { [self] in
            rescanGeneration &+= 1
            let generation = rescanGeneration
            for delay in [0, 0.25, 0.5, 1, 2, 4, 8] {
                queue.asyncAfter(deadline: .now() + delay) { [self] in
                    guard generation == rescanGeneration, delay == 0 || device == 0 else { return }
                    rescan()
                    if delay == 8, device == 0 { onMissing?() }
                }
            }
        }
    }

    func startSink() {
        queue.async { [self] in
            wantSink = true
            startSinkNow()
        }
    }

    /// A start can fail while the device is still settling, or if the extension turns the client down. It's
    /// retried each second for as long as someone reads.
    private func startSinkNow() {
        guard wantSink, lock.withLock({ sinkQueue == nil }), sink != 0 else { return }
        var out: Unmanaged<CMSimpleQueue>?
        var status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &out)
        if status == noErr, let out {
            let q = out.takeRetainedValue()
            status = CMIODeviceStartStream(device, sink)
            if status == noErr {
                Log.sink.notice("sink started, queue holds \(CMSimpleQueueGetCapacity(q))")
                return lock.withLock {
                    sinkQueue = q
                    fullSince = nil
                    sentSinceStart = 0
                }
            }
        }
        Log.sink.error("sink didn't start (\(status)), retrying in 1 s")
        guard !sinkRetryPending else { return }
        sinkRetryPending = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            sinkRetryPending = false
            startSinkNow()
        }
    }

    func stopSink() {
        queue.async { [self] in
            wantSink = false
            stopSinkNow()
        }
    }

    /// For quitting: the extension shouldn't be left consuming from a client that's gone.
    func stopSinkBeforeExit() {
        queue.sync {
            wantSink = false
            stopSinkNow()
        }
    }

    /// Frames still queued when the extension parked its consumer are ours to release.
    private func stopSinkNow() {
        guard let q = lock.withLock({ () -> CMSimpleQueue? in
            defer {
                sinkQueue = nil
                format = nil
            }
            return sinkQueue
        }) else { return }
        Log.sink.notice("sink stopped")
        CMIODeviceStopStream(device, sink)
        while let element = CMSimpleQueueDequeue(q) {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
        }
    }

    /// A full queue means the extension hasn't taken the last frames yet. A fresh frame beats a late one, so this
    /// one is dropped rather than waited on.
    func send(_ pixels: CVPixelBuffer, time: CMTime) {
        let backedUp = lock.withLock { () -> Bool in
            guard let q = sinkQueue else { return false }
            guard CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let since = fullSince ?? now
                if fullSince == nil { Log.sink.notice("sink queue full, the extension isn't taking frames") }
                fullSince = since
                return now &- since > 1_000_000_000
            }
            fullSince = nil
            if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixels) }) ?? true {
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                             formatDescriptionOut: &format)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: FastbgCamera.fps),
                                            presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard let format, CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample else { return false }
            // The queue owns the buffer once enqueued; the DAL releases it after the extension consumes it.
            let element = Unmanaged.passRetained(sample)
            let status = CMSimpleQueueEnqueue(q, element: element.toOpaque())
            if status != noErr {
                element.release()
                Log.sink.error("enqueue failed: \(status)")
            } else {
                sentSinceStart += 1
                if sentSinceStart == 1 { Log.sink.notice("first frame into the sink") }
            }
            return false
        }
        // The extension parks its consumer once nobody reads, so a queue that stays full says so, unless the count
        // still reads above zero: then the consumer is what's gone, and a restarted sink gets a new one.
        if backedUp {
            queue.async { [self] in
                lock.withLock { fullSince = nil }
                if let n = readers(), n > 0 {
                    Log.sink.notice("queue full for 1 s with \(n) readers, restarting the sink")
                    stopSinkNow()
                    startSinkNow()
                } else {
                    Log.sink.notice("queue full for 1 s, taking that as nobody reading")
                    onReaders?(0)
                }
            }
        }
    }

    private func rescan() {
        let found = ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            .first { string($0, kCMIODevicePropertyDeviceUID) == FastbgCamera.deviceUID }
        if found == nil { pollWhileMissing() }
        guard found ?? 0 != device || (found == nil && !announcedMissing) else { return }
        forgetDevice()
        presence.withLock { present = found != nil }
        guard let found else {
            announcedMissing = true
            Log.sink.notice("fastbg camera not found: extension missing, not approved, or restarting")
            return onReaders?(0) ?? ()
        }
        announcedMissing = false
        let streams = ids(found, kCMIODevicePropertyStreams)
        // The DAL reports direction from the host's side: 1 is input (what apps read), 0 output (our sink).
        guard let src = streams.first(where: { uint32($0, kCMIOStreamPropertyDirection) == 1 }),
              let snk = streams.first(where: { uint32($0, kCMIOStreamPropertyDirection) == 0 }) else {
            Log.sink.error("fastbg camera \(found) has \(streams.count) streams, no source and sink pair")
            // A replaced extension can take a moment to show them, and nothing else would look again.
            pollWhileMissing()
            return onReaders?(0) ?? ()
        }
        (device, source, sink) = (found, src, snk)
        Log.sink.notice("found fastbg camera \(found), source \(src), sink \(snk)")
        startSinkNow()
        for object in [source, device] { listen(object, FastbgCamera.readersSelector) { $0.publishReaders() } }
        listen(device, UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere)) { $0.publishReaders() }
        publishReaders()
    }

    private func publishReaders() {
        let n = readers()
        Log.sink.notice("readers: \(n.map(String.init) ?? "unknown", privacy: .public)")
        onReaders?(n)
    }

    /// The running flag stands in only while our sink is stopped: our own sink start raises it too, so it can't
    /// show the last reader leaving.
    private func readers() -> Int? {
        for object in [source, device] where object != 0 {
            if let text = string(object, Int(FastbgCamera.readersSelector)), let n = Int(text) { return n }
        }
        guard device != 0, lock.withLock({ sinkQueue == nil }) else { return nil }
        return uint32(device, kCMIODevicePropertyDeviceIsRunningSomewhere).map(Int.init)
    }

    /// Listener blocks are dropped by generation as well as removed, because removal alone has been seen to keep
    /// delivering.
    private func listen(_ object: CMIOObjectID, _ selector: UInt32, _ body: @escaping (VirtualCamera) -> Void) {
        var address = Self.address(Int(selector))
        let generation = generation
        let system = object == CMIOObjectID(kCMIOObjectSystemObject)
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, system || generation == self.generation else { return }
            body(self)
        }
        if CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func forgetDevice() {
        stopSinkNow()
        generation &+= 1
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        for (object, address, block) in listeners where object != system {
            var a = address
            CMIOObjectRemovePropertyListenerBlock(object, &a, queue, block)
        }
        listeners.removeAll { $0.0 != system }
        (device, source, sink) = (0, 0, 0)
    }

    // MARK: CMIO property reads, global scope and main element

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func ids(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    /// CFString properties arrive +1: the caller owns them.
    private func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var address = Self.address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var address = Self.address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, 4, &used, &value) == noErr else { return nil }
        return value
    }
}
