import Foundation

/// Google Cloud Translation (v3) through the site's own `/api/translate`
/// (app/server.py in the tts-webnovel repo) — the service account and the
/// per-book glossary (cultivation/System terms like "Dao" → "Đạo") both
/// live server-side, and the server stores every translated segment per
/// chapter, so re-opening a chapter (on any device, or in the web reader)
/// doesn't pay for it twice. Needs a logged-in session (guest mode gets a
/// 401, surfaced as a normal translation failure).
///
/// Unlike the other engines this one is a value built per chapter
/// (`ReaderPlaybackController.currentTranslationEngine`), since the server
/// files translations under the book/chapter they belong to.
public struct GoogleCloudTranslationEngine: TranslationEngine {
    public typealias TranslateChunk = @Sendable (_ texts: [String], _ source: String, _ target: String) async throws -> [String]

    /// Kept well under the server's per-request limits
    /// (translation.MAX_SEGMENTS_PER_REQUEST / MAX_CHARS_PER_REQUEST) —
    /// small enough that the first chunk (the start of the chapter, where
    /// the reader is) lands quickly.
    static let maxSegmentsPerChunk = 40
    static let maxCharsPerChunk = 8000
    /// The first chunk is the start of the chapter — what audio needs first
    /// — so it's kept small: its sentences go to TTS as soon as it's back,
    /// without waiting on a full 40-segment chunk.
    static let maxSegmentsInFirstChunk = 8

    private let translateChunk: TranslateChunk

    public init(baseURL: URL, bookID: Int, chapterIndex: Int) {
        self.init { texts, source, target in
            try await APIClient.shared.translate(
                baseURL: baseURL, bookID: bookID, chapterIndex: chapterIndex, texts: texts, source: source, target: target
            )
        }
    }

    /// For tests — swaps out the network call.
    public init(translateChunk: @escaping TranslateChunk) {
        self.translateChunk = translateChunk
    }

    public var displayName: String { TranslationEngineKind.google.displayName }

    public func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        source.languageCode != nil && target.languageCode != nil
    }

    /// Sends the chapter as a few chunks in parallel and yields each chunk's
    /// sentences as soon as it comes back.
    public func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error> {
        let sourceCode = source.languageCode?.identifier ?? "en"
        let targetCode = target.languageCode?.identifier ?? "vi"
        let chunks = Self.chunkIndices(for: texts)
        let translateChunk = translateChunk
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: [(Int, String)].self) { group in
                        for chunk in chunks {
                            group.addTask {
                                let translated = try await translateChunk(chunk.map { texts[$0] }, sourceCode, targetCode)
                                return Array(zip(chunk, translated))
                            }
                        }
                        for try await pairs in group {
                            for (index, text) in pairs { continuation.yield((index, text)) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Consecutive index runs of at most `maxSegmentsPerChunk` segments
    /// (`maxSegmentsInFirstChunk` for the first) / `maxCharsPerChunk`
    /// characters (a single oversized segment still gets its own chunk).
    static func chunkIndices(for texts: [String]) -> [[Int]] {
        var chunks: [[Int]] = []
        var current: [Int] = []
        var chars = 0
        for (index, text) in texts.enumerated() {
            let maxSegments = chunks.isEmpty ? maxSegmentsInFirstChunk : maxSegmentsPerChunk
            if !current.isEmpty, current.count >= maxSegments || chars + text.count > maxCharsPerChunk {
                chunks.append(current)
                current = []
                chars = 0
            }
            current.append(index)
            chars += text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
