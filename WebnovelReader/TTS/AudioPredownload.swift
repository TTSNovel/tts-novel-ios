import AVFoundation
import Foundation
import Core
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

// Pre-rendered ("downloaded") chapter audio: a downloaded book's chapters
// translated + synthesized ahead of time, so listening later is pure file
// playback — no translation, no network, no on-device TTS burning CPU while
// reading. Each chapter is one AAC .m4a plus a JSON manifest of where every
// sentence starts/ends in it; ReaderPlaybackController slices a sentence's
// clip back out on demand (see `PrerenderedChapter.clipData`), so the
// sentence-by-sentence play loop, highlight and seek work unchanged.
//
// Layout: Application Support/PrerenderedAudio/<bookID>/book.json (which
// voice — one voice per book) + job.json (the last job's per-chapter
// states) + <chapter>.m4a/.json. A chapter counts as rendered once its
// .json exists (written last, after the .m4a).

/// Everything that changes how a sentence sounds besides its text — the
/// voice plus its speaker preset. Speed is deliberately not part of it:
/// audio is rendered at 1.0x and sped up at playback (AVAudioPlayer.rate).
struct PrerenderVoice: Codable, Equatable, Sendable {
    var voice: TTSVoice
    var vieNeuOfflineV2Voice: VieNeuOfflineV2Voice
    var vieNeuOfflineV3Voice: VieNeuOfflineV3Voice
    var gwenTTSSpeaker: GwenTTSSpeaker

    var key: String {
        switch voice {
        case .vieNeuOfflineV2: return "\(voice.rawValue):\(vieNeuOfflineV2Voice.rawValue)"
        case .vieNeuOfflineV3: return "\(voice.rawValue):\(vieNeuOfflineV3Voice.rawValue)"
        case .gwenTTS: return "\(voice.rawValue):\(gwenTTSSpeaker.rawValue)"
        default: return voice.rawValue
        }
    }

    var displayName: String {
        switch voice {
        case .vieNeuOfflineV2: return "\(voice.displayName) · \(vieNeuOfflineV2Voice.rawValue)"
        case .vieNeuOfflineV3: return "\(voice.displayName) · \(vieNeuOfflineV3Voice.rawValue)"
        case .gwenTTS: return "\(voice.displayName) · \(gwenTTSSpeaker.rawValue)"
        default: return voice.displayName
        }
    }
}

struct PrerenderedBookInfo: Codable, Sendable {
    var voiceKey: String
    var voiceName: String
}

struct PrerenderedChapterManifest: Codable, Sendable {
    var voiceKey: String
    var sampleRate: Double
    /// `ReaderPlaybackController.sentenceSequence` of the chapter at render
    /// time — the manifest is only used while it still matches.
    var sentences: [String]
    /// What was actually spoken per sentence: the translation when the
    /// chapter was rendered translated, `sentences` otherwise.
    var spoken: [String]
    var translationEngine: String?
    var translationTarget: String?
    var startFrames: [Int64]
    var frameCounts: [Int64]
    var createdAt: Date

    var isTranslated: Bool { translationEngine != nil }
    var durationSeconds: Double { Double(frameCounts.reduce(0, +)) / sampleRate }
}

/// One rendered chapter, ready to hand out per-sentence clips.
struct PrerenderedChapter: Sendable {
    let manifest: PrerenderedChapterManifest
    let audioURL: URL

    /// The clip for sentence `index`, as WAV bytes AVAudioPlayer can play —
    /// nil if `text` isn't what was rendered there (the chapter's text or
    /// translation changed since).
    func clipRange(index: Int, text: String) -> (start: Int64, count: Int64)? {
        guard manifest.spoken.indices.contains(index), manifest.spoken[index] == text else { return nil }
        return (manifest.startFrames[index], manifest.frameCounts[index])
    }

    nonisolated func clipData(start: Int64, count: Int64) throws -> Data {
        let file = try AVAudioFile(forReading: audioURL)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(count, 1))) else {
            throw PrerenderError.audioFormat
        }
        file.framePosition = start
        try file.read(into: buffer, frameCount: AVAudioFrameCount(max(count, 1)))
        return WavEncoding.encode(buffer)
    }
}

enum PrerenderError: LocalizedError {
    case audioFormat
    case notDownloaded
    case voiceUnavailable(String)
    case translationIncomplete

    var errorDescription: String? {
        switch self {
        case .audioFormat: return "Unsupported audio format"
        case .notDownloaded: return "Download the book first"
        case .voiceUnavailable(let reason): return reason
        case .translationIncomplete: return "Translation returned no text"
        }
    }
}

