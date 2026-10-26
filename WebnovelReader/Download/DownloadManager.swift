import Foundation
import Core

// Native counterpart to site_assets/download.js's Cache-Storage-based
// offline books — persists each chapter's raw HTML fragment + the cover to
// Application Support/Books/<id>/ instead of the browser's Cache Storage,
// and ReaderView/CoverImage check here before hitting the network.
//
// Deliberately stores the *raw* fragment, not a parsed `Chapter` — this
// used to cache ChapterFragmentParser's output directly, which meant every
// already-downloaded book was permanently stuck with whatever parsing bugs
// existed on the day it was downloaded (e.g. the old regex/entity-
// whitelist parser leaking literal "&#x27;" into offline chapters even
// after the app was updated with a fixed parser). Re-parsing the raw HTML
// on every read costs a cheap SwiftSoup pass but guarantees offline
// chapters always reflect the current parser, same as the online path.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloadedBookIDs: Set<Int> = []
    @Published private(set) var downloading: Set<Int> = []
    @Published private(set) var progress: [Int: Double] = [:]

    private let fileManager = FileManager.default

    private init() {
        refreshDownloadedList()
    }

    func isDownloaded(_ bookID: Int) -> Bool {
        downloadedBookIDs.contains(bookID)
    }

    nonisolated func localChapter(bookID: Int, index: Int) -> Chapter? {
        let url = chapterFileURL(bookID, index)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let html = Log.attempt(.storage, "Downloaded chapter unreadable", ["book": "\(bookID)", "chapter": "\(index)"], {
            try String(contentsOf: url, encoding: .utf8)
        }) else { return nil }
        return ChapterFragmentParser.parse(html: html, index: index)
    }

    /// Downloaded books have every chapter's raw HTML on disk — parse each
    /// just far enough to pull its title back out, no separate fetch
    /// needed even though the online path (APIClient.fetchChapterTitles)
    /// hits its own dedicated endpoint.
    ///
    /// nonisolated (and called via Task.detached from ChapterTitles.load):
    /// this reads and SwiftSoup-parses one file per chapter, which for a
    /// long downloaded book (~2000 chapters) can take real seconds — no
    /// reason to make @MainActor sit through that when nothing here
    /// touches this instance's @Published state.
    nonisolated func localChapterTitles(bookID: Int) -> [String]? {
        guard let book = localBook(bookID: bookID) else { return nil }
        return (0..<book.n).map { localChapter(bookID: bookID, index: $0)?.title ?? "Chương \($0 + 1)" }
    }

    func localCoverData(bookID: Int) -> Data? {
        // nolog: book not downloaded
        guard let files = try? fileManager.contentsOfDirectory(at: bookDirectory(bookID), includingPropertiesForKeys: nil),
              let coverFile = files.first(where: { $0.lastPathComponent.hasPrefix("cover.") }) else { return nil }
        return Log.attempt(.storage, "Downloaded cover unreadable", ["book": "\(bookID)"]) { try Data(contentsOf: coverFile) }
    }

    nonisolated func localBook(bookID: Int) -> Book? {
        StoredJSON.load(Book.self, from: metaFileURL(bookID), category: .download)
    }

    /// Reconstructs a library list purely from disk — what LibraryView
    /// falls back to when fetchBooks() can't reach the server at all.
    func downloadedBooks() -> [Book] {
        downloadedBookIDs.compactMap { localBook(bookID: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func download(book: Book, baseURL: URL) async {
        guard !downloading.contains(book.id), book.n > 0 else { return }
        downloading.insert(book.id)
        progress[book.id] = 0
        EventLogStore.shared.record(.download, "Start book download", detail: book.title)
        defer {
            downloading.remove(book.id)
            progress[book.id] = nil
        }

        do {
            let dir = bookDirectory(book.id)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

            if let cover = book.cover {
                let coverData = try await APIClient.shared.fetchCoverData(baseURL: baseURL, bookID: book.id, filename: cover)
                try coverData.write(to: dir.appendingPathComponent(cover))
            }

            let fragments = try await fetchAllChapterHTML(book: book, baseURL: baseURL)
            try fileManager.createDirectory(at: chaptersDirectory(book.id), withIntermediateDirectories: true)
            for (index, html) in fragments {
                try html.write(to: chapterFileURL(book.id, index), atomically: true, encoding: .utf8)
            }
            // meta.json written last, after every chapter file — the
            // completion marker isFullyDownloaded() checks for, so a
            // retry after a failed/interrupted download starts clean
            // instead of serving a half-downloaded book as complete.
            try JSONEncoder().encode(book).write(to: metaFileURL(book.id))
            downloadedBookIDs.insert(book.id)
            EventLogStore.shared.record(.download, "Book download finished", detail: book.title)
        } catch {
            Log.error(.download, "Book download failed", error: error, ["book": "\(book.id)", "chapters": "\(book.n)"])
            EventLogStore.shared.record(.error, "Book download failed", detail: "\(book.title): \(error.localizedDescription)")
        }
    }

    func deleteDownload(bookID: Int) {
        let title = localBook(bookID: bookID)?.title
        StoredJSON.remove(bookDirectory(bookID), category: .download)
        downloadedBookIDs.remove(bookID)
        EventLogStore.shared.record(.download, "Delete downloaded book", detail: title)
    }

    /// Bounded concurrency (4 in flight) — book.n can run into the
    /// thousands for a long novel; firing that many requests at once
    /// against a single small Cloud Run instance isn't reasonable.
    private func fetchAllChapterHTML(book: Book, baseURL: URL) async throws -> [(index: Int, html: String)] {
        let indices = Array(0..<book.n)
        var nextIndex = 0
        var fragments: [(index: Int, html: String)] = []
        fragments.reserveCapacity(book.n)

        try await withThrowingTaskGroup(of: (index: Int, html: String).self) { group in
            func addNext() {
                guard nextIndex < indices.count else { return }
                let i = indices[nextIndex]
                nextIndex += 1
                group.addTask {
                    let html = try await APIClient.shared.fetchChapterHTML(baseURL: baseURL, bookID: book.id, index: i)
                    return (i, html)
                }
            }
            for _ in 0..<min(4, indices.count) { addNext() }
            while let fragment = try await group.next() {
                fragments.append(fragment)
                progress[book.id] = Double(fragments.count) / Double(indices.count)
                addNext()
            }
        }
        return fragments
    }

    // FileManager.default (not self.fileManager) in this nonisolated
    // chain — reads self's actor-isolated stored property from a
    // nonisolated context, so they go straight to the same underlying
    // singleton instead.
    private nonisolated func booksDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
        Log.attempt(.storage, "Can't create the books directory") {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private nonisolated func bookDirectory(_ bookID: Int) -> URL {
        booksDirectory().appendingPathComponent(String(bookID), isDirectory: true)
    }

    private nonisolated func chaptersDirectory(_ bookID: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent("data", isDirectory: true)
    }

    private nonisolated func chapterFileURL(_ bookID: Int, _ index: Int) -> URL {
        chaptersDirectory(bookID).appendingPathComponent(String(format: "%04d.html", index))
    }

    private nonisolated func metaFileURL(_ bookID: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent("meta.json")
    }

    /// meta.json is only written after every chapter fragment lands on
    /// disk (see download()), so its presence alone is a reliable
    /// all-or-nothing completeness marker without needing to count files.
    private func isFullyDownloaded(_ bookID: Int) -> Bool {
        fileManager.fileExists(atPath: metaFileURL(bookID).path)
            && fileManager.fileExists(atPath: chaptersDirectory(bookID).path)
    }

    private func refreshDownloadedList() {
        guard let entries = Log.attempt(.storage, "Can't list downloaded books", [:], {
            try fileManager.contentsOfDirectory(at: booksDirectory(), includingPropertiesForKeys: nil)
        }) else { return }
        downloadedBookIDs = Set(entries.compactMap { Int($0.lastPathComponent) }.filter { isFullyDownloaded($0) })
    }
}
