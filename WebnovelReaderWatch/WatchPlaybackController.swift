import Foundation
import Core

/// watchOS's own playback controller — online TTS only (see
/// `WebnovelReaderOnlineSynthesizer`, from Core), no offline-engine
/// dispatch/translation (neither is available on watchOS — no vendored
/// xcframework slice for the former, no watchOS onnxruntime product or
/// Translation-framework support for the latter). Otherwise aims for real
/// feature parity with the iPhone controller's playback mechanics: voice
/// picker, sleep timer, auto-advance, look-ahead preload, downloaded-book
/// awareness, remote-command (Now Playing) wiring — just without
/// `ReaderPlaybackController`'s own extra ~1000 lines of chapter-list
/// UI-adjacent state, translation streaming, and offline-voice bookkeeping
/// this small watch UI doesn't expose.
@MainActor
final class WatchPlaybackController: ObservableObject {
    static let shared = WatchPlaybackController()

    @Published private(set) var book: Book?
    @Published private(set) var chapterIndex = 0
    @Published private(set) var chapter: Chapter?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    @Published var voice: TTSVoice {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: Keys.voice) }
    }
    @Published var gwenTTSSpeaker: GwenTTSSpeaker {
        didSet { UserDefaults.standard.set(gwenTTSSpeaker.rawValue, forKey: Keys.gwenTTSSpeaker) }
    }
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: Keys.speed) }
    }
    @Published var autoNextChapter: Bool {
        didSet { UserDefaults.standard.set(autoNextChapter, forKey: Keys.autoNext) }
    }
    /// Minutes until playback auto-pauses; 0 = off. Smaller default than
    /// the iPhone app's (5 vs 10) — a listening session started on the
    /// wrist skews shorter in practice, and it's one Picker tap to raise.
    @Published var preloadAhead: Int {
        didSet { UserDefaults.standard.set(preloadAhead, forKey: Keys.preloadAhead) }
    }
    @Published var autoStopMinutes: Double {
        didSet {
            UserDefaults.standard.set(autoStopMinutes, forKey: Keys.autoStopMinutes)
            scheduleAutoStop()
        }
    }
    @Published private(set) var sleepTimerDeadline: Date?

    /// The 4 `TTSVoice` cases `WebnovelReaderOnlineSynthesizer` can
    /// actually serve — the 3 offline cases need engines this target
    /// doesn't link, so they're not offered in the picker at all (never a
    /// silent fallback the user has to notice).
    static let availableVoices: [TTSVoice] = [.piperVi, .googleTTS, .vieNeu, .gwenTTS]

    private let synthesizer: TTSSynthesizing = WebnovelReaderOnlineSynthesizer()
    let player = AudioPlaybackService()

    private var sentences: [String] = []
    private var sentenceIndex = 0
    /// Look-ahead cache, keyed by sentence index — filled by
    /// `refillPreloadQueue()` up to `preloadAhead` sentences beyond
    /// whichever one is currently playing. Deliberately a simpler
    /// sequential top-up than `ReaderPlaybackController`'s own windowed
    /// concurrent-fetch queue (that machinery exists to keep a long
    /// look-ahead window full under real-time playback pressure across a
    /// big preload budget) — Watch's use case is the same "don't audibly
    /// gap between sentences" goal at a much smaller budget, so a plain
    /// sequential fetch-ahead gets the same user-facing benefit without
    /// porting that whole subsystem.
    private var preloadedData: [Int: Data] = [:]
    private var preloadTask: Task<Void, Never>?
    /// Bumped on every `open`/`skipChapter` so an in-flight synthesis
    /// fetch can't land audio for a chapter/sentence that's no longer
    /// current.
    private var generation = 0
    private var sleepTimerTask: Task<Void, Never>?
    /// False right after a sentence's audio successfully starts playing —
    /// `togglePlayPause()` uses this to tell "resume the clip that's just
    /// paused" (call `player.resume()`) apart from "nothing loaded for the
    /// current sentence yet" (synthesize/pull-from-cache first). Reset to
    /// true whenever the open chapter/sentence changes out from under
    /// whatever was loaded.
    private var needsFreshSynthesis = true
    /// See `ReaderPlaybackController.sleepTimerExpired`'s doc comment —
    /// same race: without this, a sentence fetch already in flight when
    /// the timer fires can call `player.play()` moments later and silently
    /// undo the auto-pause.
    private var sleepTimerExpired = false

    private enum Keys {
        static let voice = "watch.reader.voice"
        static let gwenTTSSpeaker = "watch.reader.gwenTTSSpeaker"
        static let speed = "watch.reader.speed"
        static let autoNext = "watch.reader.autoNext"
        static let preloadAhead = "watch.reader.preloadAhead"
        static let autoStopMinutes = "watch.reader.autoStopMinutes"
    }

    private init() {
        voice = TTSVoice(rawValue: UserDefaults.standard.string(forKey: Keys.voice) ?? "") ?? .piperVi
        gwenTTSSpeaker = GwenTTSSpeaker(rawValue: UserDefaults.standard.string(forKey: Keys.gwenTTSSpeaker) ?? "") ?? .yenNhi
        let savedSpeed = UserDefaults.standard.double(forKey: Keys.speed)
        speed = savedSpeed > 0 ? savedSpeed : 1.0
        autoNextChapter = UserDefaults.standard.object(forKey: Keys.autoNext) as? Bool ?? true
        let savedPreload = UserDefaults.standard.object(forKey: Keys.preloadAhead) as? Int
        preloadAhead = savedPreload ?? 5
        autoStopMinutes = UserDefaults.standard.object(forKey: Keys.autoStopMinutes) as? Double ?? 0

        player.onFinishedPlaying = { [weak self] in
            Task { @MainActor in self?.advanceSentence() }
        }
        player.onNextChapter = { [weak self] in Task { @MainActor in await self?.skipChapter(by: 1) } }
        player.onPreviousChapter = { [weak self] in Task { @MainActor in await self?.skipChapter(by: -1) } }
        player.onPlayCommand = { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.togglePlayPause()
        }
        player.onPauseCommand = { [weak self] in
            guard let self, self.isPlaying else { return }
            self.togglePlayPause()
        }
    }

    func open(book: Book, chapterIndex: Int) async {
        self.book = book
        self.chapterIndex = chapterIndex
        await loadChapter()
    }

    func skipChapter(by delta: Int) async {
        guard let book else { return }
        let target = chapterIndex + delta
        guard target >= 0, target < book.n else { return }
        chapterIndex = target
        await loadChapter()
    }

    private func loadChapter() async {
        guard let book else { return }
        generation += 1
        let myGeneration = generation
        preloadTask?.cancel()
        preloadedData = [:]
        isLoading = true
        errorMessage = nil
        player.stop()
        isPlaying = false
        do {
            let fetched: Chapter
            if let local = DownloadManager.shared.localChapter(bookID: book.id, index: chapterIndex) {
                fetched = local
            } else {
                fetched = try await APIClient.shared.fetchChapter(baseURL: SessionStore.baseURL, bookID: book.id, index: chapterIndex)
            }
            guard myGeneration == generation else { return }
            chapter = fetched
            sentences = [fetched.title] + TextSegmentation.sentences(from: fetched.text)
            sentenceIndex = 0
            needsFreshSynthesis = true
            isLoading = false
        } catch {
            guard myGeneration == generation else { return }
            errorMessage = "Không tải được chương — kiểm tra kết nối mạng"
            isLoading = false
        }
    }

    func togglePlayPause() {
        guard !sentences.isEmpty else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            isPlaying = true
            sleepTimerExpired = false
            if needsFreshSynthesis {
                Task { await playCurrentSentence() }
            } else {
                player.resume()
                player.updateNowPlaying(bookTitle: book?.title ?? "", chapterTitle: chapter?.title ?? "")
            }
        }
    }

    private func advanceSentence() {
        guard isPlaying else { return }
        sentenceIndex += 1
        needsFreshSynthesis = true
        if sentenceIndex < sentences.count {
            Task { await playCurrentSentence() }
        } else if autoNextChapter {
            Task {
                await skipChapter(by: 1)
                guard !sentences.isEmpty else { return }
                await playCurrentSentence()
            }
        } else {
            isPlaying = false
        }
    }

    private func playCurrentSentence() async {
        guard let book, isPlaying, sentenceIndex < sentences.count else { return }
        let myGeneration = generation
        let index = sentenceIndex
        do {
            let data: Data
            if let cached = preloadedData[index] {
                data = cached
            } else {
                data = try await synthesize(text: sentences[index])
            }
            guard myGeneration == generation, isPlaying, !sleepTimerExpired else { return }
            preloadedData[index] = nil
            try player.play(data: data)
            needsFreshSynthesis = false
            player.updateNowPlaying(bookTitle: book.title, chapterTitle: chapter?.title ?? "")
            refillPreloadQueue()
        } catch {
            guard myGeneration == generation else { return }
            // `/api/tts` requires a real session (confirmed against the
            // live server: an unauthenticated POST returns a plain 401) —
            // iOS/macOS never surface this to a guest because
            // `ReaderPlaybackController` silently substitutes the offline
            // Piper voice whenever `!isLoggedIn` (see its `synthesizeAudio`
            // branch). This target has no offline engine to fall back to
            // (see class doc comment), so a guest genuinely can't play
            // anything here yet — name that specific cause instead of a
            // generic failure message that reads like a technical bug.
            if case APIError.notAuthenticated = error {
                errorMessage = "Cần đăng nhập để nghe — mở Cài đặt (⚙️) để đăng nhập"
            } else {
                errorMessage = "Không tạo được giọng đọc — thử lại"
            }
            isPlaying = false
        }
    }

    private func synthesize(text: String) async throws -> Data {
        try await synthesizer.synthesize(
            text: text, voice: voice, vieNeuOfflineV2Voice: nil, vieNeuOfflineV3Voice: nil,
            gwenTTSSpeaker: gwenTTSSpeaker, speed: speed, baseURL: SessionStore.baseURL,
            isConnected: true, isLoggedIn: SessionStore.shared.isLoggedIn
        )
    }

    /// Tops up `preloadedData` up to `preloadAhead` sentences beyond
    /// whichever one just started playing — one fetch at a time (not
    /// concurrent), which is plenty to stay ahead of real-time playback
    /// for the sentence lengths this app deals with, and keeps this a lot
    /// simpler than a windowed concurrent queue.
    private func refillPreloadQueue() {
        preloadTask?.cancel()
        let myGeneration = generation
        let boundary = min(sentenceIndex + preloadAhead, sentences.count - 1)
        guard boundary > sentenceIndex else { return }
        let toFetch = sentences
        preloadTask = Task {
            for index in (sentenceIndex + 1)...boundary {
                guard !Task.isCancelled, myGeneration == self.generation, self.preloadedData[index] == nil else { continue }
                if let data = try? await self.synthesize(text: toFetch[index]) {
                    guard !Task.isCancelled, myGeneration == self.generation else { return }
                    self.preloadedData[index] = data
                }
            }
        }
    }

    private func scheduleAutoStop() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerDeadline = nil
        sleepTimerExpired = false
        guard autoStopMinutes > 0 else { return }
        let nanoseconds = UInt64(autoStopMinutes * 60 * 1_000_000_000)
        sleepTimerDeadline = Date().addingTimeInterval(autoStopMinutes * 60)
        sleepTimerTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self.sleepTimerExpired = true
            if self.isPlaying { self.togglePlayPause() }
        }
    }
}
