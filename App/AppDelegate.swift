import AVFoundation
import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItem?
    private let installer = ExtensionInstaller()
    private var setupWindow: SetupWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let library = Library()
        let virtualCamera = VirtualCamera()
        let engine = Engine(sink: virtualCamera)
        let model = AppModel(library: library, engine: engine, virtualCamera: virtualCamera)
        self.model = model
        model.addStock()
        model.ownPreferredCamera()
        let setup = Setup(installer: installer, virtualCamera: virtualCamera)
        let setupWindow = SetupWindow(setup: setup)
        self.setupWindow = setupWindow
        statusItem = StatusItem(model: model, setup: setup) { setupWindow.show() }
        // A system extension only activates from an app in /Applications, and a copy anywhere else is a dev build
        // or an unzipped download that shouldn't make itself a login item either.
        if Bundle.main.bundlePath.hasPrefix("/Applications/") {
            // The pipeline lives in the app, so it has to be running for the camera to work. Registered once, so a
            // user who removes the login item keeps it removed.
            let key = "registeredLoginItem"
            if !UserDefaults.standard.bool(forKey: key) {
                do {
                    try SMAppService.mainApp.register()
                } catch {
                    Log.setup.error("login item registration failed: \(error, privacy: .public)")
                }
                UserDefaults.standard.set(true, forKey: key)
            }
            // A process that looked at the camera list before the extension was swapped or switched on never sees
            // its new camera. So the list is first read once activation settles, 2 s later after a swap, or once
            // the user switches the extension on from the checklist.
            installer.activate { active, replaced in
                guard active else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + (replaced ? 2 : 0)) { virtualCamera.start() }
            }
            setup.onEnabled = { [installer] in
                if !installer.isActivating { virtualCamera.start() }
            }
        } else {
            virtualCamera.start()
        }
        // Enabled but still unseen after every retry, which only a relaunch fixes. Once a minute at most, so it
        // can't loop.
        virtualCamera.onMissing = {
            Task { @MainActor in
                setup.refresh { _ in
                    guard setup.cameraStuck else { return }
                    let key = "reopenedForCamera"
                    let last = UserDefaults.standard.double(forKey: key)
                    guard Date().timeIntervalSince1970 - last > 60 else { return setupWindow.show() }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
                    Log.setup.notice("camera enabled but not visible here, reopening fastbg")
                    setup.reopen()
                }
            }
        }
        // Camera access is asked from the checklist, where the user can see why, rather than cold at launch.
        setup.refresh { allDone in
            if !allDone { setupWindow.show() }
        }
    }

    /// Stops the sink before exit, so the extension isn't left consuming from a client that's gone.
    func applicationWillTerminate(_ notification: Notification) {
        model?.handBackPreferredCamera()
        model?.virtualCamera.stopSinkBeforeExit()
    }
}
