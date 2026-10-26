import Foundation

/// The translation boundary: wraps whichever engine the reader/predownload
/// picked and logs a failed `translate` with what's needed to reproduce it —
/// engine, language pair, the first sentence that didn't come back (index
/// and text), how far it got and how long it ran. Without this an engine
/// error reaches the caller as a bare "Unable to Translate".
public struct LoggedTranslationEngine: TranslationEngine {
    public let base: TranslationEngine
    public let context: [String: String]

    public init(base: TranslationEngine, context: [String: String] = [:]) {
        self.base = base
        self.context = context
    }

    public var displayName: String { base.displayName }

    public func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        base.canTranslate(from: source, to: target)
    }

    public func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error> {
        let upstream = base.translate(texts: texts, source: source, target: target)
        let engineName = base.displayName
        let baseContext = context
        return AsyncThrowingStream { continuation in
            let task = Task {
                let started = Date()
                var done = Set<Int>()
                do {
                    for try await item in upstream {
                        done.insert(item.index)
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch {
                    let failedIndex = texts.indices.first { !done.contains($0) }
                    var info = baseContext.merging([
                        "engine": engineName,
                        "pair": "\(source.minimalIdentifier)→\(target.minimalIdentifier)",
                        "translated": "\(done.count)/\(texts.count)",
                        "ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
                    ]) { $1 }
                    if let failedIndex {
                        info["sentence"] = "\(failedIndex)"
                        info["text"] = String(texts[failedIndex].prefix(500))
                    }
                    Log.error(.translation, "Translation failed", error: error, info)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
