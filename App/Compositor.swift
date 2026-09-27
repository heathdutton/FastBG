import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// One background input of the composite.
enum Layer {
    /// The camera frame itself, which is what Off shows.
    case camera
    case texture(MTLTexture)
    case buffer(CVPixelBuffer)
    /// A frozen texture mixed with the live camera by `camera`.
    case blend(MTLTexture, camera: Float)
}

/// Mirrors `CompositeUniforms` in Shaders.swift field for field.
private struct CompositeUniforms {
    var camXform = SIMD4<Float>(1, 1, 0, 0)
    var fromXform = SIMD4<Float>(1, 1, 0, 0)
    var toXform = SIMD4<Float>(1, 1, 0, 0)
    var keyRGB = SIMD4<Float>(0, 0, 0, 0)
    var dissolve: Float = 0
    var featherPx: Float = 1.5
    var edge: Float = 0.5
    var flags: UInt32 = 0
    var keyCbCr = SIMD2<Float>(0, 0)
    var keyNear: Float = 0
    var keyFar: Float = 1
    var spill: UInt32 = 0
    var fromCamera: Float = 0
    var toCamera: Float = 0
    var keyBlur: Float = 0
    var keyStill: Float = 1
    var plateMix: Float = 0
    var despill: Float = 1
    var motionLo: Float = 0.03
    var motionHi: Float = 0.10
    var keyTurn = SIMD2<Float>(1, 0)
    var edgeSoft: Float = 0
    var keyLinear: Float = 0
    var keyShift: Float = 0
    var keyWidth: Float = 1
}

/// Mirrors `TemporalUniforms` in Shaders.swift.
private struct TemporalUniforms {
    var stillWeight: Float = 1
    var motionLo: Float = 0.03
    var motionHi: Float = 0.10
    var edge: Float = 0.5
    var hysteresis: Float = 0
    var reset: UInt32 = 0
    var soft: Float = 0
    var roomNear: Float = 0.03
    var roomGain: Float = 1.0 / 60
    var roomHold: Float = 1
}

/// The knobs the panel exposes while matting and keying are tuned on real cameras.
struct Tuning: Equatable, Sendable {
    /// The mask level that counts as the person. Lower keeps more, like a chair back.
    var detection: Float = 0.5
    /// How much a still part of the frame averages its mask over time. 0 is off, 1 is heaviest.
    var smoothing: Float = 0.75
    /// Camera pixels out to the taps the key averages its colour over. Sensor noise jitters one pixel's colour,
    /// which makes hair edges shimmer. 0 keys each pixel alone.
    var keyDenoise: Float = 1.5
    /// How much a still part of the frame averages the key over time. 0 is off.
    var keySmoothing: Float = 0.5
    /// Moves the key's edge, in half ramp widths: up takes more away, down keeps more hair.
    var keyEdge: Float = 0
    /// Scales the ramp from screen to foreground. Wider is softer and calmer, narrower is crisper.
    var keySoftness: Float = 1
    /// 0 keys and unmixes against one colour for the whole screen, 1 against the screen's colour at that spot. The
    /// matchup found 1 best, and past it worse: it only exaggerates the plate's own errors.
    var localColor: Float = 1
    /// How hard green or blue bounce light is pulled out of the foreground: up to 1 gently, to 2 strongly.
    var despill: Float = 1
    /// How far, in mask texels, Vision's edge may move to land on an edge in the picture. 0 is off.
    var refine: Float = 4
    /// How faint a picture edge the refinement follows, as -log10 of the guided filter's epsilon. Higher follows
    /// fainter edges, and texture too.
    var refineDetail: Float = 2
    /// Half the width, in mask levels, of the fade across Vision's edge. 0 is a hard edge, higher lets hair and
    /// motion blur fade the way they do in the picture.
    var edgeSoftness: Float = 0.45
    /// How far the learned room may overrule a mask Vision isn't sure of. 0 ignores it.
    var roomMemory: Float = 1
    /// Colour distance, 0...1, within which a spot still matches the learned room. Auto sets it from the noise.
    var roomTolerance: Float = 0.03
    /// The brightness change, 0...1, that counts as movement. Both smoothers stop averaging where it moves, so
    /// lower trails less and higher calms more.
    var motion: Float = 0.03

