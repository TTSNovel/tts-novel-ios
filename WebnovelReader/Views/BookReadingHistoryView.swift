import SwiftUI
import Core

/// One book's reading-history timeline from the server (every chapter
/// change any device made, newest first) — the way back when a position
/// was moved by mistake: tap a row, confirm, and that chapter becomes the
/// position again (a `restore` event) on every device. Reached from
/// BookDetailView, and from ReaderView's conflict banner.
struct BookReadingHistoryView: View {
    let book: Book
    /// Set when shown from the reader (as a sheet): the reader navigates
    /// itself. Nil when pushed from BookDetailView — this view then pushes
    /// the reader at the restored chapter.
    var onRestore: ((Int) -> Void)?

    @EnvironmentObject private var progressStore: ProgressStore
    @State private var history: ReadingHistory?
    @State private var loadError: String?
    @State private var pendingRestore: ReadingHistoryEvent?
    @State private var restoredChapterIndex: Int?

    var body: some View {
        List {
            if let history {
                ForEach(history.events) { event in
                    Button {
                        pendingRestore = event
                    } label: {
                        row(event)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("readingHistoryRow")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if let loadError {
                ContentUnavailableView(
                    "Không tải được lịch sử", systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if history == nil {
                ProgressView()
            } else if history?.events.isEmpty == true {
                ContentUnavailableView(
                    "Chưa có lịch sử đọc", systemImage: "clock",
                    description: Text("Chọn một chương để bắt đầu.")
                )
            }
        }
        .navigationTitle("Lịch sử đọc")
        .inlineNavigationTitle()
        .confirmationDialog(
            pendingRestore.map { "Đọc tiếp từ chương \($0.chapter + 1)?" } ?? "",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { event in
            Button("Đọc tiếp từ chương \(event.chapter + 1)") { restore(event) }
                .accessibilityIdentifier("readingHistoryRestoreButton")
            Button("Huỷ", role: .cancel) {}
        }
        .navigationDestination(item: $restoredChapterIndex) { index in
            ReaderView(book: book, chapterIndex: index)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ event: ReadingHistoryEvent) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chương \(event.chapter + 1)")
                    .font(.body.weight(event.applied ? .semibold : .regular))
                Text("\(event.deviceName?.isEmpty == false ? event.deviceName! : "Không rõ thiết bị") · \(Self.kindLabel(event))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.serverTS.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !event.applied {
                    Text(event.conflict ? "xung đột" : "không áp dụng")
                        .font(.caption2)
                        .foregroundStyle(event.conflict ? Color.orange : Color.secondary)
                }
            }
        }
        // Rejected/no-op events are there for the record — greyed so the
        // rows that actually moved the position stand out.
        .opacity(event.applied ? 1 : 0.55)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    static func kindLabel(_ event: ReadingHistoryEvent) -> String {
        switch event.kind {
        case .select: return "chọn chương"
        case .autoNext: return "tự sang chương"
        case .restore: return "khôi phục"
        case .legacy: return "bản cũ"
        case nil: return event.kindRaw
        }
    }

    private func load() async {
        do {
            history = try await progressStore.fetchHistory(bookID: book.id)
            loadError = nil
        } catch {
            Log.notice(.sync, "Reading history not loaded", ["book": "\(book.id)", "error": ErrorInfo(error).summary])
            loadError = "Kiểm tra kết nối mạng hoặc đăng nhập lại"
        }
    }

    private func restore(_ event: ReadingHistoryEvent) {
        EventLogStore.shared.record(.navigation, "Restore chapter from history", detail: "\(book.title) — chapter \(event.chapter + 1)")
        progressStore.record(bookID: book.id, chapterIndex: event.chapter, kind: .restore)
        if let onRestore {
            onRestore(event.chapter)
        } else {
            restoredChapterIndex = event.chapter
        }
    }
}

#Preview {
    NavigationStack {
        BookReadingHistoryView(book: Book(id: 1, title: "Truyện mẫu", author: nil, category: "Demo", n: 500, cover: nil))
    }
    .environmentObject(ProgressStore.shared)
    .environmentObject(ReaderPlaybackController.shared)
}
