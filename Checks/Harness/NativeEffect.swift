import CoreMedia
import CoreVideo
import Foundation
import Metal
import ObjectiveC
import VideoToolbox

/// macOS's own Background effect, driven directly through the private Portrait framework that runs it inside every
/// app reading a camera, so fastbg can be scored against it on the same frames. Dev-only: nothing here ships.
///
/// Every effect is available (types 115) at quality 110, as Photo Booth logs it. `type` picks the active one, 64
/// being Background alone, the way the app runs it.
final class NativeEffect {
    private let effect: NSObject
    /// The effect's queue. `render:` returns with its GPU work still running on it, a few ms of it.
    private let queue: MTLCommandQueue
    private let transfer: VTPixelTransferSession
    private let background: CVPixelBuffer
    /// Where the effect writes its person matte, sized and typed the way it asks.
    private let matteSize: CGSize
    private let matteFormat: OSType
    private(set) var matte: CVPixelBuffer?

    let effectType: UInt64

    /// Lean mode: Background alone in the available types, no colour output, and camera frames passed as BGRA.
    let lean: Bool

    init?(device: MTLDevice, background bgra: CVPixelBuffer, type: UInt64, lean: Bool = false) {
        self.effectType = type
        self.lean = lean
        guard dlopen("/System/Library/PrivateFrameworks/Portrait.framework/Portrait", RTLD_LAZY) != nil,
              let descriptorClass = NSClassFromString("PTEffectDescriptor") as? NSObject.Type,
              let effectClass = NSClassFromString("PTEffect") as? NSObject.Type,
              let queue = device.makeCommandQueue() else { return nil }
        let descriptor = descriptorClass.init()
        // The effect works at the camera's own size, which the background matches.
        let size = NSSize(width: CVPixelBufferGetWidth(bgra), height: CVPixelBufferGetHeight(bgra))
        descriptor.setValue(NSValue(size: size), forKey: "colorSize")
        descriptor.setValue(queue, forKey: "metalCommandQueue")
        self.queue = queue
        descriptor.setValue(NSNumber(value: lean ? type : UInt64(115)), forKey: "availableEffectTypes")
        if lean { descriptor.setValue(true, forKey: "allowSkipOutColorBufferWrite") }
        descriptor.setValue(NSNumber(value: type), forKey: "activeEffectType")
        descriptor.setValue(NSNumber(value: Int64(110)), forKey: "effectQuality")
        descriptor.setValue(true, forKey: "syncInitialization")
        guard let allocated = (effectClass as AnyObject).perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? NSObject,
              let effect = allocated.perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?
                .takeUnretainedValue() as? NSObject else { return nil }
        _ = effect.perform(NSSelectorFromString("waitForInitialization"))
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard let session, let bg = Self.convert(bgra, to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, session)
        else { return nil }
        self.effect = effect
        transfer = session
        background = bg
        // `+personSegmentationMatteFormatForColorSize:` returns a 24-byte {CGSize, UInt32} struct, which arm64
        // hands back through a buffer the caller provides. Swift can't name that struct in a C function type, so
        // CMTime stands in: also 24 bytes and not all floating point, so it comes back the same way. Its fields
        // then hold the width's bits, the height's, and the format in the low half of the epoch.
        typealias Format = @convention(c) (AnyClass, Selector, CGSize) -> CMTime
        let selector = NSSelectorFromString("personSegmentationMatteFormatForColorSize:")
        guard let method = class_getClassMethod(effectClass, selector) else { return nil }
        let raw = unsafeBitCast(method_getImplementation(method), to: Format.self)(effectClass, selector,
                                                                                   CGSize(width: 1920, height: 1080))
        let height = UInt64(UInt32(bitPattern: raw.timescale)) | UInt64(raw.flags.rawValue) << 32
        matteSize = CGSize(width: Double(bitPattern: UInt64(bitPattern: raw.value)), height: Double(bitPattern: height))
        matteFormat = OSType(truncatingIfNeeded: raw.epoch)
        guard (1...4096).contains(Int(matteSize.width)), (1...4096).contains(Int(matteSize.height)) else { return nil }
    }

    /// One camera frame through the effect, as BGRA. The effect keeps state between frames, like the camera does.
    func render(_ bgra: CVPixelBuffer, at time: Double) -> CVPixelBuffer? {
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let requestClass = NSClassFromString("PTEffectRenderRequest") as? NSObject.Type,
              let input = lean ? bgra : Self.convert(bgra, to: format, transfer),
              let output = Self.buffer(CVPixelBufferGetWidth(bgra), CVPixelBufferGetHeight(bgra), format)
        else { return nil }
        let request = requestClass.init()
        request.setValue(NSNumber(value: effectType), forKey: "effectType")
        request.setValue(NSNumber(value: Int64(110)), forKey: "effectQuality")
        request.setValue(NSNumber(value: time), forKey: "frameTimeSeconds")
        Self.set(request, "setInColorBuffer:", input)
        Self.set(request, "setOutColorBuffer:", output)
        Self.set(request, "setInBackgroundReplacementBuffer:", background)
        let matte = Self.buffer(Int(matteSize.width), Int(matteSize.height), matteFormat)
        Self.set(request, "setOutPersonSegmentationMatteBuffer:", matte)
        self.matte = matte
        typealias Render = @convention(c) (AnyObject, Selector, AnyObject) -> Int
        let selector = NSSelectorFromString("render:")
        let render = unsafeBitCast(class_getMethodImplementation(type(of: effect), selector), to: Render.self)
        _ = render(effect, selector, request)
        // An empty command buffer on the same queue finishes after the effect's, so the output is whole once it has.
        let fence = queue.makeCommandBuffer()
        fence?.commit()
        fence?.waitUntilCompleted()
        return Self.convert(output, to: kCVPixelFormatType_32BGRA, transfer)
    }