/// File-system side of pre-rendered audio. Stateless apart from the root
/// directory, so it's safe to use from any thread.
struct PrerenderedAudioStore: Sendable {
    static let shared = PrerenderedAudioStore()

    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrerenderedAudio", isDirectory: true)
    }

    func bookDirectory(_ bookID: Int) -> URL {
        root.appendingPathComponent(String(bookID), isDirectory: true)
    }

    private func audioURL(_ bookID: Int, _ index: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent(String(format: "%04d.m4a", index))
    }

    private func manifestURL(_ bookID: Int, _ index: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent(String(format: "%04d.json", index))
    }

    private func bookInfoURL(_ bookID: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent("book.json")
    }

    private func jobURL(_ bookID: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent("job.json")
    }

    func job(_ bookID: Int) -> PredownloadJob? {
        StoredJSON.load(PredownloadJob.self, from: jobURL(bookID), category: .predownload)
    }

    func setJob(_ job: PredownloadJob) {
        StoredJSON.save(job, to: jobURL(job.bookID), category: .predownload)
    }

    /// Books with a saved job (running, interrupted or finished).
    func jobBookIDs() -> [Int] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] // nolog: nothing downloaded yet
        return entries.compactMap { Int($0.lastPathComponent) }
            .filter { FileManager.default.fileExists(atPath: jobURL($0).path) }
    }

    func bookInfo(_ bookID: Int) -> PrerenderedBookInfo? {
        StoredJSON.load(PrerenderedBookInfo.self, from: bookInfoURL(bookID), category: .predownload)
    }

    func setBookInfo(_ info: PrerenderedBookInfo, bookID: Int) throws {
        try FileManager.default.createDirectory(at: bookDirectory(bookID), withIntermediateDirectories: true)
        try JSONEncoder().encode(info).write(to: bookInfoURL(bookID))
    }

    func chapter(bookID: Int, index: Int) -> PrerenderedChapter? {
        guard let manifest = StoredJSON.load(PrerenderedChapterManifest.self, from: manifestURL(bookID, index), category: .predownload) else { return nil }
        return PrerenderedChapter(manifest: manifest, audioURL: audioURL(bookID, index))
    }

    func hasChapter(bookID: Int, index: Int) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(bookID, index).path)
    }

    /// Books with any pre-rendered audio on disk.
    func bookIDs() -> [Int] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] // nolog: nothing downloaded yet
        return entries.compactMap { Int($0.lastPathComponent) }.filter { !renderedChapters(bookID: $0).isEmpty }
    }

    func renderedChapters(bookID: Int) -> [Int] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: bookDirectory(bookID), includingPropertiesForKeys: nil)) ?? [] // nolog: book not downloaded
        return entries.filter { $0.pathExtension == "json" }.compactMap { Int($0.deletingPathExtension().lastPathComponent) }.sorted()
    }

    func byteSize(bookID: Int) -> Int64 {
        // nolog: book not downloaded / file removed meanwhile — counts as 0 bytes
        let entries = (try? FileManager.default.contentsOfDirectory(at: bookDirectory(bookID), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } // nolog: see above
    }

    /// The m4a container's roughly fixed size on top of the audio itself.
    static let containerOverhead: Int64 = 30_000

    /// Bytes and seconds of audio per spoken character, measured from
    /// whatever has been rendered with `voiceKey` so far — nil before the
    /// first chapter lands. Feeds the download sheet's size estimate.
    func measuredRates(voiceKey: String) -> (bytesPerChar: Double, secondsPerChar: Double)? {
        var bytes: Int64 = 0, seconds = 0.0, chars = 0
        for bookID in bookIDs() where bookInfo(bookID)?.voiceKey == voiceKey {
            for index in renderedChapters(bookID: bookID).suffix(20) {
                guard let chapter = chapter(bookID: bookID, index: index) else { continue }
                // Minus the container's fixed per-file overhead, which
                // `estimate` adds back per chapter.
                let fileSize = Int64((try? chapter.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) // nolog: estimate only
                bytes += max(fileSize - Self.containerOverhead, 0)
                seconds += chapter.manifest.durationSeconds
                chars += chapter.manifest.spoken.reduce(0) { $0 + $1.count }
            }
        }
        guard chars > 0, bytes > 0 else { return nil }
        return (Double(bytes) / Double(chars), seconds / Double(chars))
    }

    func deleteChapter(bookID: Int, index: Int) {
        StoredJSON.remove(manifestURL(bookID, index), category: .predownload)
        StoredJSON.remove(audioURL(bookID, index), category: .predownload)
    }

    func deleteBook(_ bookID: Int) {
        StoredJSON.remove(bookDirectory(bookID), category: .predownload)
    }

    /// Encodes `clips` (one WAV per sentence, in order) into the chapter's
    /// .m4a and writes its manifest. The manifest goes last, so an
    /// interrupted write never looks like a finished chapter.
    func writeChapter(
        bookID: Int, index: Int, voiceKey: String, sentences: [String], spoken: [String],
        translationEngine: String?, translationTarget: String?, clips: [Data]
    ) throws {
        try FileManager.default.createDirectory(at: bookDirectory(bookID), withIntermediateDirectories: true)
        let finalURL = audioURL(bookID, index)
        let tempURL = bookDirectory(bookID).appendingPathComponent(".\(index)-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) } // nolog: temp file, already moved on success

        var writer: AVAudioFile?
        var converter: AVAudioConverter?
        var sampleRate = 0.0
        var startFrames: [Int64] = []
        var frameCounts: [Int64] = []
        var totalFrames: Int64 = 0
        for clip in clips {
            let buffer = try Self.decodeClip(clip)
            if writer == nil {
                sampleRate = buffer.format.sampleRate
                writer = try Self.makeWriter(url: tempURL, sampleRate: sampleRate)
            }
            guard let writer else { throw PrerenderError.audioFormat }
            var pcm = buffer
            if buffer.format != writer.processingFormat {
                if converter == nil || converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: writer.processingFormat)
                }
                guard let converter else { throw PrerenderError.audioFormat }
                pcm = try Self.convert(buffer, with: converter)
            }
            // Counted from the input, not `writer.length` — that only
            // advances per encoded 1024-frame AAC packet.
            startFrames.append(totalFrames)
            frameCounts.append(Int64(pcm.frameLength))
            totalFrames += Int64(pcm.frameLength)
            try writer.write(from: pcm)
        }
        writer = nil  // closes/finalizes the file
        StoredJSON.remove(finalURL, category: .predownload)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        let manifest = PrerenderedChapterManifest(
            voiceKey: voiceKey, sampleRate: sampleRate, sentences: sentences, spoken: spoken,
            translationEngine: translationEngine, translationTarget: translationTarget,
            startFrames: startFrames, frameCounts: frameCounts, createdAt: Date()
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL(bookID, index), options: .atomic)
    }

    /// Mono AAC at a speech bitrate — ~2-3 MB per 10 minutes.
    private static func makeWriter(url: URL, sampleRate: Double) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            Log.notice(.predownload, "AAC writer rejected 32 kbps, retrying with encoder default", ["sampleRate": "\(sampleRate)", "error": ErrorInfo(error).summary])
        }
        // Not every sample rate accepts every bitrate — let the encoder pick.
        settings[AVEncoderBitRateKey] = nil
        settings[AVEncoderAudioQualityKey] = AVAudioQuality.medium.rawValue
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func decodeClip(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prerender-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) } // nolog: temp file
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1))) else {
            throw PrerenderError.audioFormat
        }
        try file.read(into: buffer)
        return buffer
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw PrerenderError.audioFormat
        }
        converter.reset()
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }
}

