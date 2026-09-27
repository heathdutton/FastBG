import AppKit
import SwiftUI

/// The first-run checklist. It shows at launch while anything's missing, and closing it before everything's done
/// quits fastbg: a half set-up fastbg in the menu bar would only look like it works.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private let setup: Setup
    private var window: NSWindow?

    init(setup: Setup) {
        self.setup = setup
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.title = "Set up FastBG"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SetupView(setup: setup) { [weak self] in
                self?.window?.close()
            })
            window.center()
            self.window = window
        }
        // In the Dock while it's open, so it can be found again behind other windows.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        setup.watch(true)
    }

    func windowWillClose(_ notification: Notification) {
        setup.watch(false)
        guard setup.allDone else { return NSApp.terminate(nil) }
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SetupView: View {
    @ObservedObject var setup: Setup
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: StatusItem.glyphName)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up FastBG").font(.title3.weight(.semibold))
                    Text("4 switches, then pick FastBG in your apps.").foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                Step(state: setup.inApplications ? .done : .todo, title: "In Applications",
                     why: "macOS only loads camera extensions from there.",
                     button: "Move", action: setup.moveToApplications)
                Divider()
                Step(state: setup.camera, title: "Camera access",
                     why: "To read your webcam, only while an app is using FastBG.",
                     place: setup.cameraRefused ? "Privacy & Security > Camera > FastBG on." : nil,
                     button: setup.cameraRefused ? "Open Settings" : "Allow", action: setup.allowCamera)
                Divider()
                Step(state: setup.cameraExtension, title: "FastBG camera",
                     why: "Puts FastBG in your video apps' camera list.",
                     place: setup.cameraStuck
                        ? "On, but FastBG can't see it till it reopens." : "Camera Extensions > FastBG on.",
                     button: setup.cameraStuck ? "Reopen" : "Open Settings", enabled: setup.inApplications,
                     action: setup.cameraStuck ? setup.reopen : setup.approveExtension)
                Divider()
                Step(state: setup.loginItem, title: "Open at login",
                     why: "FastBG makes the picture, so it has to be running.",
                     place: "Login Items & Extensions > FastBG on.",
                     button: "Turn on", action: setup.openAtLogin)
                Divider()
                Step(state: setup.apps, title: "Pick FastBG in your apps",
                     why: "FaceTime switches on its own. Chrome, Zoom and most others keep their own pick.",
                     hint: "Pick FastBG in their camera menu and turn off their own background. Chrome's is in "
                        + "Settings > Privacy and security > Site settings > Camera.",
                     place: "An app has your webcam open directly. Switch it to FastBG.")
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            HStack {
                Text(!setup.allDone ? "Closing this quits FastBG."
                     : setup.apps == .done ? "All set. FastBG's in your menu bar now."
                     : "Last, pick FastBG in your apps. It's in your menu bar now.")
                    .foregroundStyle(.secondary)
                Spacer()
                if setup.allDone {
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// One checklist row. `place` says where the switch is, shown once the row is waiting on the user. `hint` shows
/// till it's done.
private struct Step: View {
    let state: Setup.State
    let title: String
    let why: String
    var hint: String?
    var place: String?
    var button: String?
    var enabled = true
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.font(.system(size: 17)).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(why).foregroundStyle(.secondary)
                if state != .done, let hint {
                    Text(hint).foregroundStyle(.secondary)
                }
                if state == .waiting, let place {
                    Text(place).foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if state != .done, let button {
                Button(button, action: action).disabled(!enabled).fixedSize()
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 10)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting: Image(systemName: "clock.fill").foregroundStyle(.orange)
        case .todo: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
