import SwiftUI

// Local-first (matches DownloadManager's offline-first reading): a
// downloaded book's cover renders from disk even with no network, falling
// back to fetching it from the server, and finally to the same
// gradient+initial placeholder book_renderer.cover_html() draws for books
// with no cover art at all.
struct CoverImage: View {
    let book: Book

    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        Group {
            if let data = downloads.localCoverData(bookID: book.id), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if let url = book.coverURL(baseURL: SessionStore.baseURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
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
