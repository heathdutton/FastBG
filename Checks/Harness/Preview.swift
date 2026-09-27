import AppKit
import CoreMedia
import CoreVideo
import QuartzCore

/// The real camera through the real pipeline, shown in a window instead of the camera extension. For judging edges
/// and the green screen by eye before a signed build exists. FASTBG_GREEN=1 turns the green screen on.
@MainActor
enum Preview {
    static func run(background: URL?) async {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        let sink = LayerSink(layer)
        let engine = Engine(sink: sink)
        if let background {
            let still = Paths.temp("preview.heic")
            do {
                try Importer.normalizeImage(src: background, dst: still)
                engine.show(.image(id: "preview", url: still))
            } catch {
                print("can't read \(background.path): \(error)")
            }
        }
        engine.setScreen(ProcessInfo.processInfo.environment["FASTBG_GREEN"] == "1" ? .any : .off)
        engine.onGreenScreenStatus = { print("green screen: \($0)") }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "fastbg preview"
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.addSublayer(layer)
        layer.frame = window.contentView?.bounds ?? .zero
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        window.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        engine.setLive(true)
        while window.isVisible { await sleep(0.2) }
        engine.setLive(false)
        await sleep(0.3)
        exit(0)
    }
}

private final class LayerSink: FrameSink, @unchecked Sendable {
    private let layer: CALayer

    init(_ layer: CALayer) { self.layer = layer }

    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let box = SurfaceBox(surface)
        DispatchQueue.main.async { [layer] in layer.contents = box.surface }
    }
}

private struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
    init(_ surface: IOSurface) { self.surface = surface }
}
