import SwiftUI
import Core

/// BookDetailView's "download audio" button — only for a downloaded book
/// (pre-rendering reads chapter text from disk). Shows a progress ring
/// while that book's job runs; either way, tapping opens the sheet.
struct AudioPredownloadButton: View {
    let book: Book
    @ObservedObject private var manager = AudioPredownloadManager.shared
    @State private var showingSheet = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            if let job = manager.jobs[book.id], job.isRunning {
                ProgressView(value: job.progressValue, total: Double(max(job.chapters.count, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Image(systemName: "waveform.badge.plus")
            }
        }
        .accessibilityLabel("Tải audio để nghe offline")
        .accessibilityIdentifier("audioPredownloadButton")
        .sheet(isPresented: $showingSheet) {
            AudioPredownloadSheet(book: book, isPresented: $showingSheet)
        }
    }
}

struct AudioPredownloadSheet: View {
    let book: Book
    @Binding var isPresented: Bool

    @EnvironmentObject private var playback: ReaderPlaybackController
    @ObservedObject private var manager = AudioPredownloadManager.shared
    /// nil = all remaining chapters.
    @State private var count: Int? = 10
    @State private var confirmingReplace = false

    private static let counts: [Int?] = [10, 50, 100, nil]

    private var voice: PrerenderVoice { playback.prerenderVoice }
    private var range: Range<Int> { manager.chapterRange(book: book, count: count) }
    private var job: AudioPredownloadManager.Job? { manager.jobs[book.id] }
    private var otherVoice: PrerenderedBookInfo? {
        manager.renderedVoice(bookID: book.id).flatMap { $0.voiceKey == voice.key ? nil : $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Giọng đọc", value: voice.displayName)
                    Picker("Số chương", selection: $count) {
                        ForEach(Self.counts, id: \.self) { value in
                            Text(value.map(String.init) ?? "Tất cả").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("audioPredownloadCountPicker")
                    if !range.isEmpty {
                        Text("Chương \(range.lowerBound + 1)–\(range.upperBound)")
                            .foregroundStyle(.secondary)
                    }
                    estimateRow
                } footer: {
                    Text("Audio được dịch và tạo sẵn theo giọng đang chọn, lúc nghe chỉ phát file — không cần mạng, đỡ tốn pin.")
                }

                if let job, job.isRunning || job.failure != nil {
                    Section("Tiến độ") {
                        ProgressView(value: job.progressValue, total: Double(max(job.chapters.count, 1)))
                        Text("\(job.completed)/\(job.chapters.count) chương")
                            .accessibilityIdentifier("audioPredownloadCompleted")
                        if job.isRunning, let current = job.currentChapter {
                            Text(Self.stepText(job, chapter: current))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityIdentifier("audioPredownloadStep")
                        }
                        if let failure = job.failure {
                            Text(failure).foregroundStyle(.red)
                        }
                    }
                }

                if let reason = manager.unavailableReason(for: voice) {
                    Section { Text(reason).foregroundStyle(.red) }
                } else if [.googleTTS, .gwenTTS].contains(voice.voice) {
                    Section {
                        Text(voice.voice == .googleTTS
                             ? "Google Cloud TTS tính phí theo số ký tự — tải nhiều chương sẽ tốn chi phí."
                             : "Gwen-TTS rất chậm (10–90 giây mỗi câu) — tải nhiều chương sẽ mất nhiều giờ.")
                            .foregroundStyle(.orange)
                    }
                }
                #if os(iOS)
                if voice.voice.isOffline {
                    Section {
                        Text("Giọng offline tạo audio ngay trên máy và tốn pin — nên cắm sạc khi tải.")
                            .foregroundStyle(.secondary)
                    }
                }
                #endif
            }
            .formStyle(.grouped)
            .navigationTitle("Tải audio")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if job?.isRunning == true {
                        Button("Dừng", role: .destructive) { manager.cancel(bookID: book.id) }
                            .accessibilityIdentifier("audioPredownloadStopButton")
                    } else {
                        Button("Tải") {
                            if otherVoice != nil { confirmingReplace = true } else { start() }
                        }
                        .disabled(range.isEmpty || manager.unavailableReason(for: voice) != nil)
                        .accessibilityIdentifier("audioPredownloadStartButton")
                    }
                }
            }
            .confirmationDialog(
                "Thay audio đã tải?", isPresented: $confirmingReplace, titleVisibility: .visible
            ) {
                Button("Xoá và tải lại", role: .destructive) { start() }
            } message: {
                Text("Sách này đã có audio giọng \(otherVoice?.voiceName ?? ""). Mỗi sách chỉ giữ một giọng.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private var estimateRow: some View {
        let estimate = manager.estimate(book: book, range: range, voice: voice)
        return LabeledContent("Dung lượng ước tính") {
            Text(estimate.bytes == 0 ? "Đã tải hết"
                 : "≈ \(ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file)) · \(Self.duration(estimate.seconds))")
                .accessibilityIdentifier("audioPredownloadEstimate")
        }
        .id(manager.storageRevision)
    }

    private func start() {
        manager.start(book: book, range: range, voice: voice)
    }

    static func stepText(_ job: AudioPredownloadManager.Job, chapter: Int) -> String {
        let prefix = "Chương \(chapter + 1)"
        switch job.step {
        case .translating: return "\(prefix) · đang dịch \(job.stepDone)/\(job.stepTotal) câu"
        case .synthesizing: return "\(prefix) · đang tạo audio \(job.stepDone)/\(job.stepTotal) câu"
        case .saving: return "\(prefix) · đang lưu"
        case nil: return "\(prefix) · đang chuẩn bị"
        }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "~\(minutes / 60) giờ \(minutes % 60) phút" : "~\(minutes) phút"
    }
}

/// Settings > Downloaded Audio — what pre-rendered audio is on disk, per
/// book, and deleting it.
struct AudioStorageView: View {
    @ObservedObject private var manager = AudioPredownloadManager.shared
    @State private var rows: [Row] = []
    @State private var confirmingDeleteAll = false

