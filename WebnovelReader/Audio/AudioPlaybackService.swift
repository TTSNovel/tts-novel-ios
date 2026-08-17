import AVFoundation
import MediaPlayer

/// Native counterpart to reader.js's single reused <audio> element +
/// setupMediaSession()/updateMediaSessionMetadata() (site_assets/
/// reader.js:653-674) — AVAudioPlayer plays one fetched TTS clip (WAV
/// bytes from /api/tts) at a time, same "fetch, play to completion, move
/// on" shape as the web reader's per-sentence audio. MPRemoteCommandCenter
/// + MPNowPlayingInfoCenter are the lock-screen/Control-Center equivalent
/// of the web MediaSession API.
@MainActor
final class AudioPlaybackService: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?

    var onFinishedPlaying: (() -> Void)?
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    /// Lock-screen / Control-Center play & pause commands — routed out to
    /// ReaderPlaybackController instead of calling resume()/pause() below
    /// directly, same reasoning as onNextChapter/onPreviousChapter: only
    /// the controller's own resume()/pause() re-arm the sleep timer
    /// (scheduleAutoStop() / clearAutoStopState()) and keep its `isPlaying`
    /// state in sync.
    var onPlayCommand: (() -> Void)?
    var onPauseCommand: (() -> Void)?
    /// AVAudioSession.interruptionNotification .began/.ended (phone calls,
    /// alarms, Maps/Siri voice prompts stealing the audio session
    /// temporarily) — routed out to ReaderPlaybackController the same way
    /// as the lock-screen commands above, so a transient interruption goes
    /// through remotePause()/remotePlay() instead of leaving `isPlaying`
    /// stuck on whatever it was before the interruption hit and playback
    /// permanently paused once the other app's audio ends.
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?

    override init() {
        super.init()
        configureRemoteCommands()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    // `Notification`/its userInfo dictionary aren't Sendable, so the raw
    // UInt values are pulled out here — still nonisolated, off the main
    // actor — before hopping over, rather than sending the notification
    // itself across the actor boundary.
    @objc nonisolated private func handleInterruptionNotification(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt
        else { return }
        let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor in
            self.handleInterruption(rawType: rawType, rawOptions: rawOptions)
        }
    }

    private func handleInterruption(rawType: UInt, rawOptions: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            guard AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) else { return }
            // The interrupting app may have deactivated the shared session;
            // reactivate it before handing back to onInterruptionEnded's
            // resume() so `player.play()` actually has audio hardware to
            // play into.
            try? AVAudioSession.sharedInstance().setActive(true)
            onInterruptionEnded?()
        @unknown default:
            break
        }
    }

    func play(data: Data) throws {
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        player = newPlayer
        newPlayer.play()
        isPlaying = true
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func pause() {
        player?.pause()
        isPlaying = false
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    func resume() {
        player?.play()
        isPlaying = true
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func updateNowPlaying(bookTitle: String, chapterTitle: String) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = chapterTitle
        info[MPMediaItemPropertyArtist] = bookTitle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Drives the lock-screen/Control-Center progress bar and elapsed-time
    /// label. `elapsed`/`duration` are ReaderPlaybackController's
    /// character-count-based estimate for the whole chapter (there's no real
    /// per-chapter audio duration — sentences are synthesized and played one
    /// clip at a time) — setting these plus a non-zero rate is enough for
    /// iOS to interpolate the displayed time on its own going forward; no
    /// per-second updates needed from here.
    func updateNowPlayingProgress(elapsed: TimeInterval, duration: TimeInterval, rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.onPlayCommand?()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onPauseCommand?()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextChapter?()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPreviousChapter?()
            return .success
        }
    }
}

extension AudioPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.onFinishedPlaying?()
        }
    }
}
