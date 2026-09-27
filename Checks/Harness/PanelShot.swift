import AppKit
import ScreenCaptureKit
import SwiftUI

/// Shows the real panel, filled from the fixtures, under where a menu bar icon would be, and captures it with the
/// glass the window server draws. Writes build/checks/panel.png.
@MainActor
enum PanelShot {
    static func run() async -> Bool {
        let root = Paths.temp("panel-library")
        try? FileManager.default.removeItem(at: root)
        let library = Library(root: root)
        for name in ["portrait-brick.jpg", "studio.jpg", "portrait-home.jpg"] {
            guard let url = Paths.fixture(name) else { return false }
            let id = UUID().uuidString.lowercased()
            guard let item = try? await Importer.importItem(.file(url), id: id, root: root) else {
                return expect(false, "panel: import \(name)")
            }
            library.add(item)
        }
        library.select(library.items[1].id)
        library.setScreen(.any)
        let sink = CaptureSink()
        let engine = Engine(sink: sink, usesCamera: false)
        let model = AppModel(library: library, engine: engine, virtualCamera: VirtualCamera())
        // FASTBG_PANEL_BUSY fills in the widest readings and a leaned slider, so Reset shows: the most any row holds.
        let busy = ProcessInfo.processInfo.environment["FASTBG_PANEL_BUSY"] != nil
        if busy {
            model.setAuto(true)
            engine.onAutoTuning?(Tuning(), AutoTune.Readings(noise: .init(luma: 0.123, chroma: 0.05), flicker: 88.8))
            model.set(\.smoothing, 0.9)
        }
        // After the view's own sampling has started, so these stick.
        if busy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                model.usage = Usage(cpu: 12.3, gpu: 45.6, neural: true)
                model.turboFill = 22.8
            }
        }
        defer { if busy { model.resetOffsets() } }
        let setup = Setup(installer: ExtensionInstaller(), virtualCamera: VirtualCamera())
        let expanded = ProcessInfo.processInfo.environment["FASTBG_PANEL_EXPANDED"] != nil
        let panel = BackgroundWindow(rootView: PanelView(model: model, library: library, setup: setup, openSetup: {},
                                                  startExpanded: expanded))
        panel.setBadge(LiveBadge(model: model))
        // FASTBG_PANEL_MANUAL turns autocalibrate off once the window's up, the way a user would, then back after.
        let manual = ProcessInfo.processInfo.environment["FASTBG_PANEL_MANUAL"] != nil
        if manual {
            model.setAuto(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { model.setAuto(false) }
        }
        defer { if manual { model.setAuto(true) } }
        // Drawn off screen by default, so running the check never flashes a window of test photos at whoever's at
        // the Mac. FASTBG_PANEL_WINDOW shows the real window for a moment instead, glass and title bar included.
        guard ProcessInfo.processInfo.environment["FASTBG_PANEL_WINDOW"] != nil else { return await offscreen(panel) }
        guard let screen = NSScreen.main else { return false }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        panel.show(under: NSRect(x: screen.frame.maxX - 300, y: screen.frame.maxY - bar, width: 24, height: bar))
        await sleep(0.8)
        defer { panel.close() }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
                return expect(false, "panel: window not capturable")
            }
            let config = SCStreamConfiguration()
            config.width = Int(panel.frame.width * screen.backingScaleFactor)
            config.height = Int(panel.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            let url = Paths.output("panel.png")
            Pixels.writePNG(image, to: url)
            print("      wrote \(url.path)")
            return expect(true, "panel: rendered \(Int(panel.frame.width))x\(Int(panel.frame.height)) pt")
        } catch {
            return expect(false, "panel: capture failed, \(error)")
        }
    }

    /// The content drawn from its layers into a bitmap, from a window that's never ordered in, in dark mode over the
    /// window colour. Materials draw flat this way.
    static func offscreen(_ panel: NSWindow, name: String = "panel") async -> Bool {
        guard let image = await render(panel), let container = panel.contentView else { return false }
        let size = container.frame.size
        // What each slider's track is filled with: grey only while autocalibrate steers it.
        func sliders(_ v: NSView) -> [NSSlider] { (v as? NSSlider).map { [$0] } ?? v.subviews.flatMap(sliders) }
        let fills = sliders(container).map { $0.trackFillColor?.usingColorSpace(.sRGB).map {
            String(format: "%.2f,%.2f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "default" }
        if !fills.isEmpty { print("      slider fills: " + fills.joined(separator: " ")) }
        let url = Paths.output("\(name).png")
        Pixels.writePNG(image, to: url)
        print("      wrote \(url.path)")
        return expect(size.width > 0 && size.height > 0, "\(name): rendered \(Int(size.width))x\(Int(size.height)) pt")
    }

    /// The window's content drawn in dark mode at the screen's scale, without the window server's glass.
    static func render(_ panel: NSWindow) async -> CGImage? {
        // The window's content is the container the SwiftUI view hangs in; the view says the size, the container
        // shows where it actually sits.
        guard let container = panel.contentView, let content = container.subviews.first else { return nil }
        panel.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true
        content.layoutSubtreeIfNeeded()
        await sleep(0.3)
        let size = content.fittingSize
        panel.setContentSize(size)
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        let view = container
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let layer = view.layer, let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var fill = NSColor.windowBackgroundColor.cgColor
        panel.appearance?.performAsCurrentDrawingAppearance { fill = NSColor.windowBackgroundColor.cgColor }
        ctx.setFillColor(fill)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Bitmap rows run bottom up, the layers' top down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        panel.appearance?.performAsCurrentDrawingAppearance { layer.render(in: ctx) }
        return ctx.makeImage()
    }
}

/// Top-down like the panel's container, so the renderer draws it the right way up.
private final class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// The first-run checklist with nothing done yet, its longest state, drawn off screen. Writes build/checks/setup.png.
@MainActor
enum SetupShot {
    static func run() async -> Bool {
        let setup = Setup(installer: ExtensionInstaller(), virtualCamera: VirtualCamera())
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        // Hung in a container, as the panel's is, which is what the renderer measures and draws.
        let host = NSHostingView(rootView: SetupView(setup: setup) {})
        let container = Flipped()
        container.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.topAnchor.constraint(equalTo: container.topAnchor),
                                     host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                                     host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                     host.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        window.contentView = container
        return await PanelShot.offscreen(window, name: "setup")
    }
}

/// The menu bar icon idle and in use, on a light and a dark menu bar, at 4x. Writes build/checks/menu-icons.png.
@MainActor
enum MenuIconShot {
    static func run() async -> Bool {
        guard let idle = StatusItem.icon(live: false), let live = StatusItem.icon(live: true) else { return false }
        let scale: CGFloat = 4, cell = NSSize(width: 44, height: 24)
        let bars: [(NSColor, NSColor)] = [(NSColor(white: 0.93, alpha: 1), .black),
                                          (NSColor(white: 0.16, alpha: 1), .white)]
        let size = NSSize(width: cell.width * 2 * scale, height: cell.height * 2 * scale)
        let image = NSImage(size: size, flipped: false) { _ in
            for (row, (bar, ink)) in bars.enumerated() {
                let y = CGFloat(1 - row) * cell.height * scale
                bar.setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell.height * scale).fill()
                for (col, icon) in [idle, live].enumerated() {
                    let box = NSRect(x: (CGFloat(col) * cell.width + 6) * scale, y: y + 2 * scale,
                                     width: icon.size.width * scale, height: icon.size.height * scale)
                    // A template icon takes the menu bar's ink, as the status bar would draw it.
                    let tinted = icon.isTemplate ? NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r)
                        ink.set()
                        r.fill(using: .sourceAtop)
                        return true
                    } : icon
                    tinted.draw(in: box)
                }
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let url = Paths.output("menu-icons.png")
        try? png.write(to: url)
        print("      wrote \(url.path)")
        return expect(idle.size.width < live.size.width && idle.size.height == live.size.height,
                      "menu icon: \(Int(idle.size.width))x\(Int(idle.size.height)) idle, "
                      + "\(Int(live.size.width))x\(Int(live.size.height)) in use")
    }
}
