// Synthesizes the green screen fixtures from Fixtures/portrait-home.jpg: the person is cut out with Vision at
// .accurate and composited over a green screen, so the true alpha is known exactly.
//
// - green-partial.png: the screen covers only the middle of the frame (a pop-up screen seen by a wide camera),
//   and the room shows around it
// - green-full.png: the screen fills the whole background
// - green-alpha.png: the person's alpha used for both, the ground truth for the key
// - green-screen.png: where the screen is in green-partial, for scoring how much uncovered room survives
//
// Run fetch-fixtures.sh first. Deterministic, so re-running rewrites identical files.
//   swift -O Checks/make-green-fixtures.swift
// With only the Command Line Tools, whose default SDK can be newer than their compiler, name an SDK that matches:
//   swift -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Checks/make-green-fixtures.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let W = 1920, H = 1080, N = W * H
let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

// A pop-up screen seen by a wide camera: the middle 55% of the width, top edge just inside the frame.
let screenX0 = 0.225 * Double(W), screenX1 = 0.775 * Double(W), screenY0 = 0.04 * Double(H)
// Chroma green as a webcam sees a fabric screen, not the paint swatch's pure value.
let green: (Float, Float, Float) = (0.14, 0.64, 0.27)
let maxSpill: Float = 0.3

struct RNG {  // SplitMix64, so the noise is the same on every run
    var s: UInt64
    mutating func next() -> Float {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
    }
}

func loadRGB(_ url: URL) -> [[Float]] {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    precondition(img.width == W && img.height == H, "\(url.lastPathComponent) must be \(W)x\(H)")
    var px = [UInt8](repeating: 0, count: N * 4)
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    return (0..<3).map { c in (0..<N).map { Float(px[$0 * 4 + c]) / 255 } }
}

