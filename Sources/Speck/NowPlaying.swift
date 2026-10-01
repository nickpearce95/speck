import AVFoundation
import AppKit
import MediaPlayer

/// Bridges remote playback to macOS media keys and the Control Centre "Now Playing" widget.
@MainActor
final class NowPlaying {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (Double) -> Void
    }

    private let center = MPNowPlayingInfoCenter.default()
    private let silence = SilentAudio()
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    var claimMediaKeys = true

    init(_ h: Handlers) {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { _ in h.play(); return .success }
        rc.pauseCommand.addTarget { _ in h.pause(); return .success }
        rc.togglePlayPauseCommand.addTarget { _ in h.toggle(); return .success }
        rc.nextTrackCommand.addTarget { _ in h.next(); return .success }
        rc.previousTrackCommand.addTarget { _ in h.previous(); return .success }
        rc.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            h.seek(e.positionTime); return .success
        }
    }

    func update(item: PlayableItem?, isPlaying: Bool, progressMs: Int, deviceName: String?) {
        guard let item else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            silence.stop()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPMediaItemPropertyArtist: item.subtitle,
            MPMediaItemPropertyAlbumTitle: deviceName.map { "\(item.album?.name ?? item.show?.name ?? "") · \($0)" } ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(item.duration_ms) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(progressMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if item.artworkURL == artworkURL, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(item.artworkURL)
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused

        // macOS sends media keys to the app that most recently produced audio, so keep a
        // silent stream running while remote playback is active.
        if isPlaying && claimMediaKeys { silence.start() } else { silence.stop() }
    }

    private func loadArtwork(_ url: URL?) {
        artworkURL = url
        artwork = nil
        guard let url else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), url == artworkURL else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            artwork = art
            if var info = center.nowPlayingInfo {
                info[MPMediaItemPropertyArtwork] = art
                center.nowPlayingInfo = info
            }
        }
    }
}

/// Outputs digital silence so macOS treats this app as the active audio app.
final class SilentAudio {
    private let engine = AVAudioEngine()
    private lazy var source = AVAudioSourceNode { isSilence, _, _, abl -> OSStatus in
        for buf in UnsafeMutableAudioBufferListPointer(abl) {
            if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) }
        }
        isSilence.pointee = false  // must count as real output for media-key routing
        return noErr
    }
    private var attached = false

    func start() {
        guard !engine.isRunning else { return }
        if !attached {
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: nil)
            attached = true
        }
        try? engine.start()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.stop()
    }
}
