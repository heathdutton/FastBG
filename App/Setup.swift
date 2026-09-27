import AVFoundation
import AppKit
import ServiceManagement

/// The four things fastbg can't work without, checked live, each with the one action that fixes it. Then the step
/// only the user can take: picking FastBG in apps that keep their own camera.
@MainActor
final class Setup: ObservableObject {
    enum State: Equatable {
        case done
        case todo
        /// Handed to System Settings, waiting on the user's switch.
        case waiting
    }

    @Published private(set) var inApplications = false
    @Published private(set) var camera = State.todo
    /// Once refused, the system prompt never shows again, so only Settings can fix it.
    @Published private(set) var cameraRefused = false
    @Published private(set) var cameraExtension = State.todo
    @Published private(set) var loginItem = State.todo
    /// Done once any app has read the FastBG camera. Waiting while some app has a real camera open directly.
    @Published private(set) var apps = State.todo
    /// Items whose button sent the user to System Settings: they read as waiting, not missing, till they're done.
    private var sent: Set<String> = []

    var allDone: Bool {
        inApplications && camera == .done && cameraExtension == .done && loginItem == .done
    }

    /// Enabled in System Settings, but this process can't see its camera. A process that looked at the camera list
    /// before the extension was swapped or switched on never sees the new camera, so the fix is a fresh fastbg.
    @Published private(set) var cameraStuck = false
    /// The extension just turned on: the moment to start looking for its camera.
    var onEnabled: (() -> Void)?

    private let installer: ExtensionInstaller
    private let virtualCamera: VirtualCamera
    private var poll: Timer?

    init(installer: ExtensionInstaller, virtualCamera: VirtualCamera) {
        self.installer = installer
        self.virtualCamera = virtualCamera
    }

    /// Re-checks every second while the checklist is open, so rows tick as switches flip in System Settings.
    func watch(_ on: Bool) {
        poll?.invalidate()
        poll = nil
        guard on else { return }
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// `checked` gets whether everything's done, once the extension's state is back from sysextd.
    func refresh(_ checked: ((Bool) -> Void)? = nil) {
        inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let access = AVCaptureDevice.authorizationStatus(for: .video)
        cameraRefused = access == .denied || access == .restricted
        camera = state("camera", access == .authorized)
        apps = UserDefaults.standard.bool(forKey: Self.pickedKey) ? .done : Camera.inUseElsewhere() ? .waiting : .todo
        let login = SMAppService.mainApp.status
        loginItem = login == .requiresApproval ? .waiting : state("login", login == .enabled)
        guard inApplications else {
            cameraExtension = .todo
            checked?(false)
            return
        }
        installer.query { [weak self] enabled, awaiting in
            guard let self else { return }
            if enabled { onEnabled?() }
            let present = virtualCamera.isPresent
            cameraStuck = enabled && !present && virtualCamera.isStarted
            if cameraStuck { sent.insert("extension") }
            cameraExtension = awaiting ? .waiting : state("extension", enabled && (present || !virtualCamera.isStarted))
            checked?(allDone)
        }
    }

    private nonisolated static let pickedKey = "setup.picked"

    /// Everything done, for the harness's pictures of the panel, which would otherwise always ask to finish setup.
    func pretendDone() {
        (inApplications, camera, cameraExtension, loginItem, apps) = (true, .done, .done, .done, .done)
    }

    /// An app is reading the FastBG camera, so it's been picked somewhere.
    nonisolated static func notePicked() {
        UserDefaults.standard.set(true, forKey: pickedKey)
    }

    private func state(_ item: String, _ done: Bool) -> State {
        if done { sent.remove(item) }
        return done ? .done : sent.contains(item) ? .waiting : .todo
    }

    func allowCamera() {
        if cameraRefused {
            sent.insert("camera")
            camera = .waiting
            return open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Activating is what puts the switch in System Settings, so it goes first. The link opens the Camera
    /// Extensions sheet itself rather than the pane that hides it behind an info button.
    func approveExtension() {
        installer.activate()
        sent.insert("extension")
        cameraExtension = .waiting
        open("x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier="
             + "com.apple.system_extension.cmio.extension-point")
    }

    func openAtLogin() {
        try? SMAppService.mainApp.register()
        refresh()
        if loginItem != .done {
            sent.insert("login")
            loginItem = .waiting
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Copies fastbg into /Applications, opens that copy and quits this one. The original goes to the Trash when
    /// it can, so Launch Services doesn't keep two fastbgs around.
    func moveToApplications() {
        let source = Bundle.main.bundleURL
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.copyItem(at: source, to: target)
        } catch {
            Log.setup.error("copying to /Applications failed: \(error, privacy: .public)")
            return NSSound.beep()
        }
        try? fm.trashItem(at: source, resultingItemURL: nil)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Starts a fresh fastbg and quits this one, whose view of the camera list went stale.
    func reopen() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }
}
