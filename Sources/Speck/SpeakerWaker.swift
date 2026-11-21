import CryptoKit
import Foundation
import Network
import os

private let log = Logger(subsystem: "app.speck.menubar", category: "Wake")

/// Wakes a speaker Spotify doesn't list yet by logging it in to your account, the way Spotify's own
/// apps do when they find a speaker on the network:
///
/// - Chromecasts: open the Spotify receiver over the Cast protocol and send it `addUser`.
/// - Sonos and other Spotify Connect speakers: ZeroConf `addUser` over local HTTP.
///
/// Both first try to swap your login for one tied to the speaker (Spotify's device-auth endpoint),
/// then fall back to your own login. Spotify may refuse logins from apps other than its own;
/// each step is logged under "app.speck.menubar" so that can be seen in Console.app.
@MainActor
final class SpeakerWaker {
    enum WakeError: LocalizedError {
        case refused(String)
        var errorDescription: String? {
            switch self { case .refused(let why): return why }
        }
    }

    private let token: () async throws -> String
    private let userId: () async throws -> String

    init(token: @escaping () async throws -> String, userId: @escaping () async throws -> String) {
        self.token = token
        self.userId = userId
    }

    func wake(_ speaker: NetworkSpeaker) async throws {
        log.info("Waking \(speaker.name, privacy: .public)")
        if let url = speaker.zeroconf {
            do {
                try await wakeZeroconf(url)
                return
            } catch let error where speaker.castEndpoint != nil {
                log.error("ZeroConf wake failed, trying Cast: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let endpoint = speaker.castEndpoint {
            try await wakeCast(endpoint, name: speaker.name, group: speaker.kind == .castGroup)
        }
    }

    // MARK: Login for the speaker

    /// Swaps our login for one issued to the speaker's own Spotify client, as Spotify's apps do.
    /// Returns nil if Spotify refuses, in which case our own login is tried instead.
    private func deviceToken(clientId: String, deviceId: String) async -> String? {
        guard let ours = try? await token(),
              let url = URL(string: "https://spclient.wg.spotify.com/device-auth/v1/refresh") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(ours)", forHTTPHeaderField: "Authorization")
        req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["clientId": clientId, "deviceId": deviceId])
        guard let response = try? await URLSession.shared.data(for: req) else {
            log.error("device-auth: no response")
            return nil
        }
        let (data, resp) = response
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        struct R: Decodable { let accessToken: String }
        guard (200..<300).contains(code), let r = try? JSONDecoder().decode(R.self, from: data) else {
            log.error("device-auth refused (HTTP \(code)): \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .public)")
            return nil
        }
        log.info("device-auth OK")
        return r.accessToken
    }

    // MARK: ZeroConf (Sonos and other Spotify Connect speakers)

    private func wakeZeroconf(_ url: URL) async throws {
        let info = try await Zeroconf.getInfo(url)
        var blob = try await token()
        if let c = info.clientID, let d = info.deviceID, let t = await deviceToken(clientId: c, deviceId: d) { blob = t }

        let user = try await userId()
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form([
            "action": "addUser", "userName": user, "blob": blob,
            "clientKey": "", "tokenType": "accesstoken",
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let status: Int?; let statusString: String?; let spotifyError: Int? }
        let r = try? JSONDecoder().decode(R.self, from: data)
        log.info("ZeroConf addUser: \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .public)")
        // 101 is ZeroConf's "OK"
        guard r?.status == 101 else {
            throw WakeError.refused("the speaker refused the login (\(r?.statusString ?? "no answer"))")
        }
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    // MARK: Google Cast (Chromecasts)

    private static let spotifyApp = "CC32E753"
    private static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    private static let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    private static let nsSpotify = "urn:x-cast:com.spotify.chromecast.secure.v1"

    private func wakeCast(_ endpoint: NWEndpoint, name: String, group: Bool) async throws {
        let channel = CastChannel(endpoint)
        let timer = Task {
            try? await Task.sleep(for: .seconds(25))
            if !Task.isCancelled { channel.close() }
        }
        defer { timer.cancel(); channel.close() }

        try await channel.open()
        try await channel.send(Self.nsConnection, to: "receiver-0", ["type": "CONNECT"])
        try await channel.send(Self.nsReceiver, to: "receiver-0",
                               ["type": "LAUNCH", "appId": Self.spotifyApp, "requestId": 1])

        // Wait for the Spotify receiver to be running and note its session's transport ID
        let transport: String = try await channel.wait { msg in
            guard msg.namespace == Self.nsReceiver else { return nil }
            if msg.payload["type"] as? String == "LAUNCH_ERROR" {
                throw WakeError.refused("Spotify didn't open on the speaker")
            }
            let apps = (msg.payload["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
            return apps.first(where: { $0["appId"] as? String == Self.spotifyApp })?["transportId"] as? String
        }
        log.info("Spotify receiver running")
        try await channel.send(Self.nsConnection, to: transport, ["type": "CONNECT"])

        let deviceId = Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let getInfo: [String: Any] = ["remoteName": name, "deviceID": deviceId, "deviceAPI_isGroup": group]
        try await channel.send(Self.nsSpotify, to: transport, ["type": "getInfo", "payload": getInfo])
        let clientId: String = try await channel.wait { msg in
            guard msg.namespace == Self.nsSpotify, msg.payload["type"] as? String == "getInfoResponse" else { return nil }
            return (msg.payload["payload"] as? [String: Any])?["clientID"] as? String ?? ""
        }

        var blob = try await token()
        if !clientId.isEmpty, let t = await deviceToken(clientId: clientId, deviceId: deviceId) { blob = t }
        let addUser: [String: Any] = ["blob": blob, "tokenType": "accesstoken"]
        try await channel.send(Self.nsSpotify, to: transport, ["type": "addUser", "payload": addUser])
        let _: Bool = try await channel.wait { msg in
            guard msg.namespace == Self.nsSpotify else { return nil }
            switch msg.payload["type"] as? String {
            case "addUserResponse":
                return true
            case "addUserError":
                let detail = (msg.payload["payload"] as? [String: Any]).map { "\($0)" } ?? ""
                log.error("addUserError: \(detail, privacy: .public)")
                throw WakeError.refused("the speaker refused the login")
            default:
                return nil
            }
        }
        log.info("Cast addUser OK")
    }
}

/// A minimal Google Cast v2 channel: TLS to port 8009, messages framed as a 4-byte big-endian
/// length followed by a `CastMessage` protobuf whose payload is JSON.
@MainActor
private final class CastChannel {
    struct Message {
        let source: String
        let namespace: String
        let payload: [String: Any]
    }

    private static let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    private let conn: NWConnection

    init(_ endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // Cast devices present self-signed certificates
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .main)
        conn = NWConnection(to: endpoint, using: NWParameters(tls: tls))
    }

    func open() async throws { try await conn.waitUntilReady(timeout: 8) }
    func close() { conn.cancel() }

    func send(_ namespace: String, to destination: String, _ payload: [String: Any]) async throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        var msg = Data()
        msg += Proto.varintField(1, 0)                 // protocol_version: CASTV2_1_0
        msg += Proto.stringField(2, "sender-0")        // source_id
        msg += Proto.stringField(3, destination)       // destination_id
        msg += Proto.stringField(4, namespace)         // namespace
        msg += Proto.varintField(5, 0)                 // payload_type: STRING
        msg += Proto.stringField(6, json)              // payload_utf8
        let frame = withUnsafeBytes(of: UInt32(msg.count).bigEndian) { Data($0) } + msg
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Reads messages, answering heartbeats, until `match` returns a value.
    func wait<T>(_ match: (Message) throws -> T?) async throws -> T {
        while true {
            let msg = try await receive()
            if msg.namespace == Self.nsHeartbeat, msg.payload["type"] as? String == "PING" {
                try await send(Self.nsHeartbeat, to: msg.source, ["type": "PONG"])
                continue
            }
            if let value = try match(msg) { return value }
        }
    }

    private func receive() async throws -> Message {
        let header = try await read(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length < 1 << 20 else { throw LocalNetError.closed }
        let fields = Proto.decode(try await read(length))
        let payload = fields[6].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return Message(source: fields[2].map { String(decoding: $0, as: UTF8.self) } ?? "",
                       namespace: fields[4].map { String(decoding: $0, as: UTF8.self) } ?? "",
                       payload: payload)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { cont.resume(throwing: error) }
                else if let data, data.count == count { cont.resume(returning: data) }
                else { cont.resume(throwing: LocalNetError.closed) }
            }
        }
    }
}

/// Just enough protobuf for `CastMessage`.
private enum Proto {
    static func varint(_ value: Int) -> Data {
        var v = UInt64(value)
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func varintField(_ number: Int, _ value: Int) -> Data { varint(number << 3) + varint(value) }

    static func stringField(_ number: Int, _ value: String) -> Data {
        let bytes = Data(value.utf8)
        return varint(number << 3 | 2) + varint(bytes.count) + bytes
    }

    /// Length-delimited fields by number; varint fields are skipped.
    static func decode(_ data: Data) -> [Int: Data] {
        let bytes = [UInt8](data)
        var fields: [Int: Data] = [:]
        var i = 0
        func readVarint() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count, shift < 64 {
                let b = bytes[i]; i += 1
                result |= Int(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < bytes.count, let key = readVarint() {
            switch key & 7 {
            case 0:
                guard readVarint() != nil else { return fields }
            case 2:
                guard let len = readVarint(), len >= 0, i + len <= bytes.count else { return fields }
                fields[key >> 3] = Data(bytes[i..<i + len])
                i += len
            default:
                return fields   // CastMessage uses no other wire types
            }
        }
        return fields
    }
}
