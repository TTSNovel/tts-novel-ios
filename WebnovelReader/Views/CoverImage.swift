import SwiftUI

// Local-first (matches DownloadManager's offline-first reading): a
// downloaded book's cover renders from disk even with no network, falling
// back to fetching it from the server, and finally to the same
// gradient+initial placeholder book_renderer.cover_html() draws for books
// with no cover art at all.
struct CoverImage: View {
    let book: Book

    @EnvironmentObject private var downloads: DownloadManager
    @State private var remoteData: Data?

    var body: some View {
        Group {
            if let data = downloads.localCoverData(bookID: book.id), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if let data = remoteData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if let url = book.coverURL(baseURL: SessionStore.baseURL) {
                placeholder
                    .task(id: url) {
                        remoteData = await CoverImageCache.shared.data(for: url)
                    }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                Text(book.title.first.map(String.init) ?? "?")
                    .font(.title.bold())
                    .foregroundStyle(.white)
            )
    }
}
