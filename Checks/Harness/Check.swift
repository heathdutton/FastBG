// fastbg-check: drives the app's own pipeline code without the camera extension, which needs a signed build.
// Build with scripts/dev-build.sh check, fetch fixtures with Checks/fetch-fixtures.sh, then run e.g.
//   build/dev/fastbg-check all
// Output images land in build/checks. Nothing here opens the physical camera except `preview` and `noise`.
import AppKit
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

@main
struct Check {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print("""
            usage: fastbg-check <command>
              all                      composite, green, dissolve, videoplay, library, web and bench
              composite                person over a still, macOS's matte and Metal
              green                    green screen calibration, key and garbage matte
              dissolve                 500 ms dissolve, mid-dissolve switch
              videoplay                a stock clip at 30 and 22.8 fps cameras, lava or FASTBG_CLIP=<name>
              library                  import, thumbnails, loops, reorder, delete, stock, page copies, drag out
              web                      live page capture, 30 fps cap, static page goes quiet
              bench                    per-frame cost of the pipeline
              panel                    the menu bar panel with fixture items, to build/checks/panel.png
              menuicon                 the menu bar icon idle and in use, to build/checks/menu-icons.png
              setup                    the first-run checklist, to build/checks/setup.png
              social                   GitHub's social preview, to build/checks/social.jpg
              turbo                    a 22.8 fps camera paced to 30 fps with filled-in frames
              temporal                 the mask's temporal filter on a flipping patch
              keyjitter                hair-edge shimmer of the key under sensor noise
              despill                  green left on the person at each despill setting
              auto                     autocalibrate's readings and picks, and the blue screen
              native                   macOS's Background effect against FastBG on a known outline
              matchup                  FastBG against macOS's Background and Vision, on known alphas
              subject                  Vision's subject lifting, cost and coverage
              webshot                  a WebKit snapshot's cost per 1080p frame
              webcompare               ScreenCaptureKit against snapshots on an animated page
              noise                    the camera's real noise beside autocalibrate's reading (opens the camera)
              preview [image]          live camera through the pipeline in a window (opens the camera)
            """)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            var ok = true
            let checks: [String: @MainActor () async -> Bool] = [
                "composite": PipelineChecks.composite,
                "green": PipelineChecks.green,
                "dissolve": PipelineChecks.dissolve,
                "library": LibraryChecks.run,
                "web": WebChecks.run,
                "bench": PipelineChecks.bench,
                "panel": PanelShot.run,
                "menuicon": MenuIconShot.run,
                "setup": SetupShot.run,
                "social": SocialShot.run,
                "turbo": TurboCheck.run,
                "videoplay": VideoPlayCheck.run,
                "noise": NoiseProbe.run,
                "webshot": WebShotBench.run,
                "webcompare": WebCompare.run,
                "temporal": TemporalCheck.run,
                "keyjitter": KeyJitterCheck.run,
                "auto": AutoCheck.run,
                "despill": KeyJitterCheck.despill,
                "native": NativeCheck.run,
                "matchup": Matchup.run,
                "subject": SubjectProbe.run,
            ]
            switch command {
            case "all":
                for name in ["composite", "green", "dissolve", "videoplay", "library", "web", "bench"] {
                    print("== \(name)")
                    ok = await checks[name]!() && ok
                }
            case "preview":
                await Preview.run(background: args.dropFirst().first.map { URL(fileURLWithPath: $0) })
                return
            default:
                guard let check = checks[command] else {
                    print("unknown command \(command)")
                    exit(2)
                }
                ok = await check()
            }
            print(ok ? "ALL PASS" : "SOME FAILED")
            exit(ok ? 0 : 1)
        }
        app.run()
    }
}

/// Prints one result line and returns whether it passed.
@discardableResult
func expect(_ pass: Bool, _ what: String) -> Bool {
    print("\(pass ? "PASS" : "FAIL")  \(what)")
    return pass
}

/// A rate that says more about the Mac than the code. A virtual machine, like a CI runner, has no real GPU or Neural
/// Engine and a few slow cores, so there a miss is reported without failing the run.
func expectRate(_ pass: Bool, _ what: String) -> Bool {
    guard !pass, NativeMatter.inVirtualMachine else { return expect(pass, what) }
    print("SKIP  \(what), in a virtual machine")
    return true
}

enum Paths {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("Checks/Fixtures")
    static let out = repo.appendingPathComponent("build/checks")

