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

    /// A soft looping pad (waiting-filler.m4a — "Underwater Ambient Pad" by
    /// isaiah658, CC0, opengameart.org) played while a listening session is
    /// waiting on audio: the gap between chapters on auto-next, or a sentence
    /// still translating/synthesizing. Besides filling the silence, it's what
    /// keeps the app running with the screen off — iOS suspends a background
    /// audio app as soon as it stops producing sound, which used to freeze
    /// auto-next until the screen came back on. No delegate: it loops
    /// forever and must never trigger `onFinishedPlaying`.
    private lazy var fillerPlayer: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "waiting-filler", withExtension: "m4a"),
              let filler = try? AVAudioPlayer(contentsOf: url) else { return nil }
        filler.numberOfLoops = -1
        filler.volume = 0
        filler.prepareToPlay()
        return filler
    }()
    private static let fillerVolume: Float = 0.25
    /// Pending start (see `startFiller`) or pending stop after a fade-out.
    private var fillerTransition: Task<Void, Never>?

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
        #if os(iOS)
        // macOS has no AVAudioSession/interruption-notification concept —
        // there's no single shared audio session another app can "steal"
        // the way a phone call or another iOS app's audio can.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        #endif
    }

    #if os(iOS)
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
    #endif

    enum PlaybackError: Error {
        case failedToStart
    }

    func play(data: Data) throws {
        stopFiller()
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        player = newPlayer
        // AVAudioPlayer.play() returns false instead of throwing when the OS
        // refuses to start (e.g. audio hardware unavailable) — left
        // unchecked, isPlaying/MPNowPlayingInfoCenter would flip to
        // "playing" with no sound and no `audioPlayerDidFinishPlaying`
        // callback ever coming to unstick playback, i.e. the pause icon
        // stays up forever with nothing audible.
        guard newPlayer.play() else {
            player = nil
            throw PlaybackError.failedToStart
        }
        isPlaying = true
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func pause() {
        stopFiller()
        player?.pause()
        isPlaying = false
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    func resume() {
        // Pausing within the clip's last ~50ms (after its final buffer was
        // already handed to the audio queue, before the finish callback)
        // leaves AVAudioPlayer resuming into silence forever: play()
        // returns true, isPlaying stays true, currentTime sits at duration,
        // and audioPlayerDidFinishPlaying never fires — playback stuck with
        // the pause icon up. Re-seeking to the same position re-primes the
        // queue so the finish callback fires normally.
        if let player { player.currentTime = player.currentTime }
        player?.play()
        isPlaying = true
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func stop() {
        stopFiller()
        player?.stop()
        player = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Starts the waiting filler unless real audio starts within `delay` —
    /// so a sentence whose audio is already buffered doesn't get a blip of
    /// filler in front of it. The session is kept alive from the call on,
    /// though: the filler player is started at volume 0 right away and
    /// only faded in after the delay.
    func startFiller(after delay: TimeInterval = 0.4) {
        guard let filler = fillerPlayer else { return }
        fillerTransition?.cancel()
        if !filler.isPlaying {
            filler.volume = 0
            filler.play()
        }
        fillerTransition = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let filler = self?.fillerPlayer, filler.isPlaying else { return }
            filler.setVolume(Self.fillerVolume, fadeDuration: 0.5)
        }
    }

    /// Fades the filler out (overlapping the start of whatever plays next)
    /// and stops it.
    func stopFiller() {
        guard let filler = fillerPlayer, filler.isPlaying else { return }
        fillerTransition?.cancel()
        filler.setVolume(0, fadeDuration: 0.4)
        fillerTransition = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.fillerPlayer?.stop()
        }
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
