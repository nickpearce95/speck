import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    // Playback
    var item: PlayableItem?
    var isPlaying = false
    var device: Device?
    var volume: Double = 50
    var shuffle = false
    private var progressMs = 0
    private var progressAt = Date()

    // Devices & search
    var devices: [Device] = []
    var searchText = "" { didSet { scheduleSearch() } }
    var results: [SearchResult] = []
    var isSearching = false

    // UI
    var isLoggedIn = false
    var status: String?

    // Login
    enum LoginState { case idle, waiting, slow }   // slow: still waiting on the browser after 20s
    var loginState = LoginState.idle
    var loginError: String?
    var isPremium: Bool?   // nil until checked

    // This Mac (Web Playback SDK)
    var localDeviceId: String?
    var canStreamHere = false   // false until the user logs in with the streaming scope
    var menuOpen = false { didSet { if menuOpen { Task { await refreshAll() } } } }

    let prefs: Prefs
    private let auth: SpotifyAuth
    private let api: SpotifyAPI
    @ObservationIgnored private var nowPlaying: NowPlaying!
    @ObservationIgnored private var localPlayer: LocalPlayer!
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var pauseUntil = Date.distantPast  // skip polls right after a command

    init() {
        prefs = Prefs()
        auth = SpotifyAuth(clientId: prefs.clientId)
        api = SpotifyAPI(auth: auth)
        isLoggedIn = auth.isLoggedIn
        nowPlaying = NowPlaying(.init(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] s in self?.seek(to: s) }
        ))
        nowPlaying.claimMediaKeys = prefs.claimMediaKeys
        localPlayer = LocalPlayer(
            tokenProvider: { [auth] in try await auth.accessToken() },
            onEvent: { [weak self] in self?.handleLocal($0) }
        )
        canStreamHere = auth.canStream
        updateLocalPlayer()
        startPolling()
        if isLoggedIn { Task { await checkPremium() } }
    }

    /// First run, or logged out with no Client ID: the setup window should guide the user.
    var needsSetup: Bool { !prefs.hasClientId || !isLoggedIn }

    /// Devices with this Mac's player first.
    var sortedDevices: [Device] {
        devices.sorted { a, b in (a.id == localDeviceId ? 0 : 1) < (b.id == localDeviceId ? 0 : 1) }
    }

    /// True when playback is on this Mac's own Speck player.
    var isLocalActive: Bool { device?.id != nil && device?.id == localDeviceId }

    // MARK: This Mac

    func setThisMacEnabled(_ on: Bool) {
        prefs.thisMacEnabled = on
        updateLocalPlayer()
    }

    /// Starts or stops the local player to match login state and the user's preference.
    private func updateLocalPlayer() {
        if isLoggedIn && canStreamHere && prefs.thisMacEnabled {
            localPlayer.start()
        } else if localPlayer.isRunning {
            localPlayer.stop()
        }
    }

    private func handleLocal(_ event: LocalPlayer.Event) {
        switch event {
        case .ready(let id):
            localDeviceId = id
            Task { await refreshDevices() }
        case .notReady:
            localDeviceId = nil
        case .stateChanged:
            // The SDK reports local changes instantly; sync without waiting for the next poll
            if isLocalActive { Task { await refreshState() } }
        case .error(let message):
            status = message
        }
    }

    /// Current position, interpolated between polls.
    func progress(at now: Date) -> Double {
        let ms = Double(progressMs) + (isPlaying ? now.timeIntervalSince(progressAt) * 1000 : 0)
        return min(ms, Double(item?.duration_ms ?? 0)) / 1000
    }

    // MARK: Auth

    func login() {
        guard loginTask == nil else { return }
        loginError = nil
        loginState = .waiting
        status = "Waiting for browser login…"
        loginTask = Task {
            let slow = Task {
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled && loginState == .waiting { loginState = .slow }
            }
            defer { slow.cancel(); loginTask = nil; loginState = .idle }
            do {
                auth.clientId = prefs.clientId
                try await auth.login()
                isLoggedIn = true
                canStreamHere = auth.canStream
                updateLocalPlayer()
                status = nil
                await checkPremium()
                await refreshAll()
            } catch is CancellationError {
                status = nil
            } catch {
                loginError = error.localizedDescription
                status = loginError
            }
        }
    }

    /// Stops waiting for the browser.
    func cancelLogin() { loginTask?.cancel() }

    private func checkPremium() async {
        guard let product = try? await api.product() else { return }
        isPremium = product == "premium"
        if isPremium == false {
            status = "This Spotify account isn't Premium. Speck can show what's playing, but Spotify only lets Premium accounts control playback."
        }
    }

    func logout() {
        auth.logout()
        isLoggedIn = false
        canStreamHere = false
        isPremium = nil
        updateLocalPlayer()
        item = nil
        devices = []
        nowPlaying.update(item: nil, isPlaying: false, progressMs: 0, deviceName: nil)
    }

    func setClaimMediaKeys(_ on: Bool) {
        prefs.claimMediaKeys = on
        nowPlaying.claimMediaKeys = on
        pushNowPlaying()
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        setLocal(playing: true)
        run { [self] in try await api.resume(deviceId: device == nil ? fallbackDeviceId : nil) }
    }

    func pause() {
        setLocal(playing: false)
        run { [api] in try await api.pause() }
    }

    func toggleShuffle() {
        shuffle.toggle()
        let on = shuffle
        run(refreshAfter: nil) { [api] in try await api.shuffle(on) }
    }

    func next() { run(refreshAfter: 0.4) { [api] in try await api.next() } }
    func previous() { run(refreshAfter: 0.4) { [api] in try await api.previous() } }

    func seek(to seconds: Double) {
        progressMs = Int(seconds * 1000)
        progressAt = Date()
        pushNowPlaying()
        run { [api] in try await api.seek(ms: Int(seconds * 1000)) }
    }

    func setVolume(_ v: Double) {
        volume = v
        run(refreshAfter: nil) { [api] in try await api.volume(Int(v)) }
    }

    func playResult(_ r: SearchResult, queueOnly: Bool = false) {
        if queueOnly {
            run(refreshAfter: nil) { [api] in try await api.queue(uri: r.uri) }
            status = "Queued \(r.name)"
            return
        }
        let target = device?.id ?? fallbackDeviceId
        run(refreshAfter: 0.6) { [api] in try await api.play(uri: r.uri, deviceId: target) }
    }

    // MARK: Devices

    func select(_ d: Device) {
        guard let id = d.id else { return }
        device = d
        let keepPlaying = isPlaying || item == nil ? true : false
        run(refreshAfter: 1.0) { [api] in try await api.transfer(to: id, play: keepPlaying) }
    }

    private var fallbackDeviceId: String? {
        devices.first(where: \.is_active)?.id ?? devices.first?.id
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; isSearching = false; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let r = try await api.search(q)
                if !Task.isCancelled { results = r }
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }

    // MARK: Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isLoggedIn && Date() >= self.pauseUntil { await self.refreshState() }
                let interval: Double = (self.isPlaying || self.menuOpen) ? 2 : 15
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refreshAll() async {
        guard isLoggedIn else { return }
        async let d: () = refreshDevices()
        async let s: () = refreshState()
        _ = await (d, s)
    }

    private func refreshDevices() async {
        if let d = try? await api.devices() { devices = d }
    }

    private func refreshState() async {
        do {
            let s = try await api.playbackState()
            item = s?.item
            isPlaying = s?.is_playing ?? false
            device = s?.device
            if let v = s?.device?.volume_percent { volume = Double(v) }
            shuffle = s?.shuffle_state ?? false
            progressMs = s?.progress_ms ?? 0
            progressAt = Date()
            pushNowPlaying()
            if status?.hasPrefix("Spotify error") == true { status = nil }
        } catch AuthError.notLoggedIn {
            isLoggedIn = auth.isLoggedIn
        } catch {
            // Transient network errors are ignored; the next poll retries.
        }
    }

    private func setLocal(playing: Bool) {
        progressMs = Int(progress(at: Date()) * 1000)
        progressAt = Date()
        isPlaying = playing
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        // When this Mac is playing real audio there's no need for the silent stream
        nowPlaying.claimMediaKeys = prefs.claimMediaKeys && !isLocalActive
        nowPlaying.update(item: item, isPlaying: isPlaying, progressMs: progressMs, deviceName: isLocalActive ? "This Mac" : device?.displayName)
    }

    /// Runs a command, surfaces errors, then re-syncs state shortly after.
    private func run(refreshAfter delay: Double? = 0.3, _ op: @escaping () async throws -> Void) {
        pauseUntil = Date().addingTimeInterval(1.5)
        Task {
            do {
                try await op()
                if status?.hasPrefix("Queued") == false { status = nil }
            } catch {
                status = error.localizedDescription
                await refreshState()
                return
            }
            if let delay {
                try? await Task.sleep(for: .seconds(delay))
                await refreshAll()
            }
        }
    }
}
