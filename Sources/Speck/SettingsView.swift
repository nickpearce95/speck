import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(PlayerModel.self) private var model
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