/// 16-bit PCM WAV from a float buffer — the clip format handed to
/// AVAudioPlayer, same as what the synthesizers return.
enum WavEncoding {
    static func encode(_ buffer: AVAudioPCMBuffer) -> Data {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let sampleRate = UInt32(buffer.format.sampleRate)
        var samples = [Int16](repeating: 0, count: frames * channels)
        if let floats = buffer.floatChannelData {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = max(-1, min(1, floats[channel][frame]))
                    samples[frame * channels + channel] = Int16(value * Float(Int16.max))
                }
            }
        } else if let ints = buffer.int16ChannelData {
            for frame in 0..<frames {
                for channel in 0..<channels { samples[frame * channels + channel] = ints[channel][frame] }
            }
        }
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(channels))
        append(sampleRate); append(sampleRate * UInt32(channels) * 2); append(UInt16(channels * 2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        samples.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) { append(sample) }
        }
        return data
    }
}

/// Where one chapter of a pre-render job is. Every chapter walks
/// pending → translating → synthesizing → saving → done, or ends in
/// failed once its retries run out — a failed chapter doesn't stop the
/// job, the next one starts. Persisted with the job (`job.json`), so a job
/// killed mid-way picks up again at its first unfinished chapter.
enum PredownloadChapterState: Codable, Equatable, Sendable {
    case pending
    case translating
    case synthesizing
    case saving
    case done
    case failed(PredownloadChapterFailure)

    /// Being worked on right now (as opposed to waiting or finished).
    var isActive: Bool { self == .translating || self == .synthesizing || self == .saving }

    var failure: PredownloadChapterFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

struct PredownloadChapterFailure: Codable, Equatable, Sendable {
    enum Step: String, Codable, Sendable { case loading, translating, synthesizing, saving }

    var step: Step
    var reason: String
    var attempts: Int
    /// The sentence it failed on (index into the chapter's sentence
    /// sequence) and that sentence's text, when it's down to one sentence.
    var sentenceIndex: Int?
    var sentenceText: String?
}

/// One book's pre-render job — what the download sheet shows, written to
/// `<bookID>/job.json` on every chapter state change.
struct PredownloadJob: Codable, Equatable, Sendable {
    var bookID: Int
    var bookTitle: String
    var voice: PrerenderVoice
    var chapters: [Int]
    var states: [Int: PredownloadChapterState]
    /// The job should be running: set on start/retry, cleared when it
    /// finishes, the user stops it or it can't go on. Still set on disk
    /// when the app was killed or iOS expired the background task — that's
    /// what gets it resumed on the next launch/foreground.
    var wantsToRun: Bool
    /// Why the whole job stopped early (the voice became unusable — no
    /// network, logged out), as opposed to one chapter failing.
    var stopReason: String?

