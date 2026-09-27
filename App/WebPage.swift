import AppKit
import WebKit

/// A web page rendering at 1920x1080 in a window nobody sees.
///
/// - WebKit stops painting a view it thinks is hidden, and a parked window counts as hidden. Only the private
///   `-[WKWebView _setWindowOcclusionDetectionEnabled:]` turns that off.
/// - The window must be ordered in, or the page reads as hidden anyway. It overlaps one real screen's corner by a
///   single point, at the lowest window level under the wallpaper, so it's tied to that screen's scale and never
///   shows.
/// - The page tells us when it has changed, through `onChange`, so a static page costs nothing once painted.
@MainActor
final class WebPage: NSObject, WKNavigationDelegate {
    static let pixelSize = CGSize(width: 1920, height: 1080)
    private static let occlusionSetter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")

    /// False once a macOS update drops the private setter. Web tiles then gray out instead of freezing on one frame.
    static var isSupported: Bool { WKWebView.instancesRespond(to: occlusionSetter) }

    let window: NSWindow
    let webView: WKWebView
    private let target: WebTarget
    private var loaded: CheckedContinuation<Bool, Never>?
    private var observers: [NSObjectProtocol] = []
    private var closed = false
    /// The page may look different now: it ran animation frames, has animations or video playing, or changed its
    /// DOM. At most every animation frame, so at most 30 times a second.
    var onChange: (() -> Void)?

