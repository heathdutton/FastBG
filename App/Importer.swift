import AVFoundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    /// Carried by a tile dragged out of the panel, beside the background itself, so a drop back in the panel or on
    /// the menu bar icon reorders or is refused instead of importing a copy. Nothing outside FastBG reads it.
    static let fastbgTile = UTType(exportedAs: "com.heathdutton.fastbg.tile")
}

enum DropPayload: Hashable, Sendable {
    case file(URL)
    case web(URL)
}

struct ImportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Turns drops and pastes into library items. Media is copied into the library and normalized once, so playback
/// stays cheap for good: video to HEVC at 1080p30 or less with no audio, stills to 8-bit sRGB HEIC that just covers
/// 1080p.
enum Importer {
    static let frame = CGSize(width: 1920, height: 1080)
    static let thumb = CGSize(width: 320, height: 180)

    // MARK: Drops

    static func payloads(from pasteboard: NSPasteboard) -> [DropPayload] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        if !files.isEmpty { return files.map { .file(filePath($0)) } }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).compactMap(webURL)
        if !urls.isEmpty { return urls.map(DropPayload.web) }
        return webURLs(in: pasteboard.string(forType: .string) ?? "").map(DropPayload.web)
    }

    static func payloads(from providers: [NSItemProvider]) async -> [DropPayload] {
        var out: [DropPayload] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider, UTType.fileURL), url.isFileURL {
                out.append(.file(filePath(url)))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadURL(provider, UTType.url).flatMap(webURL) {
                out.append(.web(url))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await loadText(provider) {
                out += webURLs(in: text).map(DropPayload.web)
            }
        }
        return out
    }

    private static func loadURL(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                done.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                done.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }

    /// Finder drags carry file reference URLs (`file:///.file/id=…`), which have no usable extension or path.
    static func filePath(_ url: URL) -> URL {
        (url as NSURL).filePathURL ?? url
    }

    static func webURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// Selected text counts when it's nothing but http(s) URLs, one per line.
    static func webURLs(in text: String) -> [URL] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let urls = lines.compactMap { URL(string: $0).flatMap(webURL) }
        return urls.count == lines.count ? urls : []
    }

    static func kind(of payload: DropPayload) -> ItemKind? {
        switch payload {
        case .web: return .web
        case .file(let url):
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
            if type.conforms(to: .html) { return .web }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .image) { return .image }
            return nil
        }
    }

    /// Copies and normalizes into the library and writes the thumbnail. Throws on anything unreadable.
    static func importItem(_ payload: DropPayload, id: String, root: URL) async throws -> Item {
        guard let kind = kind(of: payload) else { throw ImportError("unsupported") }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        let thumbURL = root.appendingPathComponent("thumbs/\(id).jpg")
        switch (payload, kind) {
        case (.file(let src), .image):
            let rel = "media/\(id).heic"
            let dst = root.appendingPathComponent(rel)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try normalizeImage(src: src, dst: dst)
                    try imageThumbnail(src: dst, dst: thumbURL)
                }.value
            } catch {
                try? fm.removeItem(at: dst)
                throw error
            }
            return Item(id: id, kind: .image, src: rel)
        case (.file(let src), .video):
            let rel = "media/\(id).mp4"
            let dst = root.appendingPathComponent(rel)
            do {
                try await normalizeVideo(src: src, dst: dst)
                try await videoThumbnail(src: dst, dst: thumbURL)
            } catch {
                try? fm.removeItem(at: dst)
                try? fm.removeItem(at: thumbURL)
                throw error
            }
            // Best effort, as for every loop: the tile stays still without one, and the model tries again.
            try? await videoLoop(src: dst, dst: root.appendingPathComponent("thumbs/\(id).heics"))
            return Item(id: id, kind: .video, src: rel)
        // A page's tile goes up at once, with a globe till its thumbnail lands: see `AppModel.thumbnailWeb`.
        case (.file(let src), .web):
            guard fm.isReadableFile(atPath: src.path) else { throw ImportError("unreadable html") }
            return Item(id: id, kind: .web, src: src.standardizedFileURL.path)
        case (.web(let url), _):
            return Item(id: id, kind: .web, src: url.absoluteString)
        }
    }

    // MARK: Video

    /// Keeps only the video track, which is what strips the audio, and bakes the track's rotation into upright
    /// frames. Rec.709 on the video composition tone-maps HDR (an iPhone's default HLG) to 8-bit SDR once, here,
    /// instead of on every frame of every call.
    static func normalizeVideo(src: URL, dst: URL) async throws {
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError("no video track")
        }
        let (natural, transform, fps, minDuration, range) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .timeRange)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let display = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        guard display.width > 0, display.height > 0 else { throw ImportError("empty video") }

        // A portrait clip fits a portrait box: same pixel budget, and the aspect-fill crop keeps more of it.
        let box = display.height > display.width ? CGSize(width: frame.height, height: frame.width) : frame
        let scale = min(1, box.width / display.width, box.height / display.height)
        let render = CGSize(width: evenFloor(display.width * scale), height: evenFloor(display.height * scale))

        // minFrameDuration is the shortest gap in the track: a variable-rate clip that ever beats 30 fps caps at
        // 30, and a 24 fps clip keeps its own cadence instead of gaining duplicated frames.
        var frameDuration = CMTime(value: 1, timescale: 30)
        if minDuration.isValid, minDuration.seconds > 0 {
            frameDuration = CMTimeMaximum(minDuration, frameDuration)
        } else if fps > 0, fps < 30 {
            frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        }

        let comp = AVMutableComposition()
        guard let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ImportError("no composition track") }
        try ct.insertTimeRange(range, of: track, at: .zero)
        ct.preferredTransform = transform

        // Rotation matrices often carry no translation, so the rotated rect is moved back to the origin first.
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
        layer.setTransform(transform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: render.width / abs(rect.width),
                                             y: render.height / abs(rect.height))), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instruction.layerInstructions = [layer]
        let video = AVMutableVideoComposition()
        video.renderSize = render
        video.frameDuration = frameDuration
        video.instructions = [instruction]
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw ImportError("no export session")
        }
        session.videoComposition = video
        try? FileManager.default.removeItem(at: dst)
        if #available(macOS 15, *) {
            try await session.export(to: dst, as: .mp4)
        } else {
            let box = ExportBox(session)
            session.outputURL = dst
            session.outputFileType = .mp4
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { done.resume() }
            }
            guard box.session.status == .completed else {
                throw ImportError("export failed: \(String(describing: box.session.error))")
            }
        }
    }

    /// AVAssetExportSession isn't Sendable. The session is only touched again after its completion has fired.
    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private static func evenFloor(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }

    static func videoThumbnail(src: URL, dst: URL) async throws {
        let asset = AVURLAsset(url: src)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 640)
        let image = try await firstFrame(generator)
        try writeThumbnail(image, to: dst)
    }

    private static func firstFrame(_ generator: AVAssetImageGenerator) async throws -> CGImage {
        if #available(macOS 15, *) { return try await generator.image(at: .zero).image }
        return try generator.copyCGImage(at: .zero, actualTime: nil)
    }

    /// The clips that ship in the app's Stock folder, in the order they're added: the calmest first.
    static let stock = ["aurora", "earth", "lava", "salmon", "canyon"]

    /// A clip that ships with FastBG. It's already in the library's format, so it's copied as it is, which APFS
    /// clones rather than duplicating, and thumbnailed like any video. Its loop comes after, like an older video's.
    static func importStock(_ src: URL, id: String, root: URL) async throws -> Item {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        let rel = "media/\(id).mp4"
        let dst = root.appendingPathComponent(rel), thumb = root.appendingPathComponent("thumbs/\(id).jpg")
        do {
            try fm.copyItem(at: src, to: dst)
            try await videoThumbnail(src: dst, dst: thumb)
        } catch {
            try? fm.removeItem(at: dst)
            try? fm.removeItem(at: thumb)
            throw error
        }
        return Item(id: id, kind: .video, src: rel)
    }

    /// A video or web tile's moving picture: 3 s at most, at 12 fps and 256x144, which covers the tile on a Retina
    /// screen. An animated HEIC, so ImageIO plays it a small frame at a time.
    static let loopRate = 12, loopLength = 3.0
    static let loopSize = CGSize(width: 256, height: 144)
    private static var loopFrames: Int { Int(loopLength) * loopRate }

    /// The video's first 3 s at most.
    static func videoLoop(src: URL, dst: URL) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        let count = max(1, min(loopFrames, Int(duration * Double(loopRate))))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Within half a frame of the loop's own rate, so frames come straight from decoding without seeking.
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(2 * loopRate))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = CGSize(width: 512, height: 512)
        let times = (0..<count).map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(loopRate)) }
        var frames: [CGImage] = []
        for await result in generator.images(for: times) {
            frames.append(try sRGB(result.image, width: Int(loopSize.width), height: Int(loopSize.height)))
        }
        guard frames.count == count else { throw ImportError("couldn't read the video's first frames") }
        try writeLoop(frames, to: dst)
    }

    /// 3 s of the page, snapshotted at the loop's own size as it runs. A page that doesn't move gets one frame, so
    /// it counts as done and isn't loaded again at the next launch.
    @MainActor
    static func webLoop(_ target: WebTarget, dst: URL) async throws {
        let page = WebPage(target: target)
        defer { page.close() }
        guard await page.load() else { throw ImportError("the page didn't load") }
        // Late images and fonts, and the page's own start-up animation.
        try? await Task.sleep(for: .milliseconds(500))
        var frames: [CGImage] = []
        let start = ContinuousClock.now
        for i in 0..<loopFrames {
            try? await Task.sleep(until: start + .seconds(Double(i) / Double(loopRate)))
            guard let shot = await page.frame(width: loopSize.width) else { break }
            frames.append(try sRGB(shot, width: Int(loopSize.width), height: Int(loopSize.height)))
        }
        guard let first = frames.first else { throw ImportError("the page never painted") }
        let bytes = { (image: CGImage) in image.dataProvider?.data as Data? }
        let moves = frames.dropFirst().contains { bytes($0) != bytes(first) }
        try writeLoop(moves ? frames : [first], to: dst)
    }

    private static func writeLoop(_ frames: [CGImage], to dst: URL) throws {
        let partial = dst.deletingLastPathComponent().appendingPathComponent("." + dst.lastPathComponent)
        guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, "public.heics" as CFString, frames.count,
                                                         nil) else { throw ImportError("no animated HEIC encoder") }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0],
        ] as CFDictionary)
        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.7,
            // ImageIO reads anything under 0.1 s back as 0.1, the old GIF floor, unless the unclamped time is there.
            kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: 1 / Double(loopRate),
                                              kCGImagePropertyHEICSUnclampedDelayTime: 1 / Double(loopRate)],
        ] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, options) }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: partial)
            throw ImportError("encoding \(dst.lastPathComponent) failed")
        }
        _ = try FileManager.default.replaceItemAt(dst, withItemAt: partial)
    }

    // MARK: Page copies

    /// The largest page that's copied, larger from places where files vanish on their own. Past it the page is used
    /// where it sits.
    static let pageLimit: Int64 = 50_000_000, transientPageLimit: Int64 = 500_000_000

    /// Where files vanish on their own: downloads, disk images and other volumes, scratch folders, Mail's attachments,
    /// and iCloud Drive, which evicts files to free space.
    static var transientPlaces: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Downloads"), URL(fileURLWithPath: "/Volumes"),
                URL(fileURLWithPath: "/private/var/folders"), URL(fileURLWithPath: "/private/tmp"),
                home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                home.appendingPathComponent("Library/Mobile Documents")]
    }

    /// Folders that hold a bit of everything, where a page's folder is no guide to what the page loads.
    static var shelves: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home] + ["Downloads", "Desktop", "Documents", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home.appendingPathComponent($0) }
    }

    /// Copies a dropped page, and what it loads, into `folder`, laid out as they were, so the page still works
    /// there once the original's gone. A page in a folder of its own takes the folder. One loose on a shelf like
    /// Downloads takes only the files it names. False when that's more than the limit allows.
    static func copyPage(_ page: URL, into folder: URL, shelves: [URL] = shelves,
                         transient: [URL] = transientPlaces) throws -> Bool {
        let base = page.deletingLastPathComponent().standardizedFileURL
        let inside = { (places: [URL]) in places.contains { page.path.hasPrefix($0.standardizedFileURL.path + "/") } }
        let limit = inside(transient) ? transientPageLimit : pageLimit
        let onShelf = shelves.contains { $0.standardizedFileURL.path == base.path }
        let files = (onShelf ? nil : folderFiles(base, limit: limit)) ?? referencedFiles(page, base: base)
        guard files.reduce(0, { $0 + $1.size }) <= limit else { return false }
        let fm = FileManager.default
        let partial = folder.deletingLastPathComponent().appendingPathComponent("." + folder.lastPathComponent)
        try? fm.removeItem(at: partial)
        do {
            for file in files {
                let dst = partial.appendingPathComponent(String(file.url.path.dropFirst(base.path.count + 1)))
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file.url, to: dst)
            }
            try? fm.removeItem(at: folder)
            try fm.moveItem(at: partial, to: folder)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return true
    }

    /// Every visible file under `base`, or nil past 2,000 files or `limit` bytes.
    private static func folderFiles(_ base: URL, limit: Int64) -> [(url: URL, size: Int64)]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        var files: [(url: URL, size: Int64)] = [], total: Int64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
            files.append((url.standardizedFileURL, Int64(values.fileSize ?? 0)))
            if files.count > 2_000 || total > limit { return nil }
        }
        return files
    }

    /// The page and the local files it names, found in its markup, stylesheets and scripts two levels deep. A
    /// script that builds a path at run time goes unseen, which a page in a folder of its own never depends on.
    private static func referencedFiles(_ page: URL, base: URL) -> [(url: URL, size: Int64)] {
        // Attribute values quoted either way or bare, as HTML allows. Each pattern captures in exactly one group.
        let patterns = [#"\b(?:src|href|poster|data)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#,
                        #"url\(\s*["']?([^"')]+?)["']?\s*\)"#, #"(?:import|from)\s*\(?\s*["']([^"']+)["']"#,
                        #"fetch\(\s*["']([^"']+)["']"#]
            .compactMap { try? NSRegularExpression(pattern: $0) }
        var found: [URL] = [page.standardizedFileURL], queue = [(page.standardizedFileURL, 0)]
        while let (file, depth) = queue.first {
            queue.removeFirst()
            guard depth < 2, ["html", "htm", "css", "js", "mjs", "svg"].contains(file.pathExtension.lowercased()),
                  let data = try? Data(contentsOf: file), data.count < 5_000_000 else { continue }
            let text = String(decoding: data, as: UTF8.self), range = NSRange(text.startIndex..., in: text)
            for match in patterns.flatMap({ $0.matches(in: text, range: range) }) {
                let group = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound }
                guard let group, let r = Range(match.range(at: group), in: text) else { continue }
                var ref = String(text[r]).trimmingCharacters(in: .whitespaces)
                ref = String(ref.prefix { $0 != "?" && $0 != "#" })
                guard !ref.isEmpty, !ref.contains(":"), !ref.hasPrefix("/"),
                      let decoded = ref.removingPercentEncoding else { continue }
                let url = file.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
                guard url.path.hasPrefix(base.path + "/"), !found.contains(url),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      found.count < 500 else { continue }
                found.append(url)
                queue.append((url, depth + 1))
            }
        }
        return found.map { ($0, Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)) }
    }

    // MARK: Stills

    /// Frame 0 (a GIF's first frame), upright, decoded straight to the smallest size that still covers 1080p,
    /// then redrawn as opaque 8-bit sRGB. The Metal texture loader skips colour management, loads grayscale as red
    /// and 16-bit files as 16-bit, and throws on any EXIF orientation but upright, so none of that may reach it.
    static func normalizeImage(src: URL, dst: URL) throws {
        let source = try openImage(src)
        guard let image = decodeCovering(source, frame) else { throw ImportError("undecodable image") }
        try writeImage(sRGB(image, width: image.width, height: image.height), to: dst, type: .heic, quality: 0.8)
    }

    static func imageThumbnail(src: URL, dst: URL) throws {
        guard let image = decodeCovering(try openImage(src), thumb) else { throw ImportError("undecodable image") }
        try writeThumbnail(image, to: dst)
    }

    private static func openImage(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(src) != nil, CGImageSourceGetCount(src) > 0, orientedSize(src) != nil
        else { throw ImportError("unreadable image") }
        return src
    }

    private static func orientedSize(_ source: CGImageSource) -> CGSize? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func coverSize(_ size: CGSize, _ target: CGSize) -> CGSize {
        let s = min(1, max(target.width / size.width, target.height / size.height))
        return CGSize(width: size.width * s, height: size.height * s)
    }

    /// The decoder's rounding of the short side can land a pixel under target, so one retry bumps the long side.
    private static func decodeCovering(_ source: CGImageSource, _ target: CGSize) -> CGImage? {
        guard let oriented = orientedSize(source) else { return nil }
        let want = coverSize(oriented, target)
        var maxPixel = Int(max(want.width, want.height).rounded(.up))
        for _ in 0..<2 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
            let covers = CGFloat(image.width) >= min(target.width, oriented.width)
                && CGFloat(image.height) >= min(target.height, oriented.height)
            if covers || maxPixel >= Int(max(oriented.width, oriented.height)) { return image }
            maxPixel += 1
        }
        return nil
    }

    /// Aspect-fills `image` into an opaque sRGB bitmap; transparency lands on black.
    private static func sRGB(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImportError("no bitmap context")
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = max(CGFloat(width) / iw, CGFloat(height) / ih)
        let dw = iw * s, dh = ih * s
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - dw) / 2, y: (CGFloat(height) - dh) / 2, width: dw, height: dh))
        guard let out = ctx.makeImage() else { throw ImportError("no bitmap image") }
        return out
    }

    static func writeThumbnail(_ image: CGImage, to url: URL) throws {
        try writeImage(sRGB(image, width: Int(thumb.width), height: Int(thumb.height)), to: url, type: .jpeg,
                       quality: 0.8)
    }

    private static func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImportError("no \(type.identifier) encoder")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImportError("encoding \(url.lastPathComponent) failed") }
    }

    // MARK: Web

    /// One snapshot of the page once it has loaded and painted.
    @MainActor
    static func webThumbnail(_ target: WebTarget, dst: URL) async {
        let page = WebPage(target: target)
        defer { page.close() }
        guard await page.load(), let image = await page.snapshot() else { return }
        try? writeThumbnail(image, to: dst)
    }
}