/// Vision's .accurate mask, bilinearly resized to the frame. The mask is 4:3 whatever the input's aspect, and
/// it spans the whole input, so the resize is non-uniform.
func personAlpha(_ url: URL) throws -> [Float] {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let req = VNGeneratePersonSegmentationRequest()
    req.qualityLevel = .accurate
    req.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try VNImageRequestHandler(cgImage: img, orientation: .up).perform([req])
    let m = req.results!.first!.pixelBuffer
    CVPixelBufferLockBaseAddress(m, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
    let mw = CVPixelBufferGetWidth(m), mh = CVPixelBufferGetHeight(m), bpr = CVPixelBufferGetBytesPerRow(m)
    let base = CVPixelBufferGetBaseAddress(m)!.assumingMemoryBound(to: UInt8.self)
    func at(_ x: Int, _ y: Int) -> Float { Float(base[min(mh - 1, max(0, y)) * bpr + min(mw - 1, max(0, x))]) / 255 }
    var a = [Float](repeating: 0, count: N)
    for y in 0..<H {
        let v = (Double(y) + 0.5) * Double(mh) / Double(H) - 0.5
        let y0 = Int(v.rounded(.down)), fy = Float(v - Double(y0))
        for x in 0..<W {
            let u = (Double(x) + 0.5) * Double(mw) / Double(W) - 0.5
            let x0 = Int(u.rounded(.down)), fx = Float(u - Double(x0))
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            a[y * W + x] = top * (1 - fy) + bottom * fy
        }
    }
    return a
}

/// Separable box blur, three passes, which is close enough to a Gaussian for a spill falloff.
func blur(_ src: [Float], radius r: Int) -> [Float] {
    var a = src, b = src
    for _ in 0..<3 {
        for y in 0..<H {
            var sum: Float = 0
            for x in -r...r { sum += a[y * W + min(W - 1, max(0, x))] }
            for x in 0..<W {
                b[y * W + x] = sum / Float(2 * r + 1)
                sum += a[y * W + min(W - 1, x + r + 1)] - a[y * W + max(0, x - r)]
            }
        }
        for x in 0..<W {
            var sum: Float = 0
            for y in -r...r { sum += b[min(H - 1, max(0, y)) * W + x] }
            for y in 0..<H {
                a[y * W + x] = sum / Float(2 * r + 1)
                sum += b[min(H - 1, y + r + 1) * W + x] - b[max(0, y - r) * W + x]
            }
        }
    }
    return a
}

/// The green as lit in a room: brightest near the top left where the light is, a few folds, and sensor noise.
func greenPlate() -> [[Float]] {
    var rng = RNG(s: 0x6661_7374_6267)
    let gw = 24, gh = 14
    let folds = (0..<(gw + 1) * (gh + 1)).map { _ in rng.next() * 2 - 1 }
    var plate = [[Float]](repeating: [Float](repeating: 0, count: N), count: 3)
    for y in 0..<H {
        for x in 0..<W {
            let nx = Float(x) / Float(W), ny = Float(y) / Float(H)
            let light = 1.06 - 0.22 * ((nx - 0.45) * (nx - 0.45) + 1.3 * (ny - 0.25) * (ny - 0.25))
            let gx = nx * Float(gw), gy = ny * Float(gh)
            let ix = min(gw - 1, Int(gx)), iy = min(gh - 1, Int(gy))
            let fx = gx - Float(ix), fy = gy - Float(iy)
            let f = (folds[iy * (gw + 1) + ix] * (1 - fx) + folds[iy * (gw + 1) + ix + 1] * fx) * (1 - fy)
                + (folds[(iy + 1) * (gw + 1) + ix] * (1 - fx) + folds[(iy + 1) * (gw + 1) + ix + 1] * fx) * fy
            let shade = light * (1 + 0.035 * f)
            let luma = (rng.next() - 0.5) * 0.04
            let i = y * W + x
            plate[0][i] = green.0 * shade + luma + (rng.next() - 0.5) * 0.015
            plate[1][i] = green.1 * shade + luma + (rng.next() - 0.5) * 0.015
            plate[2][i] = green.2 * shade + luma + (rng.next() - 0.5) * 0.015
        }
    }
    return plate
}

func coverage(partial: Bool) -> [Float] {
    if !partial { return [Float](repeating: 1, count: N) }
    var s = [Float](repeating: 0, count: N)
    for y in 0..<H {
        let cy = Float(min(1, max(0, Double(y) + 1 - screenY0)))
        for x in 0..<W {
            let cx = Float(min(1, max(0, Double(x) + 1 - screenX0)) * min(1, max(0, screenX1 - Double(x))))
            s[y * W + x] = cx * cy
        }
    }
    return s
}

func writePNG(_ channels: [[Float]], _ name: String) {
    let gray = channels.count == 1
    let bpp = gray ? 1 : 4
    var px = [UInt8](repeating: 255, count: N * bpp)
    for i in 0..<N {
        for c in 0..<channels.count { px[i * bpp + c] = UInt8((min(1, max(0, channels[c][i])) * 255).rounded()) }
    }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8 * bpp, bytesPerRow: W * bpp,
                      space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue: gray ? 0 : CGImageAlphaInfo.noneSkipLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = dir.appendingPathComponent(name)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    precondition(CGImageDestinationFinalize(dst), "writing \(name)")
    print("wrote \(url.path)")
}

/// The person's colours with the room taken out of their soft edge. Vision's edge is tens of pixels wide, and
/// in the photo those pixels are part wall, which would otherwise ride along as a pale fringe on the green.
func foreground(_ rgb: [[Float]], alpha: [Float]) -> [[Float]] {
    let solid = alpha.map { $0 >= 0.9 ? Float(1) : 0 }
    let reach = blur(solid, radius: 8)
    return rgb.map { ch in
        let spread = blur((0..<N).map { ch[$0] * solid[$0] }, radius: 8)
        return (0..<N).map { i in
            solid[i] == 1 || reach[i] < 0.01 ? ch[i] : spread[i] / reach[i]
        }
    }
}

let portraitURL = dir.appendingPathComponent("portrait-home.jpg")
let room = loadRGB(portraitURL)
let alpha = try personAlpha(portraitURL)
let person = foreground(room, alpha: alpha)
let plate = greenPlate()
// Green bounce light reaches only a band just inside the person's edge.
let edgeBand = blur(alpha.map { 1 - $0 }, radius: 6)

for partial in [true, false] {
    let screen = coverage(partial: partial)
    let spillReach = partial ? blur(screen, radius: 24) : screen
    var out = room
    for i in 0..<N {
        let a = alpha[i], s = screen[i]
        let spill = min(maxSpill, 2 * a * edgeBand[i] * spillReach[i])
        for c in 0..<3 {
            let fg = person[c][i] * (1 - spill) + plate[c][i] * spill
            let bg = plate[c][i] * s + room[c][i] * (1 - s)
            out[c][i] = fg * a + bg * (1 - a)
        }
    }
    writePNG(out, partial ? "green-partial.png" : "green-full.png")
    if partial {
        writePNG([screen], "green-screen.png")
        // What calibration will measure: the share of background (by the true alpha) that's on the screen.
        var bgPx = 0, onScreen = 0
        for i in 0..<N where alpha[i] < 0.5 { bgPx += 1; if screen[i] > 0.5 { onScreen += 1 } }
        print(String(format: "green-partial: screen covers %.1f%% of the background", 100 * Double(onScreen) / Double(bgPx)))
    }
}
writePNG([alpha], "green-alpha.png")
