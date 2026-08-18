import Foundation

/// Owns the entire reading/listening session — which book, which chapter,
/// its content, and sentence-by-sentence read-aloud — as an app-wide
/// singleton instead of being scoped to whichever ReaderView happens to be
/// on screen. This is what makes playback behave like Music/Podcasts:
/// backing out to BookDetailView or the Library no longer tears down the
/// session, because nothing about it lives in a View anymore. ReaderView
/// just calls `open(book:chapterIndex:)` once and otherwise reads this
/// object's @Published state to render; every chapter-navigation and
/// remote-command path here runs to completion on its own regardless of
/// what's currently on screen.
///
/// Ported from reader.js's readLoop() (site_assets/reader.js, around line
/// 473 in the tts-webnovel repo): split chapter text into sentences,
/// look-ahead prefetch several sentences' audio at once, play one at a
/// time, highlight + report progress as it goes, optionally auto-advance
/// to the next chapter, and optionally auto-stop the whole session after
/// N minutes.
@MainActor
final class ReaderPlaybackController: ObservableObject {
    static let shared = ReaderPlaybackController()

    // Now-playing identity — nil book means nothing has ever been opened
    // this app launch.
    @Published private(set) var book: Book?
    @Published private(set) var chapterIndex: Int = 0
    @Published private(set) var chapter: Chapter?
    @Published private(set) var loadError: String?

    @Published private(set) var isLoadingAudio = false
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var sentences: [String] = []
    @Published private(set) var highlightedSentenceIndex: Int?
    /// Furthest sentence index reached by *contiguous* preloading (-1 if
    /// none yet) — "audio is ready straight through sentence N". Not a raw
    /// count of however many fetches succeeded: on a resume mid-chapter,
    /// everything before the resume point is treated as already "through"
    /// without needing to actually be fetched (see `prepareResume`), and a
    /// plain count would silently exclude that prefix.
    @Published private(set) var preloadedThroughIndex = -1
    /// Mirrors `player.isPlaying`, but as this object's own @Published
    /// property — PlaybackBar only observes ReaderPlaybackController, so a
    /// change on the (separate) AudioPlaybackService object doesn't by
    /// itself trigger a re-render; the button previously only looked right
    /// by coincidence, whenever some *other* @Published property here (like
    /// isLoadingAudio) happened to change at the same moment. Set
    /// explicitly at every play/pause/resume/stop/finish transition below.
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?
    /// Set by PlaybackBar's title tap (it lives outside any NavigationStack
    /// — see its doc comment — so it can't use NavigationLink directly);
    /// LibraryView observes this and pushes the route onto its own
    /// navPath, then clears it back to nil.
    @Published var pendingChapterRoute: ChapterRoute?

