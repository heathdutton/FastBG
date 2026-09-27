import AppKit
import SwiftUI

/// Tooltips for the panel. The panel never activates fastbg, so focus can go straight back to the call app, and
/// AppKit only shows tooltips in the active app. So this draws the same bubble in a window of its own, after the
/// same pause, and moves straight to the next one while it's showing.
@MainActor
final class Tip {
    static let shared = Tip()
    private var window: NSPanel?
    private var label: NSTextField?
    private var pending: DispatchWorkItem?
    private var showing: String?
    private var hiddenAt = Date.distantPast

    func hover(_ text: String, _ inside: Bool, delay: TimeInterval = 0.7) {
        pending?.cancel()
        guard inside else {
            if showing == text { hide() }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pending = work
        let recent = showing != nil || Date().timeIntervalSince(hiddenAt) < 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + (recent ? min(delay, 0.05) : delay), execute: work)
    }

    func hide() {
        pending?.cancel()
        guard showing != nil else { return }
        showing = nil
        hiddenAt = Date()
        window?.orderOut(nil)
    }

    private func show(_ text: String) {
        let (window, label) = self.window.flatMap { w in self.label.map { (w, $0) } } ?? make()
        label.stringValue = text
        let size = label.fittingSize
        let pad = NSSize(width: 8, height: 4)
        let mouse = NSEvent.mouseLocation
        var frame = NSRect(x: mouse.x + 2, y: mouse.y - 22 - size.height - pad.height * 2,
                           width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            if frame.minY < screen.minY { frame.origin.y = mouse.y + 8 }
        }
        window.setFrame(frame, display: true)
        label.frame = NSRect(origin: NSPoint(x: pad.width, y: pad.height), size: size)
        window.orderFrontRegardless()
        showing = text
    }

    private func make() -> (NSPanel, NSTextField) {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                             defer: true)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.ignoresMouseEvents = true
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        window.contentView = background
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 260
        background.addSubview(label)
        (self.window, self.label) = (window, label)
        return (window, label)
    }
}

/// The info icon at a settings row's right edge, which shows what the row does on hover, or at once on a click.
/// Only the icon shows it, so reaching for a menu or a slider never brings one up.
struct InfoIcon: View {
    let text: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .contentShape(Rectangle())
            .onHover {
                hovering = $0
                Tip.shared.hover(text, $0, delay: 0.25)
            }
            .onTapGesture { Tip.shared.hover(text, true, delay: 0) }
            .accessibilityLabel(text)
    }
}
