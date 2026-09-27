// The camera extension: a relay from the app's sink stream to the source stream video apps read, with a dark frame
// whenever the app goes quiet. Every CMIO callback, the timer and the sink loop run on Relay.queue, so Relay's state
// needs no locks.
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import Security

let readerKey = CMIOExtensionProperty(rawValue: FastbgCamera.readersProperty)
let frameDuration = CMTime(value: 1, timescale: FastbgCamera.fps)

final class Relay: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    let queue = DispatchQueue(label: "fastbg.relay", qos: .userInteractive)
    private(set) var provider: CMIOExtensionProvider!
    private(set) var device: CMIOExtensionDevice!
    private(set) var source: StreamSource!
    private(set) var sink: StreamSource!
    private var providerSource: ProviderSource!
    private var watcher: NSKeyValueObservation?
    let darkSample: CMSampleBuffer
    private(set) var readers = 0
    private var lastAppFrame: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var sinkClient: CMIOExtensionClient?
    private var sinkGeneration = 0
    private var parked: ClientBox?
    private var forwarded = 0
    private var dark = false

    override init() {
        darkSample = Relay.makeDarkSample()
        super.init()
        providerSource = ProviderSource(relay: self)
        provider = CMIOExtensionProvider(source: providerSource, clientQueue: queue)
        device = CMIOExtensionDevice(localizedName: FastbgCamera.name, deviceID: FastbgCamera.deviceID,
                                     legacyDeviceID: FastbgCamera.deviceUID, source: self)
        let format = CMIOExtensionStreamFormat(formatDescription: darkSample.formatDescription!,
                                               maxFrameDuration: frameDuration, minFrameDuration: frameDuration,
                                               validFrameDurations: nil)
        source = StreamSource(name: FastbgCamera.name, id: FastbgCamera.sourceStreamID, direction: .source,
                              format: format, relay: self)
        sink = StreamSource(name: "\(FastbgCamera.name) sink", id: FastbgCamera.sinkStreamID, direction: .sink,
                            format: format, relay: self)
        // Streams go in before addDevice: the DAL freezes a device's stream list when the device is added.
        try! device.addStream(source.stream)
        try! device.addStream(sink.stream)
        try! provider.addDevice(device)
        watcher = source.stream.observe(\.streamingClients) { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.recount() }
        }
    }

    /// streamingClients is the DAL's own list, so it stays right when a reader is killed and stopStream never comes.
    func recount() {
        let count = source.stream.streamingClients.count
        guard count != readers else { return }
        Log.relay.notice("readers \(self.readers) -> \(count)")
        readers = count
        if count > 0, let box = parked {
            parked = nil
            consume(from: box, generation: sinkGeneration)
        }
        let state = readerState()
        source.stream.notifyPropertiesChanged([readerKey: state])
        device.notifyPropertiesChanged([readerKey: state])
        count > 0 ? startTimer() : stopTimer()
    }

    func readerState() -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: String(readers) as NSString, attributes: .readOnlyPropertyAttribute)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Int(FastbgCamera.fps)),
                   leeway: .milliseconds(3))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Runs only while someone reads. A gap under a second is left alone, so apps hold the last frame through a
    /// hiccup instead of flashing dark.
    func tick() {
        recount()
        let now = hostNanos()
        let starved = readers > 0 && now &- lastAppFrame > 1_000_000_000
        if starved != dark {
            dark = starved
            let what = starved ? "no app frames for 1 s, sending dark frames" : "app frames back"
            Log.relay.notice("\(what, privacy: .public)")
        }
        guard starved else { return }
        send(darkSample, at: now)
    }

    /// A relaunched app is a new client, and the framework may not start the stream again for it, so its arrival
    /// alone moves the consumer over.
    func authorizeSink(_ client: CMIOExtensionClient) -> Bool {
        guard Self.mayFeedSink(client) else { return false }
        Log.relay.notice("sink authorized for pid \(client.pid)")
        let replaced = sinkClient.map { $0.clientID != client.clientID } ?? false
        if replaced { Log.relay.notice("a new app client replaces the old one") }
        sinkClient = client
        if replaced {
            sinkGeneration &+= 1
            parked = nil
            consume(from: ClientBox(client: client), generation: sinkGeneration)
        }
        return true
    }

    /// A client that quits or crashes never stops its stream.
    func clientLeft(_ client: CMIOExtensionClient) {
        if client.clientID == sinkClient?.clientID { sinkStopped() }
        recount()
    }

    func sinkStarted() {
        guard let client = sinkClient ?? sink.stream.streamingClients.first else {
            return Log.relay.error("sink started with no client to consume from")
        }
        Log.relay.notice("sink started")
        forwarded = 0
        sinkGeneration &+= 1
        consume(from: ClientBox(client: client), generation: sinkGeneration)
    }

    func sinkStopped() {
        Log.relay.notice("sink stopped")
        sinkGeneration &+= 1
        sinkClient = nil
        parked = nil
    }

    /// One consume in flight at a time. After a frame the next one is ~33 ms out, so the loop rests 20 ms. An empty
    /// queue or an error retries after 4 ms, doubling up to 100 ms while nothing comes, so a call that returns
    /// straight away can't spin and an app that stopped sending costs next to nothing.
    /// With no readers the loop parks: the app's queue then fills, and that backpressure tells the app nobody is
    /// watching even if the reader property never reaches it.
    private func consume(from box: ClientBox, generation: Int, idle: Double = 0.004) {
        guard generation == sinkGeneration else { return }
        guard readers > 0 else { return parked = box }
        sink.stream.consumeSampleBuffer(from: box.client) { [weak self] buffer, sequence, _, hasMore, error in
            if let error, idle >= 0.1 { Log.relay.debug("consume: \(error, privacy: .public)") }
            guard let self else { return }
            let sample = buffer.map(SampleBox.init)
            self.queue.async {
                guard generation == self.sinkGeneration else { return }
                var delay = idle
                var nextIdle = min(idle * 2, 0.1)
                if let sample {
                    self.forward(sample.buffer, sequence: sequence)
                    delay = hasMore ? 0 : 0.020
                    nextIdle = 0.004
                }
                let idle = nextIdle
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.consume(from: box, generation: generation, idle: idle)
                }
            }
        }
    }

    private func forward(_ buffer: CMSampleBuffer, sequence: UInt64) {
        forwarded += 1
        if forwarded == 1 { Log.relay.notice("first app frame, \(self.readers) readers") }
        let now = hostNanos()
        lastAppFrame = now
        if readers > 0 { send(buffer, at: now) }
        sink.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
    }

    /// Restamped with the send time, so timestamps stay monotonic across the switch between dark and app frames.
    func send(_ buffer: CMSampleBuffer, at now: UInt64) {
        let pts = CMTime(value: CMTimeValue(now), timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &out) == noErr,
              let out else { return }
        source.stream.send(out, discontinuity: [], hostTimeInNanoseconds: now)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, readerKey] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let out = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { out.transportType = Int(kIOAudioDeviceTransportTypeVirtual) }
        if properties.contains(.deviceModel) { out.model = FastbgCamera.name }
        if properties.contains(readerKey) { out.setPropertyState(readerState(), forProperty: readerKey) }
        return out
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    /// Only the fastbg app may feed the camera. CMIO often hands the extension no signing ID, and this extension runs
    /// as a system user that can't always read another user's process, so a check that can't run lets the client in
    /// and says so. One that runs and fails keeps it out.
    static func mayFeedSink(_ client: CMIOExtensionClient) -> Bool {
        // CMIO passes the literal "unknown" when it couldn't tell, which says nothing either way.
        if let id = client.signingID, id != "unknown" {
            let ok = id == FastbgCamera.appSigningID
            if !ok { Log.relay.error("sink refused for \(id, privacy: .public)") }
            return ok
        }
        guard let team = ownTeam else {
            Log.relay.error("sink allowed for pid \(client.pid): this extension's own team is unreadable")
            return true
        }
        var code: SecCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(FastbgCamera.appSigningID)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
        let guest = [kSecGuestAttributePid: client.pid] as CFDictionary
        let found = SecCodeCopyGuestWithAttributes(nil, guest, [], &code)
        guard found == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else {
            Log.relay.error("sink allowed for pid \(client.pid): its signature can't be read here (\(found))")
            return true
        }
        let checked = SecCodeCheckValidity(code, [], requirement)
        guard checked == errSecSuccess else {
            Log.relay.error("sink refused for pid \(client.pid): not the fastbg app (\(checked))")
            return false
        }
        Log.relay.notice("sink client pid \(client.pid) is the fastbg app")
        return true
    }

    /// The team this extension is signed by, which the app has to share.
    static let ownTeam: String? = {
        var me: SecCode?
        var file: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &file) == errSecSuccess, let file,
              SecCodeCopySigningInformation(file, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    static func makeDarkSample() -> CMSampleBuffer {
        let (w, h) = (Int(FastbgCamera.width), Int(FastbgCamera.height))
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, FastbgCamera.pixelFormat, attrs, &pixels)
        let pb = pixels!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        for row in 0..<h {
            let line = (base + row * CVPixelBufferGetBytesPerRow(pb)).bindMemory(to: UInt32.self, capacity: w)
            // Opaque black in 10-bit ARGB: alpha is the top 2 bits, then 10 each of red, green and blue. BGRA's
            // 0xFF000000 would put most of that byte into red.
            line.update(repeating: 0xC000_0000, count: w)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }
}

