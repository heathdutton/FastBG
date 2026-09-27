import Foundation

enum ItemKind: String, Codable, Sendable {
    case image, video, web
}

/// One background in the library. `src` is the copied media relative to the library root (`media/<id>.heic`), the
/// absolute path of a referenced `.html`, or an http(s) URL string.
struct Item: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: ItemKind
    let src: String
}

enum WebTarget: Hashable, Sendable {
    case url(URL)
    /// Loaded with read access to its folder, so relative css, js and images resolve.
    case file(URL)
}

/// What the engine is asked to put behind the person.
enum BackgroundSpec: Hashable, Sendable {
    case off
    case image(id: String, url: URL)
    case video(id: String, url: URL)
    case web(id: String, target: WebTarget)

    var id: String {
        switch self {
        case .off: Library.offID
        case .image(let id, _), .video(let id, _), .web(let id, _): id
        }
    }
}

/// The library, its order, the selection and the footer settings, persisted to library.json after every change.
@MainActor
final class Library: ObservableObject {
    nonisolated static let offID = "off"

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fastbg", isDirectory: true)
    }

    private struct File: Codable {
        var selected: String
        var camera: String?
        var screen: ScreenColor?
        /// Before blue screens had their own setting. Read, never written.
        var greenScreen: Bool?
        /// The backgrounds that ship with FastBG were added once, so deleting them keeps them gone.
        var stocked: Bool?
        var items: [Item]
    }

    let root: URL
    /// library.json existed but didn't decode. It's moved aside before the first save rather than overwritten.
    private var unreadable = false
    @Published private(set) var items: [Item] = []
    @Published private(set) var selected = Library.offID
    @Published private(set) var camera: String?
    @Published private(set) var screen = ScreenColor.any
    private(set) var stocked = false

    private var fileURL: URL { root.appendingPathComponent("library.json") }

    /// A file that won't decode leaves the library empty, and stays on disk untouched until the first change.
    init(root: URL = Library.defaultRoot) {
        self.root = root
        let url = root.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: url) else { return }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            unreadable = true
            return
        }
        var seen = Set<String>()
        items = file.items.filter { $0.id != Library.offID && seen.insert($0.id).inserted }
        selected = seen.contains(file.selected) ? file.selected : Library.offID
        camera = file.camera
        screen = file.screen ?? (file.greenScreen == true ? .green : .any)
        stocked = file.stocked ?? false
        sweep()
    }

    /// Removes copied media, pages and thumbnails no item refers to, left behind by a quit mid-import, and the last
    /// run's dragged-out links.
    private func sweep() {
        let fm = FileManager.default
        try? fm.removeItem(at: drags)
        let kept = Set(items.flatMap { [$0.src, "thumbs/\($0.id).jpg", "thumbs/\($0.id).heics", "pages/\($0.id)"] })
        for folder in ["media", "thumbs", "pages"] {
            let dir = root.appendingPathComponent(folder)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where !kept.contains("\(folder)/\(name)") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    func mediaURL(for id: String, ext: String) -> URL {
        root.appendingPathComponent("media/\(id).\(ext)")
    }

    private var drags: URL { root.appendingPathComponent("drags", isDirectory: true) }

    /// What a tile dragged out of the panel hands over. A web background gives its page, and media gives a hard link
    /// with a readable name, in a folder of its own. A receiver that moves the file instead of copying it takes the
    /// link and leaves the library whole. Nil when there's nothing to hand over.
    func exportURL(for item: Item) -> URL? {
        guard isAvailable(item) else { return nil }
        switch item.kind {
        case .web:
            switch Self.webTarget(item.src) {
            case .url(let url): return url
            case .file: return pageFile(item)
            case nil: return nil
            }
        case .image, .video:
            let fm = FileManager.default
            let stale = Date().addingTimeInterval(-600)
            for old in (try? fm.contentsOfDirectory(at: drags, includingPropertiesForKeys: [.creationDateKey])) ?? []
            where ((try? old.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < stale {
                try? fm.removeItem(at: old)
            }
            let source = root.appendingPathComponent(item.src)
            let folder = drags.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let link = folder.appendingPathComponent("\(FastbgCamera.name) background")
                .appendingPathExtension(source.pathExtension)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.linkItem(at: source, to: link)
                return link
            } catch {
                return nil
            }
        }
    }

    func thumbnailURL(for id: String) -> URL {
        root.appendingPathComponent("thumbs/\(id).jpg")
    }

    /// FastBG's copy of a dropped page and what it loads, which the tile falls back to once the original's gone.
    func pageFolder(for id: String) -> URL {
        root.appendingPathComponent("pages/\(id)", isDirectory: true)
    }

    /// The page to load from: the original while it's there, so edits show, and the copy after.
    func pageFile(_ item: Item) -> URL? {
        guard item.kind == .web, case .file(let page)? = Self.webTarget(item.src) else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: page.path) { return page }
        let copy = pageFolder(for: item.id).appendingPathComponent(page.lastPathComponent)
        return fm.fileExists(atPath: copy.path) ? copy : nil
    }

    /// A video's moving thumbnail, which older libraries don't have yet.
    func loopURL(for id: String) -> URL {
        root.appendingPathComponent("thumbs/\(id).heics")
    }

    func item(_ id: String) -> Item? {
        items.first { $0.id == id }
    }

    /// Nil for an unknown id or a referenced `.html` that has moved or been deleted.
    func spec(for id: String) -> BackgroundSpec? {
        if id == Library.offID { return .off }
        guard let item = item(id), isAvailable(item) else { return nil }
        switch item.kind {
        case .image: return .image(id: id, url: root.appendingPathComponent(item.src))
        case .video: return .video(id: id, url: root.appendingPathComponent(item.src))
        case .web:
            if let page = pageFile(item) { return .web(id: id, target: .file(page)) }
            return Self.webTarget(item.src).map { .web(id: id, target: $0) }
        }
    }

    func isAvailable(_ item: Item) -> Bool {
        switch item.kind {
        case .image, .video:
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(item.src).path)
        case .web:
            guard let target = Self.webTarget(item.src) else { return false }
            if case .file = target { return pageFile(item) != nil }
            return true
        }
    }

    static func webTarget(_ src: String) -> WebTarget? {
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .url(url)
        }
        return src.hasPrefix("/") ? .file(URL(fileURLWithPath: src)) : nil
    }

    func markStocked() {
        guard !stocked else { return }
        stocked = true
        save()
    }

    func add(_ item: Item) {
        guard self.item(item.id) == nil else { return }
        items.append(item)
        save()
    }

    /// Removes the entry, its thumbnail and any copied media. A referenced `.html` is the user's file and stays.
    func remove(_ id: String) {
        guard let item = item(id) else { return }
        items.removeAll { $0.id == id }
        if selected == id { selected = Library.offID }
        let fm = FileManager.default
        try? fm.removeItem(at: thumbnailURL(for: id))
        try? fm.removeItem(at: loopURL(for: id))
        try? fm.removeItem(at: pageFolder(for: id))
        if item.kind != .web, item.src.hasPrefix("media/") {
            try? fm.removeItem(at: root.appendingPathComponent(item.src))
        }
        save()
    }

    func move(_ id: String, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(index, items.count - 1))
        guard from != to else { return }
        items.insert(items.remove(at: from), at: to)
        save()
    }

    func select(_ id: String) {
        guard id == Library.offID || item(id) != nil, id != selected else { return }
        selected = id
        save()
    }

    func setCamera(_ uniqueID: String?) {
        guard uniqueID != camera else { return }
        camera = uniqueID
        save()
    }

    func setScreen(_ color: ScreenColor) {
        guard color != screen else { return }
        screen = color
        save()
    }

    private func save() {
        let file = File(selected: selected, camera: camera, screen: screen, stocked: stocked ? true : nil, items: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if unreadable {
                unreadable = false
                let aside = root.appendingPathComponent("library.unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
            }
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            Log.library.error("saving library.json failed: \(error, privacy: .public)")
        }
    }
}
