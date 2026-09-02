import SwiftUI
import Core
#if os(macOS)
import AppKit
private typealias PlatformImage = NSImage
#else
// iOS and watchOS both ship UIKit's image/color primitives (just not the
// full view-hierarchy UIKit) — UIImage works unmodified on either. NSImage
// is the one that's macOS(AppKit)-only.
import UIKit
private typealias PlatformImage = UIImage
#endif

private extension Image {
    /// `Image(nsImage:)` on macOS, `Image(uiImage:)` on iOS/watchOS —
    /// SwiftUI has no platform-agnostic init from a decoded raw image, so
    /// this is the one seam that needs the `#if os()` instead of every
    /// call site.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

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
            if let data = downloads.localCoverData(bookID: book.id), let decoded = PlatformImage(data: data) {
                Image(platformImage: decoded).resizable().scaledToFill()
            } else if let data = remoteData, let decoded = PlatformImage(data: data) {
                Image(platformImage: decoded).resizable().scaledToFill()
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
