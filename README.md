# Speck

A tiny menu bar Spotify remote: search, play/pause/skip/seek/volume, switch devices
(Chromecasts included), and macOS media keys + Control Centre "Now Playing".
Other devices stream directly from Spotify; optionally the Mac itself is a device too.

## Build

```bash
./build.sh --install   # builds and copies to /Applications/Speck.app
```

Needs only the Xcode Command Line Tools (Swift 5.10+), macOS 14+.
To regenerate the app icon after editing `Icon/make-icon.swift`, run `Icon/make-icns.sh`.

## Setup

1. Go to https://developer.spotify.com/dashboard → **Create app**
   - Redirect URI: `http://127.0.0.1:8898/callback` (exactly this)
   - APIs used: **Web API**
2. Click the Speck icon in the menu bar → ⚙ (or ⌘,) to open **Settings**
3. Paste the app's **Client ID**, then click **Log in with Spotify**

Spotify Premium is required for playback control.

### Playing on this Mac
Speck can also be a speaker itself: it runs Spotify's official Web Playback SDK in a hidden,
locked-down WebKit view (FairPlay DRM, like Safari) and shows up as **This Mac**.
In the Spotify dashboard, tick **Web Playback SDK** under *APIs used*. Logins made before
this feature need redoing once (Speck shows "This Mac — log in again to enable").
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
  `UserDefaults` (`net.nickpearce.speck`); the Client ID isn't secret.
- Scopes are limited to reading and controlling playback, plus `streaming` (and the
  `user-read-email`/`user-read-private` scopes the SDK requires) for This Mac.
- The This Mac web view uses a non-persistent data store, can only load Spotify hosts in
  sub-frames, never navigates its top-level page, and its token bridge only answers the
  page Speck created.
- The app is ad-hoc signed with the hardened runtime. Because an ad-hoc signature changes
  on every build, macOS asks for Keychain access once after each rebuild. Choose **Always Allow**.
