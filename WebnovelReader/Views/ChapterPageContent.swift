import SwiftUI
import Core

// Matches book_renderer.py's `.reading` CSS (`rgba(255, 220, 50, 0.6)`
// background, `rgba(255, 180, 0, 0.65)` outline) exactly — a fixed warm
// yellow/orange rather than an adaptive system color, because it's chosen
// specifically to stay legible against both a near-white and a near-black
// page background. accentColor.opacity(...) (the old iOS highlight) reads
// fine in light mode but washes out to near-invisible in dark mode.
private extension Color {
    static let readingHighlight = Color(red: 1, green: 220 / 255, blue: 50 / 255).opacity(0.6)
    static let readingHighlightOutline = Color(red: 1, green: 180 / 255, blue: 0).opacity(0.65)
}

/// One chapter page's content — the actually-open chapter renders
/// interactively (sentence-highlighted, auto-scrolling, tap-to-seek); any
/// other chapter (a neighbor a pager has paged to but hasn't committed
/// navigation for yet, or before the session has caught up to it) renders a
/// plain, non-interactive preview sourced from `ReaderPlaybackController`'s
/// prefetch cache. Platform-agnostic SwiftUI — shared by iOS's
/// `ChapterPagerView` (`UIPageViewController`-backed swipe paging) and
/// macOS's (prev/next-button-backed) pager, each of which only supplies the
/// surrounding navigation chrome.
struct ChapterPageContent: View {
    let book: Book
    let index: Int

    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var session: SessionStore

    private var isCurrentSession: Bool { playback.book?.id == book.id }
    private var isLive: Bool { isCurrentSession && index == playback.chapterIndex }

    // Base point sizes are .title2.bold()/.body's actual system-font
    // metrics — reproduced as explicit sizes (rather than composing on top
    // of the semantic Font values) so `playback.fontScale` can multiply
    // them directly; SwiftUI's semantic Font cases don't expose a size to
    // scale.
    private var titleFont: Font { .system(size: 22 * playback.fontScale, weight: .bold) }
    private var bodyFont: Font { .system(size: 17 * playback.fontScale) }

    var body: some View {
        if isLive {
            livePage
        } else {
            previewPage
        }
    }

