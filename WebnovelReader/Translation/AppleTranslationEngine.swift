import Foundation
// Translation's own types aren't fully Sendable-audited — @preconcurrency
// treats crossing into/out of this class leniently instead of erroring
// under Swift 6 strict concurrency, same as Apple's own guidance for
// consuming a not-yet-audited system framework.
@preconcurrency import Translation

/// Wraps Apple's on-device Translation framework (best quality of the two
/// engines, but iOS 18+ only and — confirmed by real testing — refuses to
/// run at all on the iOS Simulator) as a `TranslationEngine`.
///
/// The awkward part: a `TranslationSession` can only be created/refreshed
/// from inside SwiftUI's `.translationTask` modifier — there's no way for
/// a plain Swift type to construct one on its own. `ChapterTranslationDriver`
/// (a `ViewModifier` attached once in `ReaderView`) is the one place that
/// modifier lives; this class bridges across that gap with a continuation:
/// `translate(...)` calls `sessionRequest` (set by the driver) to make it
/// (re)configure `.translationTask`, then awaits whatever session SwiftUI
/// eventually hands back via `provideSession`.
@available(iOS 18.0, *)
@MainActor
final class AppleTranslationEngine: TranslationEngine, @unchecked Sendable {
    static let shared = AppleTranslationEngine()

    private init() {}

    nonisolated var displayName: String { "Apple Translate" }

    /// Set by `ChapterTranslationDriver` once it's in the view hierarchy —
    /// see that type for why this is a closure handoff rather than this
    /// class owning the `.translationTask` itself.
    var sessionRequest: ((Locale.Language, Locale.Language) -> Void)?

    private var currentSession: TranslationSession?
    private var currentSourceLanguage: Locale.Language?
    private var currentTargetLanguage: Locale.Language?
    private var pendingContinuation: CheckedContinuation<TranslationSession, Never>?
    private(set) var currentProgress: TranslationProgress?

    var translationProgress: TranslationProgress? { currentProgress }

    /// Apple's framework covers broad language coverage and the only real
    /// way to know if a specific pair truly works is to attempt it — so
    /// this always returns true and lets an actual failure surface through
    /// `translate`'s thrown error, same as any other engine.
    nonisolated func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool { true }

    /// One `session.translate(_:)` call per sentence rather than the
    /// batch `translations(from:)` API — sacrifices whatever internal
    /// pipelining the batch call might do, in exchange for
    /// `translationProgress` actually being able to advance sentence by
    /// sentence instead of jumping straight from 0 to done (the original
    /// point of a large-chapter translation "feels stuck" complaint this
    /// was built to fix). The session itself stays warm across calls
    /// (`requestSession` only reconfigures on an actual language-pair
    /// change), so this isn't paying per-sentence model-load cost.
    func translate(texts: [String], source: Locale.Language, target: Locale.Language) async throws -> [String] {
        let session = await requestSession(for: source, target: target)
        currentProgress = TranslationProgress(completed: 0, total: texts.count)
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            let response = try await session.translate(text)
            results.append(response.targetText)
            currentProgress = TranslationProgress(completed: results.count, total: texts.count)
        }
        currentProgress = nil
        return results
    }

    /// Reuses the existing session when both its source AND target
    /// language already match (avoids reloading the on-device language
    /// model for back-to-back chapters in the same language pair, the
    /// common case) — otherwise asks the driver to configure a new one and
    /// suspends until it arrives.
    private func requestSession(for source: Locale.Language, target: Locale.Language) async -> TranslationSession {
        if let currentSession, currentSourceLanguage == source, currentTargetLanguage == target {
            return currentSession
        }
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            sessionRequest?(source, target)
        }
    }

    /// Called by `ChapterTranslationDriver` once SwiftUI's
    /// `.translationTask` hands back a (re)configured session.
    func provideSession(_ session: TranslationSession, for source: Locale.Language, target: Locale.Language) {
        currentSession = session
        currentSourceLanguage = source
        currentTargetLanguage = target
        pendingContinuation?.resume(returning: session)
        pendingContinuation = nil
    }
}
