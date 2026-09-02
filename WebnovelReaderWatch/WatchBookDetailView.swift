import SwiftUI
import Core

/// Book screen — resume/start-from-1, full chapter list (reuses iOS's
/// `ChapterListSheet`/`ChapterTitles` directly, Digital-Crown-scrollable
/// like any other watchOS List), and download-for-offline (reuses
/// `DownloadManager` directly — see its doc comment; storage cost per book
/// is a few MB to ~50MB even for the longest book in the library, nowhere
/// near a real constraint on watchOS's storage budget).
struct WatchBookDetailView: View {
    let book: Book

    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var startChapterIndex: Int?
    @State private var showingChapterList = false

    private var resumeChapterIndex: Int? {
        progressStore.localProgress(bookID: book.id)?.chapterIndex
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(book.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let author = book.author {
                    Text(author).font(.footnote).foregroundStyle(.secondary)
                }
                Text("\(book.n) chương").font(.footnote).foregroundStyle(.secondary)

                if let resumeChapterIndex, resumeChapterIndex > 0 {
                    Button("Tiếp tục — Chương \(resumeChapterIndex + 1)") {
                        startChapterIndex = resumeChapterIndex
                    }
                    .accessibilityIdentifier("continueButton")
                    Button("Từ đầu") {
                        startChapterIndex = 0
                    }
                    .accessibilityIdentifier("startFromBeginningButton")
                } else {
                    Button("Bắt đầu nghe") {
                        startChapterIndex = 0
                    }
                    .accessibilityIdentifier("startListeningButton")
                }

                Button {
                    showingChapterList = true
                } label: {
                    Label("Danh sách chương", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("chapterListButton")

                downloadButton
            }
        }
        .navigationTitle(book.title)
        .inlineNavigationTitle()
        .navigationDestination(item: $startChapterIndex) { chapterIndex in
            WatchPlaybackView(book: book, initialChapterIndex: chapterIndex)
        }
        .sheet(isPresented: $showingChapterList) {
            ChapterListSheet(book: book, currentChapterIndex: resumeChapterIndex ?? 0) { index in
                startChapterIndex = index
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if downloads.isDownloaded(book.id) {
            Button("Xoá bản tải xuống", role: .destructive) {
                downloads.deleteDownload(bookID: book.id)
            }
            .accessibilityIdentifier("deleteDownloadButton")
        } else if downloads.downloading.contains(book.id) {
            VStack(spacing: 4) {
                ProgressView(value: downloads.progress[book.id] ?? 0)
                Text("Đang tải...").font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("downloadProgressView")
        } else {
            Button {
                Task { await downloads.download(book: book, baseURL: SessionStore.baseURL) }
            } label: {
                Label("Tải để nghe offline", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("downloadButton")
        }
    }
}
