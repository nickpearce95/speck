import Foundation

// MARK: - Models

struct SpotifyImage: Decodable, Hashable { let url: String; let width: Int? }

struct Device: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String
    let type: String
    let is_active: Bool
    let volume_percent: Int?
    let supports_volume: Bool?
}

struct NamedRef: Decodable, Hashable { let name: String; let uri: String? }

struct PlayableItem: Decodable, Hashable {
    let name: String
    let uri: String
    let duration_ms: Int
    let artists: [NamedRef]?
    let album: Album?
    let show: Album?          // podcast episodes

    struct Album: Decodable, Hashable { let name: String; let images: [SpotifyImage]? }

    var subtitle: String {
        if let artists { return artists.map(\.name).joined(separator: ", ") }
        return show?.name ?? ""
    }
    var artworkURL: URL? {
        let imgs = album?.images ?? show?.images ?? []
        // Prefer ~300px art; fall back to whatever exists
        let pick = imgs.first { ($0.width ?? 0) <= 320 && ($0.width ?? 0) >= 200 } ?? imgs.first
        return pick.flatMap { URL(string: $0.url) }
    }
}

struct PlaybackState: Decodable {
    let device: Device?
    let is_playing: Bool
    let progress_ms: Int?
    let item: PlayableItem?
    let shuffle_state: Bool?
    let repeat_state: String?
}

struct SearchResult: Identifiable, Hashable {
    enum Kind: String { case track, album, artist, playlist }
    let kind: Kind
    let name: String
    let subtitle: String
    let uri: String
    let imageURL: URL?
    var id: String { uri }
}

// MARK: - API

enum SpotifyAPIError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .http(404, _): return "No active device — pick one under Devices"
        case .http(403, let m) where m.contains("PREMIUM"): return "Spotify Premium is required for playback control"
        case .http(let code, let m): return "Spotify error \(code): \(m)"
        }
    }
}

@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth
    private let base = URL(string: "https://api.spotify.com/v1")!

    init(auth: SpotifyAuth) { self.auth = auth }

    func playbackState() async throws -> PlaybackState? {
        let data = try await request("GET", "/me/player", query: ["additional_types": "episode"])
        return data.isEmpty ? nil : try JSONDecoder().decode(PlaybackState.self, from: data)
    }

    /// The account's subscription level, e.g. "premium" or "free".
    func product() async throws -> String? {
        struct R: Decodable { let product: String? }
        return try JSONDecoder().decode(R.self, from: try await request("GET", "/me")).product
    }

    func devices() async throws -> [Device] {
        struct R: Decodable { let devices: [Device] }
        return try JSONDecoder().decode(R.self, from: try await request("GET", "/me/player/devices")).devices
    }

    func resume(deviceId: String? = nil) async throws {
        try await request("PUT", "/me/player/play", query: deviceQuery(deviceId))
    }

    /// Plays a track (as a single URI) or a context (album/artist/playlist).
    func play(uri: String, deviceId: String? = nil) async throws {
        let body: [String: Any] = uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:")
            ? ["uris": [uri]] : ["context_uri": uri]
        try await request("PUT", "/me/player/play", query: deviceQuery(deviceId), json: body)
    }

    func pause() async throws { try await request("PUT", "/me/player/pause") }
    func next() async throws { try await request("POST", "/me/player/next") }
    func previous() async throws { try await request("POST", "/me/player/previous") }
    func seek(ms: Int) async throws { try await request("PUT", "/me/player/seek", query: ["position_ms": "\(ms)"]) }
    func volume(_ pct: Int) async throws { try await request("PUT", "/me/player/volume", query: ["volume_percent": "\(pct)"]) }
    func queue(uri: String) async throws { try await request("POST", "/me/player/queue", query: ["uri": uri]) }
    func shuffle(_ on: Bool) async throws { try await request("PUT", "/me/player/shuffle", query: ["state": on ? "true" : "false"]) }

    func transfer(to deviceId: String, play: Bool) async throws {
        try await request("PUT", "/me/player", json: ["device_ids": [deviceId], "play": play])
    }

    func search(_ q: String) async throws -> [SearchResult] {
        let data = try await request("GET", "/search", query: ["q": q, "type": "track,artist,album,playlist", "limit": "6"])

        struct Img: Decodable { let images: [SpotifyImage]? }
        struct Track: Decodable { let name: String; let uri: String; let artists: [NamedRef]; let album: Img }
        struct Artist: Decodable { let name: String; let uri: String; let images: [SpotifyImage]? }
        struct AlbumR: Decodable { let name: String; let uri: String; let artists: [NamedRef]; let images: [SpotifyImage]? }
        struct Owner: Decodable { let display_name: String? }
        struct Playlist: Decodable { let name: String; let uri: String; let owner: Owner?; let images: [SpotifyImage]? }
        struct Page<T: Decodable>: Decodable { let items: [T?] }  // Spotify sometimes returns null items
        struct R: Decodable {
            let tracks: Page<Track>?; let artists: Page<Artist>?
            let albums: Page<AlbumR>?; let playlists: Page<Playlist>?
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        func img(_ i: [SpotifyImage]?) -> URL? { (i?.last ?? i?.first).flatMap { URL(string: $0.url) } }

        var out: [SearchResult] = []
        out += (r.tracks?.items ?? []).compactMap { $0 }.map {
            .init(kind: .track, name: $0.name, subtitle: $0.artists.map(\.name).joined(separator: ", "),
                  uri: $0.uri, imageURL: img($0.album.images))
        }
        out += (r.artists?.items ?? []).compactMap { $0 }.prefix(3).map {
            .init(kind: .artist, name: $0.name, subtitle: "Artist", uri: $0.uri, imageURL: img($0.images))
        }
        out += (r.albums?.items ?? []).compactMap { $0 }.prefix(4).map {
            .init(kind: .album, name: $0.name, subtitle: $0.artists.map(\.name).joined(separator: ", "),
                  uri: $0.uri, imageURL: img($0.images))
        }
        out += (r.playlists?.items ?? []).compactMap { $0 }.prefix(4).map {
            .init(kind: .playlist, name: $0.name, subtitle: $0.owner?.display_name ?? "Playlist",
                  uri: $0.uri, imageURL: img($0.images))
        }
        return out
    }

    // MARK: Plumbing

    private func deviceQuery(_ id: String?) -> [String: String] { id.map { ["device_id": $0] } ?? [:] }

    @discardableResult
    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         json: [String: Any]? = nil) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" as-is, which servers read as a space
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if method != "GET" {
            req.httpBody = Data()  // Spotify rejects bodiless PUT/POST without Content-Length
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            struct E: Decodable { struct Inner: Decodable { let message: String; let reason: String? }; let error: Inner }
            let msg = (try? JSONDecoder().decode(E.self, from: data)).map { "\($0.error.reason ?? "") \($0.error.message)" }
                ?? String(decoding: data, as: UTF8.self)
            throw SpotifyAPIError.http(code, msg)
        }
        return data
    }
}

extension Device {
    private static let maSuffix = " | Music Assistant"

    /// Speaker name without Music Assistant's suffix.
    var baseName: String {
        name.hasSuffix(Self.maSuffix) ? String(name.dropLast(Self.maSuffix.count)) : name
    }

    /// "Kitchen | Music Assistant" → "Kitchen – Spotify Connect"
    var displayName: String {
        name.hasSuffix(Self.maSuffix) ? "\(baseName) – Spotify Connect" : name
    }
}
