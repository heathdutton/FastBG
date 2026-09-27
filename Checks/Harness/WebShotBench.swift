import AppKit
import CoreVideo
import WebKit

/// How much a WebKit snapshot costs per frame at 1920x1080, the capture path that shows no screen-sharing indicator.
@MainActor
enum WebShotBench {
    static func run() async -> Bool {
        let web = WebPage(target: .file(WebChecks.writePages().anim))
        defer { web.close() }
        guard await web.load() else { return expect(false, "webshot: page didn't load") }
        await sleep(0.5)
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        let n = 60
        var sizes = Set<String>()
        let cpu0 = PipelineChecks.cpuSeconds(), wall0 = CFAbsoluteTimeGetCurrent()
        var latency: [Double] = []
        for i in 0..<n {
            let due = wall0 + Double(i) / 30
            let wait = due - CFAbsoluteTimeGetCurrent()
            if wait > 0 { await sleep(wait) }
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let image = try? await web.webView.takeSnapshot(configuration: config),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let frame = Pixels.frame(cg)
            latency.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            sizes.insert("\(cg.width)x\(cg.height) -> \(CVPixelBufferGetWidth(frame))")
        }
        let cpu = (PipelineChecks.cpuSeconds() - cpu0) / Double(n) * 1000
        latency.sort()
        print(String(format: "      %.2f ms CPU per snapshot in this process, latency median %.1f ms, p95 %.1f ms",
                     cpu, latency[latency.count / 2], latency[latency.count * 95 / 100]))
        print("      sizes: \(sizes.sorted().joined(separator: ", "))")
        return expect(latency.count == n, "webshot: \(latency.count) of \(n) snapshots")
    }
}
