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
        thisMacEnabled = defaults.object(forKey: "thisMacEnabled") as? Bool ?? true
        clientId = defaults.string(forKey: "spotifyClientId") ?? ""
        claimMediaKeys = defaults.object(forKey: "claimMediaKeys") as? Bool ?? true
    }

    var hasClientId: Bool { !clientId.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Minimal wrapper around the login keychain (generic passwords).
enum Keychain {
    private static let service = "app.speck.menubar"

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
