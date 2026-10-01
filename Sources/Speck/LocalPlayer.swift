import AppKit
import WebKit

/// Makes this Mac a Spotify Connect device by running Spotify's official Web Playback SDK in a
/// hidden WebKit view. WebKit provides the FairPlay DRM the SDK needs, the same way Safari does.
///
/// The web view is locked down: it loads only the SDK page, may only navigate to Spotify hosts,
/// and the token bridge only answers the top-level page Speck created.
@MainActor
final class LocalPlayer: NSObject {
    enum Event {
        case ready(deviceId: String)
        case notReady
        case stateChanged
        case error(String)
    }

    static let deviceName = "Speck (This Mac)"
    private static let origin = URL(string: "https://speck.invalid/")!
    private static let allowedHostSuffixes = ["spotify.com", "scdn.co", "spotifycdn.com"]

    private let tokenProvider: () async throws -> String
    private let onEvent: (Event) -> Void
    private var webView: WKWebView?
    private var window: NSWindow?

    init(tokenProvider: @escaping () async throws -> String, onEvent: @escaping (Event) -> Void) {
        self.tokenProvider = tokenProvider
        self.onEvent = onEvent
    }

    var isRunning: Bool { webView != nil }

    func start() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // no cookies or storage kept on disk
        cfg.mediaTypesRequiringUserActionForPlayback = [] // allow playback started remotely
        // The view is never on screen, so WebKit would otherwise suspend its process within seconds
        cfg.preferences.inactiveSchedulingPolicy = .none
        cfg.userContentController.add(WeakHandler(self), name: "speck")

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: cfg)
        // Present as Safari so the SDK enables its Safari (FairPlay) code path
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        wv.navigationDelegate = self

        // Media playback needs the view to be in a window; keep it off-screen and invisible.
        let win = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.ignoresMouseEvents = true
        win.alphaValue = 0
        win.contentView = wv
        win.orderBack(nil)

        webView = wv
        window = win
        wv.loadHTMLString(Self.page, baseURL: Self.origin)
    }

    func stop() {
        webView?.evaluateJavaScript("window.__speckPlayer && window.__speckPlayer.disconnect()")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "speck")
        webView = nil
        window?.close()
        window = nil
        onEvent(.notReady)
    }

    fileprivate func handle(_ msg: WKScriptMessage) {
        // Only trust messages from the page we loaded, never from the SDK's iframes
        guard msg.frameInfo.isMainFrame, msg.frameInfo.securityOrigin.host == Self.origin.host,
              let body = msg.body as? [String: Any], let type = body["type"] as? String else { return }

        switch type {
        case "token":
            Task {
                guard let token = try? await tokenProvider(),
                      let json = try? JSONSerialization.data(withJSONObject: [token]),
                      let arg = String(data: json, encoding: .utf8) else { return }
                _ = try? await webView?.evaluateJavaScript("window.__speckToken(\(arg)[0])")
            }
        case "ready":
            if let id = body["deviceId"] as? String { onEvent(.ready(deviceId: id)) }
        case "notReady":
            onEvent(.notReady)
        case "state":
            onEvent(.stateChanged)
        case "error":
            let kind = body["kind"] as? String ?? "error"
            let message = body["message"] as? String ?? ""
            onEvent(.error(kind == "account_error" ? "This Mac needs Spotify Premium" : "This Mac: \(message)"))
        default:
            break
        }
    }

    private static let page = """
    <!doctype html><html><body><script>
    const post = (type, data) => window.webkit.messageHandlers.speck.postMessage(Object.assign({type}, data || {}));
    let waiting = [];
    window.__speckToken = t => { const w = waiting; waiting = []; w.forEach(cb => cb(t)); };
    window.onerror = m => post('error', {kind: 'script', message: String(m)});
    window.onSpotifyWebPlaybackSDKReady = () => {
      const player = new Spotify.Player({
        name: \(String(reflecting: deviceName)),
        volume: 0.8,
        getOAuthToken: cb => { waiting.push(cb); post('token'); }
      });
      player.addListener('ready', ({device_id}) => post('ready', {deviceId: device_id}));
      player.addListener('not_ready', () => post('notReady'));
      player.addListener('player_state_changed', () => post('state'));
      for (const e of ['initialization_error', 'authentication_error', 'account_error', 'playback_error'])
        player.addListener(e, ({message}) => post('error', {kind: e, message}));
      player.connect();
      window.__speckPlayer = player;
    };
    </script><script src="https://sdk.scdn.co/spotify-player.js"></script></body></html>
    """
}

extension LocalPlayer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url == Self.origin || url.scheme == "about" { return .allow }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return .cancel }
        let allowed = Self.allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        // Spotify's player iframe may load, but the top-level page must never change
        return allowed && !(action.targetFrame?.isMainFrame ?? true) ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEvent(.error("This Mac player crashed; restarting"))
        self.webView = nil
        window?.close()
        window = nil
        start()
    }
}

/// Avoids the retain cycle WKUserContentController would otherwise create.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: LocalPlayer?
    init(_ target: LocalPlayer) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.handle(message) }
    }
}
