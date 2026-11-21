# Speck

A tiny menu bar Spotify remote for macOS. Search and play, skip, seek and change volume,
and move playback between your speakers (Chromecasts included). Media keys and Control Centre's
"Now Playing" work too, and the Mac itself can be one of the speakers.

## Install

Needs macOS 14 (Sonoma) or later on an Apple Silicon Mac (M1 or newer), and Spotify Premium.

1. Open the [latest release](../../releases/latest) and download `Speck.zip` under **Assets**.
2. Double-click the zip to unzip it, then drag **Speck.app** into your **Applications** folder.
3. Open Speck. Because the app isn't notarized by Apple, macOS blocks it the first time:
   - Click **Done** (or **OK**) on the warning.
   - Open **System Settings → Privacy & Security**, scroll down to the message about
     Speck, and click **Open Anyway**. Confirm with your password or Touch ID.

   Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Speck.app`, then open it normally.
4. A setup window opens. Follow it to connect Speck to Spotify (see [Setup](#setup)).

Speck has no Dock icon. It lives in the menu bar at the top of your screen.

## Setup

The setup window takes about two minutes. It walks you through:

1. **Creating a Spotify app** on Spotify's developer site, with buttons to copy each value
   into the form.
2. **Pasting its Client ID** into Speck. If you've copied it, Speck fills it in for you.
3. **Logging in** to Spotify in your browser.

Each person creates their own Spotify app because Spotify limits apps that haven't been
approved to a small number of users. It's free, and your login stays between you and Spotify.

You can reopen the guide from the menu, or from Settings → Spotify.

<details>
<summary>Setting up by hand</summary>

1. Go to https://developer.spotify.com/dashboard/create
   - Redirect URI: `http://127.0.0.1:8898/callback` (exactly this)
   - APIs used: **Web API** and **Web Playback SDK**
2. Click the Speck icon in the menu bar → ⚙ (or ⌘,) to open **Settings**
3. Paste the app's **Client ID** (on the app's Settings page), then click **Log in with Spotify**

</details>

## Usage

- Click the menu bar icon. The search box is ready, so type and press ↩ to play the top hit.
- Click a result to play it, or ⌥-click a track to add it to the queue.
- Click a device to move playback to it. Speakers Spotify doesn't list yet appear greyed out under
  **On your network**. Click one to wake it (see [Speakers on your network](#speakers-on-your-network)).
- Media keys, AirPods and Control Centre control whatever device is playing.

Settings (⚙ in the menu, or ⌘,) also has:

- **Play on this Mac**: adds **This Mac** to your devices (see below).
- **Route media keys to Speck**: lets the keyboard's play/pause keys control music playing elsewhere.
- **Open at login**.
- **Updates**: see [Updates](#updates).

### Playing on this Mac
Speck can also be a speaker itself. It runs Spotify's official Web Playback SDK in a hidden,
locked-down web view (with the same DRM as Safari) and shows up as **This Mac**. This needs
**Web Playback SDK** ticked in your Spotify app, which the setup guide covers. Other Macs running
Speck, and the Spotify apps, see it as **Speck on** followed by the Mac's name (from System
Settings → General → Sharing).

Speck keeps This Mac connected. It reconnects after the Mac wakes from sleep or the network comes
back, reloads Spotify's player if it stops responding, and checks every minute that Spotify still
lists it. While it's reconnecting, the menu shows **This Mac — connecting…** (click it to retry
now). Settings → Playback shows what it's doing and has a **Reconnect** button.

### Speakers on your network
Spotify only lists an idle Chromecast or Sonos speaker after a Spotify app has woken it. Speck
looks for Chromecasts, Sonos and other Spotify Connect speakers on your network and lists the ones
Spotify doesn't know about yet under **On your network**. The first time, macOS asks whether
Speck may find devices on your local network. Click **Allow**. You can change this later in System
Settings → Privacy & Security → Local Network.

Click a speaker to wake it. Speck logs it in to your Spotify account the way Spotify's own apps
do, then moves playback to it once Spotify lists it. This is **experimental**: Spotify may refuse
logins that come from your own Spotify app rather than its official ones. If waking fails, play to
the speaker once from the Spotify app, and it will be selectable in Speck from then on.

For speakers that are always listed, use Music Assistant's **Spotify Connect** plugin (in Home
Assistant): add the plugin once and tick each speaker under *Connected players*. Speck shows these
as "Kitchen – Spotify Connect". For volume control to work, set the plugin's volume mode to sync
with the player (Soloist engine).

