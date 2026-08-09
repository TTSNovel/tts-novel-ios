import SwiftUI

struct BookDetailView: View {
    let book: Book

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var network: NetworkMonitor

    // readingActions pushes via this instead of NavigationLink — a
    // NavigationLink placed inside a List always renders with the system's
    // row-disclosure chrome (a plain row + chevron) no matter what
    // .buttonStyle is applied to it, which is what was actually behind the
    // "buttons stuck together/not working" report: both pills were
    // silently rendering as two side-by-side list-style rows instead of
    // buttons (confirmed by screenshotting the live simulator — see
    // BookDetailActionsUITests). A plain Button + .navigationDestination
    // isn't subject to that override, so .buttonStyle actually applies.
    @State private var pendingChapterIndex: Int?
    @State private var chapterTitles: [String]?

    var body: some View {
        List {
            // Each interactive block (readingActions, downloadControl) gets
            // its own row instead of being nested together inside one
            // shared VStack — cramming cover/title/multiple buttons into a
            // single List row was making iOS merge/miscompute their
            // accessibility frames (confirmed via BookDetailActionsUITests:
            // buttons reported wildly inconsistent heights, ~18pt vs
            // ~38pt, well under Apple's 44pt tap-target minimum) and read
            // as buttons "stuck together"/unresponsive. Separate rows is
            // the standard List-safe pattern for this.
            Section {
                VStack(spacing: 8) {
                    CoverImage(book: book)
                        .frame(width: 140, height: 187)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(book.title).font(.title3.bold()).multilineTextAlignment(.center)
                    if let author = book.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("\(book.n) chương · \(book.category)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)

                actionRow
                    .listRowSeparator(.hidden)
            }

            Section("Danh sách chương") {
                ForEach(0..<book.n, id: \.self) { index in
                    NavigationLink {
                        ReaderView(book: book, chapterIndex: index)
                    } label: {
                        Text(chapterLabel(for: index))
                    }
                }
            }
        }
        .navigationDestination(item: $pendingChapterIndex) { index in
            ReaderView(book: book, chapterIndex: index)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .readerSettingsToolbar()
        .task {
            chapterTitles = await ChapterTitles.load(book: book)
        }
    }

    /// Falls back to a bare ordinal ("Chương N") until the real title has
    /// loaded (or if it never does — e.g. offline and not downloaded) —
    /// see ChapterTitles.load.
    private func chapterLabel(for index: Int) -> String {
        guard let titles = chapterTitles, titles.indices.contains(index), !titles[index].isEmpty else {
            return "Chương \(index + 1)"
        }
        return titles[index]
    }

    /// Icon-only, one line — text-labeled pill buttons (even compact ones)
    /// still read as too much visual weight for 2-3 actions sitting right
    /// under the cover. Each icon carries an .accessibilityLabel since
    /// there's no visible text for VoiceOver to read.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 28) {
            Spacer()

            Button {
                pendingChapterIndex = 0
            } label: {
                Image(systemName: "book")
            }
            .accessibilityLabel("Đọc từ đầu")
            .accessibilityIdentifier("startFromBeginningButton")

            if let progress = progressStore.localProgress(bookID: book.id) {
                Button {
                    pendingChapterIndex = progress.chapterIndex
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .accessibilityLabel("Đọc tiếp, Chương \(progress.chapterIndex + 1)")
                .accessibilityIdentifier("continueReadingButton")
            }

            if downloads.isDownloaded(book.id) {
                Button(role: .destructive) {
                    downloads.deleteDownload(bookID: book.id)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Xoá bản tải xuống")
                .accessibilityIdentifier("deleteDownloadButton")
            } else if downloads.downloading.contains(book.id) {
                DownloadRingIcon(progress: downloads.progress[book.id] ?? 0)
                    .accessibilityLabel("Đang tải xuống")
            } else {
                Button {
                    Task { await downloads.download(book: book, baseURL: SessionStore.baseURL) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(!network.isConnected)
                .accessibilityLabel("Tải xuống để đọc offline")
                .accessibilityIdentifier("downloadButton")
            }

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.title3)
    }
}

/// App Store-style download indicator — a circular progress ring around
/// the same download glyph, in place of the plain download icon while a
/// download is in flight. Sized/backgrounded to match the bordered icon
/// buttons on either side of it in actionRow, so the row doesn't visibly
/// jump when this replaces the idle download button.
private struct DownloadRingIcon: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(progress, 0.03))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
            Image(systemName: "arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 20, height: 20)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: Circle())
    }
}

#Preview {
    NavigationStack {
        BookDetailView(book: Book(id: 1, title: "Truyện mẫu", author: nil, category: "Demo", n: 3, cover: nil))
    }
    .environmentObject(SessionStore.shared)
    .environmentObject(DownloadManager.shared)
    .environmentObject(ProgressStore.shared)
    .environmentObject(NetworkMonitor.shared)
    .environmentObject(ReaderPlaybackController.shared)
}

#Preview("Download ring") {
    HStack(spacing: 28) {
        DownloadRingIcon(progress: 0.0)
        DownloadRingIcon(progress: 0.35)
        DownloadRingIcon(progress: 0.8)
    }
    .padding()
}
