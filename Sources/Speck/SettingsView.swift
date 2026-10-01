import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(Updater.self) private var updater
    @State private var clientId = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientId, prompt: Text("From developer.spotify.com"))
                    .onSubmit(saveClientId)
                    .onChange(of: clientId) { saveClientId() }

                LabeledContent("Redirect URI") {
                    HStack {
                        Text(Prefs.redirectURI).textSelection(.enabled).foregroundStyle(.secondary)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Prefs.redirectURI, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Account") {
                    if model.isLoggedIn {
                        HStack {
                            Label("Logged in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Log Out") { model.logout() }.controlSize(.small)
                        }
                    } else {
                        Button("Log in with Spotify") { model.login() }
                            .disabled(!model.prefs.hasClientId)
                    }
                }
            } header: {
                Text("Spotify")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create an app at developer.spotify.com with the redirect URI above, then paste its Client ID here. The Client ID isn't secret; your login is stored in the macOS Keychain.")
                    Link("Open Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Playback") {
                Toggle("Play on this Mac", isOn: Binding(
                    get: { model.prefs.thisMacEnabled },
                    set: { model.setThisMacEnabled($0) }
                ))
                Text(model.canStreamHere || !model.isLoggedIn
                     ? "Adds \"This Mac\" to the device list using Spotify's official web player engine."
                     : "Log out and in again to allow playback on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Route media keys to Speck", isOn: Binding(
                    get: { model.prefs.claimMediaKeys },
                    set: { model.setClaimMediaKeys($0) }
                ))
                Text("Plays silence on this Mac while music plays elsewhere, so the keyboard's play/pause keys reach Speck.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Updates") {
                @Bindable var updater = updater
                LabeledContent("Version", value: updater.currentVersion)
                if updater.isAvailable {
                    Toggle("Install updates automatically", isOn: $updater.automatic)
                    HStack {
                        Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if case .ready = updater.state {
                            Button("Restart Now") { updater.relaunch() }.controlSize(.small)
                        } else {
                            Button("Check Now") { updater.checkNow() }.controlSize(.small)
                                .disabled(updater.state == .checking || updateInstalling)
                        }
                    }
                } else {
                    Text("This copy was built locally, so it doesn't update itself. Releases from GitHub do.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let status = model.status {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            clientId = model.prefs.clientId
            NSApp.activate()
        }
    }

    private var updateInstalling: Bool {
        if case .installing = updater.state { return true } else { return false }
    }

    private var updateStatus: String {
        switch updater.state {
        case .idle: return updater.automatic ? "Checks GitHub once a day." : "Automatic updates are off."
        case .checking: return "Checking…"
        case .upToDate: return "Speck is up to date."
        case .installing(let v): return "Installing \(v)…"
        case .ready(let v): return "Speck \(v) is installed. Restart to use it."
        case .failed(let message): return message
        }
    }

    private func saveClientId() {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != model.prefs.clientId { model.prefs.clientId = trimmed }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