    private var livePage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Placed *before* the chapter body, not after — a real
                    // chapter's text easily runs several screens long, and a
                    // banner appended after it sits below the fold until the
                    // reader scrolls all the way down, invisible for the
                    // entire translation (confirmed: real device screenshot
                    // showed only the toolbar's bare spinner, this banner
                    // nowhere on screen, chapter open at the top). Up here
                    // it's the first thing visible the moment the chapter
                    // opens — a chapter with 100+ sentences can take tens of
                    // seconds to translate, and a bare toolbar spinner alone
                    // (no count) reads as "stuck"/a bug.
                    if playback.isTranslating {
                        translationProgressBanner
                    } else if let error = playback.translationErrorMessage {
                        // Previously tracked but never shown — a tap that
                        // hits `canTranslate == false` (e.g. detected source
                        // language this engine doesn't support) reverted
                        // `showingTranslation` with zero visible feedback,
                        // reading as "the button just doesn't work."
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if let chapter = playback.chapter {
                        chapterBody(chapter)
                    } else if let error = playback.loadError {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    // /api/tts requires login even though reading itself is
                    // public — ReaderPlaybackController.makeFetchTask falls
                    // back to the on-device voice for the exact same two
                    // reasons this footnote covers, so keep them in sync.
                    if (!network.isConnected || !session.isLoggedIn) && !playback.voice.isOffline {
                        Text(
                            network.isConnected
                                ? "Chế độ khách — tạm dùng giọng đọc ngoại tuyến (đăng nhập ở Cài đặt để dùng giọng online)"
                                : "Đang offline — tạm dùng giọng đọc ngoại tuyến"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let error = playback.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                // Each page is its own hosting context rather than a shared
                // SwiftUI ancestor, so PlaybackBar's reserved space
                // (normally one `.safeAreaInset` on a common container)
                // can't be applied once above the pager — add it directly
                // to every page's content instead.
                .padding(.bottom, PlaybackBar.reservedHeight)
            }
            .onChange(of: playback.highlightedSentenceIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var translationProgressBanner: some View {
        HStack(spacing: 8) {
            if let progress = playback.translationProgress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .frame(width: 80)
                Text("Đang dịch \(progress.completed)/\(progress.total) câu")
            } else {
                ProgressView()
                Text("Đang dịch chương...")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// Plain title+text until playback has actually segmented the chapter
    /// (reader.js only wraps <span data-r-s> once reading starts, too —
    /// see wrapContentSentences' call site in start()). Once it has,
    /// render one sentence per line so the currently-playing one can be
    /// highlighted and scrolled to — sentence 0 is always the chapter
    /// title (see ReaderPlaybackController.sentenceSequence, which is what
    /// makes read-aloud announce the chapter before its body), rendered
    /// with the same bold/title styling the plain-text branch below gives
    /// it as a separate header, so there's no visible duplicate.
    @ViewBuilder
    private func chapterBody(_ chapter: Chapter) -> some View {
        if playback.sentences.isEmpty {
            Text(chapter.title).font(titleFont)
            Text(chapter.text).font(bodyFont)
        } else {
            // Falls back to the original `sentences` per-sentence for
            // whichever ones translation isn't showing, isn't needed, or
            // hasn't landed yet — same array length/order as `sentences`
            // either way, so indices below (seek/highlight) stay valid
            // regardless of how far translation has gotten. See
            // `ReaderPlaybackController.displaySentences`'s doc comment.
            let displaySentences = playback.displaySentences
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(displaySentences.enumerated()), id: \.offset) { sentenceIndex, sentence in
                    let isHighlighted = sentenceIndex == playback.highlightedSentenceIndex
                    // A real Button, not Text+.onTapGesture, so tap
                    // priority against ancestor scroll/pan surfaces (the
                    // iOS pager's own horizontal-paging scroll view
                    // wrapping this vertical SwiftUI ScrollView) resolves
                    // the same way any List row's does. .buttonStyle(.plain)
                    // strips Button's default chrome/tint so the row still
                    // looks exactly like the plain Text label it replaces —
                    // all the actual visual state (background/border) lives
                    // on the label content below, untouched by the button
                    // style. See ReaderPlaybackController.seek's doc
                    // comment for why taps could stop registering here.
                    Button {
                        playback.seek(to: sentenceIndex)
                    } label: {
                        Text(sentence)
                            .font(sentenceIndex == 0 ? titleFont : bodyFont)
                            // Explicit — .plain buttons shouldn't tint text,
                            // but this exact codebase has hit accidental
                            // accent-color text on a button label before
                            // (see "Fix blue accent text on the Model/Giọng
                            // đọc dropdown rows"); stating it plainly here
                            // costs nothing and rules that class of bug out.
                            .foregroundStyle(.primary)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(isHighlighted ? Color.readingHighlight : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.readingHighlightOutline, lineWidth: isHighlighted ? 2 : 0)
                            )
                            // Widens the tap target to the full padded row
                            // instead of just the glyphs themselves.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(sentenceIndex)
                    .accessibilityIdentifier("sentenceText_\(sentenceIndex)")
                }
            }
        }
    }

    /// A neighboring chapter's plain title + text, sourced from
    /// `playback.cachedChapter(index:)` — never interactive/highlighted
    /// (that only makes sense for whichever chapter is actually "open").
    /// Falls back to a spinner + on-appear prefetch if the pager reached
    /// here before the neighbor-prefetch (kicked off from `loadChapter`)
    /// had a chance to land.
    private var previewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let chapter = playback.cachedChapter(index: index) {
                    Text(chapter.title).font(titleFont)
                    Text(chapter.text).font(bodyFont)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await playback.prefetchChapter(index: index) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .padding(.bottom, PlaybackBar.reservedHeight)
        }
    }
}
