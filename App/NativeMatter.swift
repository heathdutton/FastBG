import CoreMedia
import CoreVideo
import Foundation
import Metal
import ObjectiveC
import VideoToolbox

/// macOS's own person matte, from the private Portrait framework behind the system's Background effect.
///
/// - A true soft matte, hair and held objects included, where Vision's is a 512x384 outline that drops a mic.
/// - Cheaper: about 5 ms a frame, 1.4 ms of it CPU, against Vision's 8 and 4 on an M5 Pro.
/// - Private: everything is looked up at runtime, calls that could throw go through `FBSendCatching`, and anything
///   unexpected returns nil, which puts Vision back.
final class NativeMatter {
    private let effect: NSObject
    /// The effect's own queue, and the event it signals once a frame's matte is written.
    private let queue: MTLCommandQueue
    private let done: MTLSharedEvent
    private var signalled: UInt64 = 0
    private let requestClass: NSObject.Type
    /// Set by the first exception, after which this instance only returns nil.
    private var broken = false
    private let setBuffer: (NSObject, String, CVPixelBuffer?) -> Void
    private let background: CVPixelBuffer
    /// Where the composite would go. The effect is told it may skip writing it, but always gets somewhere to.
    private let scratch: CVPixelBuffer
    private let pool: CVPixelBufferPool
    private var time = 0.0
    /// Frames are converted to YUV, what cameras send and the effect is built for, rather than the BGRA they arrive in.
    static let yuvInput = ProcessInfo.processInfo.environment["FASTBG_MATTE_BGRA"] == nil
    private var transfer: VTPixelTransferSession?
    private var yuvPool: CVPixelBufferPool?

    /// The Background effect alone, configured the way macOS configures it for a camera app, minus Reactions (no
    /// hand detection) and with its composited output skipped, since only the matte is used.
    /// Running in a virtual machine, where the effect runs but hands back an empty matte, which would cut the person
    /// out entirely.
    static let inVirtualMachine: Bool = {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
    }()

