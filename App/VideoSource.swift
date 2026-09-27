import AVFoundation
import CoreVideo

/// A looping, muted clip, decoded in hardware and pulled once per output frame by host time.
///
/// AVPlayerLooper plays replicas of the template item, and replicas don't inherit its outputs, so each replica gets
/// its own AVPlayerItemVideoOutput, picked through `player.currentItem`. `currentItem`, `outputs` and the video output
/// itself are safe off the main actor, so the engine queue pulls frames without a hop.
final class VideoSource: BackgroundSource, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()
    @MainActor private var player: AVQueuePlayer?
    @MainActor private var looper: AVPlayerLooper?
    @MainActor private var replicaWatch: NSKeyValueObservation?
    @MainActor private var closed = false

    private struct State {
        var player: AVQueuePlayer?
        /// Replica outputs in play order, so a replica that runs dry a tick early can hand over to the next.
        var ring: [(ObjectIdentifier, AVPlayerItemVideoOutput)] = []
        var duration = CMTime.zero
        var last: CVPixelBuffer?
    }

    @MainActor
    init(url: URL, ready: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor [weak self] in
            let ok = await self?.start(url) ?? false
            ready(ok)
        }
    }

    /// Plays, then waits for the first decoded frame, so the dissolve starts on a real picture.
    @MainActor
    private func start(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        // Until the duration is known the looper sits in .unknown and builds no replicas.
        guard let duration = try? await asset.load(.duration), duration > .zero, !closed else { return false }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        self.player = player
        self.looper = looper
        lock.withLock {
            state.player = player
            state.duration = duration
        }
        attachOutputs()
        // KVO can fire off the main thread, where an actor-isolated closure would trap.
        replicaWatch = looper.observe(\.loopingPlayerItems) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.attachOutputs() }
        }
        player.play()
        for _ in 0..<90 {
            if closed || looper.status == .failed { return false }
            if frame(at: CACurrentMediaTime()) != nil { return true }
            try? await Task.sleep(for: .milliseconds(33))
        }
        return false
    }

    @MainActor
    private func attachOutputs() {
        guard let looper else { return }
        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var ring: [(ObjectIdentifier, AVPlayerItemVideoOutput)] = []
        for item in looper.loopingPlayerItems {
            let output = item.outputs.lazy.compactMap { $0 as? AVPlayerItemVideoOutput }.first
                ?? AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            if !item.outputs.contains(where: { $0 === output }) { item.add(output) }
            ring.append((ObjectIdentifier(item), output))
        }
        lock.withLock { state.ring = ring }
    }

    func frame(at hostTime: CFTimeInterval) -> BackgroundFrame? {
        let (player, ring, duration, last) = lock.withLock { (state.player, state.ring, state.duration, state.last) }
        guard let player, let item = player.currentItem,
              let index = ring.firstIndex(where: { $0.0 == ObjectIdentifier(item) })
        else { return last.map(BackgroundFrame.buffer) }
        let output = ring[index].1
        var fresh = Self.pull(output, hostTime)
        // Near the end the current replica can run dry a tick before the player advances. The next replica sits
        // at zero with its first frame prerolled, so taking it early keeps the cadence across the loop.
        if fresh == nil, ring.count > 1, (duration - output.itemTime(forHostTime: hostTime)).seconds < 2.0 / 30 {
            fresh = Self.pull(ring[(index + 1) % ring.count].1, hostTime)
        }
        guard let fresh else { return last.map(BackgroundFrame.buffer) }
        lock.withLock { state.last = fresh }
        return .buffer(fresh)
    }

    private static func pull(_ output: AVPlayerItemVideoOutput, _ hostTime: CFTimeInterval) -> CVPixelBuffer? {
        let t = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }

    @MainActor func close() {
        closed = true
        replicaWatch = nil
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        player = nil
        looper = nil
        lock.withLock { state = State() }
    }
}