    // In memory only: a task is running it, and the current step's
    // per-sentence progress.
    var isRunning = false
    var stepDone = 0
    var stepTotal = 0

    private enum CodingKeys: String, CodingKey {
        case bookID, bookTitle, voice, chapters, states, wantsToRun, stopReason
    }

    func state(_ index: Int) -> PredownloadChapterState { states[index] ?? .pending }

    var completed: Int { chapters.filter { state($0) == .done }.count }
    var failedChapters: [Int] { chapters.filter { state($0).failure != nil } }
    var currentChapter: Int? { chapters.first { state($0).isActive } }
    var isFinished: Bool { chapters.allSatisfy { state($0) == .done || state($0).failure != nil } }

    /// Chapters done, counting the current one's sentences as a fraction.
    var progressValue: Double {
        var current = 0.0
        if let index = currentChapter {
            switch state(index) {
            case .synthesizing: current = stepTotal > 0 ? Double(stepDone) / Double(stepTotal) : 0
            case .saving: current = 1
            default: break
            }
        }
        return min(Double(completed) + current, Double(chapters.count))
    }

    /// A chapter that was mid-way when the app died lost its in-memory
    /// work, so it goes back to pending.
    mutating func resetActiveChapters() {
        for (index, state) in states where state.isActive { states[index] = .pending }
    }
}

/// A failure that's down to one sentence of the chapter.
private struct SentenceError: Error {
    var index: Int
    var underlying: Error
}

/// Runs pre-render jobs — one per book, chapter by chapter, started from
/// BookDetailView's audio download button.
@MainActor
final class AudioPredownloadManager: ObservableObject {
    static let shared = AudioPredownloadManager()

    typealias Job = PredownloadJob

    /// Every book's job on disk — running, interrupted or finished.
    @Published private(set) var jobs: [Int: Job] = [:]
    /// Bumped whenever files on disk change, so storage views reload.
    @Published private(set) var storageRevision = 0

    /// Settings > Storage "Keep played audio" — off by default: a chapter
    /// that finished playing has its pre-rendered audio deleted.
    @Published var keepPlayedAudio: Bool {
        didSet { UserDefaults.standard.set(keepPlayedAudio, forKey: "prerender.keepPlayedAudio") }
    }

    /// Same in-flight cap as live playback's preload (Q18: don't burst the
    /// TTS backend).
    private let maxConcurrentSynthesis = 3
    /// Tries per chapter before it's marked failed. A retry keeps the
    /// sentences already translated/synthesized.
    private let maxAttempts = 3
    private var tasks: [Int: Task<Void, Never>] = [:]
    private let store = PrerenderedAudioStore.shared

    private init() {
        keepPlayedAudio = UserDefaults.standard.bool(forKey: "prerender.keepPlayedAudio")
        for bookID in store.jobBookIDs() {
            guard var job = store.job(bookID) else { continue }
            job.resetActiveChapters()
            jobs[bookID] = job
        }
    }

    func isRunning(_ bookID: Int) -> Bool { jobs[bookID]?.isRunning == true }

    /// The chapter range a "next N" choice covers: from where the reader
    /// left off (chapter 1 for an unread book) — nil `count` means to the end.
    func chapterRange(book: Book, count: Int?) -> Range<Int> {
        let start = min(ProgressStore.shared.localProgress(bookID: book.id)?.chapterIndex ?? 0, max(book.n - 1, 0))
        let end = count.map { min(start + $0, book.n) } ?? book.n
        return start..<end
    }

    /// Why the current voice can't be pre-rendered right now, if it can't.
    func unavailableReason(for voice: PrerenderVoice) -> String? {
        #if !os(iOS)
        if [.vieNeuOfflineV2, .vieNeuOfflineV3].contains(voice.voice) {
            return "VieNeu offline voices aren't available on Mac — pick Piper (offline) or an online voice."
        }
        #endif
        if !voice.voice.isOffline {
            if !SessionStore.shared.isLoggedIn { return "Log in to use online voices." }
            if !NetworkMonitor.shared.isConnected { return "No internet connection." }
        }
        return nil
    }

