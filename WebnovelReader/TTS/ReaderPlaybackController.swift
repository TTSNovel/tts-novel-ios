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
    /// How many sentences (of the current chapter) have audio fetched and
    /// cached, ready to play without a network wait — reader.js's
    /// `preloadReady` counter (els.preload text).
    @Published private(set) var preloadedCount = 0
    @Published var errorMessage: String?

    /// Live-measured height of the single on-screen PlaybackBar (see its
    /// doc comment). Every other screen reserves an invisible spacer of
    /// this exact height at the bottom of its own scrollable content — a
    /// plain `.safeAreaInset` attached once on the ancestor NavigationStack
    /// does not reliably keep a *pushed* screen's own ScrollView/List
    /// content clear of the bar once the bar's height changes (e.g. the
    /// combined progress row appearing once `sentenceCount > 0`), which was
    /// the actual cause of chapter text rendering behind the bar.
    @Published var barHeight: CGFloat = 0

    /// Changing voice/speed mid-chapter used to silently keep whatever was
    /// already preloaded under the *old* setting — reader.js explicitly
    /// drops its preloadCache on both of these changes (site_assets/
    /// reader.js:831-844) specifically to avoid finishing a chapter in a
    /// mixed voice/speed; this port had been missing that call entirely.
    @Published var voice: TTSVoice {
        didSet {
            UserDefaults.standard.set(voice.rawValue, forKey: Keys.voice)
            dropPreloadedAudio()
        }
    }
    @Published var speed: Double {
        didSet {
            UserDefaults.standard.set(speed, forKey: Keys.speed)
            dropPreloadedAudio()
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
    /// How many sentences ahead to prefetch audio for — user-configurable
    /// (Cài đặt đọc), was a fixed constant before.
    @Published var preloadAhead: Int {
        didSet { UserDefaults.standard.set(preloadAhead, forKey: Keys.preloadAhead) }
    }

    let player = AudioPlaybackService()

    var isPlaying: Bool { player.isPlaying }
    var sentenceCount: Int { sentences.count }

    private var shouldAutoPlayNextChapter = false
    /// Only reset in `open()` — i.e. "a fresh navigation into a book",
    /// mirroring the old per-ReaderView-instance lifetime this used to
    /// have. Manual prev/next browsing and auto-advance within the same
    /// open session must NOT re-trigger a resume jump mid-session.
    private var hasCheckedResume = false

    private var active = false
    private var generation = 0
    /// Set by `prepareResume`, consumed by the next `start()` call so the
    /// first Play press after resuming lands on the saved sentence instead
    /// of the top of the chapter.
    private var pendingResumeIndex: Int?
    /// One fetch per sentence index, started either by the main play
    /// loop or by look-ahead prefetch — awaiting the same Task twice
    /// (once from prefetch, once from playback reaching that index) just
    /// returns the cached result, same idea as reader.js's
    /// `preloadCache[i]` Promise map.
    private var audioTasks: [Int: Task<Data, Error>] = [:]
    private var preloadedIndices: Set<Int> = []
    private var sleepTimerTask: Task<Void, Never>?

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
        hasCheckedResume = false
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
            chapter = fetched
            player.updateNowPlaying(bookTitle: book.title, chapterTitle: fetched.title)
            applyResumeIfNeeded(fetched)
            resumeAutoPlayIfNeeded()
        } catch {
            loadError = "Không tải được nội dung chương"
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
        if player.isPlaying {
            pause()
            syncProgress()
        } else if active {
            resume()
        } else {
            start()
        }
    }

    func stop() {
        active = false
        generation += 1
        audioTasks = [:]
        pendingResumeIndex = nil
        clearAutoStopState()
        player.stop()
        highlightedSentenceIndex = nil
    }

    private func syncProgress() {
        guard let book else { return }
        Task { await ProgressStore.shared.syncToServer(bookID: book.id) }
    }

    private func start() {
        let startIndex = pendingResumeIndex ?? 0
        pendingResumeIndex = nil
        beginChapter(startIndex: startIndex)
        scheduleAutoStop()
    }

    /// Shows the chapter split into sentences with the saved position
    /// highlighted/scrolled-to (via ReaderView's existing
    /// highlightedSentenceIndex machinery) without starting audio —
    /// matches "open app -> jump + highlight, Play continues from there"
    /// rather than auto-playing on launch. The index is consumed by the
    /// next `start()` call.
    private func prepareResume(sentenceIndex: Int) {
        guard let chapter else { return }
        sentences = Self.sentenceSequence(for: chapter)
        guard sentences.indices.contains(sentenceIndex) else { return }
        currentSentenceIndex = sentenceIndex
        highlightedSentenceIndex = sentenceIndex
        pendingResumeIndex = sentenceIndex
    }

    /// Call when the caller has decided NOT to continue into another
    /// chapter after finishing (auto-next disabled, or no chapter left) —
    /// releases the now-pointless sleep timer instead of letting it fire
    /// later on an already-idle controller.
    private func abandonSleepTimerIfIdle() {
        guard !active else { return }
        clearAutoStopState()
    }

    private func beginChapter(startIndex: Int) {
        guard let chapter else { return }
        sentences = Self.sentenceSequence(for: chapter)
        currentSentenceIndex = startIndex
        preloadedIndices = []
        preloadedCount = 0
        audioTasks = [:]
        active = true
        generation += 1
        Task { await playCurrentSentence(generation: generation) }
    }

    private func pause() {
        player.pause()
    }

    private func resume() {
        guard active else { return }
        player.resume()
    }

    private func advance() {
        guard active else { return }
        currentSentenceIndex += 1
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
            highlightedSentenceIndex = nil
            handleChapterFinished()
            return
        }
        guard let book else { return }

        highlightedSentenceIndex = currentSentenceIndex
        ProgressStore.shared.recordLocal(bookID: book.id, chapterIndex: chapterIndex, sentenceIndex: currentSentenceIndex)
        isLoadingAudio = audioTasks[currentSentenceIndex] == nil
        do {
            let data = try await fetchTask(index: currentSentenceIndex).value
            guard generation == self.generation else { return }
            isLoadingAudio = false
            audioTasks[currentSentenceIndex] = nil
            try player.play(data: data)
            errorMessage = nil
            // Look ahead — same idea as reader.js's PRELOAD_AHEAD loop
            // right after a sentence starts playing.
            for k in 1...max(preloadAhead, 1) {
                preload(index: currentSentenceIndex + k)
            }
        } catch {
            isLoadingAudio = false
            guard generation == self.generation else { return }
            errorMessage = "Không tạo được audio — thử lại hoặc đổi giọng đọc"
            active = false
            clearAutoStopState()
        }
    }

    private func fetchTask(index: Int) -> Task<Data, Error> {
        if let existing = audioTasks[index] { return existing }
        let task = makeFetchTask(index: index)
        audioTasks[index] = task
        return task
    }

    private func preload(index: Int) {
        guard index >= 0, index < sentences.count, audioTasks[index] == nil else { return }
        audioTasks[index] = makeFetchTask(index: index)
    }

    private func makeFetchTask(index: Int) -> Task<Data, Error> {
        let text = sentences[index]
        let voice = self.voice
        let speed = self.speed
        let generation = self.generation
        let baseURL = SessionStore.baseURL
        // Re-checked per sentence (not cached for the whole chapter) so
        // playback self-corrects the moment connectivity returns, and
        // never mutates `voice`/its persisted UserDefaults value — the
        // user's actual selection resumes automatically once back online.
        let isConnected = NetworkMonitor.shared.isConnected
        return Task {
            let data: Data
            if voice.isOffline || !isConnected {
                // No network round trip — runs the bundled ONNX model
                // right here on-device (see PiperOfflineTTSService).
                data = try await PiperOfflineTTSService.shared.synthesize(text: text, speed: speed)
            } else {
                data = try await APIClient.shared.synthesize(baseURL: baseURL, text: text, voice: voice, speed: speed)
            }
            self.markPreloaded(index: index, generation: generation)
            return data
        }
    }

    private func markPreloaded(index: Int, generation: Int) {
        guard generation == self.generation else { return }
        preloadedIndices.insert(index)
        preloadedCount = preloadedIndices.count
    }

    /// Drops every not-yet-played preloaded/in-flight sentence so the next
    /// one fetched picks up the newly changed voice/speed — reader.js's
    /// dropPreloadedAudio(). Safe to call mid-playback: by the time a
    /// sentence is actually *playing*, its entry has already been removed
    /// from `audioTasks` (see playCurrentSentence, right before
    /// `player.play`), so this only ever discards sentences ahead of
    /// what's currently audible, never interrupting it.
    private func dropPreloadedAudio() {
        for task in audioTasks.values { task.cancel() }
        audioTasks = [:]
        preloadedIndices = []
        preloadedCount = 0
    }

    private func scheduleAutoStop() {
        clearAutoStopState()
        guard autoStopMinutes > 0 else { return }
        let nanoseconds = UInt64(autoStopMinutes * 60 * 1_000_000_000)
        sleepTimerTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self.stop()
        }
    }

    private func clearAutoStopState() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
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
