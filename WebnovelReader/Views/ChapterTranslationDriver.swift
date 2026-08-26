import SwiftUI
@preconcurrency import Translation

/// Wires `AppleTranslationEngine` to Apple's Translation framework — a
/// `TranslationSession` can only be created (and only stays warm/reusable)
/// from inside the `.translationTask` SwiftUI modifier, so this is the one
/// place in the view hierarchy that actually talks to the framework;
/// `AppleTranslationEngine` publishes nothing itself and knows nothing
/// about `ReaderPlaybackController` — it just asks this driver (via
/// `sessionRequest`) to configure/refresh `.translationTask` whenever
/// `translate(...)` needs a session, and receives it back via
/// `provideSession`.
///
/// Attached once, in `ReaderView`, rather than per-page in
/// `ChapterPagerView` — one live session for the whole reading screen, not
/// one per pager slot.
@available(iOS 18.0, *)
private struct ChapterTranslationDriver: ViewModifier {
    @State private var configuration: TranslationSession.Configuration?
    @State private var pendingSource: Locale.Language?
    @State private var pendingTarget: Locale.Language?

    func body(content: Content) -> some View {
        AppleTranslationEngine.shared.sessionRequest = { source, target in
            pendingSource = source
            pendingTarget = target
            // Reuses the existing session (via `invalidate()`) when the
            // requested language pair matches whatever's already
            // configured — avoids reloading the on-device language model
            // for back-to-back chapters in the same source/target pair,
            // the common case. Only builds a genuinely new `Configuration`
            // when the pair actually changes.
            if configuration?.source == source, configuration?.target == target {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
        }
        return content
            .translationTask(configuration) { session in
                guard let pendingSource, let pendingTarget else { return }
                AppleTranslationEngine.shared.provideSession(session, for: pendingSource, target: pendingTarget)
            }
    }
}

extension View {
    /// No-op on iOS < 18 — `AppleTranslationEngine` itself is only ever
    /// selectable/usable there too (see `ReaderPlaybackController`'s
    /// engine picker), so there's nothing for a driver to do on older OS.
    @ViewBuilder
    func chapterTranslationSupport() -> some View {
        if #available(iOS 18.0, *) {
            modifier(ChapterTranslationDriver())
        } else {
            self
        }
    }
}
