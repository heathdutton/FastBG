import AVFoundation
import Foundation
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum LibraryChecks {
    static func run() async -> Bool {
        guard let photoURL = Paths.fixture("portrait-brick.jpg"), let photo = Pixels.image(photoURL) else {
            return false
        }
        var ok = true
        let root = Paths.temp("library")
        try? FileManager.default.removeItem(at: root)

        ok = expect(Importer.kind(of: .file(URL(fileURLWithPath: "/a/b.MOV"))) == .video, "kind: .MOV is video") && ok
        ok = expect(Importer.kind(of: .file(URL(fileURLWithPath: "/a/b.gif"))) == .image, "kind: .gif is a still")
            && ok
        ok = expect(Importer.kind(of: .file(URL(fileURLWithPath: "/a/b.webp"))) == .image, "kind: .webp is a still")
            && ok
        ok = expect(Importer.kind(of: .file(URL(fileURLWithPath: "/a/b.htm"))) == .web, "kind: .htm is web") && ok
        ok = expect(Importer.kind(of: .file(URL(fileURLWithPath: "/a/b.txt"))) == nil, "kind: .txt is refused") && ok
        ok = expect(Importer.webURLs(in: " https://example.com/a \n") == [URL(string: "https://example.com/a")!],
                    "paste: a lone URL in selected text") && ok
        ok = expect(Importer.webURLs(in: "see https://example.com").isEmpty, "paste: prose isn't a URL") && ok

        let library = Library(root: root)

        // An upright portrait stored sideways with EXIF orientation 6, as phones do.
        let rotated = Paths.temp("rotated.jpg")
        if let dest = CGImageDestinationCreateWithURL(rotated as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, photo, [kCGImagePropertyOrientation: 6] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        let html = Paths.temp("page/index.html")
        try? FileManager.default.createDirectory(at: html.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? "<link rel=stylesheet href=style.css><h1>fastbg</h1>".write(to: html, atomically: true, encoding: .utf8)
        try? "body { background: rgb(10, 200, 30) }".write(to: html.deletingLastPathComponent()
            .appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        let clip = makeClip()

        var payloads: [(String, DropPayload)] = [("photo", .file(photoURL)), ("rotated", .file(rotated)),
                                                 ("html", .file(html))]
        if let clip { payloads.append(("clip", .file(clip))) }
        if ProcessInfo.processInfo.environment["FASTBG_CHECK_NETWORK"] != nil {
            payloads.append(("url", .web(URL(string: "https://example.com")!)))
        }
        var ids: [String: String] = [:]
        for (name, payload) in payloads {
            let id = UUID().uuidString.lowercased()
            do {
                let started = Date()
                let item = try await Importer.importItem(payload, id: id, root: root)
                library.add(item)
                ids[name] = id
                // A page's tile goes up at once, and the app thumbnails it afterwards.
                if item.kind == .web, let target = Library.webTarget(item.src) {
                    ok = expect(Date().timeIntervalSince(started) < 0.2, "import \(name): tile up at once") && ok
                    await Importer.webThumbnail(target, dst: library.thumbnailURL(for: id))
                }
                let thumb = Pixels.image(library.thumbnailURL(for: id))
                ok = expect(thumb?.width == 320 && thumb?.height == 180, "import \(name): 320x180 thumbnail") && ok
            } catch {
                ok = expect(false, "import \(name): \(error)") && ok
            }
        }
        let junk = Paths.temp("junk.jpg")
        try? Data("not a picture".utf8).write(to: junk)
        do {
            _ = try await Importer.importItem(.file(junk), id: "junk", root: root)
            ok = expect(false, "import: an unreadable file is refused") && ok
        } catch {
            ok = expect(true, "import: an unreadable file is refused") && ok
        }

        if let id = ids["photo"], case .image(_, let url)? = library.spec(for: id), let still = Pixels.image(url) {
            ok = expect(still.width >= 1920 && still.height >= 1080 && (still.width == 1920 || still.height == 1080),
                        "import photo: \(still.width)x\(still.height) just covers 1080p") && ok
            ok = expect(url.pathExtension == "heic", "import photo: stored as HEIC") && ok
        }
        if let id = ids["rotated"], case .image(_, let url)? = library.spec(for: id), let still = Pixels.image(url) {
            ok = expect(still.height > still.width, "import rotated: orientation baked in, \(still.width)x"
                        + "\(still.height)") && ok
        }
        if let id = ids["clip"], case .video(_, let url)? = library.spec(for: id) {
            ok = await checkClip(url) && ok
            ok = checkLoop(library.loopURL(for: id)) && ok
            ok = await checkPlayback(url) && ok
        }

        // Order, selection and settings, then a relaunch.
        let order = library.items.map(\.id)
        library.move(order[order.count - 1], to: 0)
        library.select(order[1])
        library.setScreen(.blue)
        library.setCamera("camera-uid")
        let photoMedia = ids["photo"].map { root.appendingPathComponent(library.item($0)!.src) }
        if let id = ids["photo"] { library.remove(id) }
        if let id = ids["html"] { library.remove(id) }
        ok = expect(photoMedia.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false,
                    "delete: copied media removed from disk") && ok
        ok = expect(ids["photo"].map { !FileManager.default.fileExists(atPath: library.thumbnailURL(for: $0).path) }
                    ?? false, "delete: thumbnail removed from disk") && ok
        ok = expect(FileManager.default.fileExists(atPath: html.path), "delete: a referenced .html stays") && ok

        let reloaded = Library(root: root)
        ok = expect(reloaded.items == library.items, "relaunch: order survives") && ok
        ok = expect(reloaded.selected == library.selected, "relaunch: selection survives") && ok
        ok = expect(reloaded.screen == .blue && reloaded.camera == "camera-uid",
                    "relaunch: footer settings survive") && ok

        // A referenced page that moves grays out.
        let page2 = Paths.temp("page2.html")
        try? "<p>hi</p>".write(to: page2, atomically: true, encoding: .utf8)
        let item = Item(id: "moved", kind: .web, src: page2.path)
        reloaded.add(item)
        try? FileManager.default.removeItem(at: page2)
        ok = expect(!reloaded.isAvailable(item) && reloaded.spec(for: "moved") == nil, "a moved .html grays out") && ok

        let corrupt = Paths.temp("corrupt")
        try? FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let json = corrupt.appendingPathComponent("library.json")
        try? Data("{nope".utf8).write(to: json)
        let fromCorrupt = Library(root: corrupt)
        ok = expect(fromCorrupt.items.isEmpty && (try? Data(contentsOf: json)) == Data("{nope".utf8),
                    "a corrupt library.json loads empty and stays untouched") && ok
        fromCorrupt.setScreen(.blue)
        let aside = corrupt.appendingPathComponent("library.unreadable.json")
        ok = expect((try? Data(contentsOf: aside)) == Data("{nope".utf8),
                    "the first change moves a corrupt library.json aside") && ok

        // A quit mid-import leaves media and a thumbnail nothing refers to; the next launch clears them.
        let orphan = root.appendingPathComponent("media/orphan.heic")
        let orphanThumb = root.appendingPathComponent("thumbs/orphan.jpg")
        try? Data().write(to: orphan)
        try? Data().write(to: orphanThumb)
        let swept = Library(root: root)
        ok = expect(!FileManager.default.fileExists(atPath: orphan.path)
                    && !FileManager.default.fileExists(atPath: orphanThumb.path) && swept.items == reloaded.items,
                    "relaunch: orphaned media and thumbnails swept, items kept") && ok
        ok = await checkStock() && ok
        ok = checkPageCopies() && ok
        return checkDragOut(swept, root: root) && ok
    }

    /// A dropped page keeps a copy with what it loads: its whole folder when it has one, only what it names when
    /// it's loose on a shelf like Downloads, within the size limits. Once the original's gone, the copy loads.
    static func checkPageCopies() -> Bool {
        var ok = true
        let fm = FileManager.default
        let dir = Paths.temp("pages")
        try? fm.removeItem(at: dir)
        func write(_ path: String, _ text: String) {
            let url = dir.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        func sparse(_ path: String, _ bytes: UInt64) {
            let url = dir.appendingPathComponent(path)
            fm.createFile(atPath: url.path, contents: nil)
            try? FileHandle(forWritingTo: url).truncate(atOffset: bytes)
        }
        func has(_ folder: URL, _ paths: [String]) -> Bool {
            paths.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
        // A page in a folder of its own.
        write("site/index.html", "<link rel=stylesheet href=style.css><script src=\"js/run.js\"></script>")
        write("site/style.css", "body { background: url('img/bg.png') }")
        write("site/js/run.js", "")
        write("site/img/bg.png", "png")
        let site = dir.appendingPathComponent("copies/site")
        let copied = (try? Importer.copyPage(dir.appendingPathComponent("site/index.html"), into: site, shelves: [],
                                             transient: [])) ?? false
        ok = expect(copied && has(site, ["index.html", "style.css", "js/run.js", "img/bg.png"]),
                    "page copy: a page in its own folder takes the folder") && ok
        // One loose on a shelf, beside files that aren't its business.
        let shelf = dir.appendingPathComponent("shelf")
        write("shelf/page.html", "<img src='art/my%20bg.png'><link href=\"look.css?v=2\" rel=stylesheet>")
        write("shelf/look.css", "@font-face { src: url(fonts/face.woff) }")
        write("shelf/art/my bg.png", "png")
        write("shelf/fonts/face.woff", "woff")
        write("shelf/statement.pdf", "private")
        let loose = dir.appendingPathComponent("copies/loose")
        let looseOK = (try? Importer.copyPage(shelf.appendingPathComponent("page.html"), into: loose,
                                              shelves: [shelf], transient: [])) ?? false
        ok = expect(looseOK && has(loose, ["page.html", "look.css", "art/my bg.png", "fonts/face.woff"])
                    && !has(loose, ["statement.pdf"]),
                    "page copy: a loose page takes only what it names") && ok
        // Past 50 MB it's kept only from somewhere files go missing, up to 500 MB.
        write("big/page.html", "<video src=clip.mov></video>")
        sparse("big/clip.mov", 60_000_000)
        let bigPage = dir.appendingPathComponent("big/page.html")
        let refused = (try? Importer.copyPage(bigPage, into: dir.appendingPathComponent("copies/big"),
                                              shelves: [], transient: [])) ?? true
        let kept = (try? Importer.copyPage(bigPage, into: dir.appendingPathComponent("copies/big"), shelves: [],
                                           transient: [dir])) ?? false
        ok = expect(!refused && kept, "page copy: 60 MB is kept only from a place files go missing") && ok
        // The tile falls back to the copy once the original's deleted.
        let library = Library(root: dir.appendingPathComponent("library"))
        write("gone/page.html", "<p>hi</p>")
        let item = Item(id: "gone", kind: .web, src: dir.appendingPathComponent("gone/page.html").path)
        library.add(item)
        _ = try? Importer.copyPage(dir.appendingPathComponent("gone/page.html"), into: library.pageFolder(for: "gone"),
                                   shelves: [], transient: [])
        try? fm.removeItem(at: dir.appendingPathComponent("gone"))
        if case .web(_, .file(let url))? = library.spec(for: "gone") {
            ok = expect(url.path.hasPrefix(library.root.path) && library.isAvailable(item),
                        "page copy: once the original's deleted, the tile loads the copy") && ok
        } else {
            ok = expect(false, "page copy: once the original's deleted, the tile loads the copy") && ok
        }
        library.remove("gone")
        ok = expect(!fm.fileExists(atPath: library.pageFolder(for: "gone").path),
                    "page copy: deleting the tile deletes the copy") && ok
        return ok
    }

    /// Every stock clip goes into a library as it is: no re-encode, a thumbnail, playable, and remembered as added.
    static func checkStock() async -> Bool {
        var ok = true
        let root = Paths.temp("stock-library")
        try? FileManager.default.removeItem(at: root)
        let library = Library(root: root)
        for name in Importer.stock {
            let src = Paths.repo.appendingPathComponent("Stock/\(name).mp4")
            let started = Date()
            do {
                let item = try await Importer.importStock(src, id: name, root: root)
                library.add(item)
                let media = root.appendingPathComponent(item.src)
                let same = FileManager.default.contentsEqual(atPath: src.path, andPath: media.path)
                let thumb = Pixels.image(library.thumbnailURL(for: name))
                let took = Date().timeIntervalSince(started)
                ok = expect(same && thumb?.width == 320,
                            String(format: "stock %@: copied as it is, thumbnailed, in %.2f s", name, took)) && ok
                if case .video(_, let url)? = library.spec(for: name) { ok = await checkPlayback(url) && ok }
            } catch {
                ok = expect(false, "stock \(name): \(error)") && ok
            }
        }
        library.markStocked()
        let reloaded = Library(root: root)
        ok = expect(reloaded.stocked && reloaded.items.map(\.id) == Importer.stock,
                    "stock: all five in order, and remembered as added") && ok
        return ok
    }

    /// A tile dragged out of the panel carries the background and the tile marker, and moving what it handed over
    /// leaves the library alone.
    static func checkDragOut(_ library: Library, root: URL) -> Bool {
        var ok = true
        let fm = FileManager.default
        let model = AppModel(library: library, engine: Engine(sink: CaptureSink(), usesCamera: false),
                             virtualCamera: VirtualCamera())
        let marker = UTType.fastbgTile.identifier
        func inode(_ url: URL?) -> Int? {
            url.flatMap { (try? fm.attributesOfItem(atPath: $0.path))?[.systemFileNumber] as? Int }
        }
        if let still = library.items.first(where: { $0.kind == .image }) {
            let media = root.appendingPathComponent(still.src)
            let link = library.exportURL(for: still)
            ok = expect(link?.lastPathComponent == "FastBG background.heic" && inode(link) == inode(media),
                        "drag out: a still goes as a link to its media, \(link?.lastPathComponent ?? "none")") && ok
            let types = model.dragProvider(for: still).registeredTypeIdentifiers
            ok = expect(types.contains(UTType.fileURL.identifier) && types.contains(marker),
                        "drag out: a still carries its file and the tile marker") && ok
            if let link { try? fm.moveItem(at: link, to: Paths.temp("dropped.heic")) }
            ok = expect(fm.fileExists(atPath: media.path) && library.isAvailable(still),
                        "drag out: a receiver moving the file leaves the library whole") && ok
        }
        let page = Item(id: "page", kind: .web, src: "https://example.com/")
        library.add(page)
        let types = model.dragProvider(for: page).registeredTypeIdentifiers
        ok = expect(types.contains(UTType.url.identifier) && !types.contains(UTType.fileURL.identifier)
                    && types.contains(marker), "drag out: a page carries its link") && ok
        library.remove(page.id)
        return ok
    }

    /// 4K60 with audio, the case import exists for. Needs ffmpeg; skipped without it.
    static func makeClip() -> URL? {
        let out = Paths.temp("clip.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                             "testsrc2=size=3840x2160:rate=60", "-f", "lavfi", "-i", "sine=frequency=440",
                             "-t", "2", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "-shortest", out.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("SKIP  video import: no ffmpeg")
            return nil
        }
        return process.terminationStatus == 0 ? out : nil
    }

    /// The tile's moving thumbnail: 12 fps, 256x144, looping, never over 3 s, and cheap to play.
    static func checkLoop(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return expect(false, "import clip: no moving thumbnail")
        }
        let count = CGImageSourceGetCount(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let delay = (props?[kCGImagePropertyHEICSDictionary] as? [CFString: Any])?[
            kCGImagePropertyHEICSUnclampedDelayTime] as? Double ?? 0
        let started = CACurrentMediaTime()
        let frames = (0..<count).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        let decode = (CACurrentMediaTime() - started) / Double(max(count, 1)) * 1000
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let size = frames.first.map { "\($0.width)x\($0.height)" } ?? "none"
        return expect(count > 1 && Double(count) * delay <= 3.01 && abs(delay - 1.0 / 12) < 0.001
                      && size == "256x144" && frames.count == count,
                      String(format: "import clip: moving thumbnail, %d frames of %@ at %.0f fps, %d KB, %.2f ms a "
                             + "frame to decode", count, size, 1 / max(delay, 0.001), bytes / 1024, decode))
    }

    static func checkClip(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let audio = try? await asset.loadTracks(withMediaType: .audio),
              let (size, fps, formats) = try? await video.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        else { return expect(false, "import clip: unreadable result") }
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        var ok = expect(size.width <= 1920 && size.height <= 1080, "import clip: 4K scaled to \(Int(size.width))x"
                        + "\(Int(size.height))")
        ok = expect(fps <= 30.5, "import clip: 60 fps capped to \(fps)") && ok
        ok = expect(audio.isEmpty, "import clip: audio stripped") && ok
        ok = expect(codec == kCMVideoCodecType_HEVC, "import clip: HEVC") && ok
        return ok
    }

    /// Pulls frames like the engine does, at 30 Hz, for 4 s. A clip under 30 fps, like a 25 fps stock one, can only
    /// be fresh that share of the time.
    static func checkPlayback(_ url: URL) async -> Bool {
        let rate = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.nominalFrameRate))
            ?? 30
        let ready = Flag()
        let source = VideoSource(url: url) { ok in ready.set(ok) }
        for _ in 0..<100 where ready.value == nil { await sleep(0.03) }
        guard ready.value == true else {
            source.close()
            return expect(false, "video: never became ready")
        }
        var fresh = 0, longestHold = 0, hold = 0
        var last: ObjectIdentifier?
        let start = CACurrentMediaTime()
        for i in 0..<120 {
            let due = start + Double(i) / 30
            if due > CACurrentMediaTime() { await sleep(due - CACurrentMediaTime()) }
            // At the scheduled moment, as the engine samples at the camera's evenly spaced capture times.
            guard case .buffer(let pixels)? = source.frame(at: due) else { continue }
            let id = ObjectIdentifier(pixels)
            if id != last {
                fresh += 1
                hold = 0
            } else {
                hold += 1
                longestHold = max(longestHold, hold)
            }
            last = id
        }
        source.close()
        let want = Int(Double(min(rate, 30)) / 30 * 100)
        var ok = expectRate(fresh >= want, "video: \(fresh) fresh frames of 120 pulled across the loop from a "
                            + "\(Int(rate.rounded())) fps clip, \(want) wanted")
        ok = expectRate(longestHold <= 3, "video: longest hold \(longestHold) frames") && ok
        return ok
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Bool?
    var value: Bool? { lock.withLock { state } }
    func set(_ v: Bool) { lock.withLock { state = v } }
}
