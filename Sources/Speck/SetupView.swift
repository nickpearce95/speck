import AppKit
import SwiftUI

/// Hosts the setup guide in a plain AppKit window: SwiftUI on macOS 14 can't open a window at
/// launch on its own, and this lets the menu and Settings open it too.
@MainActor
enum SetupWindow {
    private static var window: NSWindow?

    static func show(_ model: PlayerModel) {
        // Rebuilt each time it's reopened, so it starts at the right step
        if window?.isVisible != true {
            let view = SetupView(close: { window?.close() }).environment(model)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Set Up Speck"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Step-by-step guide for first-time users: create a Spotify app, paste its Client ID, log in.
struct SetupView: View {
    @Environment(PlayerModel.self) private var model
    let close: () -> Void

    @State private var step = 0
    @State private var clientId = ""
    @State private var pastedFromClipboard = false

    private static let steps = ["Welcome", "Create app", "Client ID", "Log in"]
    private static let createAppURL = URL(string: "https://developer.spotify.com/dashboard/create")!
    private static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!

    private var clientIdLooksRight: Bool { SpotifyAuth.isPlausibleClientId(clientId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIndicator(steps: Self.steps, current: step)
                .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            Group {
                switch step {
                case 0: welcome
                case 1: createApp
                case 2: enterClientId
                default: logIn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 540, height: 500)
        .onAppear {
            clientId = model.prefs.clientId
            // Coming back with a Client ID already saved: go straight to logging in
            if step == 0 && model.prefs.hasClientId { step = 3 }
        }
        .onChange(of: step) { if step == 2 { pasteFromClipboardIfUseful() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if step == 2 { pasteFromClipboardIfUseful() }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Speck").font(.title2.bold())
            Text("Speck controls Spotify from your menu bar. Setting it up takes about two minutes.")
            Bullet(icon: "star.fill",
                   text: "You need **Spotify Premium**. Spotify only lets Premium accounts control playback from other apps.")
            Bullet(icon: "hammer.fill",
                   text: "You'll create your own free **Spotify developer app**. It's how Spotify lets small apps like Speck connect, and it keeps your login between you and Spotify.")
            Bullet(icon: "lock.fill",
                   text: "Speck never sees your Spotify password. You log in on Spotify's own website.")
        }
    }

    private var createApp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a Spotify app").font(.title2.bold())
            NumberedStep(1) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open Spotify's developer site and log in with your usual Spotify account. If it asks, accept the developer terms.")
                    Link(destination: Self.createAppURL) { Label("Open the Create App page", systemImage: "arrow.up.right.square") }
                }
            }
            NumberedStep(2) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fill in the form. Copy each value from here:")
                    CopyRow(label: "App name", value: "Speck")
                    CopyRow(label: "App description", value: "Menu bar remote for Spotify")
                    CopyRow(label: "Redirect URIs", value: Prefs.redirectURI)
                    Text("Paste the redirect URI exactly as shown, then click **Add**.").font(.caption).foregroundStyle(.secondary)
                    Text("Under **Which API/SDKs are you planning to use?**, tick **Web API** and **Web Playback SDK**.")
                }
            }
            NumberedStep(3) { Text("Tick the terms checkbox and click **Save**.") }
        }
    }

    private var enterClientId: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy your Client ID").font(.title2.bold())
            Text("On your new app's page, click **Settings**. The **Client ID** is at the top, under Basic Information. Copy it and paste it here.")
            HStack {
                TextField("Client ID", text: $clientId, prompt: Text("32 letters and numbers"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onChange(of: clientId) { pastedFromClipboard = false }
                Button("Paste") {
                    clientId = (NSPasteboard.general.string(forType: .string) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if clientIdLooksRight {
                Label(pastedFromClipboard ? "Pasted from your clipboard. Looks right." : "Looks right.",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if !clientId.isEmpty {
                Label("That doesn't look like a Client ID. It should be 32 letters and numbers. Make sure you copied the Client ID, not the Client secret.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Link("Can't find it? Open your Spotify apps", destination: Self.dashboardURL).font(.callout)
        }
    }

    @ViewBuilder private var logIn: some View {
        if model.isLoggedIn {
            VStack(alignment: .leading, spacing: 14) {
                Label("You're all set", systemImage: "checkmark.circle.fill")
                    .font(.title2.bold()).foregroundStyle(.green)
                if model.isPremium == false {
                    Label("This Spotify account isn't Premium. Speck can show what's playing, but Spotify only lets Premium accounts control playback.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Bullet(icon: "menubar.arrow.up.rectangle",
                       text: "Click the **Speck icon** in the menu bar at the top of your screen to open it.")
                Bullet(icon: "magnifyingglass", text: "Type to search, then press **Return** to play the top result.")
                Bullet(icon: "hifispeaker.fill", text: "Pick a speaker under **Devices** to move the music there.")
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Log in to Spotify").font(.title2.bold())
                Text("Speck opens Spotify in your browser. Log in, click **Agree**, then come back here.")
                switch model.loginState {
                case .idle:
                    Button("Log in with Spotify") { model.login() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                case .waiting, .slow:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to finish in the browser…")
                        Button("Cancel") { model.cancelLogin() }
                    }
                }
                if model.loginState == .slow {
                    Text("Seeing an error page in the browser? Check that your Spotify app's redirect URI is exactly **\(Prefs.redirectURI)**, then cancel and try again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.loginError, model.loginState == .idle {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 && !model.isLoggedIn {
                Button("Back") { step -= 1 }
                    .disabled(model.loginState != .idle)
            }
            Spacer()
            switch step {
            case 0:
                Button("Get Started") { step = 1 }.keyboardShortcut(.defaultAction)
            case 1:
                Button("I've Created the App") { step = 2 }.keyboardShortcut(.defaultAction)
            case 2:
                Button("Next") {
                    model.prefs.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
                    step = 3
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!clientIdLooksRight)
            default:
                if model.isLoggedIn {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Fills the Client ID from the clipboard when the user comes back from the browser with it copied.
    private func pasteFromClipboardIfUseful() {
        guard !clientIdLooksRight,
              let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              SpotifyAuth.isPlausibleClientId(s) else { return }
        clientId = s
        pastedFromClipboard = true
    }
}

// MARK: - Pieces

private struct StepIndicator: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        if i < current {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(i == current ? .white : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(steps[i]).font(.callout.weight(i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
                if i < steps.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                }
            }
        }
    }
}

private struct Bullet: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NumberedStep<Content: View>: View {
    let number: Int
    let content: Content

    init(_ number: Int, @ViewBuilder content: () -> Content) {
        self.number = number
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).").font(.body.monospacedDigit().bold()).frame(width: 18, alignment: .trailing)
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CopyRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
    }
}