    struct Row: Identifiable {
        let id: Int
        let title: String
        let voiceName: String
        let chapters: [Int]
        let bytes: Int64
    }

    private var totalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Total") {
                    Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                        .accessibilityIdentifier("audioStorageTotal")
                }
                Toggle("Keep played audio", isOn: $manager.keepPlayedAudio)
                    .accessibilityIdentifier("keepPlayedAudioToggle")
            } footer: {
                Text("When off, a chapter's audio is deleted once it has finished playing.")
            }

            Section("Books") {
                if rows.isEmpty {
                    Text("No downloaded audio").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text("\(row.voiceName) · \(Self.chapterSummary(row.chapters))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            manager.deleteAudio(bookID: row.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("deleteAudioButton_\(row.id)")
                    }
                    .accessibilityIdentifier("audioStorageRow_\(row.id)")
                }
            }

            if !rows.isEmpty {
                Section {
                    Button("Delete All Audio", role: .destructive) { confirmingDeleteAll = true }
                        .accessibilityIdentifier("deleteAllAudioButton")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Downloaded Audio")
        .inlineNavigationTitle()
        .confirmationDialog("Delete all downloaded audio?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { manager.deleteAll() }
        }
        .task(id: manager.storageRevision) { await reload() }
    }

    private func reload() async {
        let books = await Task.detached(priority: .userInitiated) { () -> [(id: Int, voiceName: String, chapters: [Int], bytes: Int64)] in
            let store = PrerenderedAudioStore.shared
            return store.bookIDs().map { bookID in
                (bookID, store.bookInfo(bookID)?.voiceName ?? "", store.renderedChapters(bookID: bookID), store.byteSize(bookID: bookID))
            }
        }.value
        rows = books.map { book in
            Row(
                id: book.id, title: DownloadManager.shared.localBook(bookID: book.id)?.title ?? "Book \(book.id)",
                voiceName: book.voiceName, chapters: book.chapters, bytes: book.bytes
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func chapterSummary(_ chapters: [Int]) -> String {
        guard let first = chapters.first, let last = chapters.last else { return "" }
        let range = first == last ? "ch. \(first + 1)" : "ch. \(first + 1)–\(last + 1)"
        return "\(chapters.count) chapters (\(range))"
    }
}

/// Small "N MB audio" badge for a book row — nothing when it has none.
struct AudioStorageBadge: View {
    let bookID: Int
    @ObservedObject private var manager = AudioPredownloadManager.shared
    @State private var bytes: Int64 = 0

    var body: some View {
        Group {
            if bytes > 0 {
                Label(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("audioStorageBadge")
            }
        }
        .task(id: manager.storageRevision) {
            let bookID = bookID
            bytes = await Task.detached { PrerenderedAudioStore.shared.byteSize(bookID: bookID) }.value
        }
    }
}
