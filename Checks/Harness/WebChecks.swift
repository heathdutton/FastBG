import CoreVideo
import Foundation
import ImageIO
import QuartzCore

@MainActor
enum WebChecks {
    static func run() async -> Bool {
        guard expect(WebPage.isSupported, "web: the occlusion toggle exists on this macOS") else { return false }
        let (anim, still) = writePages()
        var ok = true

        let (source, readyAfter) = await open(.file(anim))
        guard let source else { return expect(false, "web anim: never delivered a frame") }
        print(String(format: "      first frame %.2f s after the switch", readyAfter))
        await sleep(1.5)
        let (delivered, repeats) = await countFrames(source, seconds: 3)
        guard case .buffer(let frame)? = source.frame(at: 0) else { return expect(false, "web anim: no frame") }
        Pixels.save(frame, "web-anim.png")
        let reported = Double(Pixels.rgb(frame, 16, 16).x) / 4
        source.close()
        ok = expect(CVPixelBufferGetWidth(frame) == 1920 && CVPixelBufferGetHeight(frame) == 1080,
                    "web anim: capture is 1920x1080") && ok
        ok = expectRate(delivered >= 20 && delivered <= 31,
                        String(format: "web anim: capture delivers %.1f fps", delivered)) && ok
        ok = expectRate(repeats <= 1, "web anim: \(repeats) camera frames of 90 got the one before's snapshot") && ok
        ok = expect(reported >= 20 && reported <= 31.5,
                    String(format: "web anim: the page reports %.1f fps from its own rAF count", reported)) && ok

        let (quiet, _) = await open(.file(still))
        guard let quiet else { return expect(false, "web static: never delivered a frame") }
        await sleep(1)
        let (idle, _) = await countFrames(quiet, seconds: 4)
        guard case .buffer(let page)? = quiet.frame(at: 0) else { return expect(false, "web static: no frame") }
        Pixels.save(page, "web-static.png")
        let color = Pixels.rgb(page, 960, 900)
        quiet.close()
        ok = expect(idle < 0.5, String(format: "web static: %.2f fps once painted", idle)) && ok
        ok = expect(PipelineChecks.maxDiff(color, SIMD3(10, 200, 30)) <= 12,
                    "web static: the sibling css applied, background \(color)") && ok

        // Tiles: 3 s of a moving page, one frame of a still one.
        for (label, page, want) in [("anim", anim, 36), ("static", still, 1)] {
            let dst = Paths.temp("web-\(label)-loop.heics")
            let started = CACurrentMediaTime()
            do {
                try await Importer.webLoop(.file(page), dst: dst)
                let frames = CGImageSourceCreateWithURL(dst as CFURL, nil).map(CGImageSourceGetCount) ?? 0
                let bytes = (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                ok = expect(frames == want, String(format: "web %@: tile loop has %d frames, %d KB, made in %.1f s",
                                                   label, frames, bytes / 1024, CACurrentMediaTime() - started)) && ok
            } catch {
                ok = expect(false, "web \(label): tile loop failed, \(error)") && ok
            }
        }
        return ok
    }

    /// A canvas that counts its own rAF callbacks per second and paints the count into the top-left corner as
    /// red = fps * 4, and a static page with a sibling stylesheet.
    static func writePages() -> (anim: URL, still: URL) {
        let dir = Paths.temp("web")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let anim = dir.appendingPathComponent("anim.html")
        try? """
        <body style="margin:0"><canvas id=c width=1920 height=1080></canvas><script>
        const g = document.getElementById('c').getContext('2d');
        let n = 0, since = performance.now(), fps = 0;
        function f(t) {
          n++;
          if (t - since >= 1000) { fps = n * 1000 / (t - since); n = 0; since = t; }
          g.fillStyle = `hsl(${(t / 10) % 360}, 80%, 50%)`;
          g.fillRect(0, 0, 1920, 1080);
          g.fillStyle = `rgb(${Math.round(fps * 4)}, 0, 0)`;
          g.fillRect(0, 0, 32, 32);
          requestAnimationFrame(f);
        }
        requestAnimationFrame(f);
        </script>
        """.write(to: anim, atomically: true, encoding: .utf8)
        let still = dir.appendingPathComponent("static.html")
        try? "<link rel=stylesheet href=style.css><h1>fastbg</h1>".write(to: still, atomically: true, encoding: .utf8)
        try? "body { background: rgb(10, 200, 30); margin: 0 }".write(to: dir.appendingPathComponent("style.css"),
                                                                        atomically: true, encoding: .utf8)
        return (anim, still)
    }

    static func open(_ target: WebTarget) async -> (WebSource?, Double) {
        let ready = Flag()
        let start = CACurrentMediaTime()
        let source = WebSource(target: target) { ok in ready.set(ok) }
        for _ in 0..<300 where ready.value == nil { await sleep(0.03) }
        guard ready.value == true else {
            source.close()
            return (nil, 0)
        }
        return (source, CACurrentMediaTime() - start)
    }

    /// Pulls at 30 Hz, as the engine does with a 30 fps camera. Returns new frames a second and how many pulls got
    /// the same snapshot as the pull before.
    static func countFrames(_ source: BackgroundSource, seconds: Double) async -> (fps: Double, repeats: Int) {
        var changes = 0, repeats = 0
        var last: ObjectIdentifier?
        let start = CACurrentMediaTime()
        for i in 0..<Int(seconds * 30) {
            let due = start + Double(i) / 30
            if due > CACurrentMediaTime() { await sleep(due - CACurrentMediaTime()) }
            if case .buffer(let pixels)? = source.frame(at: due) {
                let id = ObjectIdentifier(pixels)
                if last != nil { id != last ? (changes += 1) : (repeats += 1) }
                last = id
            }
        }
        return (Double(changes) / seconds, repeats)
    }
}

/// The same animated page through ScreenCaptureKit and through snapshots: frames delivered, the page's own fps, and
/// the CPU each costs here and in replayd, the daemon behind ScreenCaptureKit.
@MainActor
enum WebCompare {
    static func run() async -> Bool {
        let (anim, still) = WebChecks.writePages()
        var ok = true
        for name in ["snapshots", "ScreenCaptureKit"] {
            for (page, label) in [(anim, "animated"), (still, "static")] {
                let ready = Flag()
                let done: @Sendable (Bool) -> Void = { ready.set($0) }
                let source: BackgroundSource = name == "snapshots"
                    ? WebSource(target: .file(page), ready: done) : SCKWebSource(target: .file(page), ready: done)
                for _ in 0..<300 where ready.value == nil { await sleep(0.03) }
                guard ready.value == true else {
                    source.close()
                    ok = expect(false, "\(name) \(label): never delivered a frame") && ok
                    continue
                }
                await sleep(1.5)
                let cpu0 = PipelineChecks.cpuSeconds(), daemon0 = cpuTime(of: "replayd")
                let fps = await WebChecks.countFrames(source, seconds: 4).fps
                let cpu = (PipelineChecks.cpuSeconds() - cpu0) / 4 * 100
                let daemon = (cpuTime(of: "replayd") - daemon0) / 4 * 100
                var reported = ""
                if label == "animated", case .buffer(let frame)? = source.frame(at: 0) {
                    reported = String(format: ", page reports %.1f fps", Double(Pixels.rgb(frame, 16, 16).x) / 4)
                }
                source.close()
                print(String(format: "      %@ %@: %.1f fps delivered%@, %.1f%% CPU here, %.1f%% in replayd",
                             name, label, fps, reported, cpu, daemon))
                await sleep(0.5)
            }
        }
        return ok
    }

    /// Cumulative CPU seconds of every process with this name.
    static func cpuTime(of name: String) -> Double {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "time=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        var total = 0.0
        for line in out.split(separator: "\n") where line.hasSuffix("/" + name) || line.hasSuffix(" " + name) {
            let parts = line.split(separator: " ", maxSplits: 1)[0].split(separator: ":").compactMap { Double($0) }
            total += parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
        }
        return total
    }
}
