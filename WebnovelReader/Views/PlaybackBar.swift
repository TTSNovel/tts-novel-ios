import SwiftUI

/// Persistent mini-player — the single real instance lives as a plain
/// `.overlay(alignment: .bottom)` at the window root (see
/// WebnovelReaderApp.body), NOT attached to any screen's own
/// List/NavigationStack, and NOT per-screen.
///
/// Two other placements were tried and both caused real bugs, so don't
/// reintroduce either:
/// - One real PlaybackBar per screen (attached to every List/ScrollView):
///   every screen a NavigationStack pushes stays mounted underneath the
///   current one, so N attached PlaybackBars means N simultaneously-live
///   "playPauseButton"s — an accessibility hazard (ambiguous queries) that
///   broke playback-persistence tests.
/// - The one real instance attached via `.safeAreaInset(edge: .bottom)` on
///   LibraryView's NavigationStack (or its List): nesting this bar's real,
///   conditionally-changing height (the combined-progress row only exists
///   once `sentenceCount > 0`) inside a List's own safeAreaInset chain
///   creates a genuine layout feedback loop — the bar's height affects the
///   List's inset, which affects layout, which can retrigger measurement —
///   and in testing this froze the entire app: it kept rendering a stale
///   last frame (looked visually fine in a screenshot) while every
///   accessibility query against it, for *any* element anywhere in the app,
///   silently found nothing, so no tap did anything at all. A plain
///   `.overlay` at the root doesn't participate in anyone's safeAreaInset
///   negotiation, so this can't happen.
///
/// Screens instead reserve their own bottom space for it via
/// `PlaybackBar.reservedHeight`: every screen (including LibraryView) adds
/// an inert `Color.clear` spacer of this fixed height via its own
/// `.safeAreaInset(edge: .bottom)` — see ReaderView/BookDetailView/
/// HistoryView/DownloadedBooksView/LibraryView. Deliberately a fixed
/// constant rather than a value reactively measured off the real bar (e.g.
/// via `.onGeometryChange` publishing into a shared `ObservableObject`):
/// that has the same feedback-loop risk as above. `reservedHeight` covers
/// the bar's tallest (3-row, `sentenceCount > 0`) state with a small
/// margin, so the 2-row idle state just reserves a bit more space than
/// strictly needed — a minor visual trade for real stability.
///
/// Renders nothing until something has actually been opened this session
/// (`playback.book == nil`).
struct PlaybackBar: View {
    @EnvironmentObject private var playback: ReaderPlaybackController

    static let reservedHeight: CGFloat = 100

    var body: some View {
        if let book = playback.book {
            // Explicit per-row bottom padding instead of a uniform
            // VStack `spacing:` — the progress row (row 2) only exists once
            // `sentenceCount > 0`, and a single fixed spacing value can't
            // give the title-to-controls gap enough room when that row is
            // absent without *also* stretching the already-good
            // title-to-progress-to-controls spacing when it's present.
            VStack(spacing: 0) {
                // Row 1: book title + chapter number merged onto one line
                // (was title/chapter on two lines) to keep the bar compact
                // — jumps to the reader by setting pendingChapterRoute
                // (this bar lives outside any NavigationStack, as a root
                // overlay — see its doc comment — so it can't use
                // NavigationLink directly; LibraryView observes this and
                // pushes the route onto its own navPath instead).
                Button {
                    playback.pendingChapterRoute = ChapterRoute(book: book, chapterIndex: playback.chapterIndex)
                } label: {
                    HStack(spacing: 4) {
                        Text(book.title).font(.caption).bold()
                        Text("· \(playback.chapterIndex + 1)/\(book.n)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playbackBarTitle")
                .padding(.bottom, playback.sentenceCount > 0 ? 4 : 12)

                // Row 2: one combined bar — the filled (accent) portion is
                // how far playback has actually reached, the lighter
                // portion underneath it is how far ahead audio is already
                // preloaded/buffered, same idea as a video player's
                // played-vs-buffered scrubber. Only one number is shown
                // (read position); the preload amount is legible from how
                // far the lighter shade extends past it.
                if playback.sentenceCount > 0 {
                    HStack(spacing: 6) {
                        combinedProgressBar
                        Text("\(min(playback.currentSentenceIndex + 1, playback.sentenceCount))/\(playback.sentenceCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        // Specific "preloaded through sentence N" number,
                        // separate from the read-position counter — a
                        // gray-fill bar alone only showed a fraction, not
                        // which exact sentence preload had actually reached.
                        // Same "N/total" shape as the read-position counter
                        // instead of a bare number, so it's unambiguous
                        // this is also relative to the chapter's total.
                        if playback.preloadedThroughIndex >= 0 {
                            Text("⇩\(min(playback.preloadedThroughIndex + 1, playback.sentenceCount))/\(playback.sentenceCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)
                }

                // Row 3: transport controls, centered, own line.
                HStack(spacing: 40) {
                    Button {
                        Task { await playback.goTo(playback.chapterIndex - 1) }
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .accessibilityLabel("Chương trước")
                    .disabled(playback.chapterIndex <= 0)

                    Button {
                        playback.togglePlayback()
                    } label: {
                        if playback.isLoadingAudio {
                            ProgressView()
                        } else {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        }
                    }
                    .accessibilityLabel(playback.isPlaying ? "Tạm dừng" : "Đọc")
                    .accessibilityIdentifier("playPauseButton")

                    Button {
                        Task { await playback.goTo(playback.chapterIndex + 1) }
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .accessibilityLabel("Chương tiếp")
                    .disabled(playback.chapterIndex >= book.n - 1)
                }
                .font(.title3)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            // .accessibilityElement(children: .contain) makes this VStack
            // itself a distinct accessibility node that *contains* its
            // children rather than an implicit passthrough container —
            // without it, adding a second real Button here (the title row,
            // now a Button instead of a NavigationLink — see its comment)
            // made this identifier bleed onto a child Button instead of
            // staying on this VStack, so `app.buttons["playPauseButton"]`
            // resolved to an element whose actual identifier was
            // "playbackBar" and every `matching(identifier:)` query on
            // either name silently found nothing.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playbackBar")
        }
    }

    private var combinedProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: geometry.size.width * preloadProgressValue)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * readProgressValue)
            }
        }
        .frame(height: 5)
    }

    private var readProgressValue: Double {
        guard playback.sentenceCount > 0 else { return 0 }
        return Double(min(playback.currentSentenceIndex + 1, playback.sentenceCount)) / Double(playback.sentenceCount)
    }

    // Deliberately mirrors the "⇩N/total" text above (preloadedThroughIndex),
    // NOT playback.preloadedCount — preloadedCount is a raw count of
    // sentences actually fetched *this session*, which undercounts on a
    // resume: prepareResume seeds preloadedThroughIndex at (resume position
    // - 1) since everything before that was already read/doesn't need
    // preloading, but those skipped sentences never enter preloadedCount.
    // Using preloadedCount here made this gray fill visibly stop short of
    // where the "⇩N/total" number said preload had actually reached.
    private var preloadProgressValue: Double {
        guard playback.sentenceCount > 0 else { return 0 }
        return Double(playback.preloadedThroughIndex + 1) / Double(playback.sentenceCount)
    }
}

#Preview {
    Text("Content")
        .overlay(alignment: .bottom) {
            PlaybackBar()
        }
        .environmentObject(ReaderPlaybackController.shared)
}
