import SwiftUI

// Full reading history — every book with saved progress, most-recent
// first. Reached from LibraryView's "Đọc gần đây" section header ("Xem tất
// cả"); the preview there only shows the top 5. Rows push Book onto the
// same NavigationStack LibraryView owns (its .navigationDestination(for:
// Book.self) registration covers this view too, since it's just pushed
// deeper on that same stack), landing on BookDetailView like every other
// book row in the app.
struct HistoryView: View {
    let books: [Book]

    var body: some View {
        List(books) { book in
            NavigationLink(value: book) {
                BookRow(book: book)
            }
            .accessibilityIdentifier("bookRow")
        }
        .listStyle(.plain)
        .navigationTitle("Lịch sử đọc")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if books.isEmpty {
                ContentUnavailableView(
                    "Chưa có lịch sử đọc", systemImage: "clock",
                    description: Text("Đọc thử một cuốn sách để bắt đầu.")
                )
            }
        }
        .readerSettingsToolbar()
        // See PlaybackBar's doc comment — invisible spacer, not a second bar.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: PlaybackBar.reservedHeight)
        }
    }
}

#Preview {
    NavigationStack {
        HistoryView(books: [
            Book(id: 1, title: "Truyện mẫu", author: "Tác giả", category: "Demo", n: 120, cover: nil),
        ])
        .navigationDestination(for: Book.self) { book in
            BookDetailView(book: book)
        }
    }
    .environmentObject(DownloadManager.shared)
    .environmentObject(ProgressStore.shared)
    .environmentObject(NetworkMonitor.shared)
    .environmentObject(ReaderPlaybackController.shared)
}
