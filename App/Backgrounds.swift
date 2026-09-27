import CoreVideo
import Foundation
import Metal
import MetalKit

enum BackgroundFrame {
    case texture(MTLTexture)
    /// IOSurface-backed BGRA, wrapped for Metal with no copy.
    case buffer(CVPixelBuffer)
}

/// Something that can sit behind the person. Sources are created on the main actor when their tile becomes active
/// while someone is reading the camera, report `ready` once they have a first frame, and are closed once they've
/// dissolved away.
protocol BackgroundSource: AnyObject, Sendable {
    /// The newest frame, pulled once per output frame on the engine queue. Nil only before the first frame.
    func frame(at hostTime: CFTimeInterval) -> BackgroundFrame?
    /// Frees players, windows and streams. Called once.
    @MainActor func close()
}

/// A still, decoded once into a private texture and held while it's in use.
final class StillSource: BackgroundSource, @unchecked Sendable {
    private let lock = NSLock()
    private var texture: MTLTexture?

    init(url: URL, device: MTLDevice, ready: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let texture = try? Self.load(url, device: device)
            if let self, let texture { self.lock.withLock { self.texture = texture } }
            ready(texture != nil)
        }
    }

    /// Import already made the file upright 8-bit sRGB, the only shape this loader handles faithfully.
    static func load(_ url: URL, device: MTLDevice) throws -> MTLTexture {
        let opts: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .generateMipmaps: false,
        ]
        return try MTKTextureLoader(device: device).newTexture(URL: url, options: opts)
    }

    func frame(at hostTime: CFTimeInterval) -> BackgroundFrame? {
        lock.withLock { texture.map(BackgroundFrame.texture) }
    }

    @MainActor func close() {
        lock.withLock { texture = nil }
    }
}