    /// Turns the key's idea of the screen's hue, in degrees, from what was measured.
    var keyHue: Float = 0
    /// 0 keys by distance from the screen's chroma, 1 by colour difference, which keeps a wisp's share of alpha.
    var keyLinear: Float = 1

    /// One knob: where its value survives a relaunch, and the range the panel and auto keep it in.
    struct Knob: @unchecked Sendable {
        let key: String
        let path: WritableKeyPath<Tuning, Float>
        let range: ClosedRange<Float>
    }

    static let knobs: [Knob] = [
        Knob(key: "tuning.detection", path: \.detection, range: 0.2...0.8),
        Knob(key: "tuning.smoothing", path: \.smoothing, range: 0...1),
        Knob(key: "tuning.motion", path: \.motion, range: 0.005...0.1),
        Knob(key: "tuning.refine", path: \.refine, range: 0...8),
        Knob(key: "tuning.refineDetail", path: \.refineDetail, range: 1...6),
        Knob(key: "tuning.edgeSoftness", path: \.edgeSoftness, range: 0...0.5),
        Knob(key: "tuning.roomMemory", path: \.roomMemory, range: 0...1),
        Knob(key: "tuning.roomTolerance", path: \.roomTolerance, range: 0.01...0.1),
        Knob(key: "tuning.keyDenoise", path: \.keyDenoise, range: 0...3),
        Knob(key: "tuning.keySmoothing", path: \.keySmoothing, range: 0...1),
        Knob(key: "tuning.keyEdge", path: \.keyEdge, range: -1...1),
        Knob(key: "tuning.keySoftness", path: \.keySoftness, range: 0.25...3),
        Knob(key: "tuning.keyHue", path: \.keyHue, range: -30...30),
        Knob(key: "tuning.keyLinear", path: \.keyLinear, range: 0...1),
        Knob(key: "tuning.localColor", path: \.localColor, range: 0...1),
        Knob(key: "tuning.despill", path: \.despill, range: 0...2),
    ]

    static func knob(_ path: WritableKeyPath<Tuning, Float>) -> Knob? { knobs.first { $0.path == path } }

    /// Auto's pick leaned by the user's offsets, each kept in its knob's range.
    func nudged(_ offsets: [String: Float]) -> Tuning {
        var t = self
        for knob in Self.knobs {
            guard let offset = offsets[knob.key] else { continue }
            t[keyPath: knob.path] = min(max(t[keyPath: knob.path] + offset, knob.range.lowerBound),
                                        knob.range.upperBound)
        }
        return t
    }
}

private struct FreezeUniforms {
    var aXform = SIMD4<Float>(1, 1, 0, 0)
    var bXform = SIMD4<Float>(1, 1, 0, 0)
    var t: Float = 0
}

/// The Metal side of the pipeline: one composite pass per frame, plus a dilation pass with a green screen. Used only
/// from the engine queue.
final class Compositor {
    struct Job {
        var camera: CVPixelBuffer
        /// Nil when the green screen fills the background and the key alone decides.
        var mask: CVPixelBuffer?
        /// Work on another queue that writes the mask, which this frame's GPU work waits for.
        var maskReady: GPUWait?
        /// Non-nil with a green screen: the mask then only serves as a dilated garbage matte.
        var key: Key?
        var from: Layer
        /// Non-nil while a dissolve runs.
        var to: Layer?
        /// Eased dissolve progress.
        var mix: Float
        var tuning = Tuning()
    }

