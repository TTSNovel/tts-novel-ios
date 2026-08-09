import SwiftUI

// Shared between LibraryView's "Đọc gần đây" preview, its full book list,
// and HistoryView's full list — one row style everywhere a book appears.
struct BookRow: View {
    let book: Book

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var progressStore: ProgressStore

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(book: book)
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline)
                if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(book.n) chương").font(.caption).foregroundStyle(.secondary)
                if let progress = progressStore.localProgress(bookID: book.id) {
                    Text("Đang đọc: Chương \(progress.chapterIndex + 1)/\(book.n)")
                        .font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            if downloads.isDownloaded(book.id) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
            }
        }
    }
}

#Preview {
    List {
        BookRow(book: Book(id: 1, title: "Truyện mẫu", author: "Tác giả", category: "Demo", n: 120, cover: nil))
    }
    .environmentObject(DownloadManager.shared)
    .environmentObject(ProgressStore.shared)
}