/// CMIOExtensionClient and CMSampleBuffer aren't Sendable; these carry them across the hop onto the relay queue.
struct ClientBox: @unchecked Sendable { let client: CMIOExtensionClient }
struct SampleBox: @unchecked Sendable { let buffer: CMSampleBuffer }

func hostNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

final class StreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private unowned let relay: Relay
    private let isSink: Bool

    init(name: String, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat,
         relay: Relay) {
        formats = [format]
        self.relay = relay
        isSink = direction == .sink
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction, clockType: .hostTime,
                                     source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        isSink ? [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
                  .streamSinkBuffersRequiredForStartup]
               : [.streamActiveFormatIndex, .streamFrameDuration, .streamMaxFrameDuration, readerKey]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let out = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { out.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { out.frameDuration = frameDuration }
        if properties.contains(.streamMaxFrameDuration) { out.maxFrameDuration = frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { out.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { out.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(readerKey) { out.setPropertyState(relay.readerState(), forProperty: readerKey) }
        return out
    }

    /// One format at one rate, so there's nothing a client can change.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        isSink ? relay.authorizeSink(client) : true
    }

    func startStream() throws { isSink ? relay.sinkStarted() : relay.recount() }
    func stopStream() throws { isSink ? relay.sinkStopped() : relay.recount() }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private unowned let relay: Relay
    init(relay: Relay) { self.relay = relay }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { relay.clientLeft(client) }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let out = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { out.manufacturer = FastbgCamera.name }
        return out
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
