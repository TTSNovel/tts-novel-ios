import SwiftUI

/// Persistent mini-player — the single real instance is attached via
/// `.safeAreaInset(edge: .bottom)` on LibraryView's NavigationStack (see
/// LibraryView.body), NOT per-screen. A per-screen attachment (one real
/// PlaybackBar on every List/ScrollView) was tried to fix a
/// text-covered-by-the-bar layout bug, but every screen a NavigationStack
/// pushes stays mounted underneath the current one — so N attached
/// PlaybackBars means N simultaneously-live "playPauseButton"s, which is an
/// accessibility hazard (ambiguous queries) and broke playback persistence
/// in testing.
///
/// Keeping only one real instance means a plain `.safeAreaInset` on the
/// ancestor NavigationStack is NOT enough on its own — empirically it does
/// not reliably keep a *pushed* screen's own ScrollView/List content clear
/// of this bar once its height changes (the combined progress row only
/// appears once `sentenceCount > 0`), so chapter text can render partly
/// behind it. The fix is `playback.barHeight` (published below, measured
/// live via `.onGeometryChange`): every OTHER screen reserves an invisible
/// `Color.clear` spacer of that exact height via its own
/// `.safeAreaInset(edge: .bottom)` — no duplicate interactive element, just
/// matching reserved space. See ReaderView/BookDetailView/HistoryView/
/// DownloadedBooksView.
///
/// Renders nothing until something has actually been opened this session
/// (`playback.book == nil`).
struct PlaybackBar: View {
    @EnvironmentObject private var playback: ReaderPlaybackController

    var body: some View {
        if let book = playback.book {
            VStack(spacing: 4) {
                // Row 1: book title + chapter number merged onto one line
                // (was title/chapter on two lines) to keep the bar compact
                // — pushes to the reader via the same ChapterRoute
                // navigationDestination LibraryView already registers
                // (navigationDestination registrations, unlike
                // safeAreaInset, are documented to apply stack-wide
                // regardless of push depth, so this works correctly from
                // any screen this bar is shown on).
                NavigationLink(value: ChapterRoute(book: book, chapterIndex: playback.chapterIndex)) {
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
                            .frame(width: 48, alignment: .trailing)
                    }
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                playback.barHeight = newHeight
            }
        }
        // No `else`: once a book has ever been opened this session `book`
        // never goes back to nil (see ReaderPlaybackController's doc
        // comment), so `barHeight`'s initial 0 correctly covers "nothing
        // opened yet" and never needs resetting back down.
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

    private var preloadProgressValue: Double {
        guard playback.sentenceCount > 0 else { return 0 }
        return Double(playback.preloadedCount) / Double(playback.sentenceCount)
    }
}

#Preview {
    NavigationStack {
        Text("Content")
            .safeAreaInset(edge: .bottom) {
                PlaybackBar()
            }
    }
    .environmentObject(ReaderPlaybackController.shared)
}
