import Foundation

// Native counterpart to site_assets/download.js's Cache-Storage-based
// offline books — persists parsed chapters + the cover to
// Application Support/Books/<id>/ instead of the browser's Cache Storage,
// and ReaderView/CoverImage check here before hitting the network.
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

    func localChapter(bookID: Int, index: Int) -> Chapter? {
        guard let data = try? Data(contentsOf: chaptersFileURL(bookID)),
              let chapters = try? JSONDecoder().decode([Chapter].self, from: data) else { return nil }
        return chapters.first { $0.index == index }
    }

    /// Downloaded books already have every chapter's full content (title
    /// included) cached in chaptersFileURL — free to read the titles back
    /// out of that, no separate fetch needed even though the online path
    /// (APIClient.fetchChapterTitles) hits its own dedicated endpoint.
    func localChapterTitles(bookID: Int) -> [String]? {
        guard let data = try? Data(contentsOf: chaptersFileURL(bookID)),
              let chapters = try? JSONDecoder().decode([Chapter].self, from: data) else { return nil }
        return chapters.sorted { $0.index < $1.index }.map(\.title)
    }

    func localCoverData(bookID: Int) -> Data? {
        guard let files = try? fileManager.contentsOfDirectory(at: bookDirectory(bookID), includingPropertiesForKeys: nil),
              let coverFile = files.first(where: { $0.lastPathComponent.hasPrefix("cover.") }) else { return nil }
        return try? Data(contentsOf: coverFile)
    }

    func localBook(bookID: Int) -> Book? {
        guard let data = try? Data(contentsOf: metaFileURL(bookID)) else { return nil }
        return try? JSONDecoder().decode(Book.self, from: data)
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

            let chapters = try await fetchAllChapters(book: book, baseURL: baseURL)
            let data = try JSONEncoder().encode(chapters.sorted { $0.index < $1.index })
            try data.write(to: chaptersFileURL(book.id))
            try JSONEncoder().encode(book).write(to: metaFileURL(book.id))
            downloadedBookIDs.insert(book.id)
        } catch {
            // Best-effort: chapters.json is only written on full success,
            // so isDownloaded() still reports false and a retry starts
            // clean instead of serving a half-downloaded book as complete.
        }
    }

    func deleteDownload(bookID: Int) {
        try? fileManager.removeItem(at: bookDirectory(bookID))
        downloadedBookIDs.remove(bookID)
    }

    /// Bounded concurrency (4 in flight) — book.n can run into the
    /// thousands for a long novel; firing that many requests at once
    /// against a single small Cloud Run instance isn't reasonable.
    private func fetchAllChapters(book: Book, baseURL: URL) async throws -> [Chapter] {
        let indices = Array(0..<book.n)
        var nextIndex = 0
        var chapters: [Chapter] = []
        chapters.reserveCapacity(book.n)

        try await withThrowingTaskGroup(of: Chapter.self) { group in
            func addNext() {
                guard nextIndex < indices.count else { return }
                let i = indices[nextIndex]
                nextIndex += 1
                group.addTask {
                    try await APIClient.shared.fetchChapter(baseURL: baseURL, bookID: book.id, index: i)
                }
            }
            for _ in 0..<min(4, indices.count) { addNext() }
            while let chapter = try await group.next() {
                chapters.append(chapter)
                progress[book.id] = Double(chapters.count) / Double(indices.count)
                addNext()
            }
        }
        return chapters
    }

    private func booksDirectory() -> URL {
        let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bookDirectory(_ bookID: Int) -> URL {
        booksDirectory().appendingPathComponent(String(bookID), isDirectory: true)
    }

    private func chaptersFileURL(_ bookID: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent("chapters.json")
    }

    private func metaFileURL(_ bookID: Int) -> URL {
        bookDirectory(bookID).appendingPathComponent("meta.json")
    }

    private func refreshDownloadedList() {
        guard let entries = try? fileManager.contentsOfDirectory(at: booksDirectory(), includingPropertiesForKeys: nil) else { return }
        downloadedBookIDs = Set(entries.compactMap { Int($0.lastPathComponent) }
            .filter {
                fileManager.fileExists(atPath: chaptersFileURL($0).path)
                    && fileManager.fileExists(atPath: metaFileURL($0).path)
            })
    }
}
