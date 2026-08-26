import Foundation

/// A pluggable chapter-translation backend — `ReaderPlaybackController`
/// only ever talks to whichever engine `translationEngineKind` currently
/// selects through this protocol, so adding/removing/swapping an engine
/// never touches the state machine (`evaluateTranslation`/
/// `performPendingTranslation`/the translate button/`autoTranslate`), only
/// which concrete type gets picked. Two engines exist today:
/// `AppleTranslationEngine` (on-device via Apple's Translation framework —
/// best quality, but iOS 18+ only and, per real testing, refuses to run at
/// all on the iOS Simulator) and `OpusMTTranslationEngine` (a small
/// bundled ONNX model — always available offline on any iOS version, at a
/// real quality cost on longer/complex prose — see its doc comment).
/// `Sendable` because `ReaderPlaybackController` (MainActor) holds a
/// `currentTranslationEngine: TranslationEngine?` and calls `await
/// engine.translate(...)` on it — crossing into whichever actor the
/// concrete engine actually runs on (`OpusMTTranslationEngine` is its own
/// `actor`; `AppleTranslationEngine` is `@MainActor`, `@unchecked Sendable`
/// since all its mutable state is only ever touched from MainActor) needs
/// the existential itself to be provably safe to hand across that
/// boundary.
protocol TranslationEngine: Sendable {
    /// Shown in the engine picker (Cài đặt đọc).
    var displayName: String { get }

    /// Whether this engine can currently attempt a translation from
    /// `source` to `target` — checked before `translate` so callers can
    /// skip a doomed attempt (e.g. iOS < 18 for `AppleTranslationEngine`,
    /// or an unbundled source/target pair for `OpusMTTranslationEngine` —
    /// its model is a fixed EN→VI pair, so it can't serve an arbitrary
    /// `target` the way `AppleTranslationEngine` can) instead of surfacing
    /// a generic failure after the fact.
    func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool

    /// Streams each translated sentence back tagged with its index in
    /// `texts`, as soon as that one sentence is ready — not the whole
    /// array at once. Index order, not necessarily arrival order:
    /// `OpusMTTranslationEngine` translates several sentences concurrently
    /// (see its doc comment), so a later sentence can land before an
    /// earlier one. Callers (`ReaderPlaybackController.performPendingTranslation`)
    /// display/synthesize audio per sentence as results arrive, so a long
    /// chapter fills in progressively instead of the reader staring at
    /// original text (or a spinner) until every sentence is done. Also
    /// doubles as the progress signal — "how many items have arrived so
    /// far out of `texts.count`" — so there's no separate polled property
    /// to keep in sync with it.
    func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error>
}

struct TranslationProgress: Sendable, Equatable {
    let completed: Int
    let total: Int
}

enum TranslationEngineKind: String, CaseIterable, Identifiable {
    case apple
    case opusMT

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple Translate"
        case .opusMT: return "OPUS-MT (offline)"
        }
    }
}

/// A small curated set of target ("primary") languages — this app's core
/// audience reads in Vietnamese (the default, and the only target
/// `OpusMTTranslationEngine`'s bundled model actually supports), but the
/// picker offers a few other common ones for readers who want chapters
/// translated somewhere else. Deliberately not "every BCP-47 language":
/// `ReaderPlaybackController.primaryLanguageCode` stores a plain string
/// specifically so an unlisted system default (see its doc comment) still
/// round-trips correctly even without a matching case here — this enum is
/// only for the Settings picker's options, not the source of truth.
enum PrimaryLanguageOption: String, CaseIterable, Identifiable {
    case vietnamese = "vi"
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vietnamese: return "Vietnamese"
        case .english: return "English"
        case .chineseSimplified: return "Chinese (Simplified)"
        case .chineseTraditional: return "Chinese (Traditional)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}
