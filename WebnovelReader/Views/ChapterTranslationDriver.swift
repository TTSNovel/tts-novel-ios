import SwiftUI
@preconcurrency import Translation

/// Wires `ReaderPlaybackController`'s translation state to Apple's
/// Translation framework — a `TranslationSession` can only be created (and
/// only stays warm/reusable) from inside the `.translationTask` SwiftUI
/// modifier, so this is the one place in the view hierarchy that actually
/// talks to the framework; the controller itself just publishes
/// `translationSourceLanguage`/`translationGeneration` and consumes the
/// session handed back here via `performPendingTranslation`.
///
/// Attached once, in `ReaderView`, rather than per-page in
/// `ChapterPagerView` — one live session for the whole reading screen, not
/// one per pager slot.
@available(iOS 18.0, *)
private struct ChapterTranslationDriver: ViewModifier {
    @EnvironmentObject private var playback: ReaderPlaybackController
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                await playback.performPendingTranslation(using: session)
            }
            .onChange(of: playback.translationGeneration) { _, _ in
                updateConfiguration()
            }
    }

    /// Reuses the existing session (via `invalidate()`) when the new
    /// chapter's source language matches whatever the session is already
    /// configured for — avoids reloading the on-device language model for
    /// back-to-back chapters in the same source language, which is the
    /// common case. Only builds a genuinely new `Configuration` when the
    /// language pair actually changes.
    private func updateConfiguration() {
        guard let source = playback.translationSourceLanguage else { return }
        if configuration?.source == source {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: "vi"))
        }
    }
}

extension View {
    /// No-op on iOS < 18 — `translationSourceLanguage` never gets set on
    /// those OS versions either (see `evaluateTranslation()`'s guard), so
    /// there's nothing for a driver to do there anyway.
    @ViewBuilder
    func chapterTranslationSupport() -> some View {
        if #available(iOS 18.0, *) {
            modifier(ChapterTranslationDriver())
        } else {
            self
        }
    }
}