    /// Changing voice/speed mid-chapter deliberately does NOT drop whatever
    /// is already preloaded/in-flight under the *old* setting — changing
    /// voice isn't "start over," it's "keep whatever's already buffered,
    /// and preload everything from here on with the new voice/speed."
    /// (An earlier version dropped the whole preload queue here, porting
    /// reader.js's dropPreloadedAudio() call — but that meant switching
    /// voice mid-chapter visibly threw away buffered progress the user had
    /// already waited for.) `makeFetchTask` reads `self.voice`/`self.speed`
    /// fresh at the moment each *new* fetch is queued, so nothing further
    /// is needed here for new preloads to pick up the change.
    @Published var voice: TTSVoice {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: Keys.voice) }
    }
    @Published var speed: Double {
        didSet {
            UserDefaults.standard.set(speed, forKey: Keys.speed)
            updateNowPlayingProgress()
        }
    }
    @Published var autoNextChapter: Bool {
        didSet { UserDefaults.standard.set(autoNextChapter, forKey: Keys.autoNext) }
    }
    /// 0 disables the sleep timer entirely (reader.js: "if (!minutes ||
    /// minutes <= 0) return").
    @Published var autoStopMinutes: Double {
        didSet {
            UserDefaults.standard.set(autoStopMinutes, forKey: Keys.autoStopMinutes)
            // "apply the new value to the running session" — reader.js
            // does the same (site_assets/reader.js:855).
            if active { scheduleAutoStop() }
        }
    }
    /// Max concurrent sentence-audio fetches allowed at once — user-
    /// configurable (Cài đặt đọc). NOT a fixed look-ahead distance from the
    /// playhead: `refillPreloadQueue()` keeps this many in flight
    /// continuously, sliding forward through the rest of the chapter as
    /// each one completes, whether or not playback is actually active
    /// (raising this immediately tops up to the new limit).
    @Published var preloadAhead: Int {
        didSet {
            UserDefaults.standard.set(preloadAhead, forKey: Keys.preloadAhead)
            refillPreloadQueue()
        }
    }

    let player = AudioPlaybackService()

    var sentenceCount: Int { sentences.count }

    private var shouldAutoPlayNextChapter = false
    /// Only reset in `open()` — i.e. "a fresh navigation into a book",
    /// mirroring the old per-ReaderView-instance lifetime this used to
    /// have. Manual prev/next browsing and auto-advance within the same
    /// open session must NOT re-trigger a resume jump mid-session.
    private var hasCheckedResume = false

    private var active = false
    /// Set right when an AVAudioSession interruption (call/alarm/Maps
    /// prompt) begins, cleared once consumed on .ended — see
    /// player.onInterruptionBegan/onInterruptionEnded in init().
    private var wasPlayingBeforeInterruption = false
    private var generation = 0
    /// Set by `prepareResume`, consumed by the next `start()` call so the
    /// first Play press after resuming lands on the saved sentence instead
    /// of the top of the chapter.
    private var pendingResumeIndex: Int?
    /// Next not-yet-queued sentence index for `refillPreloadQueue()` — only
    /// ever moves forward. Reset to the chapter's start index in
    /// `beginChapter`/`prepareResume`.
    private var preloadCursor = 0
    /// One fetch per sentence index, started either by the main play
    /// loop or by look-ahead prefetch — awaiting the same Task twice
    /// (once from prefetch, once from playback reaching that index) just
    /// returns the cached result, same idea as reader.js's
    /// `preloadCache[i]` Promise map.
    private var audioTasks: [Int: Task<Data, Error>] = [:]
    private var preloadedIndices: Set<Int> = []
    /// Actual fetched audio bytes, kept once a fetch completes — separate
    /// from `audioTasks` (in-flight only; an entry is removed from there
    /// the moment its Task resolves, freeing a `refillPreloadQueue()`
    /// concurrency slot) so playback can hand over already-preloaded audio
    /// immediately instead of re-fetching it.
    private var preloadedData: [Int: Data] = [:]
    private var sleepTimerTask: Task<Void, Never>?
    /// nil whenever no sleep timer is running — lets the UI show a live
    /// countdown via `Text(timerInterval:)` without polling.
    @Published private(set) var sleepTimerDeadline: Date?
    /// Set by `autoStopFired()`, checked by `playCurrentSentence` right
    /// before it plays a sentence — blocks the case where the timer fires
    /// while the *next* sentence's audio is already mid-fetch (kicked off by
    /// `advance()` just before the deadline hit): without this, that fetch
    /// would resolve moments later and `player.play(data:)` would fire
    /// anyway, silently undoing the timer's pause. Cleared on the next
    /// `resume()`/`scheduleAutoStop()` so it only suppresses the one
    /// in-flight sentence, not playback in general.
    private var sleepTimerExpired = false

    /// Rough Vietnamese-speech pace at `speed == 1.0`, used only to turn
    /// character counts into the lock-screen/Control-Center progress bar's
    /// elapsed/duration estimate (see `updateNowPlayingProgress`) — TTS
    /// audio has no real duration until each sentence is actually
    /// synthesized, so this is an approximation, not calibrated per-voice.
    private static let baseCharactersPerSecond: Double = 14

    private enum Keys {
        static let voice = "reader.model"
        static let speed = "reader.speed"
        static let autoNext = "reader.autoNext"
        static let autoStopMinutes = "reader.autoStopMinutes"
        static let preloadAhead = "reader.preloadAhead"
    }

    private init() {
        voice = TTSVoice(rawValue: UserDefaults.standard.string(forKey: Keys.voice) ?? "") ?? .piperVi
        let savedSpeed = UserDefaults.standard.double(forKey: Keys.speed)
        speed = savedSpeed > 0 ? savedSpeed : 1.0
        autoNextChapter = UserDefaults.standard.bool(forKey: Keys.autoNext)
        autoStopMinutes = UserDefaults.standard.object(forKey: Keys.autoStopMinutes) as? Double ?? 30
        let savedPreloadAhead = UserDefaults.standard.object(forKey: Keys.preloadAhead) as? Int
        preloadAhead = savedPreloadAhead ?? 10
        player.onFinishedPlaying = { [weak self] in self?.advance() }
        // Lock-screen / Control-Center next/previous-track — wired once
        // here instead of per-ReaderView, since the player itself is now
        // owned for the app's whole lifetime, not just while some
        // ReaderView happens to be on screen.
        player.onNextChapter = { [weak self] in self?.remoteSkip(by: 1) }
        player.onPreviousChapter = { [weak self] in self?.remoteSkip(by: -1) }
        player.onPlayCommand = { [weak self] in self?.remotePlay() }
        player.onPauseCommand = { [weak self] in self?.remotePause() }
        // `wasPlayingBeforeInterruption` gates the resume so a call/alarm/
        // Maps prompt that happens to land *after* the user already
        // manually paused doesn't un-pause them the moment it ends.
        player.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            wasPlayingBeforeInterruption = isPlaying
            remotePause()
        }
        player.onInterruptionEnded = { [weak self] in
            guard let self, wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            remotePlay()
        }
    }

    /// Called by ReaderView when it appears for a given book/chapter. If
    /// that's already exactly what's playing/showing (e.g. the user just
    /// backed out and back in, or reopened the same in-progress book), this
    /// is a deliberate no-op — the whole point is that navigating back into
    /// the same session doesn't interrupt or reset it. Otherwise loads the
    /// requested chapter, stopping whatever was previously playing first
    /// (a different book, or a different chapter of this one).
    func open(book: Book, chapterIndex: Int) async {
        if self.book?.id == book.id, self.chapterIndex == chapterIndex, chapter != nil {
            return
        }
        // Deliberately does NOT go through goTo() — goTo() marks a fresh
        // sentence-0 baseline, which is correct for *manual* navigation but
        // would clobber a saved mid-chapter position before
        // applyResumeIfNeeded (called from loadChapter() below) ever gets
        // to see it. This path needs to preserve whatever's actually saved.
        stop()
        self.book = book
        self.chapterIndex = chapterIndex
        chapter = nil
        clearSentenceState()
        hasCheckedResume = false
        EventLogStore.shared.record(.navigation, "Mở chương", detail: "\(book.title) — Chương \(chapterIndex + 1)")
        await loadChapter()
    }

    /// Manual chapter browsing (prev/next toolbar buttons, or a chapter-list
    /// row tapped while already inside this same book) — always stops
    /// first and loads without auto-playing, matching reader.js's plain
    /// chapter-link behavior.
    func goTo(_ index: Int) async {
        guard let book, index >= 0, index < book.n else { return }
        stop()
        chapter = nil
        clearSentenceState()
        let direction = index == chapterIndex + 1 ? "chương tiếp" : (index == chapterIndex - 1 ? "chương trước" : "chương \(index + 1)")
        EventLogStore.shared.record(.navigation, "Chuyển \(direction)", detail: "\(book.title) — Chương \(index + 1)")
        chapterIndex = index
        // Marks "now on this chapter" as a baseline even before any audio
        // plays — playCurrentSentence's progress recording takes over with
        // finer-grained positions once playback actually starts.
        ProgressStore.shared.recordLocal(bookID: book.id, chapterIndex: index, sentenceIndex: 0)
        syncProgress()
        await loadChapter()
    }

    /// Lock-screen / remote next-track & previous-track — unlike goTo()
    /// (manual toolbar browsing, which lands on the chapter without
    /// playing), a remote skip command only fires while there's an active
    /// listening session, so it should keep listening into the new chapter
    /// the same way auto-next does. Falls back to goTo()'s plain-navigation
    /// behavior when nothing was playing.
    private func remoteSkip(by delta: Int) {
        guard let book else { return }
        let index = chapterIndex + delta
        guard index >= 0, index < book.n else { return }
        guard isPlaying else {
            Task { await goTo(index) }
            return
        }
        stop()
        shouldAutoPlayNextChapter = true
        chapter = nil
        chapterIndex = index
        ProgressStore.shared.recordLocal(bookID: book.id, chapterIndex: index, sentenceIndex: 0)
        syncProgress()
        Task { await loadChapter() }
    }

    private func loadChapter() async {
        guard let book else { return }
        loadError = nil
        let continuing = shouldAutoPlayNextChapter
        if !continuing { stop() }
        // Captured *after* the stop() calls above (both this one and the
        // caller's, in open()/goTo()) so it reflects this exact navigation.
        // Without this, a slow fetchChapter() from a chapter the user has
        // already navigated away from (e.g. rapidly picking a different row
        // in ChapterListSheet before the previous pick's request lands) can
        // resolve after a newer, faster request already finished — and
        // unconditionally overwrite the correct chapter with the stale one,
        // which reads as "tapping a chapter does nothing" even though the
        // tap itself was handled correctly.
        let generation = self.generation

        if let local = DownloadManager.shared.localChapter(bookID: book.id, index: chapterIndex) {
            chapter = local
            player.updateNowPlaying(bookTitle: book.title, chapterTitle: local.title)
            applyResumeIfNeeded(local)
            resumeAutoPlayIfNeeded()
            return
        }

        do {
            let fetched = try await APIClient.shared.fetchChapter(
                baseURL: SessionStore.baseURL, bookID: book.id, index: chapterIndex
            )
            guard generation == self.generation else { return }
            chapter = fetched
            player.updateNowPlaying(bookTitle: book.title, chapterTitle: fetched.title)
            applyResumeIfNeeded(fetched)
            resumeAutoPlayIfNeeded()
        } catch {
            guard generation == self.generation else { return }
            loadError = "Không tải được nội dung chương"
            EventLogStore.shared.record(.error, "Không tải được nội dung chương", detail: "\(book.title) — Chương \(chapterIndex + 1): \(error.localizedDescription)")
        }
    }

    /// Only ever applies once per `open()` — i.e. once per fresh navigation
    /// into a book/chapter — matching "open app -> jump to saved chapter +
    /// highlight saved sentence" without re-jumping on every subsequent
    /// auto-advance or manual browse within the same session.
    private func applyResumeIfNeeded(_ chapter: Chapter) {
        guard !hasCheckedResume, let book else { return }
        hasCheckedResume = true
        guard let saved = ProgressStore.shared.localProgress(bookID: book.id), saved.chapterIndex == chapterIndex else {
            return
        }
        prepareResume(sentenceIndex: saved.sentenceIndex)
    }

    private func resumeAutoPlayIfNeeded() {
        guard shouldAutoPlayNextChapter else { return }
        shouldAutoPlayNextChapter = false
        beginChapter(startIndex: 0)
    }

    /// A chapter finished playing on its own (not stopped/errored). If
    /// auto-next is on and there's another chapter, jump to it without
    /// stopping playback state — loadChapter() picks up
    /// `shouldAutoPlayNextChapter` and continues the same listening
    /// session (sleep timer keeps counting) instead of starting a fresh one.
    private func handleChapterFinished() {
        guard let book, autoNextChapter, chapterIndex < book.n - 1 else {
            abandonSleepTimerIfIdle()
            return
        }
        shouldAutoPlayNextChapter = true
        chapter = nil
        chapterIndex += 1
        Task { await loadChapter() }
    }

    /// Single entry point the play/pause button calls — decides start vs.
    /// resume vs. pause from internal state so callers don't have to guess
    /// (e.g. "finished the last sentence" leaves `active` false, at which
    /// point only a fresh `start` makes sense, not `resume`).
    func togglePlayback() {
        guard chapter != nil else { return }
        if isPlaying {
            pause()
            syncProgress()
        } else if active {
            resume()
        } else {
            start()
        }
    }

    /// Lock-screen / Control-Center Play — unlike togglePlayback() (used by
    /// the in-app button, which infers start/resume/pause from current
    /// state), MPRemoteCommandCenter's play and pause are two separate,
    /// non-toggling commands, so this always means "start playing".
    /// Routes through the same resume()/start() the in-app button uses —
    /// critically through scheduleAutoStop(), which resets
    /// `sleepTimerExpired` and re-arms the countdown. Previously the lock
    /// screen called AudioPlaybackService.resume() directly, bypassing all
    /// of that: after a sleep-timer pause, `sleepTimerExpired` stayed true
    /// forever, so the very next sentence silently refused to play (see
    /// `playCurrentSentence`'s guard).
    private func remotePlay() {
        guard chapter != nil, !isPlaying else { return }
        if active {
            resume()
        } else {
            start()
        }
    }

    private func remotePause() {
        guard isPlaying else { return }
        pause()
        syncProgress()
    }

    func stop() {
        active = false
        generation += 1
        audioTasks = [:]
        preloadedIndices = []
        preloadedData = [:]
        preloadedThroughIndex = -1
        pendingResumeIndex = nil
        clearAutoStopState()
        player.stop()
        isPlaying = false
        highlightedSentenceIndex = nil
        updateNowPlayingProgress()
    }

    /// Clears the sentence-segmented view of the *previous* chapter right
    /// when abandoning it for a different one (`open()`/`goTo()`, wherever
    /// `chapter` gets set to nil ahead of the new one loading).
    ///
    /// `sentences` only ever gets (re)populated by `beginChapter` or
    /// `prepareResume` — and manual chapter navigation (goTo, e.g. from
    /// ChapterListSheet) deliberately does *not* call either of those
    /// (see goTo's doc comment: it lands on the chapter without playing,
    /// and `hasCheckedResume` blocks `applyResumeIfNeeded` from firing a
    /// second time within the same open() session). Without this reset,
    /// `sentences` silently kept the *old* chapter's segmented text after
    /// switching chapters, and ReaderView.chapterBody renders from
    /// `playback.sentences` whenever it's non-empty — so tapping "Chương 6"
    /// in the chapter list correctly updated the header/position counters
    /// (those read `chapter`/`chapterIndex`, which loadChapter sets
    /// correctly) while the actual body text kept showing chapter 1's
    /// content, exactly as if the tap had silently loaded the wrong
    /// chapter. Deliberately NOT done inside `stop()` itself — `stop()` is
    /// also used to just halt playback in place (e.g. the sleep timer)
    /// without abandoning the chapter, where clearing this would wrongly
    /// blow away the current reading position's highlighting.
    private func clearSentenceState() {
        sentences = []
        currentSentenceIndex = 0
        updateNowPlayingProgress()
    }

    /// Pushes an estimated elapsed/duration/rate to
    /// MPNowPlayingInfoCenter so the lock screen and Control Center show a
    /// progress bar + counting time like Music/Podcasts, even though TTS
    /// audio has no real per-chapter duration. Called at every sentence
    /// boundary and play/pause/speed transition — iOS interpolates the
    /// displayed time on its own between calls as long as elapsed/duration/
    /// rate are kept current, so this doesn't need a per-second timer.
    private func updateNowPlayingProgress() {
        guard !sentences.isEmpty else {
            player.updateNowPlayingProgress(elapsed: 0, duration: 0, rate: 0)
            return
        }
        let rate = Self.baseCharactersPerSecond * max(speed, 0.1)
        let totalChars = sentences.reduce(0) { $0 + $1.count }
        let elapsedChars = sentences[0..<min(currentSentenceIndex, sentences.count)].reduce(0) { $0 + $1.count }
        let duration = Double(totalChars) / rate
        let elapsed = Double(elapsedChars) / rate
        player.updateNowPlayingProgress(elapsed: elapsed, duration: duration, rate: isPlaying ? speed : 0)
    }

    private func syncProgress() {
        guard let book else { return }
        Task { await ProgressStore.shared.syncToServer(bookID: book.id) }
    }

    private func start() {
        let startIndex = pendingResumeIndex ?? 0
        // No log call here — playCurrentSentence() logs every sentence it
        // actually starts playing (including this first one), so a separate
        // "Phát audio" entry here would just duplicate that.
        // If prepareResume() already primed preloading from this exact
        // position (pendingResumeIndex was set), beginChapter must NOT
        // reset it — that would throw away the head start it already
        // bought while the user was looking at the resumed position before
        // pressing Play.
        let alreadyPrimed = pendingResumeIndex != nil
        pendingResumeIndex = nil
        beginChapter(startIndex: startIndex, resetPreload: !alreadyPrimed)
        scheduleAutoStop()
    }

    /// Shows the chapter split into sentences with the saved position
    /// highlighted/scrolled-to (via ReaderView's existing
    /// highlightedSentenceIndex machinery) without starting audio —
    /// matches "open app -> jump + highlight, Play continues from there"
    /// rather than auto-playing on launch. The index is consumed by the
    /// next `start()` call.
    ///
    /// Also starts preloading from this position immediately, even though
    /// nothing is playing yet — preloading isn't tied to `active`/Play, so
    /// audio for the resumed position (and beyond) is already buffering by
    /// the time the user actually presses Play.
    private func prepareResume(sentenceIndex: Int) {
        guard let chapter else { return }
        sentences = Self.sentenceSequence(for: chapter)
        guard sentences.indices.contains(sentenceIndex) else { return }
        currentSentenceIndex = sentenceIndex
        highlightedSentenceIndex = sentenceIndex
        pendingResumeIndex = sentenceIndex
        updateNowPlayingProgress()
        preloadedIndices = []
        preloadedData = [:]
        preloadedThroughIndex = sentenceIndex - 1
        preloadCursor = sentenceIndex
        audioTasks = [:]
        refillPreloadQueue()
    }

    /// Call when the caller has decided NOT to continue into another
    /// chapter after finishing (auto-next disabled, or no chapter left) —
    /// releases the now-pointless sleep timer instead of letting it fire
    /// later on an already-idle controller.
    private func abandonSleepTimerIfIdle() {
        guard !active else { return }
        clearAutoStopState()
    }

    /// `resetPreload: false` when called right after `prepareResume` already
    /// set up preloading from this exact `startIndex` — see `start()`.
    /// Crucially, `generation` is only bumped when actually resetting:
    /// bumping it unconditionally would silently orphan every preload
    /// `Task` prepareResume already had in flight — their eventual
    /// `markPreloaded` calls check `generation == self.generation` and
    /// would find a mismatch, so the audio they fetch would still play
    /// fine (whoever awaits the Task still gets its value) but never get
    /// recorded as preloaded, leaving `preloadedThroughIndex` stuck behind
    /// however far playback had actually already gotten.
    private func beginChapter(startIndex: Int, resetPreload: Bool = true) {
        guard let chapter else { return }
        sentences = Self.sentenceSequence(for: chapter)
        currentSentenceIndex = startIndex
        updateNowPlayingProgress()
        if resetPreload {
            preloadedIndices = []
            preloadedData = [:]
            preloadedThroughIndex = startIndex - 1
            preloadCursor = startIndex
            audioTasks = [:]
            generation += 1
        }
        active = true
        Task { await playCurrentSentence(generation: generation) }
    }

    private func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingProgress()
        EventLogStore.shared.record(.playback, "Tạm dừng", detail: playbackDetail())
        // Pausing ends the current sleep-timer "session" — the countdown
        // shouldn't keep ticking down (or fire) while nothing is playing.
        // resume() starts a fresh one, same as a brand-new start().
        clearAutoStopState()
    }

    private func resume() {
        guard active else { return }
        scheduleAutoStop()
        player.resume()
        isPlaying = true
        updateNowPlayingProgress()
        EventLogStore.shared.record(.playback, "Tiếp tục phát", detail: playbackDetail())
    }

    private func playbackDetail() -> String? {
        guard let book else { return nil }
        return "\(book.title) — Chương \(chapterIndex + 1), câu \(currentSentenceIndex + 1)"
    }

    private func advance() {
        guard active else { return }
        currentSentenceIndex += 1
        updateNowPlayingProgress()
        Task { await playCurrentSentence(generation: generation) }
    }

    private func playCurrentSentence(generation: Int) async {
        guard active, generation == self.generation else { return }
        guard currentSentenceIndex < sentences.count else {
            // Ran out of sentences normally — end of chapter. Sleep timer
            // is deliberately left running here: resumeAutoPlayIfNeeded may
            // continue straight into the next chapter, and only
            // handleChapterFinished knows whether that's actually going to
            // happen (see abandonSleepTimerIfIdle()).
            active = false
            isPlaying = false
            highlightedSentenceIndex = nil
            updateNowPlayingProgress()
            handleChapterFinished()
            return
        }
        guard let book else { return }

        highlightedSentenceIndex = currentSentenceIndex
        ProgressStore.shared.recordLocal(bookID: book.id, chapterIndex: chapterIndex, sentenceIndex: currentSentenceIndex)
        // Always show loading while waiting on this sentence's audio, even
        // if it was already mid-fetch as a preload (not just when starting
        // a brand-new fetch) — otherwise pressing Play while preload
        // happens to still be catching up shows no feedback at all until
        // audio suddenly starts, which reads as "the tap didn't do
        // anything."
        isLoadingAudio = true
        preloadCursor = max(preloadCursor, currentSentenceIndex + 1)
        do {
            let data = try await fetchTask(index: currentSentenceIndex).value
            guard generation == self.generation, !sleepTimerExpired else {
                isLoadingAudio = false
                return
            }
            isLoadingAudio = false
            try player.play(data: data)
            isPlaying = true
            updateNowPlayingProgress()
            errorMessage = nil
            // Every sentence that actually starts playing, whether from a
            // manual Play press or auto-advancing to the next one — not
            // just the user-initiated actions — so the history/log reflects
            // what was actually read aloud (câu 1, câu 2, ... câu 100), not
            // only "pressed play once."
            EventLogStore.shared.record(.playback, "Phát câu \(currentSentenceIndex + 1)", detail: playbackDetail())
            // Keep the preload queue topped up now that a slot may have
            // freed (or the playhead moved) — see refillPreloadQueue().
            refillPreloadQueue()
        } catch {
            isLoadingAudio = false
            guard generation == self.generation else { return }
            errorMessage = "Không tạo được audio — thử lại hoặc đổi giọng đọc"
            active = false
            isPlaying = false
            updateNowPlayingProgress()
            clearAutoStopState()
            EventLogStore.shared.record(.error, "Không tạo được audio", detail: "\(playbackDetail() ?? "") — \(error.localizedDescription)")
        }
    }

    private func fetchTask(index: Int) -> Task<Data, Error> {
        if let cached = preloadedData[index] { return Task { cached } }
        if let existing = audioTasks[index] { return existing }
        let task = makeFetchTask(index: index)
        audioTasks[index] = task
        return task
    }

    private func preload(index: Int) {
        guard index >= 0, index < sentences.count, audioTasks[index] == nil, !preloadedIndices.contains(index) else { return }
        audioTasks[index] = makeFetchTask(index: index)
    }

    /// Tops up preloading up to `preloadAhead` sentences beyond wherever
    /// `currentSentenceIndex` actually is right now — a bounded window,
    /// NOT "keep fetching until the whole chapter is done": an earlier
    /// version had this run unbounded to the end of the chapter (gated only
    /// by concurrency), which defeated the whole point of the setting —
    /// abandoning a chapter partway through would've silently fetched (and
    /// wasted the bandwidth/cost for) every remaining sentence's audio.
    ///
    /// Still independent of whether playback is *active* (so it keeps
    /// buffering while paused, and a voice/speed change — which no longer
    /// drops the queue, see `voice`'s didSet — just continues with the new
    /// setting instead of restarting) — just bounded by *distance* from the
    /// playhead rather than by time or by chapter end. The window re-slides
    /// forward on its own as `currentSentenceIndex` advances, since every
    /// call recomputes the boundary from its current value.
    private func refillPreloadQueue() {
        guard !sentences.isEmpty else { return }
        let boundary = min(currentSentenceIndex + preloadAhead, sentences.count - 1)
        while preloadCursor <= boundary {
            preload(index: preloadCursor)
            preloadCursor += 1
        }
    }

    private func makeFetchTask(index: Int) -> Task<Data, Error> {
        let text = sentences[index]
        let voice = self.voice
        let speed = self.speed
        let generation = self.generation
        let baseURL = SessionStore.baseURL
        // Re-checked per sentence (not cached for the whole chapter) so
        // playback self-corrects the moment connectivity returns or the
        // user logs in mid-chapter, and never mutates `voice`/its persisted
        // UserDefaults value — the user's actual selection resumes
        // automatically once back online / logged in.
        let isConnected = NetworkMonitor.shared.isConnected
        // /api/tts stays behind login even though browsing/reading is now
        // public (tts-webnovel's server.py) — a guest falls back to the
        // on-device voice exactly like being offline does, same mechanism,
        // just a different reason. ReaderView's footnote explains this.
        let isLoggedIn = SessionStore.shared.isLoggedIn
        return Task {
            let data: Data
            if voice == .vieNeuOffline {
                // No network round trip — runs the bundled GGUF backbone +
                // VieNeu-Codec ONNX decoder right here on-device (see
                // VieNeuOfflineTTSService).
                data = try await VieNeuOfflineTTSService.shared.synthesize(text: text, speed: speed)
            } else if voice.isOffline || !isConnected || !isLoggedIn {
                // No network round trip — runs the bundled ONNX model
                // right here on-device (see PiperOfflineTTSService).
                data = try await PiperOfflineTTSService.shared.synthesize(text: text, speed: speed)
            } else {
                data = try await APIClient.shared.synthesize(baseURL: baseURL, text: text, voice: voice, speed: speed)
            }
            self.markPreloaded(index: index, data: data, generation: generation)
            return data
        }
    }

    /// Stores the fetched audio, removes it from `audioTasks` (it's done —
    /// no longer "in flight"), advances the contiguous
    /// `preloadedThroughIndex` frontier, and calls `refillPreloadQueue()`
    /// in case the window has since slid forward (currentSentenceIndex
    /// advanced) enough to include a new sentence.
    private func markPreloaded(index: Int, data: Data, generation: Int) {
        guard generation == self.generation else { return }
        preloadedData[index] = data
        audioTasks[index] = nil
        preloadedIndices.insert(index)
        var next = preloadedThroughIndex + 1
        while preloadedIndices.contains(next) {
            preloadedThroughIndex = next
            next += 1
        }
        refillPreloadQueue()
    }

    private func scheduleAutoStop() {
        clearAutoStopState()
        sleepTimerExpired = false
        guard autoStopMinutes > 0 else { return }
        let nanoseconds = UInt64(autoStopMinutes * 60 * 1_000_000_000)
        sleepTimerDeadline = Date().addingTimeInterval(autoStopMinutes * 60)
        sleepTimerTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self.autoStopFired()
        }
    }

    /// The sleep-timer firing must behave like the user pressing Pause, not
    /// like abandoning the chapter: calling `stop()` here used to clear
    /// `pendingResumeIndex`, the preload cache, and the loaded AVAudioPlayer
    /// buffer, so the next Play press fell back to `start()`'s `startIndex =
    /// pendingResumeIndex ?? 0` — silently restarting at the top of the
    /// chapter instead of continuing from wherever playback actually was.
    /// Reusing `pause()`'s exact effect (leaves `active` true, keeps the
    /// player's buffered sentence and the preload queue intact) means the
    /// next press correctly routes through `togglePlayback()`'s `resume()`
    /// branch instead.
    ///
    /// `sleepTimerExpired = true` covers the one case `pause()` alone
    /// doesn't: if the deadline lands right as `advance()` has already
    /// kicked off the *next* sentence's fetch, that fetch finishing moments
    /// later would otherwise call `player.play()` and silently undo this
    /// pause — see `playCurrentSentence`'s check.
    private func autoStopFired() {
        guard active else { return }
        sleepTimerExpired = true
        pause()
        syncProgress()
    }

    private func clearAutoStopState() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerDeadline = nil
    }

    /// Chapter title read aloud first, as sentence 0, before the body —
    /// previously only chapter.text was ever spoken, so listening to a
    /// chapter never announced which one it was. ReaderView's chapterBody
    /// renders index 0 with the same bold/title styling it used to give
    /// the title as a separate header, so this doesn't create a visible
    /// duplicate.
    static func sentenceSequence(for chapter: Chapter) -> [String] {
        [chapter.title] + TextSegmentation.sentences(from: TextSegmentation.cleaned(chapter.text))
    }
}
