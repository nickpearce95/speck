import AppKit
import CryptoKit
import Foundation
import Observation

/// Updates Speck from the latest GitHub release.
///
/// Release builds carry the repo and the update public key in Info.plist (see build.sh and the
/// release workflow); local builds don't, so they never replace themselves. An update is only
/// installed if `Speck.zip` matches the Ed25519 signature in `Speck.zip.sig`, the app inside has
/// the same bundle ID, a higher version and a valid code signature. The new app replaces this one
/// on disk straight away and runs from the next launch; "Restart" just gets there sooner.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate, installing(String), ready(String), failed(String)
    }

    private(set) var state = State.idle
    var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "autoUpdate"); if automatic { checkIfDue() } }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let repo = Bundle.main.object(forInfoDictionaryKey: "SpeckUpdateRepo") as? String ?? ""
    private let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SpeckUpdatePublicKey") as? String)
        .flatMap { Data(base64Encoded: $0) }
        .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    private let defaults = UserDefaults.standard
    private static let interval: TimeInterval = 24 * 60 * 60

    /// False for local builds, which have no repo or key baked in.
    var isAvailable: Bool { !repo.isEmpty && publicKey != nil }

    init() {
        automatic = defaults.object(forKey: "autoUpdate") as? Bool ?? true
        guard isAvailable else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))   // let launch and login settle first
            while true {
                checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func checkIfDue() {
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if automatic, Date().timeIntervalSince(last) >= Self.interval { checkNow() }
    }

    func checkNow() {
        guard isAvailable, let publicKey else { return }
        switch state { case .checking, .installing, .ready: return; default: break }
        state = .checking
        Task {
            do {
                let release = try await Self.latestRelease(repo: repo)
                defaults.set(Date(), forKey: "lastUpdateCheck")
                guard Self.isNewer(release.version, than: currentVersion) else { state = .upToDate; return }
                state = .installing(release.version)
                try await Self.install(release, publicKey: publicKey, currentVersion: currentVersion)
                state = .ready(release.version)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Quits, then reopens the (already replaced) app once this process has exited.
    func relaunch() {
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Steps (off the main actor)

    struct Release {
        let version: String
        let zip: URL
        let signature: URL
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private nonisolated static func latestRelease(repo: String) async throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Response: Decodable { let tag_name: String; let assets: [Asset] }

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Couldn't check for updates") }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let zip = r.assets.first(where: { $0.name == "Speck.zip" })?.browser_download_url,
              let sig = r.assets.first(where: { $0.name == "Speck.zip.sig" })?.browser_download_url
        else { throw UpdateError("The latest release has no signed download") }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return Release(version: version, zip: zip, signature: sig)
    }

    /// Numeric dot-separated comparison: 0.10 > 0.9.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private nonisolated static func install(_ release: Release, publicKey: Curve25519.Signing.PublicKey,
                                            currentVersion: String) async throws {
        let current = Bundle.main.bundleURL
        guard !current.path.contains("/AppTranslocation/") else {
            throw UpdateError("Move Speck to your Applications folder to get updates")
        }
        let fm = FileManager.default
        // A scratch folder on the same volume as the app, so the final swap is a rename
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        defer { try? fm.removeItem(at: work) }

        let (zipFile, _) = try await URLSession.shared.download(from: release.zip)
        let (sigData, _) = try await URLSession.shared.data(from: release.signature)
        let zipData = try Data(contentsOf: zipFile)
        try? fm.removeItem(at: zipFile)
        guard let sig = Data(base64Encoded: String(decoding: sigData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              publicKey.isValidSignature(sig, for: zipData)
        else { throw UpdateError("The update's signature didn't match, so it wasn't installed") }

        let zip = work.appendingPathComponent("Speck.zip")
        try zipData.write(to: zip)
        try run("/usr/bin/ditto", "-x", "-k", zip.path, work.path)

        let new = work.appendingPathComponent("Speck.app")
        guard let info = Bundle(url: new)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              isNewer(version, than: currentVersion)
        else { throw UpdateError("The downloaded update isn't a newer Speck") }
        try run("/usr/bin/codesign", "--verify", "--strict", new.path)

        do {
            _ = try fm.replaceItemAt(current, withItemAt: new)
        } catch {
            throw UpdateError("Couldn't replace Speck in \(current.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
    }

    private nonisolated static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed while installing the update")
        }
    }
}
