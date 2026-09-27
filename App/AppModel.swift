import AVFoundation
import AppKit
import UniformTypeIdentifiers
import VideoToolbox

/// Ties the library, the engine and the virtual camera together behind the panel.
@MainActor
final class AppModel: ObservableObject {
    struct CameraChoice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// An import still copying or transcoding, shown as a tile with a spinner.
    struct PendingImport: Identifiable, Hashable {
        let id: String
        let kind: ItemKind
    }

    let library: Library
    let engine: Engine
    let virtualCamera: VirtualCamera
    /// Some app is reading the fastbg camera.
    @Published private(set) var live = false
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var greenScreenStatus = GreenScreenStatus.off
    @Published private(set) var pending: [PendingImport] = []
    /// macOS's own Background effect is running on the camera fastbg reads, under whatever fastbg puts there.
    @Published private(set) var systemBackground = false
    /// Matting knobs shown in the panel while edges and flicker are tuned on real cameras: what's in use, auto's pick
    /// leaned by the user's offsets while auto is on.
    @Published private(set) var tuning = AppModel.savedTuning()
    /// Picks the tuning from the camera's noise and Vision's flicker. On unless turned off.
    @Published private(set) var auto = UserDefaults.standard.object(forKey: "auto") as? Bool ?? true
    /// How far the user has leaned each of auto's picks, by knob key. Kept while auto adapts around them.
    @Published private(set) var offsets = AppModel.savedOffsets()
    /// What auto measured last, while the camera is being read.
    @Published private(set) var readings: AutoTune.Readings?
    /// Spends more for a steadier picture: a slow camera's gaps filled with interpolated frames. Off unless turned on.
    @Published private(set) var turbo = UserDefaults.standard.bool(forKey: "turbo")
    /// The camera's frame rate while Turbo fills in frames to 30 fps. Settable for the harness, like `usage`.
    @Published var turboFill: Double?
    /// The window's on screen and not covered, which is when tiles move and the usage meter samples.
    @Published private(set) var windowVisible = false
    private var usageWanted = false
    /// Whether each video's or page's moving thumbnail is on disk, looked up once.
    private var loops: [String: Bool] = [:]
    private var makingLoops = false
    /// Tried this run and failed, like a page that's offline, so they aren't retried in a loop.
    private var loopFailed: Set<String> = []
    private var copyingPages = false
    /// Pages too big to keep a copy of, with the change date they were tried at, so they're tried again only once
    /// they change.
    private var pagesSkipped: [String: Date] = [:]
    /// FastBG's own share of CPU and GPU, while the settings that show it are on screen.
    /// Settable for the harness's pictures of the panel.
    @Published var usage: Usage?
    private var usageTimer: Timer?
    /// The matte picked by hand, used while Autocalibrate is off. Autocalibrate always asks for macOS's.
    @Published private(set) var systemMatte = UserDefaults.standard.object(forKey: "systemMatte") as? Bool ?? true
    /// Where masks came from last: false after macOS's matte failed and Vision stood in.
    @Published private(set) var usingSystemMatte: Bool?
    /// Auto's own pick, before the offsets.
    private var autoBase = Tuning()
    /// The newest drop, which becomes active when its import finishes unless a tile is clicked first.
    private var activateOnImport: String?
    private var thumbnails: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []

