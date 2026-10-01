import Foundation
import Observation
import Security

/// User settings. Nothing here is secret: with PKCE the Spotify client ID is public.
@MainActor
@Observable
final class Prefs {
    static let redirectPort = 8898
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/callback" }

    private let defaults = UserDefaults.standard

    var clientId: String {
        didSet { defaults.set(clientId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotifyClientId") }
    }
    /// Play a silent audio stream while music is playing remotely so macOS routes media keys here.
    var claimMediaKeys: Bool {
        didSet { defaults.set(claimMediaKeys, forKey: "claimMediaKeys") }
    }

    /// Run the Web Playback SDK so this Mac appears as a Spotify device.
    var thisMacEnabled: Bool {
        didSet { defaults.set(thisMacEnabled, forKey: "thisMacEnabled") }
    }

    init() {
        LegacyMigration.run()
        thisMacEnabled = defaults.object(forKey: "thisMacEnabled") as? Bool ?? true
        clientId = defaults.string(forKey: "spotifyClientId") ?? ""
        claimMediaKeys = defaults.object(forKey: "claimMediaKeys") as? Bool ?? true
    }

    var hasClientId: Bool { !clientId.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Minimal wrapper around the login keychain (generic passwords).
enum Keychain {
    private static let service = "net.nickpearce.speck"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    @discardableResult
    static func write(_ data: Data, _ account: String) -> Bool {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Speck – Spotify login"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Moves settings and tokens out of the plain-text files used by earlier builds, then deletes them.
private enum LegacyMigration {
    static func run() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speck", isDirectory: true)
        let configURL = dir.appendingPathComponent("config.json")
        let tokensURL = dir.appendingPathComponent("tokens.json")
        let defaults = UserDefaults.standard

        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = obj["spotifyClientId"] as? String, !id.hasPrefix("PASTE"),
               defaults.string(forKey: "spotifyClientId") == nil {
                defaults.set(id, forKey: "spotifyClientId")
            }
            if let claim = obj["claimMediaKeys"] as? Bool, defaults.object(forKey: "claimMediaKeys") == nil {
                defaults.set(claim, forKey: "claimMediaKeys")
            }
        }
        // config.json also held the Home Assistant token, which is no longer used: always delete it.
        try? FileManager.default.removeItem(at: configURL)

        if let data = try? Data(contentsOf: tokensURL) {
            if Keychain.read(SpotifyAuth.keychainAccount) != nil || Keychain.write(data, SpotifyAuth.keychainAccount) {
                try? FileManager.default.removeItem(at: tokensURL)
            }
        }
        // Remove the folder once empty
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