    /// Size/duration estimate for rendering `range` with `voice`: average
    /// characters of a few sampled chapters × the measured (or default)
    /// rates.
    func estimate(book: Book, range: Range<Int>, voice: PrerenderVoice) -> (bytes: Int64, seconds: Double) {
        let pending = range.filter { !isRendered(bookID: book.id, index: $0, voiceKey: voice.key) }
        guard !pending.isEmpty else { return (0, 0) }
        let step = max(pending.count / 5, 1)
        let samples = stride(from: 0, to: pending.count, by: step).prefix(5).compactMap {
            DownloadManager.shared.localChapter(bookID: book.id, index: pending[$0])
        }
        let averageChars = samples.isEmpty ? 6000.0
            : Double(samples.reduce(0) { $0 + $1.text.count + $1.title.count }) / Double(samples.count)
        // Defaults: ~14 chars/s of speech (ReaderPlaybackController's
        // estimate) at 32 kbps AAC ≈ 4 KB/s.
        let rates = store.measuredRates(voiceKey: voice.key) ?? (bytesPerChar: 4000.0 / 14, secondsPerChar: 1 / 14.0)
        let chars = averageChars * Double(pending.count)
        let overhead = Int64(pending.count) * PrerenderedAudioStore.containerOverhead
        return (Int64(chars * rates.bytesPerChar) + overhead, chars * rates.secondsPerChar)
    }

    func isRendered(bookID: Int, index: Int, voiceKey: String) -> Bool {
        store.bookInfo(bookID)?.voiceKey == voiceKey && store.hasChapter(bookID: bookID, index: index)
    }

    /// The voice a book's audio was rendered with, if any is on disk.
    func renderedVoice(bookID: Int) -> PrerenderedBookInfo? {
        guard !store.renderedChapters(bookID: bookID).isEmpty else { return nil }
        return store.bookInfo(bookID)
    }

    func start(book: Book, range: Range<Int>, voice: PrerenderVoice) {
        guard !isRunning(book.id), !range.isEmpty else { return }
        // One voice per book — the sheet confirmed replacing a different one.
        if let info = store.bookInfo(book.id), info.voiceKey != voice.key {
            store.deleteBook(book.id)
            ReaderPlaybackController.shared.prerenderedAudioDeleted(bookID: book.id)
            storageRevision += 1
        }
        let chapters = Array(range)
        var states: [Int: PredownloadChapterState] = [:]
        for index in chapters {
            states[index] = isRendered(bookID: book.id, index: index, voiceKey: voice.key) ? .done : .pending
        }
        jobs[book.id] = Job(
            bookID: book.id, bookTitle: book.title, voice: voice, chapters: chapters,
            states: states, wantsToRun: true, stopReason: nil
        )
        EventLogStore.shared.record(.download, "Start audio download", detail: "\(book.title) — \(chapters.count) chapters, \(voice.displayName)")
        launch(bookID: book.id)
    }

    /// "Thử lại": failed chapters go back to pending and the job runs again
    /// (also continues a job that stopped early or was stopped).
    func retryFailed(bookID: Int) {
        guard var job = jobs[bookID], !job.isRunning else { return }
        for index in job.failedChapters { job.states[index] = .pending }
        job.wantsToRun = true
        job.stopReason = nil
        jobs[bookID] = job
        EventLogStore.shared.record(.download, "Retry failed audio chapters", detail: job.bookTitle)
        launch(bookID: bookID)
    }

    /// Restarts jobs that were still meant to be running when the app was
    /// killed or iOS ended their background time — called on launch and
    /// whenever the app comes back to the foreground.
    func resumeInterruptedJobs() {
        for (bookID, job) in jobs where job.wantsToRun && !job.isRunning {
            EventLogStore.shared.record(.download, "Resume audio download", detail: job.bookTitle)
            launch(bookID: bookID)
        }
    }

    /// User stop — unlike an interruption, not resumed later.
    func cancel(bookID: Int) {
        if jobs[bookID]?.wantsToRun == true {
            jobs[bookID]?.wantsToRun = false
            persist(bookID)
        }
        tasks[bookID]?.cancel()
    }

    func deleteAudio(bookID: Int) {
        cancel(bookID: bookID)
        store.deleteBook(bookID)
        ReaderPlaybackController.shared.prerenderedAudioDeleted(bookID: bookID)
        jobs[bookID] = nil
        storageRevision += 1
    }

    func deleteAll() {
        for bookID in Set(store.bookIDs() + Array(jobs.keys)) { deleteAudio(bookID: bookID) }
        StoredJSON.remove(store.root, category: .predownload)
        storageRevision += 1
    }

    /// A chapter finished playing — drop its audio unless the user keeps it.
    func chapterDidFinishPlaying(bookID: Int, index: Int) {
        guard !keepPlayedAudio, store.hasChapter(bookID: bookID, index: index) else { return }
        store.deleteChapter(bookID: bookID, index: index)
        storageRevision += 1
    }

    // MARK: - State machine