    private static func set(_ object: NSObject, _ name: String, _ buffer: CVPixelBuffer?) {
        typealias Setter = @convention(c) (AnyObject, Selector, CVPixelBuffer?) -> Void
        let selector = NSSelectorFromString(name)
        unsafeBitCast(class_getMethodImplementation(type(of: object), selector), to: Setter.self)(object, selector,
                                                                                                   buffer)
    }

    static func buffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &out)
        return out
    }

    static func convert(_ pixels: CVPixelBuffer, to format: OSType, _ session: VTPixelTransferSession)
        -> CVPixelBuffer? {
        guard let out = buffer(CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), format) else {
            return nil
        }
        return VTPixelTransferSessionTransferImage(session, from: pixels, to: out) == noErr ? out : nil
    }
}

/// Native Background against fastbg on the fixture with a known true outline: edge error near the outline.
@MainActor
enum NativeCheck {
    static func run() async -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let photo = Paths.fixture("portrait-home.jpg").flatMap(Pixels.image) else { return false }
        let frame = Pixels.frame(photo)
        let magenta = Pixels.frame(Pixels.image(Pixels.solidPNG("magenta", r: 255, g: 0, b: 255))!)
        let type = UInt64(ProcessInfo.processInfo.environment["FASTBG_NATIVE_TYPE"] ?? "") ?? 32
        guard let native = NativeEffect(device: device, background: magenta, type: type) else {
            return expect(false, "native: the Portrait framework's effect didn't start")
        }
        var out: CVPixelBuffer?
        for i in 0..<30 { out = native.render(frame, at: Double(i) / 30) }
        guard let out else { return expect(false, "native: no frame out") }
        Pixels.save(out, "native.png")
        if let matte = native.matte {
            let type = CVPixelBufferGetPixelFormatType(matte)
            print("      native matte \(CVPixelBufferGetWidth(matte))x\(CVPixelBufferGetHeight(matte)), format "
                  + String(format: "%08x", type))
            SubjectProbe.save(matte, "native-matte.png")
            // How the effect turns its matte into the alpha it composites with: triangulated from a second run over
            // green, bucketed by matte value.
            let green = Pixels.frame(Pixels.image(Pixels.solidPNG("green", r: 0, g: 255, b: 0))!)
            guard let other = NativeEffect(device: device, background: green, type: native.effectType) else {
                return false
            }
            var otherOut: CVPixelBuffer?
            for i in 0..<30 { otherOut = other.render(frame, at: Double(i) / 30) }
            guard let otherOut else { return false }
            let fromOutput = Matchup.triangulate(out, otherOut, sampled: true)
            var sums = [Double](repeating: 0, count: 21), counts = [Int](repeating: 0, count: 21)
            CVPixelBufferLockBaseAddress(matte, .readOnly)
            let base = CVPixelBufferGetBaseAddress(matte)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(matte)
            var total = 0.0, soft = 0.0, softN = 0, signed = 0.0
            for gy in 0..<(1080 / Matchup.step) {
                for gx in 0..<(1920 / Matchup.step) {
                    let m = Float(base[gy * Matchup.step * row + gx * Matchup.step]) / 255
                    let o = fromOutput[gy * (1920 / Matchup.step) + gx]
                    total += Double(abs(m - o))
                    let bucket = Int((m * 20).rounded())
                    sums[bucket] += Double(o)
                    counts[bucket] += 1
                    if m > 0.05 && m < 0.95 {
                        soft += Double(abs(m - o))
                        signed += Double(o - m)
                        softN += 1
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(matte, .readOnly)
            let n = Double((1080 / Matchup.step) * (1920 / Matchup.step))
            print(String(format: "      output vs matte: %.2f overall, %.2f where soft (output %+.2f on average)",
                         total / n * 100, soft / Double(max(softN, 1)) * 100, signed / Double(max(softN, 1)) * 100))
            print("      matte -> output alpha: " + (0...20).map { b in
                counts[b] == 0 ? "" : String(format: "%.2f:%.2f", Double(b) / 20, sums[b] / Double(counts[b]))
            }.filter { !$0.isEmpty }.joined(separator: " "))
        }
        let centre = Pixels.rgb(out, 60, 60)
        print("      native corner colour \(centre)")
        return expect(PipelineChecks.isMagenta(centre), "native: the effect replaced the background")
    }
}
