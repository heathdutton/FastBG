import AppKit
import SwiftUI

/// FastBG's window, shaped like macOS's own Background picker: titled, closable, dragged by its empty spots, and
/// floating over the call app without ever taking its focus. It opens under the menu bar icon, stays where it's
/// dragged till FastBG quits or the screens change, then goes back under the icon, where nobody has to hunt for it.
@MainActor
final class BackgroundWindow: NSPanel {
    private let hosting: FittingHostingView<AnyView>
    /// The user dragged it somewhere of their own since launch or the last change of screens.
    private var placed = false
    /// Set while the window moves itself, so only the user's moves count as placing it.
    private var fitting = false
    private var moves: NSObjectProtocol?
    private var screens: NSObjectProtocol?
    private var occlusion: NSObjectProtocol?
    /// On screen and at least partly uncovered, or not: closed, covered, or on another space.
    var onVisible: ((Bool) -> Void)?

    init(rootView: some View) {
        hosting = FittingHostingView(rootView: AnyView(rootView))
        // Only reports its size. Left to set the window's minimum size too, it grows the window upward from its
        // bottom corner before `fit` can hold the top edge, and everything jumps up and back.
        hosting.sizingOptions = [.intrinsicContentSize]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered,
                   defer: true)
        title = FastbgCamera.name
        // A utility panel's title bar, like the Fonts panel's: 24 pt rather than 32, with only the close button.
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The content hangs from the top of a flipped container at its own full height, so a window that's a frame
        // late growing leaves new rows below its edge for that frame instead of re-centering everything above them.
        let container = TopPinnedView()
        container.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        contentView = container
        hosting.onResize = { [weak self] in DispatchQueue.main.async { self?.fit() } }
        moves = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.fitting, self.isVisible else { return }
                self.placed = true
            }
        }
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placed = false }
        }
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onVisible?(self.isVisible && self.occlusionState.contains(.visible))
            }
        }
    }

    override var canBecomeKey: Bool { true }

    /// A view on the title bar's right, for the in-use badge.
    func setBadge(_ view: some View) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let hosting = NSHostingView(rootView: view)
        // No taller than the title bar, or AppKit grows the bar to fit it.
        hosting.frame.size = NSSize(width: 70, height: 20)
        accessory.view = hosting
        addTitlebarAccessoryViewController(accessory)
    }

    /// Under the menu bar icon at `anchor`, in screen coordinates, till the user has put it somewhere of their own.
    func show(under anchor: NSRect) {
        fit()
        if !placed {
            let size = frame.size
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? .main
            if let visible = screen?.visibleFrame {
                let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
                fitting = true
                setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
                fitting = false
            }
        }
        makeKeyAndOrderFront(nil)
        // AppKit would focus the first control that takes it, a popup menu, and ring it in blue like a form field.
        makeFirstResponder(nil)
    }

    override func close() {
        Tip.shared.hide()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// Follows the content's size, keeping the top edge where it is and the window on screen.
    private func fit() {
        let size = hosting.fittingSize
        guard size.width > 0 else { return }
        let content = NSRect(origin: .zero, size: size)
        var target = frameRect(forContentRect: content)
        target.origin = NSPoint(x: frame.minX, y: frame.maxY - target.height)
        if let visible = (screen ?? .main)?.visibleFrame, target.minY < visible.minY {
            target.origin.y = visible.minY
        }
        fitting = true
        setFrame(target, display: true)
        fitting = false
    }
}

/// Reports when SwiftUI's content changes size, so the window can follow it. Its own height follows at once, through
/// its intrinsic size, pinned to the container's top.
private final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }

    /// AppKit counts all of SwiftUI's surface as background, so a tile dragged to reorder would move the window
    /// instead. The panel's empty spots move it through a SwiftUI gesture, and the title bar always does.
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class TopPinnedView: NSView {
    override var isFlipped: Bool { true }
}