## Updates

Speck keeps itself up to date. Once a day it checks for a new release, installs it in the
background and shows **Restart to update** in the menu. In Settings → Updates you can turn this
off or click **Check Now**. After an update, macOS asks once for Keychain access. Choose
**Always Allow**.

Speck needs to be in your Applications folder to update itself.

## Troubleshooting

- **The browser shows `INVALID_CLIENT: Invalid redirect URI`.** Your Spotify app's redirect URI
  must be exactly `http://127.0.0.1:8898/callback`. Fix it in the app's settings on
  developer.spotify.com, click **Save**, then cancel the login in Speck and try again.
- **The browser shows `INVALID_CLIENT: Invalid client`.** The Client ID is wrong. Copy it again
  from your app's Settings page. Make sure it's the Client ID, not the Client secret.
- **"Another app is using port 8898".** Speck needs that port briefly while you log in. Quit
  whatever is using it and try again.
- **"Spotify Premium is required" or "This Spotify account isn't Premium".** Spotify only lets
  Premium accounts control playback from other apps.
- **"No active device".** Open Spotify on one of your devices, or pick one under **Devices**.
- **A Chromecast or Sonos speaker is missing.** Check Speck is allowed in System Settings →
  Privacy & Security → Local Network, then see [Speakers on your network](#speakers-on-your-network).
- **This Mac is missing or stuck on "connecting".** Look at Settings → Playback → Status, or open
  Console.app and search for `app.speck.menubar` to see each step. The same logs show why waking a
  speaker failed.

## Security notes

- Spotify login uses Authorization Code + PKCE (no client secret) with a one-shot listener
  on `127.0.0.1` that only accepts the redirect carrying the expected `state`.
- Tokens are stored in the login Keychain (item "Speck – Spotify login"). Settings live in
  `UserDefaults` (`app.speck.menubar`); the Client ID isn't secret.
- Scopes are limited to reading and controlling playback, plus `streaming` (and the
  `user-read-email`/`user-read-private` scopes the SDK requires) for This Mac.
- The This Mac web view uses a non-persistent data store, can only load Spotify hosts in
  sub-frames, never navigates its top-level page, and its token bridge only answers the
  page Speck created.
- Speaker discovery uses Bonjour on your local network only. Waking a speaker sends it a
  Spotify access token over your local network (to a Chromecast over TLS, to Spotify Connect
  speakers over plain HTTP, which is how Spotify's ZeroConf protocol works).
- Updates are only installed when `Speck.zip` matches its Ed25519 signature (checked against a
  public key built into the app), and the app inside has the same bundle ID, a newer version and
  a valid code signature.
- The app is ad-hoc signed with the hardened runtime. Because an ad-hoc signature changes
  on every build, macOS asks for Keychain access once after each update or rebuild.

## Development

### Build from source

```bash
./build.sh --install   # builds and copies to /Applications/Speck.app
```

Needs only the Xcode Command Line Tools (Swift 5.10+), macOS 14+. Local builds don't update
themselves. To regenerate the app icon after editing `Icon/make-icon.swift`, run
`Icon/make-icns.sh`. Every pull request is built on a GitHub Mac to check it compiles.

### Releasing

Run **Actions → Release → Run workflow** and enter the new version (e.g. `1.1`), or push a
tag like `v1.1`. GitHub builds the app and publishes `Speck.zip` with a signature that
installed copies check before updating.

One-time setup: run `swift scripts/update-key.swift | pbcopy` and paste the result as a
repository secret named `UPDATE_SIGNING_KEY` (Settings → Secrets and variables → Actions).
Keep a copy somewhere safe. Installed copies only accept updates signed with this key.

## License

[MIT](LICENSE). Speck isn't affiliated with or endorsed by Spotify. Using it means creating a
Spotify app, which is covered by Spotify's
[Developer Terms](https://developer.spotify.com/terms).
