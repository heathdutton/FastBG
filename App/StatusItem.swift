import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar icon and FastBG's window. A click opens or closes the window; a right-click offers Open and Quit.
/// The icon takes drops too, for a drag started while the window's closed.
@MainActor
final class StatusItem: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let window: BackgroundWindow
    private let model: AppModel
    private let setup: Setup
    private let openSetup: () -> Void
    private var liveWatch: AnyCancellable?

    init(model: AppModel, setup: Setup, openSetup: @escaping () -> Void) {
        self.model = model
        self.setup = setup
        self.openSetup = openSetup
        window = BackgroundWindow(rootView: PanelView(model: model, library: model.library, setup: setup,
                                                      openSetup: openSetup))
        super.init()
        window.setBadge(LiveBadge(model: model))
        window.onVisible = { [weak model] in model?.setWindowVisible($0) }
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        liveWatch = model.$live.sink { [weak self] live in self?.setIcon(live: live) }
        // The status bar window forwards drag messages to its delegate, which is the one way to take drops on the
        // icon without covering the button with a view of our own. The window exists once the item is laid out.
        DispatchQueue.main.async { [weak self] in self?.acceptDrops() }
        screenWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.acceptDrops() }
        }
    }

    private var screenWatch: NSObjectProtocol?

    /// Reapplied when the window opens and when screens change, in case AppKit rebuilt the status bar window.
    private func acceptDrops() {
        guard let window = item.button?.window, window.delegate !== self else { return }
        window.registerForDraggedTypes([.fileURL, .URL, .string])
        window.delegate = self
    }

    /// The Background family's striped glyph. The dotted one Control Center uses draws its background dots as a
    /// secondary layer at part opacity, so the part that means "background" all but vanished next to solid icons like
    /// the camera's.
    static let glyphName = "person.and.background.striped.horizontal"

    private func setIcon(live: Bool) {
        item.button?.image = Self.icon(live: live)
    }

    /// The glyph alone in the menu bar's own colour while idle. While an app reads the camera it sits white in a green
    /// capsule the size of macOS's camera-in-use pill, at the same size and spot, so only the capsule comes and goes.
    static func icon(live: Bool) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        else { return nil }
        let pill = NSSize(width: 32, height: 20)
        let g = glyph.size, fit = min((pill.width - 8) / g.width, (pill.height - 5) / g.height)
        let drawn = NSSize(width: g.width * fit, height: g.height * fit)
        // Idle it's only as wide as the glyph, so the item takes a normal icon's room in the menu bar.
        let size = live ? pill : NSSize(width: drawn.width.rounded(.up), height: pill.height)
        let image = NSImage(size: size, flipped: false) { rect in
            if live {
                NSColor.systemGreen.setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            }
            let box = NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                             width: drawn.width, height: drawn.height)
            // A solid mask, every layer at full strength.
            let mask = NSImage(size: box.size, flipped: false) { r in
                glyph.draw(in: r)
                (live ? NSColor.white : NSColor.black).set()
                r.fill(using: .sourceAtop)
                return true
            }
            mask.draw(in: box)
            return true
        }
        image.isTemplate = !live
        image.accessibilityDescription = live ? "\(FastbgCamera.name), in use" : FastbgCamera.name
        return image
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { return showMenu() }
        window.isVisible ? window.close() : open()
    }

    @objc private func open() {
        guard let button = item.button, let bar = button.window else { return }
        acceptDrops()
        setup.refresh()
        window.show(under: bar.convertToScreen(button.convert(button.bounds, to: nil)))
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open \(FastbgCamera.name)", action: #selector(open), keyEquivalent: "").target = self
        if !setup.allDone {
            menu.addItem(withTitle: "Finish Setup...", action: #selector(finishSetup), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(FastbgCamera.name)", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func finishSetup() { openSetup() }

    /// A tile dragged out of the panel is refused, or it'd come back as a copy of itself.
    private func payloads(_ board: NSPasteboard) -> [DropPayload] {
        let tile = NSPasteboard.PasteboardType(UTType.fastbgTile.identifier)
        return board.types?.contains(tile) == true ? [] : Importer.payloads(from: board)
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !payloads(sender.draggingPasteboard).isEmpty
        item.button?.highlight(accepts)
        return accepts ? .copy : []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        item.button?.highlight(false)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        let found = payloads(sender.draggingPasteboard)
        guard !found.isEmpty else { return false }
        model.importPayloads(found)
        return true
    }
}
