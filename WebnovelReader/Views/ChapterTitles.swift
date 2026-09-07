import Foundation
import Core

/// Shared by BookDetailView and ChapterListSheet — both show a full
/// chapter list and need real titles rather than a bare "Chương N", so
/// this is the one place that decides where those come from (offline
/// cache vs. network) and caches the result for the rest of the session.
@MainActor
enum ChapterTitles {
    private static var cache: [Int: [String]] = [:]

    /// nil means "not available yet" (still loading, or failed) — callers
    /// fall back to a plain ordinal label in that case rather than blocking
    /// the chapter list on this.
    static func load(book: Book) async -> [String]? {
        if let cached = cache[book.id] { return cached }
        // Task.detached: localChapterTitles reads + SwiftSoup-parses one
        // file per chapter, which for a long downloaded book can take
        // several real seconds. DownloadManager itself stays @MainActor
        // (its @Published state needs that), but that one method and its
        // path helpers are `nonisolated` precisely so this call can run
        // off the main thread instead of freezing the UI for the whole
        // scan — see DownloadManager.localChapterTitles's doc comment.
        let manager = DownloadManager.shared
        if let local = await Task.detached(priority: .userInitiated, operation: {
            manager.localChapterTitles(bookID: book.id)
        }).value {
            cache[book.id] = local
            return local
        }
        guard let fetched = try? await APIClient.shared.fetchChapterTitles(baseURL: SessionStore.baseURL, bookID: book.id) else {
            return nil
        }
        cache[book.id] = fetched
        return fetched
    }
}