    init(library: Library, engine: Engine, virtualCamera: VirtualCamera) {
        self.library = library
        self.engine = engine
        self.virtualCamera = virtualCamera
        engine.onGreenScreenStatus = { [weak self] status in self?.greenScreenStatus = status }
        // A switch the user made that fails is undone. One that fails as a call starts, say offline with a URL
        // background, shows Off for that call and stays selected, so the next call tries it again.
        engine.onSwitchDropped = { [weak self] _, showing, userInitiated in
            guard let self, userInitiated else { return }
            NSSound.beep()
            // What's on screen may have been deleted while the failed one loaded.
            if showing != Library.offID, self.library.item(showing) == nil {
                self.library.select(Library.offID)
                self.engine.show(.off)
            } else {
                self.library.select(showing)
            }
        }
        engine.onSystemBackground = { [weak self] on in self?.systemBackground = on }
        engine.onWebFrame = { [weak self] id, pixels in self?.webFrame(id, pixels) }
        engine.onMatteSource = { [weak self] system in self?.usingSystemMatte = system }
        engine.onTurboFill = { [weak self] fps in self?.turboFill = fps }
        engine.setSystemMatte(auto || systemMatte)
        engine.setTurbo(turbo)
        engine.onAutoTuning = { [weak self] base, readings in
            guard let self, auto else { return }
            autoBase = base
            self.readings = readings
            let nudged = base.nudged(offsets)
            if nudged != tuning { tuning = nudged }
        }
        engine.setTuning(tuning)
        engine.setOffsets(offsets)
        engine.setAuto(auto)
        engine.setCamera(library.camera)
        engine.setScreen(auto ? .any : library.screen)
        if library.spec(for: library.selected) == nil { library.select(Library.offID) }
        engine.show(library.spec(for: library.selected) ?? .off)
        virtualCamera.onReaders = { [weak self] readers in
            Task { @MainActor in self?.readersChanged(readers) }
        }
        refreshCameras()
        makeMissingLoops()
        copyPages()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.refreshCameras()
                    self.engine.camerasChanged()
                    self.virtualCamera.rescanSoon()
                }
            })
        }
    }

    /// Nil keeps the current state: the count is unknown, not zero. The sink is started on every report with
    /// readers, since a relaunched extension comes back as a new device whose sink starts out stopped.
    private func readersChanged(_ readers: Int?) {
        guard let readers else { return }
        if readers > 0 {
            virtualCamera.startSink()
            Setup.notePicked()
        }
        guard (readers > 0) != live else { return }
        live = readers > 0
        Log.engine.notice("\(readers) reading fastbg, live: \(self.live)")
        if !live { virtualCamera.stopSink() }
        engine.setLive(live)
    }

    private func refreshCameras() {
        let devices = Camera.devices()
        cameras = devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
        automaticCamera = Camera.automatic(devices.filter { !$0.isSuspended })?.localizedName
        takePreferredCamera()
        // A lid opening or closing suspends the built-in camera without connecting or disconnecting anything.
        suspensions = devices.map { device in
            device.observe(\.isSuspended) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshCameras()
                    self?.engine.camerasChanged()
                }
            }
        }
    }

    private var suspensions: [NSKeyValueObservation] = []
    /// The camera Automatic picks from those plugged in and free, named beside it in the picker.
    @Published private(set) var automaticCamera: String?

    /// "" stands for Automatic, since a picker's tag can't be nil.
    var cameraChoice: String { library.camera ?? "" }

    func setCamera(_ uniqueID: String) {
        let pinned = uniqueID.isEmpty ? nil : uniqueID
        library.setCamera(pinned)
        engine.setCamera(pinned)
    }

    /// macOS has no API to switch its Background effect off, so this opens its own Video Effects menu, where it's
    /// one click.
    func showVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    /// A slider moved. With auto on it leans auto's pick, so the lean holds as auto adapts; with it off it's the
    /// value itself.
    func set(_ path: WritableKeyPath<Tuning, Float>, _ value: Float) {
        guard auto else {
            var t = tuning
            t[keyPath: path] = value
            return setTuning(t)
        }
        guard let knob = Tuning.knob(path) else { return }
        let offset = value - autoBase[keyPath: path]
        offsets[knob.key] = abs(offset) < (knob.range.upperBound - knob.range.lowerBound) * 0.01 ? nil : offset
        saveOffsets()
    }

    func setTurbo(_ on: Bool) {
        turbo = on
        UserDefaults.standard.set(on, forKey: "turbo")
        engine.setTurbo(on)
    }

    /// Samples every 2 s while it's watched and the window's on screen, and not at all otherwise.
    func watchUsage(_ on: Bool) {
        usageWanted = on
        updateUsageTimer()
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        updateUsageTimer()
    }

    private func updateUsageTimer() {
        let run = usageWanted && windowVisible
        guard run != (usageTimer != nil) else { return }
        usageTimer?.invalidate()
        usageTimer = nil
        guard run else { return }
        _ = Usage.measure()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var usage = Usage.measure()
                usage?.neural = self.engine.usesNeuralEngine()
                self.usage = usage
            }
        }
    }

    func setSystemMatte(_ on: Bool) {
        systemMatte = on
        UserDefaults.standard.set(on, forKey: "systemMatte")
        guard !auto else { return }
        usingSystemMatte = nil
        engine.setSystemMatte(on)
    }

    /// Quitting leaves the FastBG camera in every app's list, showing black. Apps that follow the system's preferred
    /// camera switch back by themselves once it names a real one again, so it's pointed at the camera FastBG was
    /// reading, and only when it named FastBG. Apps that keep a camera of their own choosing keep FastBG.
    func handBackPreferredCamera() {
        guard let preferred = AVCaptureDevice.systemPreferredCamera, Camera.isFastbg(preferred),
              let real = Camera.resolve(library.camera) else { return }
        AVCaptureDevice.userPreferredCamera = real
        UserDefaults.standard.set(real.uniqueID, forKey: Self.handedBackKey)
        Log.camera.notice("preferred camera handed back to \(real.localizedName, privacy: .public)")
    }

    private static let takenKey = "preferredCamera.taken", handedBackKey = "preferredCamera.handedBack"
    /// Set by the app, never by the harness, since the preferred camera is every app's setting.
    private var ownsPreferredCamera = false

    func ownPreferredCamera() {
        ownsPreferredCamera = true
        // The system's camera choice reads nil for a moment after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.takePreferredCamera() }
    }

    /// Makes FastBG the system's preferred camera, which is shared by every app, so FaceTime and the others that
    /// follow it use FastBG without being asked. Once when its camera first shows up, and again at launch when
    /// quitting handed the choice back and nobody's picked another camera since.
    private func takePreferredCamera() {
        guard ownsPreferredCamera, let fastbg = Camera.fastbg() else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.takenKey) {
            defaults.set(true, forKey: Self.takenKey)
        } else if let back = defaults.string(forKey: Self.handedBackKey) {
            // Nil until the system has settled its choice, a moment after launch.
            guard let preferred = AVCaptureDevice.systemPreferredCamera else { return }
            defaults.removeObject(forKey: Self.handedBackKey)
            guard preferred.uniqueID == back else { return }
        } else {
            return
        }
        AVCaptureDevice.userPreferredCamera = fastbg
        Log.camera.notice("FastBG made the preferred camera")
    }

    /// Back to auto's own picks.
    func resetOffsets() {
        offsets = [:]
        saveOffsets()
    }

    private func saveOffsets() {
        UserDefaults.standard.set(offsets.mapValues(Double.init), forKey: "auto.offsets")
        engine.setOffsets(offsets)
        tuning = autoBase.nudged(offsets)
    }

    private static func savedOffsets() -> [String: Float] {
        (UserDefaults.standard.dictionary(forKey: "auto.offsets") as? [String: Double] ?? [:]).mapValues(Float.init)
    }

    private func setTuning(_ tuning: Tuning) {
        self.tuning = tuning
        engine.setTuning(tuning)
        for knob in Tuning.knobs {
            UserDefaults.standard.set(Double(tuning[keyPath: knob.path]), forKey: knob.key)
        }
    }

    private static func savedTuning() -> Tuning {
        var tuning = Tuning()
        for knob in Tuning.knobs {
            guard let v = UserDefaults.standard.object(forKey: knob.key) as? Double else { continue }
            tuning[keyPath: knob.path] = Float(v)
        }
        return tuning
    }

    /// The menu's choice, which Auto sets aside while it's on.
    func setScreen(_ color: ScreenColor) {
        library.setScreen(color)
        if !auto { engine.setScreen(color) }
    }

    /// Auto on or off. On, it looks for either screen whatever the menu says. Turning it off keeps what's in use,
    /// the screen it found and the sliders, as the place to tune from.
    func setAuto(_ on: Bool) {
        auto = on
        UserDefaults.standard.set(on, forKey: "auto")
        engine.setAuto(on)
        if on {
            engine.setScreen(.any)
            if !systemMatte {
                usingSystemMatte = nil
                engine.setSystemMatte(true)
            }
        } else {
            readings = nil
            setTuning(tuning)
            setSystemMatte(usingSystemMatte ?? true)
            if let rgb = screenRGB { library.setScreen(rgb.z > rgb.y ? .blue : .green) }
            engine.setScreen(library.screen)
        }
    }

    /// What the screen row names while Auto decides: the colour it's keying, or where the search is at.
    var screenFound: String {
        if let rgb = screenRGB { return rgb.z > rgb.y ? "Blue" : "Green" }
        return greenScreenStatus == .notFound ? "None found" : screenPending
    }

    /// Before a screen's found: the camera's only read while an app has FastBG open, so till then there's nothing
    /// to look at.
    var screenPending: String { live ? "Checking" : "Waiting" }

    /// The screen's measured colour while one is being keyed.
    var screenRGB: SIMD3<Float>? {
        if case .keyed(_, let rgb) = greenScreenStatus { return rgb }
        return nil
    }

    func isAvailable(_ item: Item) -> Bool {
        library.isAvailable(item) && (item.kind != .web || WebPage.isSupported)
    }

    /// A page that's going on screen now thumbnails from its first frame (`onWebFrame`). One that isn't loads once
    /// on its own for it.
    private func thumbnailWeb(_ item: Item) {
        guard !(live && library.selected == item.id), let target = Library.webTarget(item.src) else { return }
        let url = library.thumbnailURL(for: item.id)
        Task {
            await Importer.webThumbnail(target, dst: url)
            thumbnailChanged(item.id)
        }
    }

    private func webFrame(_ id: String, _ pixels: CVPixelBuffer) {
        let url = library.thumbnailURL(for: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        let box = ImageBox(image)
        Task.detached(priority: .utility) {
            try? Importer.writeThumbnail(box.image, to: url)
            await MainActor.run { self.thumbnailChanged(id) }
        }
    }

    private func thumbnailChanged(_ id: String) {
        thumbnails[id] = nil
        loops[id] = nil
        objectWillChange.send()
    }

    /// The backgrounds that ship with FastBG go into the library the first time it runs, each tile spinning till
    /// it's in. Once added, deleting one keeps it deleted.
    func addStock() {
        guard !library.stocked else { return }
        let clips = Importer.stock.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Stock").map { (name, $0) }
        }
        guard !clips.isEmpty else { return }
        let ids = clips.map { _ in UUID().uuidString.lowercased() }
        pending.append(contentsOf: ids.map { PendingImport(id: $0, kind: .video) })
        Task {
            for ((name, url), id) in zip(clips, ids) {
                do {
                    library.add(try await Importer.importStock(url, id: id, root: library.root))
                } catch {
                    Log.library.error("stock \(name, privacy: .public) wasn't added: \(error, privacy: .public)")
                }
                pending.removeAll { $0.id == id }
            }
            library.markStocked()
            makeMissingLoops()
        }
    }

    /// A dropped page loads from where it is, and the library keeps a copy of it and what it loads for when the
    /// original's gone, refreshed whenever the original changes. One at a time, off the main thread.
    private func copyPages() {
        guard !copyingPages else { return }
        func changed(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        let due = library.items.lazy.compactMap { item -> (String, URL, URL, Date)? in
            guard item.kind == .web, case .file(let page)? = Library.webTarget(item.src),
                  let edited = changed(page), self.pagesSkipped[item.id] != edited else { return nil }
            let folder = self.library.pageFolder(for: item.id)
            if let copied = changed(folder.appendingPathComponent(page.lastPathComponent)), copied >= edited {
                return nil
            }
            return (item.id, page, folder, edited)
        }.first
        guard let (id, page, folder, edited) = due else { return }
        copyingPages = true
        Task {
            let kept = await Task.detached(priority: .utility) {
                (try? Importer.copyPage(page, into: folder)) ?? false
            }.value
            if !kept {
                pagesSkipped[id] = edited
                Log.library.notice("no copy kept of \(page.lastPathComponent, privacy: .public): past the size limit")
            }
            copyingPages = false
            copyPages()
        }
    }

    /// A video's or page's moving thumbnail, if it has one yet.
    func loop(_ id: String) -> URL? {
        let url = library.loopURL(for: id)
        if loops[id] == nil { loops[id] = FileManager.default.fileExists(atPath: url.path) }
        return loops[id] == true ? url : nil
    }

    /// Videos and pages without a moving thumbnail get one, one at a time: ones imported before tiles moved, and
    /// every new page, whose tile goes up before anything's loaded.
    private func makeMissingLoops() {
        // A run already going looks again after each one it makes.
        guard !makingLoops else { return }
        let missing = library.items.filter { $0.kind != .image && loop($0.id) == nil && isAvailable($0) }
        guard let item = missing.first(where: { !loopFailed.contains($0.id) }) else { return }
        makingLoops = true
        let dst = library.loopURL(for: item.id)
        let spec = library.spec(for: item.id)
        Task {
            do {
                switch spec {
                case .video(_, let src)?:
                    try await Task.detached(priority: .utility) { try await Importer.videoLoop(src: src, dst: dst) }
                        .value
                case .web(_, let target)?:
                    try await Importer.webLoop(target, dst: dst)
                default:
                    break
                }
                thumbnailChanged(item.id)
            } catch {
                loopFailed.insert(item.id)
            }
            makingLoops = false
            makeMissingLoops()
        }
    }

    func thumbnail(_ id: String) -> NSImage? {
        if let cached = thumbnails[id] { return cached }
        let image = NSImage(contentsOf: library.thumbnailURL(for: id))
        thumbnails[id] = image
        return image
    }

    func select(_ id: String) {
        activateOnImport = nil
        guard let spec = library.spec(for: id), library.item(id).map(isAvailable) ?? true else {
            return NSSound.beep()
        }
        library.select(id)
        engine.show(spec)
        if case .web = spec { copyPages() }
    }

    /// Deleting the active background dissolves to Off.
    func delete(_ id: String) {
        let wasSelected = library.selected == id
        library.remove(id)
        thumbnails[id] = nil
        loops[id] = nil
        if wasSelected { engine.show(.off) }
    }

    /// A dragged tile carries the background itself, so it lands in Finder, a browser or a mail as a file or a link,
    /// with the tile marker beside it.
    func dragProvider(for item: Item) -> NSItemProvider {
        let provider = library.exportURL(for: item).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        let id = Data(item.id.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fastbgTile.identifier, visibility: .all) {
            $0(id, nil)
            return nil
        }
        return provider
    }

    func move(_ id: String, to index: Int) {
        library.move(id, to: index)
    }

    /// Anything unreadable is ignored with a beep. The last accepted item becomes active once it's imported.
    func importPayloads(_ payloads: [DropPayload]) {
        let accepted = payloads.compactMap { payload in Importer.kind(of: payload).map { (payload, $0) } }
        if accepted.count < payloads.count || payloads.isEmpty { NSSound.beep() }
        for (index, (payload, kind)) in accepted.enumerated() {
            let id = UUID().uuidString.lowercased()
            pending.append(PendingImport(id: id, kind: kind))
            if index == accepted.count - 1 { activateOnImport = id }
            Task {
                do {
                    let item = try await Importer.importItem(payload, id: id, root: library.root)
                    pending.removeAll { $0.id == id }
                    library.add(item)
                    if activateOnImport == id { select(id) }
                    if item.kind == .web { thumbnailWeb(item) }
                    makeMissingLoops()
                    copyPages()
                } catch {
                    pending.removeAll { $0.id == id }
                    if activateOnImport == id { activateOnImport = nil }
                    NSSound.beep()
                }
            }
        }
    }

    func openPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image, .html]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        importPayloads(panel.urls.map(DropPayload.file))
    }

    func paste() {
        importPayloads(Importer.payloads(from: .general))
    }
}

/// Carries a finished frame's image to the thumbnail writer.
private struct ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