    private func launch(bookID: Int) {
        guard let job = jobs[bookID], tasks[bookID] == nil else { return }
        jobs[bookID]?.isRunning = true
        persist(bookID)
        tasks[bookID] = Task { await self.run(bookID: bookID) }
        beginBackgroundTask(bookID: bookID, title: job.bookTitle)
    }

    private func transition(_ bookID: Int, _ index: Int, to state: PredownloadChapterState) {
        jobs[bookID]?.states[index] = state
        setProgress(bookID, done: 0, total: 0)
        persist(bookID)
    }

    private func setProgress(_ bookID: Int, done: Int, total: Int) {
        jobs[bookID]?.stepDone = done
        jobs[bookID]?.stepTotal = total
    }

    private func persist(_ bookID: Int) {
        guard let job = jobs[bookID] else { return }
        store.setJob(job)
    }

    private func run(bookID: Int) async {
        // Everything logged under this job — translation, synthesis,
        // storage — carries which download it was.
        await withLogContext(["job": "predownload", "book": "\(bookID)", "voice": jobs[bookID]?.voice.key ?? "-"]) {
            await runJob(bookID: bookID)
        }
    }

    private func runJob(bookID: Int) async {
        let started = Date()
        defer {
            tasks[bookID] = nil
            jobs[bookID]?.isRunning = false
            // Stopped mid-chapter: that chapter starts over next time.
            jobs[bookID]?.resetActiveChapters()
            setProgress(bookID, done: 0, total: 0)
            if jobs[bookID]?.isFinished == true { jobs[bookID]?.wantsToRun = false }
            persist(bookID)
            storageRevision += 1
            endBackgroundTask(bookID: bookID)
        }
        guard let job = jobs[bookID] else { return }
        let voice = job.voice
        do {
            try store.setBookInfo(PrerenderedBookInfo(voiceKey: voice.key, voiceName: voice.displayName), bookID: bookID)
        } catch {
            Log.error(.predownload, "Audio download can't write book info", error: error)
            stop(bookID, reason: error.localizedDescription)
            return
        }
        for index in job.chapters where jobs[bookID]?.state(index) == .pending {
            if Task.isCancelled { break }
            if isRendered(bookID: bookID, index: index, voiceKey: voice.key) {
                transition(bookID, index, to: .done)
                continue
            }
            // Nothing can succeed without the voice — stop instead of
            // failing every remaining chapter.
            if let reason = unavailableReason(for: voice) {
                stop(bookID, reason: reason)
                return
            }
            await withLogContext(["chapter": "\(index)"]) {
                await renderWithRetries(bookID: bookID, index: index, voice: voice)
            }
            storageRevision += 1
            updateBackgroundTaskProgress(bookID: bookID)
        }
        guard let job = jobs[bookID] else { return }
        if Task.isCancelled {
            EventLogStore.shared.record(.download, job.wantsToRun ? "Audio download interrupted" : "Audio download stopped", detail: job.bookTitle)
        } else if job.failedChapters.isEmpty {
            EventLogStore.shared.record(.download, "Audio download finished", detail: job.bookTitle)
        } else {
            Log.notice(.predownload, "Audio download finished with failed chapters", [
                "failed": job.failedChapters.map { "\($0)" }.joined(separator: ","),
                "completed": "\(job.completed)/\(job.chapters.count)",
                "runSeconds": "\(Int(Date().timeIntervalSince(started)))",
            ])
            EventLogStore.shared.record(.error, "Audio download finished, \(job.failedChapters.count) chapters failed", detail: job.bookTitle)
        }
    }

    private func stop(_ bookID: Int, reason: String) {
        jobs[bookID]?.stopReason = reason
        jobs[bookID]?.wantsToRun = false
        Log.notice(.predownload, "Audio download stopped early", ["reason": reason])
        EventLogStore.shared.record(.error, "Audio download stopped", detail: "\(jobs[bookID]?.bookTitle ?? ""): \(reason)")
    }

