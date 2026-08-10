import SwiftUI

// Web parity: site_assets' /download.html ("Đã tải xuống") lists every
// downloaded book regardless of online/offline state. LibraryView already
// falls back to `downloads.downloadedBooks()` for its main list when
// offline (see loadBooks()'s isOfflineMode branch) — this is the same data
// source, just reachable directly from the toolbar while online too,
// instead of only appearing as an automatic fallback.
struct DownloadedBooksView: View {
    @EnvironmentObject private var downloads: DownloadManager

    private var books: [Book] { downloads.downloadedBooks() }

    var body: some View {
        List(books) { book in
            NavigationLink(value: book) {
                BookRow(book: book)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Đã tải xuống")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if books.isEmpty {
                ContentUnavailableView(
                    "Chưa tải truyện nào", systemImage: "arrow.down.circle",
                    description: Text("Tải truyện xuống từ trang chi tiết sách để đọc offline.")
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
        DownloadedBooksView()
            .navigationDestination(for: Book.self) { book in
                BookDetailView(book: book)
            }
    }
    .environmentObject(DownloadManager.shared)
    .environmentObject(ProgressStore.shared)
    .environmentObject(NetworkMonitor.shared)
    .environmentObject(ReaderPlaybackController.shared)
    .environmentObject(SessionStore.shared)
}
