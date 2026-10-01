# Speck

A tiny menu bar Spotify remote: search, play/pause/skip/seek/volume, switch devices
(Chromecasts included), and macOS media keys + Control Centre "Now Playing".
Other devices stream directly from Spotify; optionally the Mac itself is a device too.

## Install

Needs macOS 14 (Sonoma) or later on an Apple Silicon Mac (M1 or newer).

1. Open the [latest release](../../releases/latest) and download `Speck.zip` under **Assets**.
2. Double-click the zip to unzip it, then drag **Speck.app** into your **Applications** folder.
3. Open Speck. Because the app isn't notarized by Apple, macOS blocks it the first time:
   - Click **Done** (or **OK**) on the warning.
   - Open **System Settings → Privacy & Security**, scroll down to the message about
     Speck, and click **Open Anyway**. Confirm with your password or Touch ID.

   Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Speck.app`, then open it normally.
4. Speck has no Dock icon. Look for its icon in the menu bar, then follow [Setup](#setup).

Speck keeps itself up to date: once a day it checks for a new release, installs it in the
background and shows **Restart to update** in the menu. Turn this off, or check straight away,
in Settings → Updates. After an update, macOS asks once for Keychain access. Choose **Always Allow**.

## Build from source

```bash
./build.sh --install   # builds and copies to /Applications/Speck.app
```

Needs only the Xcode Command Line Tools (Swift 5.10+), macOS 14+.
To regenerate the app icon after editing `Icon/make-icon.swift`, run `Icon/make-icns.sh`.
Local builds don't update themselves.

## Releasing

Run **Actions → Release → Run workflow** and enter a version (e.g. `0.2`), or push a tag like
`v0.2`. GitHub builds the app and publishes `Speck.zip` with a signature that installed copies
check before updating.

One-time setup: run `swift scripts/update-key.swift | pbcopy` and paste the result as a
repository secret named `UPDATE_SIGNING_KEY` (Settings → Secrets and variables → Actions).
Keep a copy somewhere safe. Installed copies only accept updates signed with this key.

## Setup

1. Go to https://developer.spotify.com/dashboard → **Create app**
   - Redirect URI: `http://127.0.0.1:8898/callback` (exactly this)
   - APIs used: **Web API** and **Web Playback SDK**
2. Click the Speck icon in the menu bar → ⚙ (or ⌘,) to open **Settings**
3. Paste the app's **Client ID**, then click **Log in with Spotify**

Spotify Premium is required for playback control.

### Playing on this Mac
Speck can also be a speaker itself: it runs Spotify's official Web Playback SDK in a hidden,
locked-down WebKit view (FairPlay DRM, like Safari) and shows up as **This Mac**.
This needs **Web Playback SDK** ticked in the Spotify dashboard (see Setup).
Turn it off in Settings → Playback → Play on this Mac.

### Chromecasts
Spotify only lists an idle Chromecast after something has woken it. For speakers that
are always listed, use Music Assistant's **Spotify Connect** plugin (in Home Assistant):
add the plugin once and tick each speaker under *Connected players*. Speck shows these
as "Kitchen – Spotify Connect". For volume control to work, set the plugin's volume mode
to sync with the player (Soloist engine).

## Usage
- Click the menu bar icon. The search box is focused, so type and press ↩ to play the top hit.
- Click a result to play it, or ⌥-click a track to add it to the queue.
- Click a device to move playback to it.
- Media keys / AirPods / Control Centre control whatever device is playing.

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
- Updates are only installed when `Speck.zip` matches its Ed25519 signature (checked against a
  public key built into the app), and the app inside has the same bundle ID, a newer version and
  a valid code signature.
- The app is ad-hoc signed with the hardened runtime. Because an ad-hoc signature changes
  on every build, macOS asks for Keychain access once after each rebuild. Choose **Always Allow**.
