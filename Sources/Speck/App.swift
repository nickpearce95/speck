import AppKit
import SwiftUI

@main
struct SpeckApp: App {
    @State private var model = PlayerModel()
    @State private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
                .environment(updater)
                .frame(width: 340)
                .onAppear { model.menuOpen = true }
                .onDisappear { model.menuOpen = false }
        } label: {
            Image(nsImage: model.isPlaying ? MenuBarIcon.playing : MenuBarIcon.idle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model).environment(updater)
        }
    }
}

struct MenuContent: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoggedIn {
                NowPlayingView().padding(14)
                Divider()
                SearchSection().padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                DevicesSection().padding(.horizontal, 14).padding(.vertical, 10)
            } else {
                LoginView().padding(16)
            }
            if let status = model.status {
                Divider()
                Text(status)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Footer().padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
}

// MARK: - Now playing

struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var model
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                AsyncImage(url: model.item?.artworkURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.item?.name ?? "Nothing playing").font(.headline).lineLimit(1)
                    Text(model.item?.subtitle ?? "Search below or pick a device")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let d = model.device {
                        Label(model.isLocalActive ? "This Mac" : d.displayName,
                              systemImage: model.isLocalActive ? "laptopcomputer" : icon(for: d.type))
                            .font(.caption).foregroundStyle(.green).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if let item = model.item {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let duration = Double(item.duration_ms) / 1000
                    let pos = scrubbing ?? model.progress(at: ctx.date)
                    VStack(spacing: 0) {
                        Slider(value: Binding(get: { pos }, set: { scrubbing = $0 }), in: 0...max(duration, 1)) { editing in
                            if !editing, let s = scrubbing { model.seek(to: s); scrubbing = nil }
                        }
                        .controlSize(.mini)
                        HStack {
                            Text(fmt(pos)); Spacer(); Text(fmt(duration))
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 28) {
                Button { model.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.body.weight(model.shuffle ? .bold : .regular))
                        .foregroundStyle(model.shuffle ? Color.green : Color.secondary)
                }
                .help(model.shuffle ? "Shuffle on" : "Shuffle off")
                Button { model.previous() } label: { Image(systemName: "backward.fill") }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34))
                }
                Button { model.next() } label: { Image(systemName: "forward.fill") }
                // Balances the shuffle button so play/pause stays centred
                Image(systemName: "shuffle").font(.body).hidden()
            }
            .buttonStyle(.plain)
            .font(.title3)

            if model.device?.supports_volume ?? false {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { model.volume }, set: { model.volume = $0 }), in: 0...100) { editing in
                        if !editing { model.setVolume(model.volume) }
                    }
                    .controlSize(.mini)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded(.down)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Search

struct SearchSection: View {
    @Environment(PlayerModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search songs, artists, albums, playlists", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = model.results.first { model.playResult(first) } }
                if model.isSearching { ProgressView().controlSize(.small) }
                else if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if !model.results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.results) { r in ResultRow(result: r) }
                    }
                }
                // Explicit height: a ScrollView in a menu bar window otherwise collapses to zero
                .frame(height: min(CGFloat(model.results.count) * 44, 300))
                Text("Click to play · ⌥-click to add tracks to queue")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .onAppear { focused = true }
    }
}

struct ResultRow: View {
    @Environment(PlayerModel.self) private var model
    let result: SearchResult
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: result.imageURL) { $0.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: 32, height: 32)
                .clipShape(result.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name).lineLimit(1)
                Text("\(result.kind.rawValue.capitalized) · \(result.subtitle)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(hover ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            let queue = NSEvent.modifierFlags.contains(.option) && result.kind == .track
            model.playResult(result, queueOnly: queue)
        }
    }
}

// MARK: - Devices

struct DevicesSection: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Devices").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.devices.isEmpty {
                Text("No devices found").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.sortedDevices, id: \.self) { d in
                let local = d.id != nil && d.id == model.localDeviceId
                DeviceRow(name: local ? "This Mac" : d.displayName,
                          icon: local ? "laptopcomputer" : icon(for: d.type),
                          active: d.is_active) { model.select(d) }
            }
            if model.isLoggedIn && !model.canStreamHere && model.prefs.thisMacEnabled {
                DeviceRow(name: "This Mac — log in again to enable", icon: "laptopcomputer", active: false) {
                    model.login()
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceRow: View {
    let name: String, icon: String, active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 18)
                Text(name).lineLimit(1)
                Spacer()
                if active { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
            .foregroundStyle(active ? .green : .primary)
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(hover ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

func icon(for type: String) -> String {
    switch type.lowercased() {
    case "computer": return "laptopcomputer"
    case "smartphone": return "iphone"
    case "tv", "castvideo": return "tv"
    case "speaker", "castaudio": return "hifispeaker.fill"
    default: return "hifispeaker"
    }
}

// MARK: - Login & footer

struct LoginView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speck").font(.title3.bold())
            if model.prefs.hasClientId {
                Text("Connect your Spotify account. You'll be sent to Spotify in your browser.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Log in with Spotify") { model.login() }.buttonStyle(.borderedProminent)
            } else {
                Text("Add your Spotify Client ID in Settings to get started.")
                    .font(.callout).foregroundStyle(.secondary)
                OpenSettingsButton(title: "Open Settings…")
            }
        }
    }
}

struct Footer: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        HStack {
            OpenSettingsButton(title: nil)
            Spacer()
            if case .ready(let version) = updater.state {
                Button("Restart to update to \(version)") { updater.relaunch() }
                    .buttonStyle(.plain).foregroundStyle(.green)
            }
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .font(.caption)
    }
}

/// Opens the Settings window and brings it to the front (menu bar apps aren't active by default).
struct OpenSettingsButton: View {
    let title: String?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            NSApp.activate()
            openSettings()
        } label: {
            if let title { Text(title) } else { Image(systemName: "gearshape") }
        }
        .buttonStyle(title == nil ? AnyButtonStyle(.plain) : AnyButtonStyle(.bordered))
        .keyboardShortcut(",")
    }
}

struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