    init?(device: MTLDevice, width: Int, height: Int) {
        guard !Self.inVirtualMachine else { return nil }
        let path = "/System/Library/PrivateFrameworks/Portrait.framework/Portrait"
        let background: Int64 = 64, quality: Int64 = 110
        guard dlopen(path, RTLD_LAZY) != nil,
              let descriptorClass = NSClassFromString("PTEffectDescriptor") as? NSObject.Type,
              let effectClass = NSClassFromString("PTEffect") as? NSObject.Type,
              let requestClass = NSClassFromString("PTEffectRenderRequest") as? NSObject.Type,
              let queue = device.makeCommandQueue() else { return nil }
        let keys = ["colorSize", "metalCommandQueue", "availableEffectTypes", "activeEffectType", "effectQuality",
                    "syncInitialization", "allowSkipOutColorBufferWrite"]
        let requestSelectors = ["setEffectType:", "setEffectQuality:", "setFrameTimeSeconds:", "setInColorBuffer:",
                                "setOutColorBuffer:", "setInBackgroundReplacementBuffer:",
                                "setOutPersonSegmentationMatteBuffer:"]
        let descriptor = descriptorClass.init()
        guard keys.allSatisfy({ descriptor.responds(to: NSSelectorFromString("set" + $0.prefix(1).uppercased()
                                                                               + $0.dropFirst() + ":")) }),
              requestSelectors.allSatisfy({ requestClass.instancesRespond(to: NSSelectorFromString($0)) })
        else { return nil }
        descriptor.setValue(NSValue(size: NSSize(width: width, height: height)), forKey: "colorSize")
        descriptor.setValue(queue, forKey: "metalCommandQueue")
        guard let done = device.makeSharedEvent() else { return nil }
        (self.queue, self.done) = (queue, done)
        let full = ProcessInfo.processInfo.environment["FASTBG_MATTE_FULL"] != nil
        descriptor.setValue(NSNumber(value: UInt64(full ? 115 : background)), forKey: "availableEffectTypes")
        descriptor.setValue(NSNumber(value: UInt64(background)), forKey: "activeEffectType")
        descriptor.setValue(NSNumber(value: quality), forKey: "effectQuality")
        descriptor.setValue(true, forKey: "syncInitialization")
        descriptor.setValue(!full, forKey: "allowSkipOutColorBufferWrite")
        guard let allocated = (effectClass as AnyObject).perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? NSObject else { return nil }
        var raw: Int = 0
        var reason: NSString?
        guard FBSendCatching(allocated, NSSelectorFromString("initWithDescriptor:"), descriptor, &raw, &reason),
              let pointer = UnsafeRawPointer(bitPattern: raw),
              let effect = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? NSObject,
              FBSendCatching(effect, NSSelectorFromString("waitForInitialization"), nil, &raw, &reason) else {
            Log.engine.error("macOS's matte failed to start: \(reason ?? "no effect", privacy: .public)")
            return nil
        }

        // `+personSegmentationMatteFormatForColorSize:` returns a 24-byte {CGSize, UInt32} struct, which arm64
        // hands back through a buffer the caller provides. Swift can't name that struct in a C function type, so
        // CMTime stands in: also 24 bytes and not all floating point, so it comes back the same way. Its fields
        // then hold the width's bits, the height's, and the format in the low half of the epoch.
        typealias Format = @convention(c) (AnyClass, Selector, CGSize) -> CMTime
        let formatSelector = NSSelectorFromString("personSegmentationMatteFormatForColorSize:")
        guard let formatMethod = class_getClassMethod(effectClass, formatSelector) else { return nil }
        let format = unsafeBitCast(method_getImplementation(formatMethod), to: Format.self)(
            effectClass, formatSelector, CGSize(width: width, height: height))
        let matteWidth = Double(bitPattern: UInt64(bitPattern: format.value))
        let heightBits = UInt64(UInt32(bitPattern: format.timescale)) | UInt64(format.flags.rawValue) << 32
        let matteHeight = Double(bitPattern: heightBits)
        let pixelFormat = OSType(truncatingIfNeeded: format.epoch)
        // The engine reads it as Vision's 8-bit mask. Anything else means the framework changed under us.
        guard pixelFormat == kCVPixelFormatType_OneComponent8, (64...4096).contains(Int(matteWidth)),
              (64...4096).contains(Int(matteHeight)) else { return nil }

        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var pool: CVPixelBufferPool?
        var poolAttrs = attrs
        poolAttrs[kCVPixelBufferPixelFormatTypeKey] = pixelFormat
        poolAttrs[kCVPixelBufferWidthKey] = Int(matteWidth)
        poolAttrs[kCVPixelBufferHeightKey] = Int(matteHeight)
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                poolAttrs as CFDictionary, &pool)
        // Its compositing step reads and writes the camera's own YUV, whatever format the input comes in.
        let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var black: CVPixelBuffer?, scratch: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, yuv, attrs as CFDictionary, &black)
        CVPixelBufferCreate(nil, width, height, yuv, attrs as CFDictionary, &scratch)
        guard let pool, let black, let scratch, effect.responds(to: NSSelectorFromString("render:")) else {
            return nil
        }
        self.effect = effect
        self.requestClass = requestClass
        self.setBuffer = { object, name, buffer in
            typealias Setter = @convention(c) (AnyObject, Selector, CVPixelBuffer?) -> Void
            let selector = NSSelectorFromString(name)
            unsafeBitCast(class_getMethodImplementation(type(of: object), selector), to: Setter.self)(
                object, selector, buffer)
        }
        self.background = black
        self.scratch = scratch
        self.pool = pool
    }

    /// The matte for one camera frame, 8-bit and IOSurface-backed like Vision's. The effect keeps state between
    /// frames, so frames go in order, one instance per camera.
    /// The matte, which isn't written till `ready` is signalled, and what it's read from till then.
    func mask(for frame: CVPixelBuffer) -> (matte: CVPixelBuffer, ready: GPUWait)? {
        guard !broken else { return nil }
        var matte: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &matte) == kCVReturnSuccess, let matte else { return nil }
        let request = requestClass.init()
        request.setValue(NSNumber(value: UInt64(64)), forKey: "effectType")
        request.setValue(NSNumber(value: Int64(110)), forKey: "effectQuality")
        request.setValue(NSNumber(value: time), forKey: "frameTimeSeconds")
        time += 1.0 / 30
        // The request's buffer properties don't retain, so each buffer has to outlive `render:` on its own.
        let input = Self.yuvInput ? yuv(frame) ?? frame : frame
        setBuffer(request, "setInColorBuffer:", input)
        setBuffer(request, "setOutColorBuffer:", scratch)
        setBuffer(request, "setInBackgroundReplacementBuffer:", background)
        setBuffer(request, "setOutPersonSegmentationMatteBuffer:", matte)
        var status = 0
        var reason: NSString?
        guard FBSendCatching(effect, NSSelectorFromString("render:"), request, &status, &reason) else {
            broken = true
            Log.engine.error("macOS's matte threw, using Vision: \(reason ?? "", privacy: .public)")
            return nil
        }
        // `render:` returns with its GPU work still running, about 4 ms of it. Commands on one queue run in order, so
        // an event signalled after them marks the matte done, and the compositor's GPU waits on it, not a thread.
        guard let signal = queue.makeCommandBuffer() else { return nil }
        signalled += 1
        signal.encodeSignalEvent(done, value: signalled)
        signal.commit()
        return (matte, GPUWait(event: done, value: signalled, inputs: [input]))
    }

    /// The frame converted to 8-bit 4:2:0 video range, on the GPU.
    private func yuv(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        if yuvPool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: CVPixelBufferGetWidth(frame),
                kCVPixelBufferHeightKey: CVPixelBufferGetHeight(frame),
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &yuvPool)
        }
        var out: CVPixelBuffer?
        guard let transfer, let yuvPool, CVPixelBufferPoolCreatePixelBuffer(nil, yuvPool, &out) == kCVReturnSuccess,
              let out, VTPixelTransferSessionTransferImage(transfer, from: frame, to: out) == noErr else { return nil }
        return out
    }
}
