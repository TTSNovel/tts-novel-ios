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
// voice — one voice per book) + <chapter>.m4a/.json. A chapter counts as
// rendered once its .json exists (written last, after the .m4a).

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

    var errorDescription: String? {
        switch self {
        case .audioFormat: return "Unsupported audio format"
        case .notDownloaded: return "Download the book first"
        case .voiceUnavailable(let reason): return reason
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

    func bookInfo(_ bookID: Int) -> PrerenderedBookInfo? {
        guard let data = try? Data(contentsOf: bookInfoURL(bookID)) else { return nil }
        return try? JSONDecoder().decode(PrerenderedBookInfo.self, from: data)
    }

    func setBookInfo(_ info: PrerenderedBookInfo, bookID: Int) throws {
        try FileManager.default.createDirectory(at: bookDirectory(bookID), withIntermediateDirectories: true)
        try JSONEncoder().encode(info).write(to: bookInfoURL(bookID))
    }

    func chapter(bookID: Int, index: Int) -> PrerenderedChapter? {
        guard let data = try? Data(contentsOf: manifestURL(bookID, index)),
              let manifest = try? JSONDecoder().decode(PrerenderedChapterManifest.self, from: data) else { return nil }
        return PrerenderedChapter(manifest: manifest, audioURL: audioURL(bookID, index))
    }

    func hasChapter(bookID: Int, index: Int) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(bookID, index).path)
    }

    /// Books with any pre-rendered audio on disk.
    func bookIDs() -> [Int] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { Int($0.lastPathComponent) }.filter { !renderedChapters(bookID: $0).isEmpty }
    }

    func renderedChapters(bookID: Int) -> [Int] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: bookDirectory(bookID), includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "json" }.compactMap { Int($0.deletingPathExtension().lastPathComponent) }.sorted()
    }

    func byteSize(bookID: Int) -> Int64 {
        let entries = (try? FileManager.default.contentsOfDirectory(at: bookDirectory(bookID), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
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
                let fileSize = Int64((try? chapter.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                bytes += max(fileSize - Self.containerOverhead, 0)
                seconds += chapter.manifest.durationSeconds
                chars += chapter.manifest.spoken.reduce(0) { $0 + $1.count }
            }
        }
        guard chars > 0, bytes > 0 else { return nil }
        return (Double(bytes) / Double(chars), seconds / Double(chars))
    }

    func deleteChapter(bookID: Int, index: Int) {
        try? FileManager.default.removeItem(at: manifestURL(bookID, index))
        try? FileManager.default.removeItem(at: audioURL(bookID, index))
    }

    func deleteBook(_ bookID: Int) {
        try? FileManager.default.removeItem(at: bookDirectory(bookID))
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
        defer { try? FileManager.default.removeItem(at: tempURL) }

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
        try? FileManager.default.removeItem(at: finalURL)
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
        if let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
            return file
        }
        // Not every sample rate accepts every bitrate — let the encoder pick.
        settings[AVEncoderBitRateKey] = nil
        settings[AVEncoderAudioQualityKey] = AVAudioQuality.medium.rawValue
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func decodeClip(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prerender-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
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

/// Runs pre-render jobs — one book at a time, chapter by chapter, started
/// from BookDetailView's audio download button.
@MainActor
final class AudioPredownloadManager: ObservableObject {
    static let shared = AudioPredownloadManager()

    struct Job: Equatable {
        var bookID: Int
        var bookTitle: String
        var chapters: [Int]
        var completed: Int
        var currentChapter: Int?
        var failure: String?
        var isRunning: Bool
    }

    /// The running (or last stopped/failed) job per book.
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
    private var tasks: [Int: Task<Void, Never>] = [:]
    private let store = PrerenderedAudioStore.shared

    private init() {
        keepPlayedAudio = UserDefaults.standard.bool(forKey: "prerender.keepPlayedAudio")
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
        if voice.voice.isOffline { return "Offline voices aren't available on Mac — pick an online voice." }
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
        jobs[book.id] = Job(
            bookID: book.id, bookTitle: book.title, chapters: chapters,
            completed: chapters.filter { isRendered(bookID: book.id, index: $0, voiceKey: voice.key) }.count,
            currentChapter: nil, failure: nil, isRunning: true
        )
        EventLogStore.shared.record(.download, "Bắt đầu tải audio", detail: "\(book.title) — \(chapters.count) chương, \(voice.displayName)")
        tasks[book.id] = Task { await self.run(book: book, chapters: chapters, voice: voice) }
        beginBackgroundTask(book: book)
    }

    func cancel(bookID: Int) {
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
        for bookID in store.bookIDs() { deleteAudio(bookID: bookID) }
        try? FileManager.default.removeItem(at: store.root)
        storageRevision += 1
    }

    /// A chapter finished playing — drop its audio unless the user keeps it.
    func chapterDidFinishPlaying(bookID: Int, index: Int) {
        guard !keepPlayedAudio, store.hasChapter(bookID: bookID, index: index) else { return }
        store.deleteChapter(bookID: bookID, index: index)
        storageRevision += 1
    }

    private func run(book: Book, chapters: [Int], voice: PrerenderVoice) async {
        defer {
            jobs[book.id]?.isRunning = false
            jobs[book.id]?.currentChapter = nil
            tasks[book.id] = nil
            storageRevision += 1
            endBackgroundTask(bookID: book.id)
        }
        do {
            try store.setBookInfo(PrerenderedBookInfo(voiceKey: voice.key, voiceName: voice.displayName), bookID: book.id)
            for index in chapters {
                try Task.checkCancellation()
                if isRendered(bookID: book.id, index: index, voiceKey: voice.key) { continue }
                if let reason = unavailableReason(for: voice) { throw PrerenderError.voiceUnavailable(reason) }
                jobs[book.id]?.currentChapter = index
                try await renderChapter(book: book, index: index, voice: voice)
                jobs[book.id]?.completed += 1
                storageRevision += 1
                updateBackgroundTaskProgress(bookID: book.id)
            }
            EventLogStore.shared.record(.download, "Tải audio xong", detail: book.title)
        } catch is CancellationError {
            EventLogStore.shared.record(.download, "Dừng tải audio", detail: book.title)
        } catch {
            jobs[book.id]?.failure = error.localizedDescription
            EventLogStore.shared.record(.error, "Tải audio thất bại", detail: "\(book.title): \(error.localizedDescription)")
        }
    }

    private func renderChapter(book: Book, index: Int, voice: PrerenderVoice) async throws {
        guard let chapter = DownloadManager.shared.localChapter(bookID: book.id, index: index) else {
            throw PrerenderError.notDownloaded
        }
        let playback = ReaderPlaybackController.shared
        let sentences = ReaderPlaybackController.sentenceSequence(for: chapter)
        guard !sentences.isEmpty else { return }

        // Translate exactly the way opening the chapter would (Q4: frozen
        // into the download) — only when it needs translating and
        // auto-translate is on, with the currently selected engine.
        var spoken = sentences
        var engineName: String?
        var target: String?
        if playback.autoTranslate, let dominant = playback.dominantLanguage(of: sentences),
           dominant.rawValue != playback.primaryLanguageCode {
            let source = Locale.Language(identifier: dominant.rawValue)
            let targetLanguage = playback.primaryLanguage
            if playback.translationEngineKind == .apple { await playback.refreshGlossary() }
            if let engine = playback.translationEngine(bookID: book.id, chapterIndex: index, source: source),
               engine.canTranslate(from: source, to: targetLanguage) {
                for try await (position, text) in engine.translate(texts: sentences, source: source, target: targetLanguage) {
                    spoken[position] = text
                }
                engineName = playback.translationEngineKind.rawValue
                target = playback.primaryLanguageCode
            }
        }

        let synthesizer = playback.synthesizer
        let baseURL = SessionStore.baseURL
        let isConnected = NetworkMonitor.shared.isConnected
        let isLoggedIn = SessionStore.shared.isLoggedIn
        let limit = maxConcurrentSynthesis
        let texts = spoken
        let clips = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var results = [Data?](repeating: nil, count: texts.count)
            var next = 0
            func addNext() {
                guard next < texts.count else { return }
                let position = next
                next += 1
                group.addTask {
                    let data = try await synthesizer.synthesize(
                        text: texts[position], voice: voice.voice,
                        vieNeuOfflineV2Voice: voice.vieNeuOfflineV2Voice, vieNeuOfflineV3Voice: voice.vieNeuOfflineV3Voice,
                        gwenTTSSpeaker: voice.gwenTTSSpeaker, speed: 1.0, baseURL: baseURL,
                        isConnected: isConnected, isLoggedIn: isLoggedIn
                    )
                    return (position, data)
                }
            }
            for _ in 0..<min(limit, texts.count) { addNext() }
            while let (position, data) = try await group.next() {
                results[position] = data
                addNext()
            }
            return results.compactMap { $0 }
        }
        try Task.checkCancellation()

        let store = self.store
        let bookID = book.id
        try await Task.detached(priority: .utility) {
            try store.writeChapter(
                bookID: bookID, index: index, voiceKey: voice.key, sentences: sentences, spoken: texts,
                translationEngine: engineName, translationTarget: target, clips: clips
            )
        }.value
    }

    // MARK: - Background execution (iOS 26+)

    // iOS suspends the app ~30s after it backgrounds unless audio is
    // playing; a BGContinuedProcessingTask (user-initiated, shows system
    // progress UI) lets a long "All chapters" job keep going. Older iOS:
    // the job just stops when suspended and the button resumes it later —
    // finished chapters stay on disk. macOS doesn't suspend, nothing to do.
    #if os(iOS)
    private static let backgroundTaskPrefix = "dev.yanglong.webnovelreader.audio-predownload"
    private var registeredBackgroundIDs: Set<String> = []
    private var backgroundTasks: [Int: AnyObject] = [:]
    #endif

    private func beginBackgroundTask(book: Book) {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return }
        let identifier = "\(Self.backgroundTaskPrefix).\(book.id)"
        if !registeredBackgroundIDs.contains(identifier) {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                Task { @MainActor in self.attachBackgroundTask(task, bookID: book.id) }
            }
            guard registered else { return }
            registeredBackgroundIDs.insert(identifier)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Downloading audio", subtitle: book.title)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            EventLogStore.shared.record(.download, "Không chạy nền được", detail: error.localizedDescription)
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
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.cancel(bookID: bookID) }
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
        task.setTaskCompleted(success: jobs[bookID]?.failure == nil)
        #endif
    }
}
