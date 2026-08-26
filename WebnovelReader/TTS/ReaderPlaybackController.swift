import Foundation
import NaturalLanguage

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
    /// Non-nil once `evaluateTranslation()` has detected the current
    /// chapter's dominant language and it isn't Vietnamese — the language
    /// Apple's on-device Translation framework should translate *from*.
    /// nil means either detection hasn't run yet, the chapter is already
    /// Vietnamese, or the OS is older than iOS 18 (Translation is
    /// unavailable there — see `evaluateTranslation()`'s `#available`
    /// guard). Views key the translate button's visibility off this.
    @Published private(set) var translationSourceLanguage: Locale.Language?
    /// Parallel array to `sentences` (same count/order, title included as
    /// index 0) once translation for the current chapter has completed —
    /// nil while untranslated or still in flight. Always populated in the
    /// background as soon as `translationSourceLanguage` is set, regardless
    /// of `showingTranslation`/`autoTranslate` — the setting only controls
    /// whether the *display* defaults to it, not whether the translation
    /// itself happens.
    @Published private(set) var translatedSentences: [String]?
    @Published private(set) var isTranslating = false
    /// Polled from the active engine's own `translationProgress` while
    /// `isTranslating` — see `TranslationEngine.translationProgress`'s doc
    /// comment for why this is polled rather than pushed. nil whenever
    /// nothing is in flight (including right after it finishes — cleared
    /// alongside `isTranslating`).
    @Published private(set) var translationProgress: TranslationProgress?
    /// Whether the reader is currently showing `translatedSentences`
    /// (falling back to `sentences` if not yet ready) instead of the
    /// original text — what the toolbar translate button toggles. Reset to
    /// `autoTranslate`'s value every time a new chapter's translation is
    /// evaluated, so the global setting is the per-chapter default while
    /// still letting a single tap override it for that chapter.
    @Published var showingTranslation = false
    @Published private(set) var translationErrorMessage: String?
    /// Bumped once per `evaluateTranslation()` call (i.e. once per chapter
    /// load) — lets `performPendingTranslation` and the view-side
    /// `.translationTask` driver both discard a stale in-flight result from
    /// a chapter the user has since navigated away from, same pattern as
    /// `generation` guards audio fetches below.
    @Published private(set) var translationGeneration = 0
    /// Furthest sentence index reached by *contiguous* preloading (-1 if
    /// none yet) — "audio is ready straight through sentence N". Not a raw
    /// count of however many fetches succeeded: on a resume mid-chapter,
    /// everything before the resume point is treated as already "through"
    /// without needing to actually be fetched (see `prepareResume`), and a
    /// plain count would silently exclude that prefix.
    ///
    /// This is the right value for *gating* (`waitForInitialBuffer` needs
    /// guaranteed-in-order-ready audio), but a poor one for a *progress
    /// display*: fetches complete out of order (concurrent, network/CPU
    /// timing varies), so this can sit frozen behind one slow straggler
    /// while a dozen sentences *ahead* of it have actually already
    /// finished, then jump straight to the target the moment the straggler
    /// lands — see `preloadedDisplayCount` for the number that's actually
    /// meant to be shown incrementing sentence-by-sentence.
    @Published private(set) var preloadedThroughIndex = -1
    /// Sentences with ready audio, counted as they actually finish
    /// (regardless of fetch order) plus whatever prefix `prepareResume`/
    /// `beginChapter` credited as already-good without fetching — the
    /// "N" PlaybackBar's "⇩N/total" and buffered-progress bar should show.
    /// Deliberately separate from `preloadedThroughIndex`: that one only
    /// advances contiguously (see its doc comment), which reads as the
    /// progress bar doing nothing for a while and then jumping straight to
    /// the target once the slowest in-window fetch finally lands, instead
    /// of ticking up as each sentence's audio actually becomes ready.
    @Published private(set) var preloadedDisplayCount = 0
    /// Mirrors `player.isPlaying`, but as this object's own @Published
    /// property — PlaybackBar only observes ReaderPlaybackController, so a
    /// change on the (separate) AudioPlaybackService object doesn't by
    /// itself trigger a re-render; the button previously only looked right
    /// by coincidence, whenever some *other* @Published property here (like
    /// isLoadingAudio) happened to change at the same moment. Set
    /// explicitly at every play/pause/resume/stop/finish transition below.
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?
    /// Bumped alongside every user-facing error surfaced above (both this
    /// and `loadError`) — WebnovelReaderApp observes this to pop an
    /// app-wide alert regardless of which screen is currently on screen.
    /// `errorMessage`/`loadError` alone aren't enough: they only render
    /// inline on ReaderView, which isn't guaranteed to be visible since
    /// playback keeps going in the background across navigation (that's the
    /// whole point of this controller being app-wide) — without this, the
    /// only place an error was ever actually noticeable was EventLogStore's
    /// history screen. A counter (rather than reacting to `lastErrorMessage`
    /// changing) also alerts on a second failure whose text happens to
    /// repeat verbatim, which a plain equality-based onChange would miss.
    ///
    /// `lastErrorMessage` deliberately carries the same full detail
    /// (book/chapter/sentence + underlying error) as the matching
    /// EventLogStore entry, not the short, generic text `errorMessage`/
    /// `loadError` show inline — this alert is the one place most users will
    /// actually see an error, so it should say exactly what went wrong
    /// rather than send them digging through history for the detail.
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var errorEventID = 0

    private func surfaceError(_ message: String, detail: String?) {
        if let detail, !detail.isEmpty {
            lastErrorMessage = "\(message)\n\(detail)"
        } else {
            lastErrorMessage = message
        }
        errorEventID += 1
    }
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
    /// Which of the 4 bundled speaker presets `.vieNeuOfflineV2` decodes with
    /// (see VieNeuOfflineV2Voice) — irrelevant for every other `voice` case,
    /// but kept as a single persisted setting rather than reset on model
    /// switch, so it's remembered next time the user picks vieNeuOfflineV2
    /// again.
    @Published var vieNeuOfflineV2Voice: VieNeuOfflineV2Voice {
        didSet { UserDefaults.standard.set(vieNeuOfflineV2Voice.rawValue, forKey: Keys.vieNeuOfflineVoice) }
    }
    /// Which of the 14 bundled speaker presets `.vieNeuOfflineV3` decodes
    /// with (see VieNeuOfflineV3Voice) — same rationale as
    /// `vieNeuOfflineV2Voice` above, a separate persisted setting since V2
    /// and V3 have entirely different preset sets.
    @Published var vieNeuOfflineV3Voice: VieNeuOfflineV3Voice {
        didSet { UserDefaults.standard.set(vieNeuOfflineV3Voice.rawValue, forKey: Keys.vieNeuOfflineV3Voice) }
    }
    /// Which of the 9 built-in reference speakers `.gwenTTS` clones (see
    /// GwenTTSSpeaker) — irrelevant for every other `voice` case, kept as a
    /// single persisted setting like `vieNeuOfflineV2Voice` above.
    @Published var gwenTTSSpeaker: GwenTTSSpeaker {
        didSet { UserDefaults.standard.set(gwenTTSSpeaker.rawValue, forKey: Keys.gwenTTSSpeaker) }
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
    /// "Tự động dịch" in Cài đặt đọc — when on, a chapter whose detected
    /// language isn't Vietnamese displays translated without the user
    /// tapping the translate button. Applied immediately to whatever
    /// chapter is currently open (not just future chapter loads) so
    /// flipping this mid-read takes effect right away.
    @Published var autoTranslate: Bool {
        didSet {
            UserDefaults.standard.set(autoTranslate, forKey: Keys.autoTranslate)
            if translationSourceLanguage != nil { showingTranslation = autoTranslate }
        }
    }
    /// Which `TranslationEngine` actually performs the translation — see
    /// that protocol's doc comment. Switching mid-chapter re-attempts
    /// translation with the new engine for whatever chapter is currently
    /// open, same immediacy as `autoTranslate` above.
    @Published var translationEngineKind: TranslationEngineKind {
        didSet {
            UserDefaults.standard.set(translationEngineKind.rawValue, forKey: Keys.translationEngineKind)
            if translationSourceLanguage != nil {
                // Bumped so a still-in-flight fetch from the *previous*
                // engine can't race this one and overwrite its result —
                // see the `generation == translationGeneration` guards in
                // `performPendingTranslation`.
                translationGeneration += 1
                translatedSentences = nil
                Task { await performPendingTranslation() }
            }
        }
    }
    /// The language chapters get translated *into* — "Ngôn ngữ chính" in
    /// Cài đặt đọc. Defaults to the device's own iOS language (see
    /// `Self.systemDefaultPrimaryLanguageCode`) rather than a hardcoded
    /// "vi", so a reader whose iOS is set to e.g. English gets translations
    /// in English by default; still overridable in Settings. Plain
    /// `String` (a BCP-47 language code) rather than `Locale.Language`
    /// directly so it round-trips through `UserDefaults` — `primaryLanguage`
    /// below is the `Locale.Language` every call site actually wants.
    @Published var primaryLanguageCode: String {
        didSet {
            UserDefaults.standard.set(primaryLanguageCode, forKey: Keys.primaryLanguageCode)
            // Whether the *current* chapter needs translating, and what
            // source language it needs translating from, both depend on
            // this — fully re-derive rather than just re-fetching with the
            // stale target.
            if !sentences.isEmpty { evaluateTranslation(for: sentences) }
        }
    }
    var primaryLanguage: Locale.Language { Locale.Language(identifier: primaryLanguageCode) }

    private static func systemDefaultPrimaryLanguageCode() -> String {
        Locale.current.language.languageCode?.identifier ?? "vi"
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
    /// How many sentences ahead of the playhead to keep buffered — user-
    /// configurable (Cài đặt đọc, "Số câu tải trước"). A look-ahead
    /// *distance*, not a concurrency limit: `refillPreloadQueue()` queues
    /// every sentence up to `currentSentenceIndex + preloadAhead`, but only
    /// `maxConcurrentFetches` of those actually fetch at once (see there) —
    /// raising this to 20+ widens how far ahead buffering reaches without
    /// spraying 20 requests at the network/backend simultaneously. Keeps
    /// buffering whether or not playback is actually active (raising this
    /// immediately tops up to the new window), and survives a voice/speed
    /// change mid-chapter (see `voice`'s didSet).
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
    /// How many leading sentences `preloadedDisplayCount` should credit
    /// without a matching `preloadedIndices` entry — the chapter's start
    /// index on a fresh `beginChapter`, or the resume position on
    /// `prepareResume` (mirrors `preloadedThroughIndex`'s `startIndex - 1`/
    /// `sentenceIndex - 1` seeding, just as a count instead of an index).
    private var preloadedPrefixCount = 0
    /// Real cap on simultaneous in-flight fetches, independent of
    /// `preloadAhead` — that setting is how *far* ahead to buffer, this is
    /// how many of that window's fetches actually run at once. Keeping this
    /// small regardless of how large `preloadAhead` is set to (up to 20 in
    /// settings) avoids bursting the TTS backend with a wall of
    /// simultaneous requests; `refillPreloadQueue()` tops back up to this
    /// count every time a fetch completes, so the window still fills in
    /// full, just a few sentences at a time instead of all at once.
    private let maxConcurrentFetches = 3
    /// Extra attempts (beyond the first) for a single sentence's *online*
    /// TTS fetch, on top of the first try — offline synthesis (VieNeu/
    /// Piper) never goes through this, since a local failure isn't
    /// transient the way a dropped connection is. Added after GCP Cloud Run
    /// logs for tts-gpu showed `429 "no available instance"` responses and
    /// a client-visible "The network connection was lost" right when the
    /// server's own log had a multi-minute gap — the *same* sentence text
    /// then succeeded moments later on the app's next manual retry. A
    /// short, capped number of automatic retries here catches exactly that
    /// case without a user having to notice playback stopped and press Play
    /// again themselves. Capped (not unbounded) so a hard failure — wrong
    /// voice config, revoked auth — still surfaces promptly instead of
    /// silently stalling playback for a long chain of doomed retries.
    private let maxTTSFetchRetries = 2
    /// One fetch per sentence index, started either by the main play
    /// loop or by look-ahead prefetch — awaiting the same Task twice
    /// (once from prefetch, once from playback reaching that index) just
    /// returns the cached result, same idea as reader.js's
    /// `preloadCache[i]` Promise map.
    private var audioTasks: [Int: Task<Data, Error>] = [:]

    /// Cancels every in-flight fetch before dropping them — plain
    /// `audioTasks = [:]` (what every reset site here used to do) drops the
    /// dictionary's references but does NOT stop the underlying `Task`s:
    /// they keep running to completion in the background, burning CPU on
    /// synthesis for a chapter/generation nobody's waiting on anymore.
    /// Concretely, on-device Piper/VieNeu synthesis is CPU-bound, so a
    /// still-running orphaned fetch from a chapter the user already left
    /// competes for the same cores as the *new* chapter's own preload —
    /// observed as a single sentence taking 20+ seconds instead of a
    /// fraction of that. `markPreloaded`'s generation check already made
    /// orphaned results harmless once they eventually land, but nothing
    /// previously made them stop *promptly*.
    private func cancelInFlightFetches() {
        for task in audioTasks.values { task.cancel() }
        audioTasks = [:]
    }

    private var preloadedIndices: Set<Int> = []
    /// Actual fetched audio bytes, kept once a fetch completes — separate
    /// from `audioTasks` (in-flight only; an entry is removed from there
    /// the moment its Task resolves, freeing a `refillPreloadQueue()`
    /// concurrency slot) so playback can hand over already-preloaded audio
    /// immediately instead of re-fetching it.
    private var preloadedData: [Int: Data] = [:]
    /// In-memory prefetch cache for chapter *content* (title/text), separate
    /// from `DownloadManager`'s all-or-nothing full-book offline store —
    /// this is a small rolling window around whatever chapter is current, so
    /// swiping/tapping into a neighboring chapter that was already prefetched
    /// lands instantly instead of hitting the network cold. Trimmed by
    /// `trimChapterCache()`, cleared entirely on a book switch in `open()`.
    private var chapterCache: [Int: Chapter] = [:]
    /// Guards `prefetchChapter(index:)` against firing a second redundant
    /// fetch for an index that's already in flight — e.g. `loadChapter()`'s
    /// own neighbor-prefetch and a pager slot's own "not cached yet" fallback
    /// can both want the same index at once after a distant chapter jump.
    private var chapterCacheInFlight: Set<Int> = []
    /// Chapter index the next-chapter audio warm-up below is currently
    /// targeting — nil while idle. Set only once `beginNextChapterAudioWarmup`
    /// actually has content to work with and starts queuing fetches.
    private var nextChapterPreloadIndex: Int?
    /// The target chapter's sentence split, snapshotted at warm-up start.
    /// `beginChapter` re-checks this against `Self.sentenceSequence(for:)`
    /// for whatever chapter it's actually about to play before trusting
    /// `nextChapterPreloadedData` below — guards against `chapterCache`
    /// having been evicted/replaced with different content in the meantime.
    private var nextChapterSentences: [String] = []
    private var nextChapterAudioTasks: [Int: Task<Data, Error>] = [:]
    private var nextChapterPreloadedData: [Int: Data] = [:]
    /// Separate, smaller concurrency budget than `maxConcurrentFetches` —
    /// this work is purely speculative and must not meaningfully compete
    /// with the current chapter's own (playback-critical) preload fetches.
    private let nextChapterWarmupBudget = 2
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
        static let vieNeuOfflineVoice = "reader.vieNeuOfflineVoice"
        static let vieNeuOfflineV3Voice = "reader.vieNeuOfflineV3Voice"
        static let gwenTTSSpeaker = "reader.gwenTTSSpeaker"
        static let speed = "reader.speed"
        static let autoNext = "reader.autoNext"
        static let autoTranslate = "reader.autoTranslate"
        static let translationEngineKind = "reader.translationEngineKind"
        static let primaryLanguageCode = "reader.primaryLanguageCode"
        static let autoStopMinutes = "reader.autoStopMinutes"
        static let preloadAhead = "reader.preloadAhead"
    }

    private init() {
        voice = TTSVoice(rawValue: UserDefaults.standard.string(forKey: Keys.voice) ?? "") ?? .piperVi
        vieNeuOfflineV2Voice = VieNeuOfflineV2Voice(
            rawValue: UserDefaults.standard.string(forKey: Keys.vieNeuOfflineVoice) ?? ""
        ) ?? .thucDoan
        vieNeuOfflineV3Voice = VieNeuOfflineV3Voice(
            rawValue: UserDefaults.standard.string(forKey: Keys.vieNeuOfflineV3Voice) ?? ""
        ) ?? .doanTrang
        gwenTTSSpeaker = GwenTTSSpeaker(
            rawValue: UserDefaults.standard.string(forKey: Keys.gwenTTSSpeaker) ?? ""
        ) ?? .yenNhi
        let savedSpeed = UserDefaults.standard.double(forKey: Keys.speed)
        speed = savedSpeed > 0 ? savedSpeed : 1.0
        autoNextChapter = UserDefaults.standard.bool(forKey: Keys.autoNext)
        autoTranslate = UserDefaults.standard.bool(forKey: Keys.autoTranslate)
        translationEngineKind = TranslationEngineKind(
            rawValue: UserDefaults.standard.string(forKey: Keys.translationEngineKind) ?? ""
        ) ?? .apple
        primaryLanguageCode = UserDefaults.standard.string(forKey: Keys.primaryLanguageCode)
            ?? Self.systemDefaultPrimaryLanguageCode()
        autoStopMinutes = UserDefaults.standard.object(forKey: Keys.autoStopMinutes) as? Double ?? 30
        let savedPreloadAhead = UserDefaults.standard.object(forKey: Keys.preloadAhead) as? Int
        preloadAhead = savedPreloadAhead ?? 10
        player.onFinishedPlaying = { [weak self] in self?.advance() }
        // Lock-screen / Control-Center next/previous-track — wired once
        // here instead of per-ReaderView, since the player itself is now
        // owned for the app's whole lifetime, not just while some
        // ReaderView happens to be on screen.
        player.onNextChapter = { [weak self] in self?.skipChapter(by: 1) }
        player.onPreviousChapter = { [weak self] in self?.skipChapter(by: -1) }
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
        if self.book?.id != book.id {
            // A different book's neighbor-chapter content is irrelevant
            // (and would otherwise sit around unbounded in memory) —
            // trimChapterCache() alone wouldn't catch this since its window
            // is centered on chapterIndex, which is about to be overwritten
            // anyway.
            chapterCache = [:]
            chapterCacheInFlight = []
            cancelNextChapterWarmup()
        }
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

    /// Lock-screen / remote next-track & previous-track, and swipe-left/
    /// right chapter navigation in the reader — unlike goTo() (manual
    /// toolbar/chapter-list browsing, which lands on the chapter without
    /// playing), a skip only fires while there's an active listening
    /// session, so it should keep listening into the new chapter the same
    /// way auto-next does — a swipe shouldn't feel more aggressive about
    /// auto-starting audio than the equivalent button tap. Falls back to
    /// goTo()'s plain-navigation behavior when nothing was playing.
    func skipChapter(by delta: Int) {
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
            evaluateTranslation(for: Self.sentenceSequence(for: local))
            prepareSentencesForDisplay(local)
            resumeAutoPlayIfNeeded()
            prefetchNeighborChapters()
            trimChapterCache()
            return
        }

        if let cached = chapterCache[chapterIndex] {
            chapter = cached
            player.updateNowPlaying(bookTitle: book.title, chapterTitle: cached.title)
            evaluateTranslation(for: Self.sentenceSequence(for: cached))
            prepareSentencesForDisplay(cached)
            resumeAutoPlayIfNeeded()
            prefetchNeighborChapters()
            trimChapterCache()
            return
        }

        do {
            let fetched = try await APIClient.shared.fetchChapter(
                baseURL: SessionStore.baseURL, bookID: book.id, index: chapterIndex
            )
            guard generation == self.generation else { return }
            chapter = fetched
            player.updateNowPlaying(bookTitle: book.title, chapterTitle: fetched.title)
            evaluateTranslation(for: Self.sentenceSequence(for: fetched))
            prepareSentencesForDisplay(fetched)
            resumeAutoPlayIfNeeded()
            prefetchNeighborChapters()
            trimChapterCache()
        } catch {
            guard generation == self.generation else { return }
            loadError = "Không tải được nội dung chương"
            let detail = "\(book.title) — Chương \(chapterIndex + 1): \(error.localizedDescription)"
            surfaceError(loadError!, detail: detail)
            EventLogStore.shared.record(.error, "Không tải được nội dung chương", detail: detail)
        }
    }

    /// Read access for ReaderView's non-live pager slots (the neighboring
    /// chapters shown either side of whichever one is actually "current") —
    /// returns whatever `prefetchChapter`/`loadChapter` has already stashed
    /// in `chapterCache`, or nil if it hasn't landed yet.
    func cachedChapter(index: Int) -> Chapter? {
        chapterCache[index]
    }

    /// Fetches a single chapter's content into `chapterCache` without
    /// disturbing any currently-loaded/playing chapter — used both
    /// proactively (`prefetchNeighborChapters`) and reactively (a pager slot
    /// that renders before its neighbor has been prefetched yet). Checks the
    /// on-disk offline download first, same source `loadChapter` itself
    /// prefers, before hitting the network.
    func prefetchChapter(index: Int) async {
        guard let book, index >= 0, index < book.n else { return }
        guard chapterCache[index] == nil, !chapterCacheInFlight.contains(index) else { return }
        chapterCacheInFlight.insert(index)
        defer { chapterCacheInFlight.remove(index) }
        if let local = DownloadManager.shared.localChapter(bookID: book.id, index: index) {
            chapterCache[index] = local
            return
        }
        do {
            let fetched = try await APIClient.shared.fetchChapter(
                baseURL: SessionStore.baseURL, bookID: book.id, index: index
            )
            chapterCache[index] = fetched
        } catch {
            // Silent — this is speculative work; `loadChapter`'s own
            // network fetch (with its user-facing error surface) is what
            // actually matters if the user navigates here before this
            // retries on its own.
        }
    }

    /// Kicks off (fire-and-forget) prefetching for the chapters immediately
    /// before/after whatever just finished loading — called from both of
    /// `loadChapter`'s success paths so neighbors stay warm as the user
    /// reads/navigates forward or backward through a book.
    private func prefetchNeighborChapters() {
        Task { await prefetchChapter(index: chapterIndex - 1) }
        Task { await prefetchChapter(index: chapterIndex + 1) }
    }

    /// Bounds `chapterCache`'s memory footprint on long books — keeps only a
    /// small window around the current chapter, since anything further away
    /// is no longer a plausible swipe/tap target.
    private func trimChapterCache() {
        let keepRange = (chapterIndex - 2)...(chapterIndex + 2)
        chapterCache = chapterCache.filter { keepRange.contains($0.key) }
    }

    /// Populates `sentences`/highlight for whichever chapter just loaded —
    /// called unconditionally from every `loadChapter()` success path, not
    /// just the ones that end up auto-playing. The reader's tap-to-select
    /// rows (see `seek(to:)`) only exist when `sentences` is non-empty
    /// (ReaderView/ChapterPagerView fall back to plain, non-interactive
    /// text otherwise) — before this, that array was only ever filled by
    /// `beginChapter()` (pressing Play, or auto-continuing into the next
    /// chapter while already playing), so manually swiping to or picking a
    /// chapter *without* already playing left `sentences` empty and the
    /// whole select feature silently disappeared until Play was pressed.
    ///
    /// Only the very first chapter load of a session (`hasCheckedResume`
    /// false, reset in `open()`) considers the saved cross-launch resume
    /// position; every other chapter load (manual swipe/goTo, or
    /// auto-next) starts at sentence 0 — landing on a chapter should show
    /// its top, not silently re-jump to an unrelated old position.
    private func prepareSentencesForDisplay(_ chapter: Chapter) {
        var resumeIndex = 0
        if !hasCheckedResume {
            hasCheckedResume = true
            if let book, let saved = ProgressStore.shared.localProgress(bookID: book.id), saved.chapterIndex == chapterIndex {
                resumeIndex = saved.sentenceIndex
            }
        }
        prepareResume(sentenceIndex: resumeIndex)
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

    /// Tapping a sentence's text in ReaderView selects it as the read-aloud
    /// position — highlights it and primes preloading from there — WITHOUT
    /// starting audio. Selecting is a "point at where to read from" action,
    /// distinct from actually pressing Play; only `togglePlayback()`
    /// starts/resumes sound. Reuses `prepareResume`'s exact preload-window
    /// seeding for the tapped index, same priming a fresh cold-open resume
    /// gets before the user's first Play press.
    ///
    /// Always logs on entry (before the range guard) — reported symptom is
    /// "tapping a sentence stops doing anything after a while," which could
    /// mean either the tap gesture itself stops reaching this method (a
    /// SwiftUI/UIKit gesture-recognition conflict — the ChapterPagerView doc
    /// comment covers the nested UIPageViewController/ScrollView touch
    /// handling this sits inside) or that it's reached but silently guarded
    /// out. If a future report shows no "Bấm chọn câu" entry at all for a
    /// tap the user remembers making, that's the former; if the entry is
    /// there but nothing happened, it's the latter — ActionHistoryView is
    /// how to tell the two apart without a live debugger attached.
    func seek(to index: Int) {
        let detail = book.map { "\($0.title) — Chương \(chapterIndex + 1), câu \(index + 1)" }
        EventLogStore.shared.record(.navigation, "Bấm chọn câu \(index + 1)", detail: detail)
        guard sentences.indices.contains(index) else {
            EventLogStore.shared.record(
                .error, "Bấm chọn câu ngoài phạm vi",
                detail: "\(detail ?? "") — chỉ có \(sentences.count) câu"
            )
            return
        }
        stop()
        prepareResume(sentenceIndex: index)
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
        cancelInFlightFetches()
        preloadedIndices = []
        preloadedData = [:]
        preloadedThroughIndex = -1
        preloadedPrefixCount = 0
        preloadedDisplayCount = 0
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
        // Same "abandoning this chapter for a different one" rationale as
        // above — without this, a slow in-flight translation for the old
        // chapter could still land and get shown against the new one.
        translationSourceLanguage = nil
        translatedSentences = nil
        isTranslating = false
        showingTranslation = false
        translationErrorMessage = nil
        translationGeneration += 1
    }

    /// The text actually driving TTS synthesis right now — translated
    /// sentences once translation is showing AND has actually landed, the
    /// original `sentences` otherwise. Kept separate from what
    /// `ChapterPagerView` renders (which falls back to `sentences` the same
    /// way while translation is still pending) only in spirit — the real
    /// reason this exists is `activeSentencesReady` below: synthesis must
    /// never read from here until that's true, or it fetches audio for text
    /// that's about to be replaced.
    private var activeSentenceSource: [String] {
        showingTranslation ? (translatedSentences ?? sentences) : sentences
    }

    /// False exactly while playback *should* be reading translated text but
    /// that translation hasn't landed yet — gates `refillPreloadQueue()`/
    /// `playCurrentSentence` so audio is never synthesized against text
    /// that's about to be swapped out once translation lands (which would
    /// mean re-fetching everything anyway, and briefly reading the wrong
    /// language through a Vietnamese voice in the meantime).
    private var activeSentencesReady: Bool {
        !showingTranslation || translatedSentences != nil
    }

    /// Picks the `TranslationEngine` `translationEngineKind` currently
    /// selects — `nil` only for `.apple` on iOS < 18, where
    /// `AppleTranslationEngine` itself doesn't exist (the type is gated
    /// `@available(iOS 18.0, *)`). `.opusMT` (`OpusMTTranslationEngine`)
    /// has no such restriction, so it's always available.
    private var currentTranslationEngine: TranslationEngine? {
        switch translationEngineKind {
        case .apple:
            if #available(iOS 18.0, *) { return AppleTranslationEngine.shared } else { return nil }
        case .opusMT:
            return OpusMTTranslationEngine.shared
        }
    }

    /// Detects `sentences`' dominant language and, if it isn't already
    /// `primaryLanguage`, sets `translationSourceLanguage` (which is what
    /// the toolbar button's visibility keys off) and kicks off a
    /// background translation attempt — always, regardless of
    /// `showingTranslation`/`autoTranslate` (the setting only controls
    /// whether the result is *shown* by default, not whether it's fetched
    /// — see `showingTranslation`'s doc comment). Takes the sentence array
    /// as a parameter rather than reading `self.sentences` so callers in
    /// `loadChapter()` can resolve `showingTranslation` *before* calling
    /// `prepareSentencesForDisplay()` — that matters because
    /// `prepareSentencesForDisplay` → `prepareResume` kicks off preload
    /// immediately, and `refillPreloadQueue()` gates on `showingTranslation`
    /// (via `activeSentencesReady`) being already resolved; getting this
    /// backwards let a chapter needing translation briefly preload
    /// original-language audio before this had a chance to run.
    private func evaluateTranslation(for sentences: [String]) {
        translationGeneration += 1
        translatedSentences = nil
        isTranslating = false
        translationErrorMessage = nil
        guard !sentences.isEmpty else {
            translationSourceLanguage = nil
            showingTranslation = false
            return
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sentences.joined(separator: "\n"))
        let dominant = recognizer.dominantLanguage
        guard let dominant, dominant.rawValue != primaryLanguageCode else {
            translationSourceLanguage = nil
            showingTranslation = false
            // Logged even in the "no translation needed" branch — a chapter
            // that unexpectedly *did* need translation but landed here
            // instead (NLLanguageRecognizer misdetecting, or returning nil
            // outright on ambiguous/short text) is exactly the kind of
            // report ("auto-translate sometimes doesn't work") this is
            // meant to make diagnosable after the fact instead of only
            // reproducible live.
            let detail = book.map { "\($0.title) — Chương \(chapterIndex + 1)" } ?? ""
            EventLogStore.shared.record(
                .translation, "Không cần dịch (đã là ngôn ngữ chính)",
                detail: "\(detail) — phát hiện: \(dominant?.rawValue ?? "không xác định"), ngôn ngữ chính: \(primaryLanguageCode)"
            )
            return
        }
        translationSourceLanguage = Locale.Language(identifier: dominant.rawValue)
        showingTranslation = autoTranslate
        EventLogStore.shared.record(
            .translation, "Phát hiện chương cần dịch",
            detail: "\(book.map { "\($0.title) — Chương \(chapterIndex + 1)" } ?? "") — phát hiện: \(dominant.rawValue)"
        )
        Task { await performPendingTranslation() }
    }

    /// The toolbar translate button's action — switches the reader between
    /// original and translated text for the current chapter. A no-op if the
    /// chapter doesn't need translation (button is hidden in that case
    /// anyway); doesn't block on `translatedSentences` being ready — the
    /// reader falls back to showing the original text until it lands.
    func toggleTranslationDisplay() {
        guard translationSourceLanguage != nil else { return }
        showingTranslation.toggle()
        if showingTranslation, translatedSentences == nil, !isTranslating {
            // Defensive retry — the background fetch already kicked off
            // from `evaluateTranslation()` should normally have this
            // covered, but if it somehow never ran (or failed and reverted
            // `showingTranslation` before the user re-enabled it), a manual
            // tap should still be able to start one rather than silently
            // showing nothing.
            Task { await performPendingTranslation() }
        }
        invalidateAudioForActiveSentenceSourceChange()
    }

    /// Whatever's already fetched/buffered/playing was synthesized against
    /// whichever text source (original vs. translated) was active *before*
    /// this toggle — must be discarded and resynthesized against the new
    /// one starting at the current position, since (unlike a voice/speed
    /// change — see `voice`'s didSet, which deliberately keeps old buffered
    /// audio) the actual words being read just changed, not just how
    /// they're voiced. Playing old-language audio through a Vietnamese
    /// voice would come out as mispronounced gibberish. No-ops if nothing
    /// has actually started playing yet (`active`/`isPlaying` both false) —
    /// `refillPreloadQueue()`'s own `activeSentencesReady` gate already
    /// covers that case cleanly without needing a stop/restart.
    private func invalidateAudioForActiveSentenceSourceChange() {
        guard active || isPlaying else { return }
        let wasPlaying = isPlaying
        let resumeIndex = currentSentenceIndex
        stop()
        prepareResume(sentenceIndex: resumeIndex)
        if wasPlaying { start() }
    }

    /// Runs the actual translation for the current chapter's `sentences`
    /// through whichever engine `translationEngineKind` currently selects
    /// (see `currentTranslationEngine`) — this controller never talks to
    /// `TranslationSession`/ONNX Runtime/etc. directly, only the
    /// `TranslationEngine` protocol, so swapping engines never touches this
    /// method.
    func performPendingTranslation() async {
        guard let source = translationSourceLanguage, !sentences.isEmpty else { return }
        let target = primaryLanguage
        let logDetail = book.map { "\($0.title) — Chương \(chapterIndex + 1) (\(source.minimalIdentifier)→\(target.minimalIdentifier))" } ?? ""
        guard let engine = currentTranslationEngine, engine.canTranslate(from: source, to: target) else {
            translationErrorMessage = "Dịch không khả dụng trên thiết bị này"
            showingTranslation = false
            EventLogStore.shared.record(.translation, "Không có công cụ dịch khả dụng", detail: logDetail)
            return
        }
        let generation = translationGeneration
        let textsToTranslate = sentences
        isTranslating = true
        translationProgress = nil
        translationErrorMessage = nil
        EventLogStore.shared.record(.translation, "Bắt đầu dịch chương", detail: "\(logDetail) — \(engine.displayName), \(textsToTranslate.count) câu")
        let startedAt = Date()
        // Polls the engine's own progress while the translate call below is
        // in flight — see `TranslationEngine.translationProgress`'s doc
        // comment for why this is polling rather than a pushed callback.
        let progressPoller = Task {
            while !Task.isCancelled {
                let progress = await engine.translationProgress
                guard generation == translationGeneration else { return }
                translationProgress = progress
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { progressPoller.cancel() }
        do {
            let translated = try await engine.translate(texts: textsToTranslate, source: source, target: target)
            guard generation == translationGeneration else { return }
            translatedSentences = translated
            isTranslating = false
            translationProgress = nil
            // Preload may have been sitting idle this whole time, gated by
            // `activeSentencesReady` in `refillPreloadQueue()` — now that
            // translation has actually landed, give it a nudge to resume.
            refillPreloadQueue()
            EventLogStore.shared.record(
                .translation, "Dịch chương xong",
                detail: "\(logDetail) — \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s"
            )
        } catch {
            guard generation == translationGeneration else { return }
            translationErrorMessage = "Không dịch được nội dung chương"
            isTranslating = false
            translationProgress = nil
            // Translation isn't coming — fall back to showing/reading the
            // original rather than leaving `showingTranslation` stuck true
            // with no translated text ever arriving, which would otherwise
            // leave `activeSentencesReady` false forever and stall playback
            // until `waitForActiveSentencesReady`'s deadline.
            showingTranslation = false
            EventLogStore.shared.record(
                .error, "Không dịch được nội dung chương",
                detail: "\(logDetail) — \(error.localizedDescription)"
            )
        }
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
        preloadedPrefixCount = sentenceIndex
        preloadedDisplayCount = sentenceIndex
        preloadCursor = sentenceIndex
        cancelInFlightFetches()
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
            // If the just-finished chapter's warm-up (see
            // `beginNextChapterAudioWarmup`) already speculatively
            // synthesized this exact chapter's opening sentences, seed from
            // that instead of starting the preload window from empty — the
            // whole point of the warm-up. The content-equality check (not
            // just an index match) guards against `chapterCache` having
            // been evicted/replaced with different content in the meantime.
            // `nextChapterPreloadedData` is always synthesized from the
            // *original* text (see `makeNextChapterWarmupTask`/
            // `nextChapterSentences`, both computed straight off the raw
            // chapter, with no translation awareness) — `!showingTranslation`
            // guards against seeding wrong-language audio into a chapter
            // that's actually supposed to read translated text; falling
            // through to the plain-reset branch below re-fetches correctly
            // via `activeSentenceSource` instead.
            if !showingTranslation, chapterIndex == nextChapterPreloadIndex, nextChapterSentences == sentences, !nextChapterPreloadedData.isEmpty {
                preloadedData = nextChapterPreloadedData
                preloadedIndices = Set(nextChapterPreloadedData.keys)
                preloadedPrefixCount = startIndex
                var next = startIndex
                while preloadedIndices.contains(next) { next += 1 }
                preloadedThroughIndex = next - 1
                preloadedDisplayCount = preloadedPrefixCount + preloadedIndices.filter { $0 >= startIndex }.count
                preloadCursor = max(startIndex, next)
                cancelInFlightFetches()
            } else {
                preloadedIndices = []
                preloadedData = [:]
                preloadedThroughIndex = startIndex - 1
                preloadedPrefixCount = startIndex
                preloadedDisplayCount = startIndex
                preloadCursor = startIndex
                cancelInFlightFetches()
            }
            cancelNextChapterWarmup()
            generation += 1
        }
        active = true
        let generation = self.generation
        refillPreloadQueue()
        // Show the loading spinner across the buffer wait below, not just
        // across the single-sentence fetch inside playCurrentSentence —
        // otherwise pressing Play on a cold chapter (no cache yet) shows no
        // feedback at all until the whole buffer wait finishes.
        isLoadingAudio = true
        Task {
            await waitForInitialBuffer(startIndex: startIndex, generation: generation)
            await playCurrentSentence(generation: generation)
        }
    }

    /// Waits for the preload window to actually fill up to `preloadAhead`
    /// sentences (or the end of the chapter, whichever is sooner) before
    /// the first sentence starts playing — so a cold start (no cache yet)
    /// buffers ahead first instead of playing sentence 1 immediately and
    /// then catching up to the fetch queue sentence by sentence, which is
    /// what made playback stutter right after pressing Play on a fresh
    /// chapter. If preloading already had a head start (see
    /// `prepareResume`), this resolves immediately since the target is
    /// already met.
    ///
    /// Bounded by a timeout so a single stuck fetch (e.g. a preload task
    /// whose offline synthesis is still contending for CPU with an
    /// orphaned fetch from a chapter just left — see
    /// `cancelInFlightFetches()` — or, for the online path, one that's
    /// exhausted `fetchOnlineAudioWithRetry`'s retries and failed for good)
    /// can't hang playback forever; past that, it just starts with
    /// whatever is ready, same as before this existed. 60s errs generous:
    /// on-device CPU-bound synthesis (Piper/VieNeu) for a full 20-sentence
    /// window has no hard latency bound, and this is a backstop against a
    /// stuck fetch, not the common-case wait.
    private func waitForInitialBuffer(startIndex: Int, generation: Int) async {
        guard sentences.indices.contains(startIndex) else { return }
        let boundary = min(startIndex + preloadAhead - 1, sentences.count - 1)
        let deadline = Date().addingTimeInterval(60)
        while preloadedThroughIndex < boundary {
            guard active, generation == self.generation, Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Polls until `activeSentencesReady` (translation either isn't wanted,
    /// or has landed) or a generous deadline passes — translation is a
    /// single on-device call over already-loaded text, normally resolving
    /// in well under a second, so this is a backstop against a genuinely
    /// stuck case, not the common-case wait. `performPendingTranslation`'s
    /// catch reverts `showingTranslation` to false on an outright failure
    /// (making `activeSentencesReady` true immediately), so this deadline
    /// only ever matters if translation neither succeeds nor fails —
    /// same shape/rationale as `waitForInitialBuffer` above.
    private func waitForActiveSentencesReady(generation: Int) async {
        let deadline = Date().addingTimeInterval(30)
        while !activeSentencesReady {
            guard active, generation == self.generation, Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
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
        // isLoadingAudio may already be true from beginChapter's initial-
        // buffer wait (see waitForInitialBuffer) — reset it here too, since
        // this guard can now be the first thing to see a stop()/chapter
        // switch that happened *during* that wait, and stop() itself
        // doesn't touch isLoadingAudio.
        guard active, generation == self.generation else {
            isLoadingAudio = false
            return
        }
        guard currentSentenceIndex < sentences.count else {
            // Ran out of sentences normally — end of chapter. Sleep timer
            // is deliberately left running here: resumeAutoPlayIfNeeded may
            // continue straight into the next chapter, and only
            // handleChapterFinished knows whether that's actually going to
            // happen (see abandonSleepTimerIfIdle()).
            active = false
            isPlaying = false
            isLoadingAudio = false
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
        // Never fetch/play against text that's about to be swapped out once
        // a pending translation lands — see `activeSentencesReady`. Usually
        // resolves in well under a second (translation kicks off as soon as
        // the chapter loads, long before playback catches up to it); falls
        // through regardless once the deadline passes, or immediately once
        // `performPendingTranslation`'s catch reverts `showingTranslation`
        // on an outright failure.
        await waitForActiveSentencesReady(generation: generation)
        guard generation == self.generation else {
            isLoadingAudio = false
            return
        }
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
            let detail = "\(playbackDetail() ?? "") — \(error.localizedDescription)"
            surfaceError("Không tạo được audio", detail: detail)
            active = false
            isPlaying = false
            updateNowPlayingProgress()
            clearAutoStopState()
            EventLogStore.shared.record(.error, "Không tạo được audio", detail: detail)
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
        // While a translation this chapter should be reading is still
        // pending, don't fetch anything at all — see `activeSentencesReady`.
        // `performPendingTranslation`'s success path calls this again once
        // it lands to resume.
        guard activeSentencesReady, !sentences.isEmpty else { return }
        let boundary = min(currentSentenceIndex + preloadAhead, sentences.count - 1)
        while preloadCursor <= boundary, audioTasks.count < maxConcurrentFetches {
            preload(index: preloadCursor)
            preloadCursor += 1
        }
        // Only once the current chapter's own window is fully *fetched*
        // (not merely queued) — triggering while its tail is still
        // in-flight would have this compete for CPU/network with exactly
        // the fetches `waitForInitialBuffer` may be blocking on.
        if preloadedThroughIndex >= boundary {
            beginNextChapterAudioWarmup()
        }
    }

    /// Speculatively pre-synthesizes the next chapter's audio, up to the same
    /// `preloadAhead` depth as the current chapter's own window, once that
    /// window is fully fetched (see the call site above) — so continuing
    /// playback across a chapter boundary (auto-next, remote/swipe skip) is
    /// just as buffered as the current chapter was, instead of restarting
    /// preloading from zero. Forward direction only, by design — there's no
    /// equivalent warm-up for the previous chapter.
    private func beginNextChapterAudioWarmup() {
        guard let book, chapterIndex < book.n - 1 else { return }
        let targetIndex = chapterIndex + 1
        if nextChapterPreloadIndex == targetIndex, !nextChapterSentences.isEmpty {
            refillNextChapterWarmup()
            return
        }
        guard let nextChapter = cachedChapter(index: targetIndex) else {
            // Not prefetched yet — kick it off and retry once it lands.
            // No-ops harmlessly if `loadChapter`'s own neighbor-prefetch is
            // already in flight for the same index (`chapterCacheInFlight`).
            Task {
                await prefetchChapter(index: targetIndex)
                guard self.chapterIndex + 1 == targetIndex else { return }
                self.beginNextChapterAudioWarmup()
            }
            return
        }
        cancelNextChapterWarmup()
        nextChapterPreloadIndex = targetIndex
        nextChapterSentences = Self.sentenceSequence(for: nextChapter)
        refillNextChapterWarmup()
    }

    private func refillNextChapterWarmup() {
        guard !nextChapterSentences.isEmpty else { return }
        // Mirrors `preloadAhead` rather than a small fixed count — once the
        // current chapter's own window is fully buffered (the trigger for
        // this warm-up in the first place), the next chapter should end up
        // buffered just as deep, not just a token few sentences.
        let budget = min(preloadAhead, nextChapterSentences.count)
        var index = 0
        while index < budget, nextChapterAudioTasks.count < nextChapterWarmupBudget {
            if nextChapterPreloadedData[index] == nil, nextChapterAudioTasks[index] == nil {
                nextChapterAudioTasks[index] = makeNextChapterWarmupTask(index: index)
            }
            index += 1
        }
    }

    private func makeNextChapterWarmupTask(index: Int) -> Task<Data, Error> {
        let text = nextChapterSentences[index]
        let voice = self.voice
        let vieNeuOfflineV2Voice = self.vieNeuOfflineV2Voice
        let vieNeuOfflineV3Voice = self.vieNeuOfflineV3Voice
        let gwenTTSSpeaker = self.gwenTTSSpeaker
        let speed = self.speed
        let baseURL = SessionStore.baseURL
        let isConnected = NetworkMonitor.shared.isConnected
        let isLoggedIn = SessionStore.shared.isLoggedIn
        let targetIndex = nextChapterPreloadIndex
        // Lower priority than the current chapter's own preload fetches
        // (plain `Task { }` in `makeFetchTask`) — under CPU contention from
        // on-device Piper/VieNeu synthesis, the scheduler should favor
        // whatever's actually about to play over this speculative work.
        return Task(priority: .utility) {
            let data = try await self.synthesizeAudio(
                text: text, voice: voice, vieNeuOfflineV2Voice: vieNeuOfflineV2Voice,
                vieNeuOfflineV3Voice: vieNeuOfflineV3Voice, gwenTTSSpeaker: gwenTTSSpeaker,
                speed: speed, baseURL: baseURL, isConnected: isConnected, isLoggedIn: isLoggedIn
            )
            self.markNextChapterWarmed(index: index, data: data, targetIndex: targetIndex)
            return data
        }
    }

    private func markNextChapterWarmed(index: Int, data: Data, targetIndex: Int?) {
        guard targetIndex == nextChapterPreloadIndex else { return }
        nextChapterPreloadedData[index] = data
        nextChapterAudioTasks[index] = nil
        refillNextChapterWarmup()
    }

    /// Cancels any in-flight warm-up fetches before dropping them — same
    /// rationale as `cancelInFlightFetches()` — and clears the warm cache.
    /// Called both when the warm-up's target chapter changes (superseded by
    /// a different "next chapter") and once `beginChapter` has consumed it.
    private func cancelNextChapterWarmup() {
        for task in nextChapterAudioTasks.values { task.cancel() }
        nextChapterAudioTasks = [:]
        nextChapterPreloadedData = [:]
        nextChapterPreloadIndex = nil
        nextChapterSentences = []
    }

    private func makeFetchTask(index: Int) -> Task<Data, Error> {
        // Reads whichever text is actually meant to be spoken right now —
        // see `activeSentenceSource`. Callers (`preload`/`fetchTask`) only
        // ever reach here once `refillPreloadQueue`/`playCurrentSentence`
        // have confirmed `activeSentencesReady`, so this is never mid-flight
        // against text that's about to change out from under it.
        let text = activeSentenceSource[index]
        let voice = self.voice
        let vieNeuOfflineV2Voice = self.vieNeuOfflineV2Voice
        let vieNeuOfflineV3Voice = self.vieNeuOfflineV3Voice
        let gwenTTSSpeaker = self.gwenTTSSpeaker
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
            let data = try await self.synthesizeAudio(
                text: text, voice: voice, vieNeuOfflineV2Voice: vieNeuOfflineV2Voice,
                vieNeuOfflineV3Voice: vieNeuOfflineV3Voice, gwenTTSSpeaker: gwenTTSSpeaker,
                speed: speed, baseURL: baseURL, isConnected: isConnected, isLoggedIn: isLoggedIn
            )
            self.markPreloaded(index: index, data: data, generation: generation)
            return data
        }
    }

    /// Pure synthesis given an explicit voice/speed/connectivity snapshot —
    /// no side effects on `audioTasks`/`preloadedData`/`generation`, so both
    /// the current chapter's own fetch (`makeFetchTask`, via `markPreloaded`
    /// afterward) and the next-chapter audio warm-up
    /// (`beginNextChapterAudioWarmup`, via its own separate cache) can share
    /// this exact online/offline branching + retry logic without
    /// duplicating it.
    private func synthesizeAudio(
        text: String,
        voice: TTSVoice,
        vieNeuOfflineV2Voice: VieNeuOfflineV2Voice,
        vieNeuOfflineV3Voice: VieNeuOfflineV3Voice,
        gwenTTSSpeaker: GwenTTSSpeaker,
        speed: Double,
        baseURL: URL,
        isConnected: Bool,
        isLoggedIn: Bool
    ) async throws -> Data {
        if voice == .vieNeuOfflineV2 {
            // No network round trip — runs the bundled GGUF backbone +
            // VieNeu-Codec ONNX decoder right here on-device (see
            // VieNeuOfflineV2TTSService).
            return try await VieNeuOfflineV2TTSService.shared.synthesize(
                text: text, speed: speed, voice: vieNeuOfflineV2Voice
            )
        } else if voice == .vieNeuOfflineV3 {
            // No network round trip — runs the actual v3-Turbo backbone +
            // MOSS codec through ONNX Runtime right here on-device (see
            // VieNeuOfflineV3TTSService).
            return try await VieNeuOfflineV3TTSService.shared.synthesize(
                text: text, speed: speed, voice: vieNeuOfflineV3Voice
            )
        } else if voice.isOffline || !isConnected || !isLoggedIn {
            // No network round trip — runs the bundled ONNX model right
            // here on-device (see PiperOfflineTTSService).
            return try await PiperOfflineTTSService.shared.synthesize(text: text, speed: speed)
        } else {
            return try await fetchOnlineAudioWithRetry(
                baseURL: baseURL, text: text, voice: voice, speed: speed, gwenSpeaker: gwenTTSSpeaker
            )
        }
    }

    /// Retries a failed *online* TTS fetch up to `maxTTSFetchRetries` more
    /// times (see its doc comment), but only for errors that look transient
    /// — a dropped/timed-out connection, or the server queue rejecting the
    /// request (429) / a backend hiccup (5xx). Retrying `.notAuthenticated`
    /// or a malformed response would just burn through the retry budget on
    /// a failure that can't self-resolve, delaying the moment the real
    /// error reaches the user. Linear backoff (1s, then 2s) rather than
    /// immediate retry, giving the Cloud Run GPU fleet a moment to free up
    /// an instance instead of hammering it again right away.
    private func fetchOnlineAudioWithRetry(
        baseURL: URL, text: String, voice: TTSVoice, speed: Double, gwenSpeaker: GwenTTSSpeaker?
    ) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await APIClient.shared.synthesize(
                    baseURL: baseURL, text: text, voice: voice, speed: speed, gwenSpeaker: gwenSpeaker
                )
            } catch {
                guard attempt < maxTTSFetchRetries, Self.isRetryableTTSError(error) else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    private static func isRetryableTTSError(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .httpStatus(let code): return code == 429 || (500...599).contains(code)
            case .invalidResponse: return true
            case .notAuthenticated: return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet, .dnsLookupFailed, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Stores the fetched audio, removes it from `audioTasks` (it's done —
    /// no longer "in flight"), advances the contiguous
    /// `preloadedThroughIndex` frontier and the order-independent
    /// `preloadedDisplayCount`, and calls `refillPreloadQueue()` in case the
    /// window has since slid forward (currentSentenceIndex advanced) enough
    /// to include a new sentence.
    private func markPreloaded(index: Int, data: Data, generation: Int) {
        guard generation == self.generation else { return }
        preloadedData[index] = data
        audioTasks[index] = nil
        preloadedIndices.insert(index)
        preloadedDisplayCount = preloadedPrefixCount + preloadedIndices.count
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
