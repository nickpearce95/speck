import AppKit
import Network
import os
import SystemConfiguration
import WebKit

private let log = Logger(subsystem: "app.speck.menubar", category: "ThisMac")

/// Makes this Mac a Spotify Connect device by running Spotify's official Web Playback SDK in a
/// hidden WebKit view. WebKit provides the FairPlay DRM the SDK needs, the same way Safari does.
///
/// The web view is locked down: it loads only the SDK page, may only navigate to Spotify hosts,
/// and the token bridge only answers the top-level page Speck created.
///
/// The SDK doesn't recover by itself when its connection drops (sleep, Wi-Fi changes, a script that
/// fails to load), so this keeps it alive: a watchdog reloads it if it isn't ready in time, failures
/// retry with backoff, and it reconnects after the Mac wakes or the network comes back. Each step is
/// logged under the "app.speck.menubar" subsystem (Console.app) and reported for Settings.
@MainActor
final class LocalPlayer: NSObject {
    enum Event {
        case ready(deviceId: String)
        case notReady
        case stateChanged
        case error(String)   // worth showing the user
        case phase(String)   // what the player is doing, for Settings
    }

    /// Named after the Mac (System Settings → General → Sharing), so with Speck on several Macs
    /// each one can tell the others apart, and so can the Spotify apps.
    static let deviceName = "Speck on \((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac")"

    /// `deviceName` as a JavaScript string literal. JSON is valid JS; `<` is escaped so a computer
    /// name can't close the script tag.
    private static var deviceNameJS: String {
        let json = (try? JSONEncoder().encode(deviceName)).map { String(decoding: $0, as: UTF8.self) } ?? "\"Speck\""
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static let origin = URL(string: "https://speck.invalid/")!
    private static let allowedHostSuffixes = ["spotify.com", "scdn.co", "spotifycdn.com"]

    private let tokenProvider: () async throws -> String
    private let onEvent: (Event) -> Void
    private var webView: WKWebView?
    private var window: NSWindow?

    private var wanted = false            // between start() and stop()
    private var deviceId: String?         // set while the SDK reports ready
    private var failures = 0              // consecutive, for backoff
    private var networkUp = true
    private var watchdog: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()

    init(tokenProvider: @escaping () async throws -> String, onEvent: @escaping (Event) -> Void) {
        self.tokenProvider = tokenProvider
        self.onEvent = onEvent
        super.init()

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged(up: up) } }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    var isRunning: Bool { wanted }

    func start() {
        guard !wanted else { return }
        wanted = true
        failures = 0
        launch()
    }

    func stop() {
        wanted = false
        retryTask?.cancel()
        teardown()
        onEvent(.notReady)
        report("Off")
    }

    /// Reloads the player now, e.g. because Spotify stopped listing it or the user asked.
    func restart(_ reason: String) {
        guard wanted else { return }
        log.info("Restarting: \(reason, privacy: .public)")
        retryTask?.cancel()
        teardown()
        launch()
    }

    // MARK: Lifecycle

    private func launch() {
        guard wanted, webView == nil else { return }
        report("Loading Spotify's player")

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
        armWatchdog(30, "Spotify's player didn't start in time")
    }

    /// Removes the web view. Doesn't touch `wanted`, so callers decide whether to retry.
    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        if let wv = webView {
            // Tell Spotify the device is leaving; keep the view alive until the script has run
            wv.evaluateJavaScript("window.__speckPlayer && window.__speckPlayer.disconnect()") { _, _ in
                withExtendedLifetime(wv) {}
            }
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "speck")
            wv.navigationDelegate = nil
        }
        webView = nil
        window?.close()
        window = nil
        if deviceId != nil {
            deviceId = nil
            onEvent(.notReady)
        }
    }

    /// Tears down and tries again after a backoff: 2s, 4s, 8s… up to 2 minutes.
    private func fail(_ reason: String) {
        guard wanted else { return }
        failures += 1
        log.error("Failed (\(self.failures)): \(reason, privacy: .public)")
        teardown()
        retryTask?.cancel()
        guard networkUp else {
            report("Waiting for the network")
            return
        }
        let delay = min(pow(2, Double(failures)), 120)
        report("\(reason). Retrying in \(Int(delay))s")
        if failures >= 3 { onEvent(.error("This Mac can't connect to Spotify (\(reason)). Retrying…")) }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    private func armWatchdog(_ seconds: Double, _ reason: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fail(reason)
        }
    }

    private func report(_ phase: String) {
        log.info("\(phase, privacy: .public)")
        onEvent(.phase(phase))
    }

    // MARK: Sleep and network

    private func willSleep() {
        guard wanted else { return }
        log.info("Mac is going to sleep")
        retryTask?.cancel()
        teardown()
        report("Paused while the Mac sleeps")
    }

    private func didWake() {
        guard wanted else { return }
        log.info("Mac woke up")
        failures = 0
        retryTask?.cancel()
        teardown()
        // Give Wi-Fi a moment to rejoin; the watchdog and backoff cover a slow network
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    private func networkChanged(up: Bool) {
        let wasUp = networkUp
        networkUp = up
        guard wanted, up, !wasUp else { return }
        log.info("Network is back")
        failures = 0
        // If the SDK is still connected, leave it alone so music playing here isn't interrupted
        if deviceId == nil { restart("network came back") }
    }

    // MARK: Messages from the page

    fileprivate func handle(_ msg: WKScriptMessage) {
        // Only trust messages from the page we loaded, never from the SDK's iframes
        guard msg.frameInfo.isMainFrame, msg.frameInfo.securityOrigin.host == Self.origin.host,
              msg.webView === webView,
              let body = msg.body as? [String: Any], let type = body["type"] as? String else { return }

        switch type {
        case "token":
            Task {
                do {
                    let token = try await tokenProvider()
                    let json = try JSONSerialization.data(withJSONObject: [token])
                    _ = try await webView?.evaluateJavaScript("window.__speckToken(\(String(decoding: json, as: UTF8.self))[0])")
                } catch {
                    fail("couldn't get a Spotify login token")
                }
            }
        case "ready":
            guard let id = body["deviceId"] as? String else { return }
            deviceId = id
            failures = 0
            watchdog?.cancel()
            report("Connected")
            onEvent(.ready(deviceId: id))
        case "notReady":
            // The SDK may reconnect by itself; if it doesn't, reload it
            deviceId = nil
            onEvent(.notReady)
            report("Spotify dropped the connection; reconnecting")
            armWatchdog(20, "Spotify dropped the connection")
        case "state":
            onEvent(.stateChanged)
        case "error":
            let kind = body["kind"] as? String ?? "error"
            let message = body["message"] as? String ?? ""
            switch kind {
            case "account_error":
                // Retrying won't help
                retryTask?.cancel()
                teardown()
                report("Needs Spotify Premium")
                onEvent(.error("This Mac needs Spotify Premium"))
            case "playback_error":
                onEvent(.error("This Mac: \(message)"))
            case "script":
                // Often harmless noise from the SDK; the watchdog catches a player that stops working
                log.error("Script error: \(message, privacy: .public)")
            default:   // load, connect, initialization_error, authentication_error
                fail(message.isEmpty ? kind : message)
            }
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
        name: \(deviceNameJS),
        volume: 0.8,
        getOAuthToken: cb => { waiting.push(cb); post('token'); }
      });
      player.addListener('ready', ({device_id}) => post('ready', {deviceId: device_id}));
      player.addListener('not_ready', () => post('notReady'));
      player.addListener('player_state_changed', () => post('state'));
      for (const e of ['initialization_error', 'authentication_error', 'account_error', 'playback_error'])
        player.addListener(e, ({message}) => post('error', {kind: e, message}));
      player.connect().then(ok => { if (!ok) post('error', {kind: 'connect', message: "Spotify's player couldn't connect"}); });
      window.__speckPlayer = player;
    };
    </script><script src="https://sdk.scdn.co/spotify-player.js"
      onerror='post("error", {kind: "load", message: "Spotify player script failed to load"})'></script></body></html>
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
        guard webView === self.webView else { return }
        fail("the player process crashed")
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
