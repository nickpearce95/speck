import Foundation
import Network
import Observation
import os

private let log = Logger(subsystem: "app.speck.menubar", category: "Discovery")

/// A speaker found on the local network. Spotify may not list it: an idle Chromecast or Sonos only
/// joins your account's device list once a Spotify app wakes it.
struct NetworkSpeaker: Identifiable, Hashable {
    enum Kind: Hashable { case cast, castGroup, sonos, connect }

    let name: String
    var kind: Kind
    var icon: String
    /// Google Cast service, used to open Spotify on a Chromecast.
    var castEndpoint: NWEndpoint?
    /// Spotify Connect ZeroConf address (http://ip:port/path), used to wake Sonos and others.
    var zeroconf: URL?

    var id: String { Self.key(name) }
    var canWake: Bool { castEndpoint != nil || zeroconf != nil }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when Spotify lists this speaker (directly, or through Music Assistant).
    func matches(_ d: Device) -> Bool {
        Self.key(d.name) == id || Self.key(d.baseName) == id
    }
}

/// Browses Bonjour for Chromecasts (`_googlecast._tcp`), Sonos (`_sonos._tcp`) and other Spotify
/// Connect speakers (`_spotify-connect._tcp`), merging entries that share a name.
@MainActor
@Observable
final class SpeakerDiscovery {
    private(set) var speakers: [NetworkSpeaker] = []

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var found: [NWEndpoint: NetworkSpeaker] = [:]
    @ObservationIgnored private var resolving: Set<NWEndpoint> = []

    func start() {
        guard browsers.isEmpty else { return }
        browse("_googlecast._tcp") { [weak self] in self?.addCast($0) }
        browse("_sonos._tcp") { [weak self] in self?.addSonos($0) }
        browse("_spotify-connect._tcp") { [weak self] in self?.addZeroconf($0) }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        found = [:]
        speakers = []
    }

