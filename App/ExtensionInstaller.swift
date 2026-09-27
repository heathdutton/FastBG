import Foundation
import SystemExtensions

/// Activates the embedded camera extension and reports whether the user has switched it on. Activating is safe on
/// every launch: an active extension of the same version completes without asking anyone. macOS only offers to
/// replace one whose CFBundleVersion or CFBundleShortVersionString differs, so the extension's build number has to go
/// up whenever its code changes.
@MainActor
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    /// Everyone waiting on the activation or the query that's out, answered together when it ends.
    private var activationWaiters: [(_ active: Bool, _ replaced: Bool) -> Void] = []
    private var queryWaiters: [(_ enabled: Bool, _ awaitingApproval: Bool) -> Void] = []
    private var activationID: ObjectIdentifier?
    private var queryID: ObjectIdentifier?
    private var queriedAt = Date.distantPast
    private var replacing = false
    /// An activation request is out. The old extension can still read as enabled while it's being swapped.
    private(set) var isActivating = false

    /// `done` gets whether the extension is active, and whether this request swapped out an older version. A process
    /// that looked at the camera list before a swap never sees the new camera, so callers wait for this first. A call
    /// while one's out waits for that one rather than sending another.
    func activate(_ done: ((_ active: Bool, _ replaced: Bool) -> Void)? = nil) {
        if let done { activationWaiters.append(done) }
        guard !isActivating else { return }
        replacing = false
        isActivating = true
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FastbgCamera.extensionBundleID, queue: .main)
        activationID = ObjectIdentifier(request)
        submit(request)
    }

    private func finishActivation(_ active: Bool) {
        isActivating = false
        activationID = nil
        let waiters = activationWaiters
        activationWaiters = []
        for done in waiters { done(active, replacing) }
    }

    /// One query out at a time, and calls meanwhile wait for its answer. One with no answer after 10 s is given up
    /// on, so a request macOS never answers can't hold up every later one.
    func query(_ done: @escaping (_ enabled: Bool, _ awaitingApproval: Bool) -> Void) {
        queryWaiters.append(done)
        guard queryID == nil || Date().timeIntervalSince(queriedAt) > 10 else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: FastbgCamera.extensionBundleID, queue: .main)
        (queryID, queriedAt) = (ObjectIdentifier(request), Date())
        submit(request)
    }

    private func answerQuery(_ id: ObjectIdentifier, _ enabled: Bool, _ awaiting: Bool) {
        guard id == queryID else { return }
        queryID = nil
        let waiters = queryWaiters
        queryWaiters = []
        for done in waiters { done(enabled, awaiting) }
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             foundProperties properties: [OSSystemExtensionProperties]) {
        let live = properties.filter { !$0.isUninstalling }
        let enabled = live.contains { $0.isEnabled }
        let awaiting = !enabled && live.contains { $0.isAwaitingUserApproval }
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated { answerQuery(id, enabled, awaiting) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        let (old, new) = (existing.bundleVersion, ext.bundleVersion)
        Log.setup.notice("replacing extension \(old, privacy: .public) with \(new, privacy: .public)")
        MainActor.assumeIsolated { replacing = true }
        return .replace
    }

    /// The setup checklist shows where to approve it.
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Log.setup.notice("extension awaits approval in System Settings")
        MainActor.assumeIsolated { finishActivation(false) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Log.setup.notice("extension active, reboot needed: \(result == .willCompleteAfterReboot)")
        MainActor.assumeIsolated { finishActivation(result == .completed) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        Log.setup.error("extension request failed: \(error, privacy: .public)")
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            if id == activationID {
                finishActivation(false)
            } else {
                answerQuery(id, false, false)
            }
        }
    }
}
