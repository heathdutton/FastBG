import AVFoundation
import QuartzCore

/// The camera's noise as it really is, beside what autocalibrate reads from it: 3 s of the preferred camera, at the
/// format it's already in, so a call using it isn't disturbed. Opens the camera, so run it only when asked.
final class NoiseProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(t: Double, luma: [Float], sample: [SIMD3<Float>])] = []
    /// Luma on a 192x108 grid, 0 to 1.
    static func lumaGrid(_ pixels: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        var out: [Float] = []
        for gy in 0..<108 {
            for gx in 0..<192 {
                let p = base + ((gy * 2 + 1) * h / 216) * row + ((gx * 2 + 1) * w / 384) * 4
                out.append((0.299 * Float(p[2]) + 0.587 * Float(p[1]) + 0.114 * Float(p[0])) / 255)
            }
        }
        return out
    }

    /// Grain within one frame: each pixel against the mean of its four neighbours, where the picture is flat.
    static func spatialNoise(_ pixels: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        func l(_ x: Int, _ y: Int) -> Float {
            let p = base + y * row + x * 4
            return (0.299 * Float(p[2]) + 0.587 * Float(p[1]) + 0.114 * Float(p[0])) / 255
        }
        var residuals: [Float] = []
        for y in stride(from: 4, to: h - 4, by: 9) {
            for x in stride(from: 4, to: w - 4, by: 9) {
                let n = [l(x - 1, y), l(x + 1, y), l(x, y - 1), l(x, y + 1)]
                // Flat: the neighbours agree, so the difference is grain, not an edge.
                guard (n.max()! - n.min()!) < 0.03 else { continue }
                residuals.append(abs(l(x, y) - n.reduce(0, +) / 4))
            }
        }
        residuals.sort()
        // Median absolute residual to a standard deviation, for the four-neighbour mean's own share of the noise.
        return residuals.isEmpty ? 0 : residuals[residuals.count / 2] / 0.6745 / Float(1.25).squareRoot()
    }

    private var spatial: [Float] = []

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = sampleBuffer.imageBuffer else { return }
        let entry = (sampleBuffer.presentationTimeStamp.seconds, Self.lumaGrid(pixels), AutoTune.sample(pixels))
        let grain = Self.spatialNoise(pixels)
        lock.withLock {
            frames.append(entry)
            spatial.append(grain)
        }
    }

    @MainActor
    static func run() async -> Bool {
        let probe = NoiseProbe()
        guard let device = Camera.resolve(nil) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return expect(false, "noise: no camera") }
        let session = AVCaptureSession()
        let (format, fastest, slowest) = (device.activeFormat, device.activeVideoMinFrameDuration,
                                          device.activeVideoMaxFrameDuration)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let queue = DispatchQueue(label: "noise-probe")
        output.setSampleBufferDelegate(probe, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return expect(false, "noise: busy") }
        session.addInput(input)
        session.addOutput(output)
        // Set back to the format and frame rates the camera's already running, so a call using it keeps them.
        if (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            device.activeVideoMinFrameDuration = fastest
            device.activeVideoMaxFrameDuration = slowest
            device.unlockForConfiguration()
        }
        session.startRunning()
        await sleep(3.5)
        session.stopRunning()
        let (frames, spatial) = probe.lock.withLock { (probe.frames, probe.spatial) }
        guard frames.count > 20 else { return expect(false, "noise: only \(frames.count) frames") }
        let used = Array(frames.dropFirst(10))
        let fps = Double(used.count - 1) / (used.last!.t - used.first!.t)
        // What autocalibrate reads: its estimator on each pair in a row.
        let reads = zip(used, used.dropFirst()).compactMap { AutoTune.noise($0.sample, $1.sample) }
        let auto = reads.map(\.luma).sorted()[reads.count / 2]
        let autoChroma = reads.map(\.chroma).sorted()[reads.count / 2]
        // The truth over time: each grid point's spread across the frames, the median point, where it's still.
        var perPoint: [Float] = []
        for i in used[0].luma.indices {
            let v = used.map { $0.luma[i] }
            let mean = v.reduce(0, +) / Float(v.count)
            let sd = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(v.count - 1)).squareRoot()
            if v.max()! - v.min()! < 0.15 { perPoint.append(sd) }
        }
        perPoint.sort()
        let temporal = perPoint.isEmpty ? 0 : perPoint[perPoint.count / 2]
        let level = used.flatMap(\.luma).reduce(0, +) / Float(used.count * used[0].luma.count)
        let grain = spatial.sorted()[spatial.count / 2]
        print(String(format: "      %@ at %.1f fps, mean level %.1f%%", device.localizedName, fps, level * 100))
        print(String(format: "      autocalibrate reads %.2f%% luma, %.2f%% chroma (median of %d pairs)",
                     auto * 100, autoChroma * 100, reads.count))
        print(String(format: "      frame to frame %.2f%% luma (median still point), grain within a frame %.2f%%",
                     temporal * 100, grain * 100))
        return expect(true, "noise: measured")
    }
}
