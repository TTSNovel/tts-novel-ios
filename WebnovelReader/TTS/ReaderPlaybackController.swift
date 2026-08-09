import Foundation

/// Drives sentence-by-sentence read-aloud, ported from reader.js's
/// readLoop() (site_assets/reader.js, around line 473 in the tts-webnovel
/// repo): split chapter text into sentences, look-ahead prefetch several
/// sentences' audio at once, play one at a time, highlight + report
/// progress as it goes, optionally auto-advance to the next chapter, and
/// optionally auto-stop the whole session after N minutes.
@MainActor
final class ReaderPlaybackController: ObservableObject {
    @Published private(set) var isLoadingAudio = false
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var sentences: [String] = []
    @Published private(set) var highlightedSentenceIndex: Int?
    /// How many sentences (of the current chapter) have audio fetched and
    /// cached, ready to play without a network wait — reader.js's
    /// `preloadReady` counter (els.preload text).
    @Published private(set) var preloadedCount = 0
    @Published var errorMessage: String?

    @Published var voice: TTSVoice {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: Keys.voice) }
    }
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: Keys.speed) }
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

    let player = AudioPlaybackService()

    var isPlaying: Bool { player.isPlaying }
    var sentenceCount: Int { sentences.count }

    /// Called when playback reaches the end of the chapter's sentences
    /// normally (not stopped/errored) — mirrors reader.js's end-of-
    /// readLoop-iteration check (`autoNext && hasNext`). The view owns
    /// chapter navigation (it knows book.n and how to fetch the next
    /// chapter's text), so this just signals "finished"; the view decides
    /// whether autoNextChapter + bounds mean it should actually advance
    /// and restart playback.
    var onChapterFinished: (() -> Void)?

    private var baseURL: URL?
    private var active = false
    private var generation = 0
    /// One fetch per sentence index, started either by the main play
    /// loop or by look-ahead prefetch — awaiting the same Task twice
    /// (once from prefetch, once from playback reaching that index) just
    /// returns the cached result, same idea as reader.js's
    /// `preloadCache[i]` Promise map.
    private var audioTasks: [Int: Task<Data, Error>] = [:]
    private var preloadedIndices: Set<Int> = []
    private var sleepTimerTask: Task<Void, Never>?

    private let preloadAhead = 6

    private enum Keys {
        static let voice = "reader.model"
        static let speed = "reader.speed"
        static let autoNext = "reader.autoNext"
        static let autoStopMinutes = "reader.autoStopMinutes"
    }

    init() {
        voice = TTSVoice(rawValue: UserDefaults.standard.string(forKey: Keys.voice) ?? "") ?? .piperVi
        let savedSpeed = UserDefaults.standard.double(forKey: Keys.speed)
        speed = savedSpeed > 0 ? savedSpeed : 1.0
        autoNextChapter = UserDefaults.standard.bool(forKey: Keys.autoNext)
        autoStopMinutes = UserDefaults.standard.object(forKey: Keys.autoStopMinutes) as? Double ?? 30
        player.onFinishedPlaying = { [weak self] in self?.advance() }
    }

    func start(text: String, baseURL: URL) {
        beginChapter(text: text, baseURL: baseURL)
        scheduleAutoStop()
    }

    /// Like `start`, but for auto-advancing to the next chapter mid-
    /// session (see `onChapterFinished`) — deliberately does NOT touch
    /// the sleep timer. reader.js only calls scheduleAutoStop() once, from
    /// its own `start()`; the timer is a wall-clock budget for the whole
    /// listening session, not reset every chapter boundary.
    func continueToNextChapter(text: String, baseURL: URL) {
        beginChapter(text: text, baseURL: baseURL)
    }

    /// Call when the caller has decided NOT to continue into another
    /// chapter after `onChapterFinished` fires (auto-next disabled, or no
    /// chapter left) — releases the now-pointless sleep timer instead of
    /// letting it fire later on an already-idle controller.
    func abandonSleepTimerIfIdle() {
        guard !active else { return }
        clearAutoStopState()
    }

    private func beginChapter(text: String, baseURL: URL) {
        self.baseURL = baseURL
        sentences = TextSegmentation.sentences(from: TextSegmentation.cleaned(text))
        currentSentenceIndex = 0
        preloadedIndices = []
        preloadedCount = 0
        audioTasks = [:]
        active = true
        generation += 1
        Task { await playCurrentSentence(generation: generation) }
    }

    /// Single entry point the play/pause button calls — decides start vs.
    /// resume vs. pause from internal state so callers don't have to guess
    /// (e.g. "finished the last sentence" leaves `active` false, at which
    /// point only a fresh `start` makes sense, not `resume`).
    func togglePlay(text: String, baseURL: URL) {
        if player.isPlaying {
            pause()
        } else if active {
            resume()
        } else {
            start(text: text, baseURL: baseURL)
        }
    }

    func stop() {
        active = false
        generation += 1
        audioTasks = [:]
        clearAutoStopState()
        player.stop()
        highlightedSentenceIndex = nil
    }

    func pause() {
        player.pause()
    }

    func resume() {
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
            // is deliberately left running here: onChapterFinished's
            // handler may continue straight into the next chapter, and
            // only it knows whether that's actually going to happen (see
            // abandonSleepTimerIfIdle()).
            active = false
            highlightedSentenceIndex = nil
            onChapterFinished?()
            return
        }
        guard let baseURL else { return }

        highlightedSentenceIndex = currentSentenceIndex
        isLoadingAudio = audioTasks[currentSentenceIndex] == nil
        do {
            let data = try await fetchTask(index: currentSentenceIndex, baseURL: baseURL).value
            guard generation == self.generation else { return }
            isLoadingAudio = false
            audioTasks[currentSentenceIndex] = nil
            try player.play(data: data)
            errorMessage = nil
            // Look ahead — same idea as reader.js's PRELOAD_AHEAD loop
            // right after a sentence starts playing.
            for k in 1...preloadAhead {
                preload(index: currentSentenceIndex + k, baseURL: baseURL)
            }
        } catch {
            isLoadingAudio = false
            guard generation == self.generation else { return }
            errorMessage = "Không tạo được audio — thử lại hoặc đổi giọng đọc"
            active = false
            clearAutoStopState()
        }
    }

    private func fetchTask(index: Int, baseURL: URL) -> Task<Data, Error> {
        if let existing = audioTasks[index] { return existing }
        let task = makeFetchTask(index: index, baseURL: baseURL)
        audioTasks[index] = task
        return task
    }

    private func preload(index: Int, baseURL: URL) {
        guard index >= 0, index < sentences.count, audioTasks[index] == nil else { return }
        audioTasks[index] = makeFetchTask(index: index, baseURL: baseURL)
    }

    private func makeFetchTask(index: Int, baseURL: URL) -> Task<Data, Error> {
        let text = sentences[index]
        let voice = self.voice
        let speed = self.speed
        let generation = self.generation
        return Task {
            let data = try await APIClient.shared.synthesize(baseURL: baseURL, text: text, voice: voice, speed: speed)
            self.markPreloaded(index: index, generation: generation)
            return data
        }
    }

    private func markPreloaded(index: Int, generation: Int) {
        guard generation == self.generation else { return }
        preloadedIndices.insert(index)
        preloadedCount = preloadedIndices.count
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
}