    static func fixture(_ name: String) -> URL? {
        let url = fixtures.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("SKIP  missing fixture \(name): run Checks/fetch-fixtures.sh")
            return nil
        }
        return url
    }

    static func output(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out.appendingPathComponent(name)
    }

    static func temp(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fastbg-check-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

enum Pixels {
    static func pool(_ width: Int, _ height: Int) -> CVPixelBufferPool {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        return pool!
    }

    static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// An IOSurface-backed BGRA frame like the camera's, aspect-filled from `image`.
    static func frame(_ image: CGImage, width: Int = 1920, height: Int = 1080, shift: CGFloat = 0) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool(width, height), &pb)
        let pixels = pb!
        CVPixelBufferLockBaseAddress(pixels, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        let s = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        let origin = CGPoint(x: (CGFloat(width) - w) / 2 + shift, y: (CGFloat(height) - h) / 2)
        ctx.draw(image, in: CGRect(origin: origin, size: CGSize(width: w, height: h)))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// A solid colour still, written as a PNG the way import would leave an image: 8-bit sRGB, opaque.
    static func solidPNG(_ name: String, r: UInt8, g: UInt8, b: UInt8) -> URL {
        let url = Paths.temp("\(name).png")
        let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                                 alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        writePNG(ctx.makeImage()!, to: url)
        return url
    }

    /// One pixel's 8-bit RGB, whether the buffer is a BGRA camera frame or FastBG's 10-bit packed output.
    @inline(__always)
    static func pixel(_ base: UnsafePointer<UInt8>, _ row: Int, _ format: OSType, _ x: Int, _ y: Int) -> SIMD3<Int> {
        let p = base + y * row + x * 4
        guard format == kCVPixelFormatType_ARGB2101010LEPacked else { return SIMD3(Int(p[2]), Int(p[1]), Int(p[0])) }
        let v = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
        func eight(_ ten: UInt32) -> Int { Int((ten & 1023) * 255 + 511) / 1023 }
        return SIMD3(eight(v >> 20), eight(v >> 10), eight(v))
    }

    static func cgImage(_ pixels: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        return image
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    static func save(_ pixels: CVPixelBuffer, _ name: String) {
        guard let image = cgImage(pixels) else { return }
        let url = Paths.output(name)
        writePNG(image, to: url)
        print("      wrote \(url.path)")
    }

    static func rgb(_ pixels: CVPixelBuffer, _ x: Int, _ y: Int) -> SIMD3<Int> {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        return pixel(CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self),
                     CVPixelBufferGetBytesPerRow(pixels), CVPixelBufferGetPixelFormatType(pixels), x, y)
    }

    /// Gray levels of an 8-bit grayscale PNG, row-major.
    static func gray(_ url: URL) -> (width: Int, height: Int, values: [UInt8])? {
        guard let image = image(url) else { return nil }
        let w = image.width, h = image.height
        var values = [UInt8](repeating: 0, count: w * h)
        let ok = values.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, values) : nil
    }
}

/// Keeps what the engine sends, and lets a check read pixels the moment each frame lands.
final class CaptureSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var latest: CVPixelBuffer?
    private let inspect: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    init(inspect: (@Sendable (CVPixelBuffer, CMTime) -> Void)? = nil) {
        self.inspect = inspect
    }

    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        inspect?(pixelBuffer, time)
        lock.withLock {
            frames += 1
            latest = pixelBuffer
        }
    }

    var count: Int { lock.withLock { frames } }
    var last: CVPixelBuffer? { lock.withLock { latest } }
}

/// A clock an engine reads in place of real time, advanced by the check. The dissolve and matchup checks share it.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: CFTimeInterval = 1000
    var now: CFTimeInterval { lock.withLock { t } }
    func advance(_ dt: CFTimeInterval) { lock.withLock { t += dt } }
}

/// Feeds one camera frame through the engine and waits for the GPU to hand it back.
@MainActor
func feed(_ engine: Engine, _ pixels: CVPixelBuffer, at seconds: CFTimeInterval, sink: CaptureSink) async {
    let before = sink.count
    let frame = FrameRef(pixels)
    engine.queue.async {
        engine.process(camera: frame.pixels, time: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
    for _ in 0..<200 where sink.count == before {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

struct FrameRef: @unchecked Sendable {
    let pixels: CVPixelBuffer
    init(_ pixels: CVPixelBuffer) { self.pixels = pixels }
}

func sleep(_ seconds: Double) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}