    private func browse(_ type: String, onFound: @escaping @MainActor (NWBrowser.Result) -> Void) {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            MainActor.assumeIsolated {
                for change in changes {
                    switch change {
                    case .added(let r): onFound(r)
                    case .changed(_, let r, _): onFound(r)
                    case .removed(let r): self?.remove(r.endpoint)
                    default: break
                    }
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                log.error("Browsing \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    private func remove(_ endpoint: NWEndpoint) {
        if found.removeValue(forKey: endpoint) != nil { merge() }
    }

    private func add(_ speaker: NetworkSpeaker, for endpoint: NWEndpoint) {
        guard !browsers.isEmpty else { return }   // stopped while resolving
        log.info("Found \(speaker.name, privacy: .public)")
        found[endpoint] = speaker
        merge()
    }

    // MARK: Each kind of service

    /// Cast TXT records carry the friendly name (`fn`) and model (`md`).
    private func addCast(_ r: NWBrowser.Result) {
        guard case .bonjour(let txt) = r.metadata, let name = txt["fn"], !name.isEmpty else { return }
        let model = txt["md"] ?? ""
        let group = model.localizedCaseInsensitiveContains("group")
        let video = model == "Chromecast" || model.localizedCaseInsensitiveContains("tv")
            || model.localizedCaseInsensitiveContains("ultra")
        add(NetworkSpeaker(name: name, kind: group ? .castGroup : .cast,
                           icon: group ? "hifispeaker.2.fill" : video ? "tv" : "hifispeaker.fill",
                           castEndpoint: r.endpoint),
            for: r.endpoint)
    }

    /// Sonos names come from the speaker's description (its room name).
    private func addSonos(_ r: NWBrowser.Result) {
        resolve(r) { [weak self] host, _ in
            guard let name = try await LocalNet.sonosRoomName(host: host) else { return }
            self?.add(NetworkSpeaker(name: name, kind: .sonos, icon: "hifispeaker.fill"), for: r.endpoint)
        }
    }

    /// Spotify Connect speakers describe themselves through ZeroConf `getInfo`.
    private func addZeroconf(_ r: NWBrowser.Result) {
        guard case .bonjour(let txt) = r.metadata else { return }
        let path = txt["CPath"] ?? "/"
        resolve(r) { [weak self] host, port in
            guard let url = URL(string: "http://\(host):\(port)\(path.hasPrefix("/") ? path : "/" + path)") else { return }
            let info = try await Zeroconf.getInfo(url)
            let type = (info.deviceType ?? "").uppercased()
            // Computers and phones running Spotify advertise this too; they aren't speakers
            guard let name = info.remoteName, !name.isEmpty,
                  !["COMPUTER", "SMARTPHONE", "TABLET"].contains(type) else { return }
            let isSonos = (info.brandDisplayName ?? "").localizedCaseInsensitiveContains("sonos")
            self?.add(NetworkSpeaker(name: name, kind: isSonos ? .sonos : .connect,
                                     icon: type == "TV" ? "tv" : "hifispeaker.fill", zeroconf: url),
                      for: r.endpoint)
        }
    }

    /// Looks up the service's IPv4 address, then runs `body`. Failures are logged and ignored.
    private func resolve(_ r: NWBrowser.Result, _ body: @escaping @MainActor (String, UInt16) async throws -> Void) {
        guard !resolving.contains(r.endpoint) else { return }
        resolving.insert(r.endpoint)
        Task {
            defer { resolving.remove(r.endpoint) }
            do {
                let (host, port) = try await LocalNet.resolveIPv4(r.endpoint)
                try await body(host, port)
            } catch {
                log.error("Couldn't read \(r.endpoint.debugDescription, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// One entry per name. A Sonos speaker can show up as `_sonos` and `_spotify-connect`, and a
    /// stereo pair as two speakers with the same room name.
    private func merge() {
        var byKey: [String: NetworkSpeaker] = [:]
        for s in found.values {
            guard var merged = byKey[s.id] else { byKey[s.id] = s; continue }
            merged.castEndpoint = merged.castEndpoint ?? s.castEndpoint
            merged.zeroconf = merged.zeroconf ?? s.zeroconf
            if s.kind == .sonos { merged.kind = .sonos }
            byKey[s.id] = merged
        }
        speakers = byKey.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Local network helpers

enum LocalNetError: LocalizedError {
    case timedOut, unresolved, closed
    var errorDescription: String? {
        switch self {
        case .timedOut: return "the speaker didn't answer"
        case .unresolved: return "couldn't find the speaker's address"
        case .closed: return "the speaker closed the connection"
        }
    }
}

/// Lets a continuation be resumed exactly once from a callback that fires many times.
final class OnceFlag { var done = false }

extension NWConnection {
    /// Starts the connection and waits until it's ready, failing after `timeout` seconds.
    func waitUntilReady(timeout: Double) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { self?.cancel() }
        }
        defer { timer.cancel() }
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume()
                case .failed(let error), .waiting(let error):
                    once.done = true
                    cont.resume(throwing: error)
                case .cancelled:
                    once.done = true
                    cont.resume(throwing: LocalNetError.timedOut)
                default:
                    break
                }
            }
            start(queue: .main)
        }
    }
}

enum LocalNet {
    /// The IPv4 address and port behind a Bonjour service.
    static func resolveIPv4(_ endpoint: NWEndpoint) async throws -> (String, UInt16) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        defer { conn.cancel() }
        try await conn.waitUntilReady(timeout: 5)
        guard case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint,
              case .ipv4(let address) = host else { throw LocalNetError.unresolved }
        return (address.rawValue.map { String($0) }.joined(separator: "."), port.rawValue)
    }

    /// A Sonos speaker's room name, from its UPnP description.
    static func sonosRoomName(host: String) async throws -> String? {
        guard let url = URL(string: "http://\(host):1400/xml/device_description.xml") else { return nil }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
        let xml = String(decoding: data, as: UTF8.self)
        guard let open = xml.range(of: "<roomName>"),
              let close = xml.range(of: "</roomName>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Spotify Connect's local ZeroConf API, which speakers serve over plain HTTP.
enum Zeroconf {
    struct Info: Decodable {
        let remoteName: String?
        let deviceType: String?
        let deviceID: String?
        let clientID: String?
        let brandDisplayName: String?
    }

    static func getInfo(_ url: URL) async throws -> Info {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "action", value: "getInfo"), URLQueryItem(name: "version", value: "2.7.1")]
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: comps.url!, timeoutInterval: 5))
        return try JSONDecoder().decode(Info.self, from: data)
    }
}
