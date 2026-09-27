import AppKit
import CoreImage
import QuartzCore
import UniformTypeIdentifiers

/// GitHub's social preview, 1280x640: FastBG's own output over a stock clip, beside the panel holding the stock
/// tiles. The camera is `presenter-green.png`, a made-up person with no likeness to clear, in front of a pop-up green
/// screen that leaves the room showing around it, so the key and the matte both show. It's kept out of git with the
/// other fixtures, and fetch-fixtures.sh doesn't make it. Writes build/checks/social.jpg, a JPEG because GitHub caps
/// the upload at 1 MB.
@MainActor
enum SocialShot {
    static let clip = "aurora"
    static let size = CGSize(width: 1280, height: 640)

    static func run() async -> Bool {
        guard let output = await output() else { return expect(false, "social: no output frame") }
        guard let panel = await panel() else { return expect(false, "social: no panel") }
        guard let card = compose(output: output, panel: panel) else { return expect(false, "social: compose") }
        let url = Paths.output("social.jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, card, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("      wrote \(url.path)")
        return expect(bytes > 0 && bytes < 1_000_000, "social: \(card.width)x\(card.height), \(bytes / 1000) KB")
    }

    /// The presenter through the real pipeline, green screen key and matte, over the clip a few seconds in.
    static func output() async -> CGImage? {
        // A 4:3 webcam shot, cut to 16:9 from the top so her hair keeps its headroom.
        guard let shot = Paths.fixture("presenter-green.png").flatMap(Pixels.image),
              let wide = shot.cropping(to: CGRect(x: 0, y: 0, width: shot.width, height: shot.width * 9 / 16))
        else { return nil }
        let camera = Pixels.frame(wide)
        let sink = CaptureSink()
        let engine = Engine(sink: sink, usesCamera: false)
        engine.setScreen(.any)
        engine.show(.video(id: clip, url: Paths.repo.appendingPathComponent("Stock/\(clip).mp4")))
        engine.setLive(true)
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 4 {
            await feed(engine, camera, at: CACurrentMediaTime(), sink: sink)
            await sleep(1.0 / 30)
        }
        engine.setLive(false)
        // Trimmed on the right, where the clip, shot from the space station, has some of the station in it.
        return sink.last.flatMap(Pixels.cgImage)?.cropping(to: CGRect(x: 0, y: 0, width: 1760, height: 990))
    }

    /// The panel with the five stock clips, the clip in use selected.
    static func panel() async -> CGImage? {
        let root = Paths.temp("social-library")
        try? FileManager.default.removeItem(at: root)
        let library = Library(root: root)
        for name in Importer.stock {
            let src = Paths.repo.appendingPathComponent("Stock/\(name).mp4")
            guard let item = try? await Importer.importStock(src, id: name, root: root) else { return nil }
            library.add(item)
        }
        library.select(clip)
        let model = AppModel(library: library, engine: Engine(sink: CaptureSink(), usesCamera: false),
                             virtualCamera: VirtualCamera())
        let setup = Setup(installer: ExtensionInstaller(), virtualCamera: VirtualCamera())
        setup.pretendDone()
        let window = BackgroundWindow(rootView: PanelView(model: model, library: library, setup: setup, openSetup: {},
                                                          startExpanded: false))
        return await PanelShot.render(window)
    }

    static func compose(output: CGImage, panel: CGImage) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(origin: .zero, size: size)

        // The output again behind everything, blurred and darkened, so the card takes its colours.
        let blurred = CIImage(cgImage: output).clampedToExtent()
            .applyingGaussianBlur(sigma: 40).cropped(to: CGRect(x: 0, y: 0, width: output.width, height: output.height))
        if let backdrop = CIContext().createCGImage(blurred, from: blurred.extent) {
            ctx.draw(backdrop, in: cover(CGSize(width: output.width, height: output.height), full))
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(full)

        // The call as the other side sees it, left, and the panel that picked it, right.
        let video = CGRect(x: 56, y: 56, width: 720, height: 405)
        framed(ctx, output, in: video, radius: 18)
        let panelWidth: CGFloat = 400
        let panelHeight = panelWidth * CGFloat(panel.height) / CGFloat(panel.width)
        framed(ctx, panel, in: CGRect(x: 824, y: (size.height - panelHeight) / 2, width: panelWidth,
                                      height: panelHeight), radius: 14)

        // Icon, name and slogan, above the call.
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSImage(contentsOf: Paths.repo.appendingPathComponent(".github/icon.png"))?
            .draw(in: NSRect(x: 50, y: 518, width: 76, height: 76))
        NSAttributedString(string: "FastBG", attributes: [
            .font: NSFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: 138, y: 524))
        NSAttributedString(string: "Video and live web backgrounds in any app.", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.8),
        ]).draw(at: NSPoint(x: 58, y: 476))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// `image` in `rect`, rounded, over a soft shadow and inside a hairline.
    static func framed(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: cover(CGSize(width: image.width, height: image.height), rect))
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// Where `source` goes to fill `rect`, centred, cropped by the rect's edges.
    static func cover(_ source: CGSize, _ rect: CGRect) -> CGRect {
        let scale = max(rect.width / source.width, rect.height / source.height)
        let w = source.width * scale, h = source.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