    /// One chapter, through to `done` or `failed`. Translations and clips
    /// that already succeeded carry over to the next attempt.
    private func renderWithRetries(bookID: Int, index: Int, voice: PrerenderVoice) async {
        var work = ChapterWork()
        for attempt in 1...maxAttempts {
            do {
                try await renderChapter(bookID: bookID, index: index, voice: voice, work: &work)
                transition(bookID, index, to: .done)
                return
            } catch {
                // Stopping mid-request surfaces as URLError.cancelled (or a
                // translation error), not CancellationError — still a stop.
                if Log.isCancellation(error) || Task.isCancelled { return } // nolog: a stop, not a failure
                let failure = failureDetails(error, step: work.step, attempts: attempt, work: work)
                let title = jobs[bookID]?.bookTitle ?? ""
                let context = [
                    "step": failure.step.rawValue, "attempt": "\(attempt)/\(maxAttempts)",
                    "sentence": failure.sentenceIndex.map { "\($0)" } ?? "-",
                ]
                // A chapter missing from the download won't appear by retrying.
                if attempt == maxAttempts || work.step == .loading {
                    Log.error(.predownload, "Audio chapter failed", error: (error as? SentenceError)?.underlying ?? error, context)
                    transition(bookID, index, to: .failed(failure))
                    EventLogStore.shared.record(.error, "Chapter \(index + 1) failed", detail: "\(title): \(failure.reason)")
                    return
                }
                Log.notice(.predownload, "Audio chapter retry", context.merging(["error": failure.reason]) { $1 })
                EventLogStore.shared.record(.download, "Retry chapter \(index + 1) (attempt \(attempt + 1))", detail: "\(title): \(failure.reason)")
                if #available(iOS 18.0, macOS 15.0, *), work.step == .translating,
                   ReaderPlaybackController.shared.translationEngineKind == .apple {
                    // A long-lived session can start failing every call
                    // ("Unable to Translate") hours into a download.
                    AppleTranslationEngine.shared.resetSession()
                }
                do { try await Task.sleep(for: .seconds(2 * attempt)) } catch { return } // nolog: cancelled while waiting
            }
        }
    }

    private func failureDetails(_ error: Error, step: PredownloadChapterFailure.Step, attempts: Int, work: ChapterWork) -> PredownloadChapterFailure {
        var failure = PredownloadChapterFailure(step: step, reason: error.localizedDescription, attempts: attempts)
        if let sentence = error as? SentenceError {
            failure.reason = sentence.underlying.localizedDescription
            failure.sentenceIndex = sentence.index
            let texts = step == .synthesizing ? work.spoken : work.sentences
            if let texts, texts.indices.contains(sentence.index) { failure.sentenceText = texts[sentence.index] }
        }
        return failure
    }

    /// What a chapter's attempts have produced so far.
    private struct ChapterWork {
        var step: PredownloadChapterFailure.Step = .loading
        var sentences: [String]?
        /// Per sentence: its translation once it's in.
        var translated: [String?] = []
        /// What gets synthesized — set once translation (if any) is done.
        var spoken: [String]?
        var engineName: String?
        var target: String?
        var clips: [Data?] = []
    }

    private func renderChapter(bookID: Int, index: Int, voice: PrerenderVoice, work: inout ChapterWork) async throws {
        work.step = .loading
        guard let chapter = DownloadManager.shared.localChapter(bookID: bookID, index: index) else {
            throw PrerenderError.notDownloaded
        }
        let playback = ReaderPlaybackController.shared
        let sentences = work.sentences ?? ReaderPlaybackController.sentenceSequence(for: chapter)
        work.sentences = sentences
        guard !sentences.isEmpty else { return }

        // Translate exactly the way opening the chapter would (Q4: frozen
        // into the download) — only when it needs translating and
        // auto-translate is on, with the currently selected engine.
        if work.spoken == nil {
            var spoken = sentences
            if playback.autoTranslate, let dominant = playback.dominantLanguage(of: sentences),
               dominant.rawValue != playback.primaryLanguageCode {
                let source = Locale.Language(identifier: dominant.rawValue)
                let targetLanguage = playback.primaryLanguage
                if playback.translationEngineKind == .apple { await playback.refreshGlossary() }
                if let engine = playback.translationEngine(bookID: bookID, chapterIndex: index, source: source),
                   engine.canTranslate(from: source, to: targetLanguage) {
                    work.step = .translating
                    transition(bookID, index, to: .translating)
                    if work.translated.count != sentences.count { work.translated = Array(repeating: nil, count: sentences.count) }
                    let missing = work.translated.indices.filter { work.translated[$0] == nil }
                    var done = sentences.count - missing.count
                    setProgress(bookID, done: done, total: sentences.count)
                    do {
                        for try await (position, text) in engine.translate(texts: missing.map { sentences[$0] }, source: source, target: targetLanguage) {
                            work.translated[missing[position]] = text
                            done += 1
                            setProgress(bookID, done: done, total: sentences.count)
                        }
                    } catch {
                        // The engine doesn't say which sentence — the first
                        // one still untranslated is where it stopped.
                        if let failed = work.translated.firstIndex(where: { $0 == nil }) {
                            throw SentenceError(index: failed, underlying: error)
                        }
                        throw error
                    }
                    if let failed = work.translated.firstIndex(where: { $0 == nil }) {
                        throw SentenceError(index: failed, underlying: PrerenderError.translationIncomplete)
                    }
                    spoken = work.translated.map { $0 ?? "" }
                    work.engineName = playback.translationEngineKind.rawValue
                    work.target = playback.primaryLanguageCode
                }
            }
            work.spoken = spoken
        }
        let texts = work.spoken ?? sentences

        work.step = .synthesizing
        transition(bookID, index, to: .synthesizing)
        let synthesizer = playback.synthesizer
        let baseURL = SessionStore.baseURL
        let isConnected = NetworkMonitor.shared.isConnected
        let isLoggedIn = SessionStore.shared.isLoggedIn
        let limit = maxConcurrentSynthesis
        if work.clips.count != texts.count { work.clips = Array(repeating: nil, count: texts.count) }
        let missing = work.clips.indices.filter { work.clips[$0] == nil }
        var synthesized = texts.count - missing.count
        setProgress(bookID, done: synthesized, total: texts.count)
        var clips = work.clips
        defer { work.clips = clips }
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func addNext() {
                guard next < missing.count else { return }
                let position = missing[next]
                next += 1
                group.addTask {
                    do {
                        let data = try await synthesizer.synthesize(
                            text: texts[position], voice: voice.voice,
                            vieNeuOfflineV2Voice: voice.vieNeuOfflineV2Voice, vieNeuOfflineV3Voice: voice.vieNeuOfflineV3Voice,
                            gwenTTSSpeaker: voice.gwenTTSSpeaker, speed: 1.0, baseURL: baseURL,
                            isConnected: isConnected, isLoggedIn: isLoggedIn
                        )
                        return (position, data)
                    } catch {
                        throw SentenceError(index: position, underlying: error)
                    }
                }
            }
            for _ in 0..<min(limit, missing.count) { addNext() }
            while let (position, data) = try await group.next() {
                clips[position] = data
                synthesized += 1
                setProgress(bookID, done: synthesized, total: texts.count)
                addNext()
            }
        }
        try Task.checkCancellation()