    static let width = Int(FastbgCamera.width), height = Int(FastbgCamera.height)
    /// The output's Metal format, matching `FastbgCamera.pixelFormat`.
    static let outputFormat = MTLPixelFormat.bgr10a2Unorm
    /// How far the garbage matte grows past Vision's edge, as a share of the frame width. Wide enough that its
    /// soft, lagging edge never cuts into hair or a fast hand; everything past it is the room left showing.
    static let dilation = 0.02
    /// The same for macOS's full-resolution matte, which sits on the true edge: just room for the key's wisps of
    /// hair, so a chair back beside the person stays out, as the native effect leaves it.
    static let fineDilation = 0.008

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let composite: MTLRenderPipelineState
    /// The composite plus a second target, the key and brightness it saw at each pixel, which the next frame
    /// averages over.
    private let compositeKeyed: MTLRenderPipelineState
    private let freezer: MTLRenderPipelineState
    private let temporal: MTLComputePipelineState
    /// Ping-pong mask state and camera brightness, at the mask's size: read one pair, write the other. Plus this
    /// frame's decided mask and camera colour at that size, for the refinement.
    private var history: (width: Int, height: Int, masks: [MTLTexture], lumas: [MTLTexture], front: Int,
                          decided: MTLTexture, guide: MTLTexture, inside: MTLTexture, rooms: [MTLTexture])?
    private var refinement: (diameter: Int, filter: MPSImageGuidedFilter, coefficients: MTLTexture)?
    private let cache: CVMetalTextureCache
    private let pool: CVPixelBufferPool
    private let white: MTLTexture
    private var matte: (width: Int, height: Int, dilate: MPSImageDilate, blur: MPSImageGaussianBlur,
                        dilated: MTLTexture, blurred: MTLTexture, shrink: (MPSImageBilinearScale, MTLTexture)?)?
    private var frozen: [MTLTexture] = []
    private var screen: (map: ScreenMap, texture: MTLTexture)?
    private var plate: (plate: ScreenPlate, texture: MTLTexture)?
    /// Ping-pong key state at output size. Stale once a frame goes out without the key.
    private var keyState: (textures: [MTLTexture], front: Int, valid: Bool)?
    private var frozenIndex = 0

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw CompositorError("no command queue") }
        self.queue = queue
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let library = try device.makeLibrary(source: Shaders.source, options: options)
        composite = try Self.pipeline(device, library, "compositeFS", Self.outputFormat)
        compositeKeyed = try Self.pipeline(device, library, "compositeKeyedFS", Self.outputFormat, extra: .rg16Float)
        freezer = try Self.pipeline(device, library, "freezeFS", .bgra8Unorm)
        guard let kernel = library.makeFunction(name: "temporalMask") else {
            throw CompositorError("no temporal kernel")
        }
        temporal = try device.makeComputePipelineState(function: kernel)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw CompositorError("no texture cache") }
        self.cache = cache
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: FastbgCamera.pixelFormat,
            kCVPixelBufferWidthKey: Self.width,
            kCVPixelBufferHeightKey: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        // No allocation threshold: readers can hold on to sent frames, and a capped pool would then starve.
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                attrs as CFDictionary, &pool)
        guard let pool else { throw CompositorError("no pixel buffer pool") }
        self.pool = pool
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: d) else { throw CompositorError("no texture") }
        var one: UInt8 = 255
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 1)
        self.white = white
    }

    private static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, _ fragment: String,
                                 _ format: MTLPixelFormat, extra: MTLPixelFormat? = nil)
        throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreenVS")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
        if let extra { d.colorAttachments[1].pixelFormat = extra }
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// Encodes and commits one output frame. `done` runs on a Metal thread once the GPU has finished. False means
    /// the frame was dropped.
    @discardableResult
    func render(_ job: Job, done: @escaping @Sendable (CVPixelBuffer) -> Void) -> Bool {
        var held: [CVMetalTexture] = []
        guard let out = outputBuffer(), let target = wrap(out, Self.outputFormat, &held),
              let cam = wrap(job.camera, .bgra8Unorm, &held),
              let cb = queue.makeCommandBuffer() else { return false }
        if let wait = job.maskReady { cb.encodeWaitForEvent(wait.event, value: wait.value) }
        let camXform = Self.aspectFill(cam.width, cam.height)
        var u = CompositeUniforms()
        u.camXform = camXform
        u.edge = job.tuning.detection
        u.edgeSoft = min(max(job.tuning.edgeSoftness, 0), 0.5)
        // Every step that can fail comes before the temporal history and the key state flip, so a frame that's
        // dropped never leaves them pointing at textures nothing wrote.
        guard let (from, fromXform) = resolve(job.from, cam, camXform, &held) else { return false }
        u.fromXform = fromXform
        if case .blend(_, let camera) = job.from { u.fromCamera = camera }
        var to = from
        if let layer = job.to, job.mix > 0 {
            guard let (t, toXform) = resolve(layer, cam, camXform, &held) else { return false }
            to = t
            u.toXform = toXform
            u.dissolve = job.mix
            if case .blend(_, let camera) = layer { u.toCamera = camera }
        }
        var mask = white, fence = white, screenMap = white
        if let pixels = job.mask {
            guard let m = wrap(pixels, .r8Unorm, &held) else { return false }
            mask = m
            // The garbage matte grows from the held in-or-out state, not Vision's raw mask, or anything Vision can't
            // decide on, like a chair in front of the screen, flickers straight through the key.
            var hold = m
            if let decided = encodeTemporal(cb, fresh: m, camera: cam, tuning: job.tuning) {
                mask = decided.mask
                hold = decided.inside
                if let fit = encodeRefinement(cb, decided.mask, guide: decided.guide, tuning: job.tuning) {
                    mask = fit
                    u.flags |= 128
                }
            }
            if job.key != nil, let matte = encodeGarbageMatte(cb, hold) { fence = matte }
        } else {
            u.flags |= 4
        }
        // With Vision off the screen fills the background, and the key alone decides everywhere.
        if job.mask != nil, let map = job.key?.screen, let texture = screenTexture(map) {
            screenMap = texture
            u.flags |= 16
        }
        var targets = [target], plateTexture = white, prior = white
        if let key = job.key {
            let t = job.tuning
            u.flags |= 1
            u.keyCbCr = SIMD2(key.cb, key.cr)
            let half = (key.far - key.near) / 2, width = half * max(t.keySoftness, 0.1)
            let mid = (key.near + key.far) / 2 + t.keyEdge * half
            u.keyNear = max(mid - width, 0.001)
            u.keyFar = mid + width
            u.keyRGB = SIMD4(key.rgb, 0)
            u.spill = key.spill
            u.keyBlur = max(t.keyDenoise, 0)
            u.keyStill = 1 - 0.9 * min(max(t.keySmoothing, 0), 1)
            u.plateMix = min(max(t.localColor, 0), 1)
            u.despill = min(max(t.despill, 0), 2)
            (u.motionLo, u.motionHi) = Self.motionRamp(t.motion)
            u.keyLinear = min(max(t.keyLinear, 0), 1)
            u.keyShift = t.keyEdge
            u.keyWidth = max(t.keySoftness, 0.1)
            let turn = t.keyHue * .pi / 180
            u.keyTurn = SIMD2(cos(turn), sin(turn))
            if let p = key.plate, let texture = self.plateTexture(p) {
                plateTexture = texture
                u.flags |= 64
            }
            if var state = keyStateTextures() {
                prior = state.textures[state.front]
                state.front ^= 1
                targets.append(state.textures[state.front])
                if state.valid { u.flags |= 32 }
                state.valid = true
                keyState = state
            }
        } else {
            keyState?.valid = false
        }
        encode(cb, targets.count > 1 ? compositeKeyed : composite, targets: targets,
               textures: [cam, mask, from, to, fence, screenMap, plateTexture, prior], uniforms: &u)
        finish(cb, out: out, camera: job.camera, held: held, keep: job.maskReady?.inputs ?? [], done: done)
        return true
    }

    /// The camera alone, aspect-filled to 1920x1080 and turned into the output's format: what Off sends.
    @discardableResult
    func scale(camera: CVPixelBuffer, done: @escaping @Sendable (CVPixelBuffer) -> Void) -> Bool {
        var held: [CVMetalTexture] = []
        guard let out = outputBuffer(), let target = wrap(out, Self.outputFormat, &held),
              let cam = wrap(camera, .bgra8Unorm, &held),
              let cb = queue.makeCommandBuffer() else { return false }
        var u = CompositeUniforms()
        u.camXform = Self.aspectFill(cam.width, cam.height)
        u.fromXform = u.camXform
        u.flags = 2
        encode(cb, composite, targets: [target], textures: [cam, white, cam, cam, white, white, white, white],
               uniforms: &u)
        finish(cb, out: out, camera: camera, held: held, done: done)
        return true
    }

    /// Bakes mix(from, to, t) of two backgrounds into a texture of its own, for a switch that lands mid-dissolve.
    /// Two textures take turns, because the dissolve being frozen may itself start from the previous freeze. The
    /// camera never goes in: the engine keeps its share live.
    func freeze(from: Layer, to: Layer, mix: Float) -> MTLTexture? {
        var held: [CVMetalTexture] = []
        guard let cb = queue.makeCommandBuffer(), let (a, aXform) = resolveBackground(from, &held),
              let (b, bXform) = resolveBackground(to, &held) else { return nil }
        if frozen.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width,
                                                             height: Self.height, mipmapped: false)
            d.storageMode = .private
            d.usage = [.renderTarget, .shaderRead]
            frozen = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
            guard frozen.count == 2 else {
                frozen = []
                return nil
            }
        }
        frozenIndex ^= 1
        let target = frozen[frozenIndex]
        var u = FreezeUniforms(aXform: aXform, bXform: bXform, t: mix)
        encode(cb, freezer, targets: [target], textures: [a, b], uniforms: &u)
        let refs = Refs(held)
        cb.addCompletedHandler { _ in _ = refs }
        cb.commit()
        return target
    }

    /// The texture cache pins every surface it has wrapped until a flush ages it out, so this runs once per frame
    /// and once more when compositing stops.
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }

    /// Releases the textures only a live pipeline needs.
    func idle() {
        frozen = []
        matte = nil
        screen = nil
        plate = nil
        keyState = nil
        history = nil
        refinement = nil
        flush()
    }

    /// The smoothed mask for this frame. Starts over whenever the mask changes size, which is also the first frame.
    private func encodeTemporal(_ cb: MTLCommandBuffer, fresh: MTLTexture, camera: MTLTexture,
                                tuning: Tuning) -> (mask: MTLTexture, guide: MTLTexture, inside: MTLTexture)? {
        var u = TemporalUniforms()
        let smoothing = min(max(tuning.smoothing, 0), 1)
        u.stillWeight = 1 - 0.95 * smoothing
        u.hysteresis = 0.15 * smoothing
        u.edge = tuning.detection
        (u.motionLo, u.motionHi) = Self.motionRamp(tuning.motion)
        u.soft = min(max(tuning.edgeSoftness, 0), 0.5)
        u.roomNear = min(max(tuning.roomTolerance, 0.005), 0.2)
        u.roomHold = min(max(tuning.roomMemory, 0), 1)
        var current = history
        if current?.width != fresh.width || current?.height != fresh.height {
            func texture(_ format: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: fresh.width,
                                                                 height: fresh.height, mipmapped: false)
                d.storageMode = .private
                d.usage = [.shaderRead, .shaderWrite]
                return device.makeTexture(descriptor: d)
            }
            let made = [texture(.rgba16Float), texture(.rgba16Float), texture(.r16Float), texture(.r16Float),
                        texture(.r16Float), texture(.rgba16Float), texture(.r8Unorm), texture(.rgba16Float),
                        texture(.rgba16Float)].compactMap { $0 }
            guard made.count == 9 else { return nil }
            // Kept only once the pass that fills them is encoded, so a failure here starts afresh next frame too.
            current = (fresh.width, fresh.height, [made[0], made[1]], [made[2], made[3]], 0, made[4], made[5],
                       made[6], [made[7], made[8]])
            u.reset = 1
        }
        guard var h = current, let enc = cb.makeComputeCommandEncoder() else { return nil }
        let (read, write) = (h.front, h.front ^ 1)
        enc.setComputePipelineState(temporal)
        for (i, t) in [fresh, h.masks[read], h.masks[write], camera, h.lumas[read], h.lumas[write], h.decided,
                       h.guide, h.inside, h.rooms[read], h.rooms[write]].enumerated() {
            enc.setTexture(t, index: i)
        }
        enc.setBytes(&u, length: MemoryLayout<TemporalUniforms>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: fresh.width, height: fresh.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        h.front = write
        history = h
        return (h.decided, h.guide, h.inside)
    }

    /// Fits the mask, around each texel, as a linear function of the camera's colour: He and Sun's fast guided
    /// filter, fitted at the mask's size. The composite applies the fit to the full-size camera.
    private func encodeRefinement(_ cb: MTLCommandBuffer, _ mask: MTLTexture, guide: MTLTexture,
                                  tuning: Tuning) -> MTLTexture? {
        let radius = Int(min(max(tuning.refine, 0), 8).rounded())
        guard radius > 0 else { return nil }
        if refinement?.diameter != 2 * radius + 1 || refinement?.coefficients.width != mask.width
            || refinement?.coefficients.height != mask.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: mask.width,
                                                             height: mask.height, mipmapped: false)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            guard let coefficients = device.makeTexture(descriptor: d) else { return nil }
            refinement = (2 * radius + 1, MPSImageGuidedFilter(device: device, kernelDiameter: 2 * radius + 1),
                          coefficients)
        }
        guard let refinement else { return nil }
        refinement.filter.epsilon = powf(10, -min(max(tuning.refineDetail, 1), 6))
        refinement.filter.encodeRegression(to: cb, sourceTexture: mask, guidanceTexture: guide, weightsTexture: nil,
                                           destinationCoefficientsTexture: refinement.coefficients)
        return refinement.coefficients
    }

    /// Uploaded once per calibration: the map only changes when the green screen is measured again.
    private func screenTexture(_ map: ScreenMap) -> MTLTexture? {
        if let screen, screen.map == map { return screen.texture }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: ScreenMap.width,
                                                         height: ScreenMap.height, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        map.values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, ScreenMap.width, ScreenMap.height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: ScreenMap.width)
        }
        screen = (map, texture)
        return texture
    }

    /// Below `lo` a brightness change is sensor noise, above `hi` it's movement.
    private static func motionRamp(_ motion: Float) -> (Float, Float) {
        let lo = min(max(motion, 0.005), 0.2)
        return (lo, lo * 3.3)
    }

    /// Uploaded when the plate changes, about once a second while the key follows the light.
    private func plateTexture(_ p: ScreenPlate) -> MTLTexture? {
        if let plate, plate.plate == p { return plate.texture }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: ScreenPlate.width,
                                                         height: ScreenPlate.height, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        let bytes = p.rgb.flatMap { c -> [UInt8] in
            let v = (simd_clamp(c, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * Float(255))
                .rounded(.toNearestOrAwayFromZero)
            return [UInt8(v.x), UInt8(v.y), UInt8(v.z), 255]
        }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, ScreenPlate.width, ScreenPlate.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: ScreenPlate.width * 4)
        }
        plate = (p, texture)
        return texture
    }

    private func keyStateTextures() -> (textures: [MTLTexture], front: Int, valid: Bool)? {
        if let keyState { return keyState }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: Self.width,
                                                         height: Self.height, mipmapped: false)
        d.storageMode = .private
        d.usage = [.renderTarget, .shaderRead]
        let made = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        guard made.count == 2 else { return nil }
        keyState = (made, 0, false)
        return keyState
    }

    private func outputBuffer() -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    /// `keep` is buffers another queue's work still reads, held till this frame's GPU work, which waited on it, ends.
    private func finish(_ cb: MTLCommandBuffer, out: CVPixelBuffer, camera: CVPixelBuffer, held: [CVMetalTexture],
                        keep: [CVPixelBuffer] = [], done: @escaping @Sendable (CVPixelBuffer) -> Void) {
        CVBufferPropagateAttachments(camera, out)
        let refs = Refs(held, out, keep)
        cb.addCompletedHandler { buffer in
            guard buffer.status == .completed, let out = refs.output else { return }
            done(out)
        }
        cb.commit()
        flush()
    }

    private func resolve(_ layer: Layer, _ cam: MTLTexture, _ camXform: SIMD4<Float>, _ held: inout [CVMetalTexture])
        -> (MTLTexture, SIMD4<Float>)? {
        if case .camera = layer { return (cam, camXform) }
        return resolveBackground(layer, &held)
    }

    private func resolveBackground(_ layer: Layer, _ held: inout [CVMetalTexture]) -> (MTLTexture, SIMD4<Float>)? {
        switch layer {
        case .camera:
            return nil
        case .texture(let t), .blend(let t, _):
            return (t, Self.aspectFill(t.width, t.height))
        case .buffer(let pixels):
            guard let t = wrap(pixels, .bgra8Unorm, &held) else { return nil }
            return (t, Self.aspectFill(t.width, t.height))
        }
    }

    /// Grows the mask by `dilation` of the frame width with a round probe, then blurs it. What it grows from is an
    /// in-or-out state, so without the blur the fence's edge would follow the mask's texels in visible steps wherever
    /// the room shows past the screen. Those texels aren't square in output space, so x and y get their own radius.
    private func encodeGarbageMatte(_ cb: MTLCommandBuffer, _ mask: MTLTexture) -> MTLTexture? {
        if matte?.width != mask.width || matte?.height != mask.height {
            // A full-size matte is grown at a quarter of its size: the probe's cost goes with its area.
            let fine = mask.width > 512
            let width = fine ? mask.width / 4 : mask.width, height = fine ? mask.height / 4 : mask.height
            let px = (fine ? Self.fineDilation : Self.dilation) * Double(Self.width)
            let rx = max(1, Int((px * Double(width) / Double(Self.width)).rounded()))
            let ry = max(1, Int((px * Double(height) / Double(Self.height)).rounded()))
            let kw = 2 * rx + 1, kh = 2 * ry + 1
            // MPSImageDilate takes the max of pixel minus probe, so 0 inside the ellipse and 1 outside makes a disk.
            var probe = [Float](repeating: 1, count: kw * kh)
            for y in 0..<kh {
                for x in 0..<kw {
                    let dx = Double(x - rx) / Double(rx), dy = Double(y - ry) / Double(ry)
                    if dx * dx + dy * dy <= 1 { probe[y * kw + x] = 0 }
                }
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height,
                                                             mipmapped: false)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            guard let dilated = device.makeTexture(descriptor: d), let blurred = device.makeTexture(descriptor: d),
                  let small = device.makeTexture(descriptor: d)
            else { return nil }
            matte = (mask.width, mask.height,
                     MPSImageDilate(device: device, kernelWidth: kw, kernelHeight: kh, values: probe),
                     MPSImageGaussianBlur(device: device, sigma: 1.5), dilated, blurred,
                     fine ? (MPSImageBilinearScale(device: device), small) : nil)
        }
        guard let matte else { return nil }
        var source = mask
        if let (scale, small) = matte.shrink {
            scale.encode(commandBuffer: cb, sourceTexture: mask, destinationTexture: small)
            source = small
        }
        matte.dilate.encode(commandBuffer: cb, sourceTexture: source, destinationTexture: matte.dilated)
        matte.blur.encode(commandBuffer: cb, sourceTexture: matte.dilated, destinationTexture: matte.blurred)
        return matte.blurred
    }

    private func encode<U: BitwiseCopyable>(_ cb: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState,
                                            targets: [MTLTexture], textures: [MTLTexture], uniforms: inout U) {
        let pass = MTLRenderPassDescriptor()
        for (i, target) in targets.enumerated() {
            pass.colorAttachments[i].texture = target
            pass.colorAttachments[i].loadAction = .dontCare
            pass.colorAttachments[i].storeAction = .store
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<U>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Zero-copy Metal view of an IOSurface-backed buffer. It and its CVMetalTexture go into `held` and must outlive
    /// the GPU work, or CoreVideo and Vision can recycle the surface under it.
    private func wrap(_ pixels: CVPixelBuffer, _ format: MTLPixelFormat, _ held: inout [CVMetalTexture])
        -> MTLTexture? {
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, format,
                                                        CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels),
                                                        0, &cv) == kCVReturnSuccess,
              let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        held.append(cv)
        held.append(pixels)
        return texture
    }

    /// UV scale and offset that aspect-fill a source into 1920x1080, cropping the overflow evenly.
    static func aspectFill(_ w: Int, _ h: Int) -> SIMD4<Float> {
        let sw = Float(w), sh = Float(h), dw = Float(width), dh = Float(height)
        let s = max(dw / sw, dh / sh)
        let fx = (dw / s) / sw, fy = (dh / s) / sh
        return SIMD4(fx, fy, (1 - fx) / 2, (1 - fy) / 2)
    }
}

/// Carries per-frame CoreVideo objects into Metal's Sendable completion handler, keeping them alive until then.
private final class Refs: @unchecked Sendable {
    let textures: [CVMetalTexture]
    let output: CVPixelBuffer?
    let buffers: [CVPixelBuffer]
    init(_ textures: [CVMetalTexture], _ output: CVPixelBuffer? = nil, _ buffers: [CVPixelBuffer] = []) {
        self.textures = textures
        self.output = output
        self.buffers = buffers
    }
}

/// A point on another queue's timeline, and the buffers its work reads until it gets there.
struct GPUWait: @unchecked Sendable {
    let event: MTLSharedEvent
    let value: UInt64
    let inputs: [CVPixelBuffer]
}

struct CompositorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
