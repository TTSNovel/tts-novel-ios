import SwiftUI
import Core

/// The core watch screen — play/pause, chapter-level skip (not
/// sentence-level; screen real estate), a compact now-playing readout, and
/// a plain speed stepper (not the iPhone's full ReaderSettingsSheet).
struct WatchPlaybackView: View {
    let book: Book
    let initialChapterIndex: Int

    @EnvironmentObject private var playback: WatchPlaybackController
    @EnvironmentObject private var progressStore: ProgressStore

    var body: some View {
        VStack(spacing: 10) {
            Text(playback.chapter?.title ?? "Đang tải...")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("chapterTitleLabel")

            if let errorMessage = playback.errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.red)
            }

            HStack(spacing: 20) {
                Button {
                    Task { await playback.skipChapter(by: -1) }
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(playback.chapterIndex <= 0)
                .accessibilityIdentifier("previousChapterButton")

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .disabled(playback.isLoading)
                .accessibilityIdentifier("playPauseButton")

                Button {
                    Task { await playback.skipChapter(by: 1) }
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(playback.chapterIndex + 1 >= book.n)
                .accessibilityIdentifier("nextChapterButton")
            }
            .buttonStyle(.plain)

            Stepper(
                "Tốc độ \(String(format: "%.2gx", playback.speed))",
                value: $playback.speed, in: 0.5...2.0, step: 0.1
            )
            .font(.caption2)
            .accessibilityIdentifier("speedStepper")
        }
        .padding()
        .task {
            await playback.open(book: book, chapterIndex: initialChapterIndex)
        }
        .onDisappear {
            progressStore.recordLocal(bookID: book.id, chapterIndex: playback.chapterIndex, sentenceIndex: 0)
            Task { await progressStore.syncToServer(bookID: book.id) }
        }
    }
}