        work.step = .saving
        transition(bookID, index, to: .saving)
        let store = self.store
        let finished = clips.compactMap { $0 }
        let engineName = work.engineName, target = work.target
        try await Task.detached(priority: .utility) { // nolog: awaited via .value
            try store.writeChapter(
                bookID: bookID, index: index, voiceKey: voice.key, sentences: sentences, spoken: texts,
                translationEngine: engineName, translationTarget: target, clips: finished
            )
        }.value
    }

    // MARK: - Background execution (iOS 26+)

    // iOS suspends the app ~30s after it backgrounds unless audio is
    // playing; a BGContinuedProcessingTask (user-initiated, shows system
    // progress UI) lets a long "All chapters" job keep going. Older iOS:
    // the job just stops when suspended; `resumeInterruptedJobs` picks it
    // up on the next foreground. macOS doesn't suspend, nothing to do.
    #if os(iOS)
    private static let backgroundTaskPrefix = "dev.yanglong.webnovelreader.audio-predownload"
    private var registeredBackgroundIDs: Set<String> = []
    private var backgroundTasks: [Int: AnyObject] = [:]
    #endif

    private func beginBackgroundTask(bookID: Int, title: String) {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return }
        let identifier = "\(Self.backgroundTaskPrefix).\(bookID)"
        if !registeredBackgroundIDs.contains(identifier) {
            // `@Sendable` keeps the handler nonisolated: BGTaskScheduler calls
            // it on a background queue, and an inferred @MainActor closure
            // traps there (Swift 6 isolation check).
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { @Sendable task in
                // BGTask isn't Sendable; it's only touched on the main actor from here on.
                guard let processingTask = task as? BGContinuedProcessingTask else { return }
                nonisolated(unsafe) let task = processingTask
                Task { @MainActor in self.attachBackgroundTask(task, bookID: bookID) }
            }
            guard registered else { return }
            registeredBackgroundIDs.insert(identifier)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Downloading audio", subtitle: title)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.error(.predownload, "Background task request rejected", error: error, ["book": "\(bookID)"])
            EventLogStore.shared.record(.download, "Can't continue in background", detail: error.localizedDescription)
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    private func attachBackgroundTask(_ task: BGContinuedProcessingTask, bookID: Int) {
        guard isRunning(bookID) else {
            task.setTaskCompleted(success: true)
            return
        }
        backgroundTasks[bookID] = task
        // An interruption, not a user stop: the job stays `wantsToRun` and
        // resumes on the next foreground.
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.tasks[bookID]?.cancel() }
        }
        updateBackgroundTaskProgress(bookID: bookID)
    }
    #endif

    private func updateBackgroundTaskProgress(bookID: Int) {
        #if os(iOS)
        guard #available(iOS 26.0, *), let task = backgroundTasks[bookID] as? BGContinuedProcessingTask, let job = jobs[bookID] else { return }
        task.progress.totalUnitCount = Int64(job.chapters.count)
        task.progress.completedUnitCount = Int64(job.completed)
        #endif
    }

    private func endBackgroundTask(bookID: Int) {
        #if os(iOS)
        guard #available(iOS 26.0, *), let task = backgroundTasks.removeValue(forKey: bookID) as? BGContinuedProcessingTask else { return }
        task.setTaskCompleted(success: jobs[bookID].map { $0.failedChapters.isEmpty && $0.stopReason == nil } ?? true)
        #endif
    }
}