    init(target: WebTarget) {
        self.target = target
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.userContentController.addUserScript(
            WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let relay = ChangeRelay()
        config.userContentController.add(relay, name: "fastbgChanged")
        webView = WKWebView(frame: .zero, configuration: config)
        window = ParkedWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        super.init()
        relay.page = self
        webView.navigationDelegate = self
        if Self.isSupported {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            // perform(_:with:) would pass an object pointer, which a BOOL parameter reads as YES.
            let set = unsafeBitCast(webView.method(for: Self.occlusionSetter), to: Setter.self)
            set(webView, Self.occlusionSetter, false)
        }
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.isExcludedFromWindowsMenu = true
        window.contentView = webView
        park()
        window.orderFrontRegardless()
        let center = NotificationCenter.default
        for (name, object) in [(NSApplication.didChangeScreenParametersNotification, nil as AnyObject?),
                               (NSWindow.didChangeBackingPropertiesNotification, window)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.park() }
            })
        }
    }

    /// Starts the navigation and waits for it to finish. False when it fails, the page can't be hosted, or it's
    /// still loading after `timeout`, since one hanging request would otherwise hold a switch or an import forever.
    func load(timeout: Duration = .seconds(15)) async -> Bool {
        guard Self.isSupported, !closed else { return false }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishLoad(false)
        }
        return await withCheckedContinuation { done in
            loaded = done
            switch target {
            // Straight from the site each time, never WebKit's disk cache, so the page is as live as a browser tab.
            case .url(let url): webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            case .file(let url): webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
    }

    /// The page as it's painted now, `width` points wide.
    func frame(width: CGFloat) async -> CGImage? {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(width))
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The painted page, a moment after load so late images and fonts make it in.
    func snapshot() async -> CGImage? {
        try? await Task.sleep(for: .milliseconds(500))
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Importer.thumb.width)
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func close() {
        closed = true
        onChange = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "fastbgChanged")
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        finishLoad(false)
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func finishLoad(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad(true) }

    /// A redirect or a script navigating during load cancels the first navigation, which isn't a failure.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if (error as NSError).code != NSURLErrorCancelled { finishLoad(false) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        if (error as NSError).code != NSURLErrorCancelled { finishLoad(false) }
    }

    /// A heavy page's content process can be killed under memory pressure, which leaves a blank view.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    /// Sized to 1920x1080 px at its screen's scale, with pageZoom undoing the scale, so the page lays out at
    /// 1920x1080 CSS px and renders exactly 1920x1080 pixels on a 1x or a 2x screen.
    private func park() {
        guard let (screen, frame) = Self.parkingSpot() else { return }
        window.setFrame(frame, display: false)
        webView.pageZoom = 1 / screen.backingScaleFactor
    }

    /// A corner qualifies when the window, grown outward from it, touches no other screen, so the window stays tied
    /// to the screen whose scale it was sized for.
    private static func parkingSpot() -> (NSScreen, NSRect)? {
        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            let size = NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
            let f = screen.frame
            let origins = [
                NSPoint(x: f.maxX - 1, y: f.maxY - 1),
                NSPoint(x: f.minX - size.width + 1, y: f.maxY - 1),
                NSPoint(x: f.maxX - 1, y: f.minY - size.height + 1),
                NSPoint(x: f.minX - size.width + 1, y: f.minY - size.height + 1),
            ]
            for origin in origins {
                let rect = NSRect(origin: origin, size: size)
                if NSScreen.screens.allSatisfy({ $0 == screen || !$0.frame.intersects(rect) }) {
                    return (screen, rect)
                }
            }
        }
        return nil
    }

    /// Runs in every frame of the page, iframes included.
    ///
    /// - Caps requestAnimationFrame at 30 callbacks a second. Between slots nothing native is pending: a timer
    ///   sleeps until just before the next 1/30 s slot, then one native rAF lands on that slot's vsync, so a
    ///   120 Hz display doesn't wake the page on every refresh.
    /// - Tells fastbg when the page may look different: after each batch of animation frames, on DOM changes and
    ///   loads, and on a 30 Hz pulse only while CSS animations, videos or animated GIFs are running.
    static let pageScript = """
    (() => {
      if (window.__fastbgPage) return;
      Object.defineProperty(window, '__fastbgPage', { value: true });
      const changed = () => { try { window.webkit.messageHandlers.fastbgChanged.postMessage(0); } catch (e) {} };

      const nativeRAF = window.requestAnimationFrame.bind(window);
      const INTERVAL = 1000 / 30;
      const EARLY = 6;  // ms the timer wakes before the slot, so the vsync after it is the slot's own
      const SLACK = 4;  // ms a vsync may land before the slot and still count, absorbing vsync jitter
      let pending = new Map();
      let nextId = 1, last = -Infinity, timer = 0, raf = 0;
      function deliver(ts) {
        raf = 0;
        if (ts - last < INTERVAL - SLACK) { schedule(); return; }
        last = ts;
        const due = pending;
        pending = new Map();
        for (const cb of due.values()) {
          try { cb(ts); } catch (e) { setTimeout(() => { throw e; }); }
        }
        changed();
      }
      function schedule() {
        if (timer || raf || pending.size === 0) return;
        const wait = last + INTERVAL - EARLY - performance.now();
        if (wait > 0) {
          timer = setTimeout(() => { timer = 0; if (pending.size) raf = nativeRAF(deliver); }, wait);
        } else {
          raf = nativeRAF(deliver);
        }
      }
      window.requestAnimationFrame = function requestAnimationFrame(cb) {
        const id = nextId++;
        pending.set(id, cb);
        schedule();
        return id;
      };
      window.cancelAnimationFrame = function cancelAnimationFrame(id) { pending.delete(id); };

      let pulse = 0;
      function moving() {
        if (document.getAnimations && document.getAnimations().some(a => a.playState === 'running')) return true;
        if ([...document.querySelectorAll('video')].some(v => !v.paused && !v.ended)) return true;
        return !!document.querySelector('img[src*=".gif" i]');
      }
      function beat() {
        if (moving()) { changed(); return; }
        clearInterval(pulse);
        pulse = 0;
      }
      function wake() {
        changed();
        if (!pulse) pulse = setInterval(beat, INTERVAL);
      }
      for (const type of ['animationstart', 'transitionstart', 'play', 'load']) {
        document.addEventListener(type, wake, true);
      }
      new MutationObserver(changed).observe(document, {
        subtree: true, childList: true, attributes: true, characterData: true
      });
      document.addEventListener('DOMContentLoaded', wake);
      if (document.fonts) document.fonts.ready.then(changed);
    })();
    """

    fileprivate func pageChanged() {
        onChange?()
    }
}

/// Script messages hold their handler strongly; this keeps the page out of that cycle.
private final class ChangeRelay: NSObject, WKScriptMessageHandler {
    weak var page: WebPage?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { page?.pageChanged() }
    }
}

/// AppKit pulls windows back onto a screen through constrainFrameRect, so it's a no-op here.
private final class ParkedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
