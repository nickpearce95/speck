import AppKit
import CryptoKit
import Foundation
import Network

struct Tokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String?     // granted scopes; nil for logins made before this was recorded
}

enum AuthError: LocalizedError {
    case missingClientId, invalidClientId, invalidRedirectURI, notLoggedIn, timedOut, denied, portInUse
    case badCallback(String), tokenExchange(String)
    var errorDescription: String? {
        switch self {
        case .missingClientId: return "Add your Spotify Client ID in Settings"
        case .invalidClientId:
            return "Spotify doesn't recognise that Client ID. Copy it again from your app's Settings page on developer.spotify.com."
        case .invalidRedirectURI:
            return "Your Spotify app is missing the redirect URI. Add \(Prefs.redirectURI) under Redirect URIs in its settings, then Save."
        case .notLoggedIn: return "Not logged in"
        case .timedOut:
            return "Didn't hear back from Spotify. If the browser showed an error, check the Client ID and redirect URI, then try again."
        case .denied: return "You cancelled the login on Spotify. Try again when you're ready."
        case .portInUse:
            return "Another app is using port \(Prefs.redirectPort), which Speck needs for login. Quit it and try again."
        case .badCallback(let s): return "Login failed: \(s)"
        case .tokenExchange(let s): return "Spotify rejected the login: \(s)"
        }
    }
}

/// Spotify Authorization Code + PKCE flow with a loopback redirect (no client secret needed).
/// Tokens are kept in the login keychain.
@MainActor
final class SpotifyAuth {
    // streaming + user-read-email/private are required by the Web Playback SDK (This Mac)
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing "
        + "streaming user-read-email user-read-private"
    nonisolated static let keychainAccount = "spotify-tokens"

    var clientId: String
    private var tokens: Tokens?
    private var refreshTask: Task<Tokens, Error>?

    var isLoggedIn: Bool { tokens != nil }

    /// Whether the current login allows playing audio on this Mac (older logins need redoing).
    var canStream: Bool { tokens?.scope?.split(separator: " ").contains("streaming") ?? false }

    init(clientId: String) {
        self.clientId = clientId
        self.tokens = Keychain.read(Self.keychainAccount).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    func logout() {
        tokens = nil
        Keychain.delete(Self.keychainAccount)
    }

    /// Returns a valid access token, refreshing if it expires within a minute.
    func accessToken() async throws -> String {
        guard let t = tokens else { throw AuthError.notLoggedIn }
        if t.expiresAt.timeIntervalSinceNow > 60 { return t.accessToken }
        if let task = refreshTask { return try await task.value.accessToken }
        let task = Task { try await self.refresh(t.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    /// True when the text looks like a Spotify Client ID (32 hex characters).
    static func isPlausibleClientId(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count == 32 && t.allSatisfy(\.isHexDigit)
    }

    func login() async throws {
        let clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else { throw AuthError.missingClientId }

        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(32)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Prefs.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
        ]

        // Spotify shows a bad Client ID or redirect URI as an error page and never redirects back,
        // so ask it first and say what's wrong instead of leaving the user waiting.
        if let problem = await Self.preflight(comps.url!) { throw problem }
        try Task.checkCancellation()

        // The server only returns a callback whose state matches; forged requests are ignored.
        let server = LoopbackServer(port: UInt16(Prefs.redirectPort), expectedState: state)
        let items = try await withTaskCancellationHandler {
            try await server.waitForCallback {
                NSWorkspace.shared.open(comps.url!)
            }
        } onCancel: {
            Task { @MainActor in server.cancel() }
        }
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }

        if q("error") == "access_denied" { throw AuthError.denied }
        if let err = q("error") { throw AuthError.badCallback(err) }
        guard let code = q("code") else { throw AuthError.badCallback("no code") }

        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Prefs.redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ], previousRefresh: nil)
    }

    private func refresh(_ refreshToken: String) async throws -> Tokens {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ], previousRefresh: refreshToken)
    }

    @discardableResult
    private func tokenRequest(_ form: [String: String], previousRefresh: String?) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // Only a rejected grant means the login is dead; 429/5xx are transient and retried later.
            if previousRefresh != nil && (code == 400 || code == 401) { logout() }
            struct E: Decodable { let error: String?; let error_description: String? }
            let e = try? JSONDecoder().decode(E.self, from: data)
            throw AuthError.tokenExchange(e?.error_description ?? e?.error ?? "HTTP \(code)")
        }
        struct R: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let scope: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        let t = Tokens(accessToken: r.access_token,
                       refreshToken: r.refresh_token ?? previousRefresh ?? "",
                       expiresAt: Date().addingTimeInterval(r.expires_in),
                       scope: r.scope ?? tokens?.scope)
        tokens = t
        Keychain.write(try JSONEncoder().encode(t), Self.keychainAccount)
        return t
    }

    /// Loads the authorize URL without following redirects. A valid app redirects to Spotify's login;
    /// a bad one gets a 400 page naming the problem. Anything unexpected returns nil so login goes ahead.
    private static func preflight(_ url: URL) async -> AuthError? {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest) async -> URLRequest? { nil }
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req, delegate: NoRedirect()),
              (resp as? HTTPURLResponse)?.statusCode == 400 else { return nil }
        let body = String(decoding: data, as: UTF8.self).lowercased()
        if body.contains("invalid redirect uri") { return .invalidRedirectURI }
        if body.contains("invalid client") { return .invalidClientId }
        return nil
    }

    private static func randomString(_ n: Int) -> String {
        // randomElement() uses SystemRandomNumberGenerator, which is cryptographically secure on Apple platforms
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

/// Short-lived HTTP listener on 127.0.0.1 that waits for the OAuth redirect carrying the expected state.
final class LoopbackServer: @unchecked Sendable {
    private let port: UInt16
    private let expectedState: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[URLQueryItem], Error>?

    init(port: UInt16, expectedState: String) {
        self.port = port
        self.expectedState = expectedState
    }

    func waitForCallback(onReady: @escaping @MainActor () -> Void) async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                l.stateUpdateHandler = { state in
                    if case .ready = state { Task { @MainActor in onReady() } }
                    if case .failed(let e) = state {
                        if case .posix(.EADDRINUSE) = e { self.finish(.failure(AuthError.portInUse)) }
                        else { self.finish(.failure(e)) }
                    }
                }
                l.start(queue: .main)
                listener = l
                DispatchQueue.main.asyncAfter(deadline: .now() + 180) { self.finish(.failure(AuthError.timedOut)) }
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// Stops waiting (the user gave up on the browser login).
    func cancel() { finish(.failure(CancellationError())) }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []

            guard path.hasPrefix("/callback"),
                  items.first(where: { $0.name == "state" })?.value == self.expectedState else {
                Self.respond(conn, status: "400 Bad Request", message: "Ignored.")
                return  // keep listening for the genuine redirect
            }
            Self.respond(conn, status: "200 OK", message: "Speck is connected. You can close this tab.")
            self.finish(.success(items))
        }
    }

    private static func respond(_ conn: NWConnection, status: String, message: String) {
        let body = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'>"
            + "<h2>\(message)</h2></body></html>"
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(body)"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        listener?.cancel()
        listener = nil
        c.resume(with: result)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
