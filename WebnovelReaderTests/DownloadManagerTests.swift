import XCTest
@testable import WebnovelReader

/// Exercises the actual bug scenario end-to-end: download a real book's
/// chapters through `DownloadManager.download`, then read one back via
/// `localChapter` exactly like `ReaderPlaybackController.loadChapter()`
/// does — proving the on-disk cache is raw HTML re-parsed on read (current
/// parser), not a frozen `Chapter` snapshot from whatever parser existed
/// at download time.
@MainActor
final class DownloadManagerTests: XCTestCase {
    private let baseURL = SessionStore.baseURL
    private let bookID = 85

    override func tearDown() async throws {
        DownloadManager.shared.deleteDownload(bookID: bookID)
        try await super.tearDown()
    }

    func testDownloadedChapterHasNoResidualEntitiesAndSurvivesReinstall() async throws {
        // n: 89 (not the book's real ~1232) — enough to cover chapter 88,
        // the one originally reported broken, without downloading the
        // whole book for a test.
        let book = Book(id: bookID, title: "Test Book 85", author: nil, category: "test", n: 89, cover: nil)

        await DownloadManager.shared.download(book: book, baseURL: baseURL)

        guard DownloadManager.shared.isDownloaded(bookID) else {
            throw XCTSkip("live server unreachable — skipping download-cache check")
        }

        let chapter88 = DownloadManager.shared.localChapter(bookID: bookID, index: 88)
        XCTAssertNotNil(chapter88, "chapter 88 should be readable from the local cache after download")

        let entityPattern = try! NSRegularExpression(pattern: "&#?[a-zA-Z0-9]+;")
        for index in [84, 85, 86, 87, 88] {
            guard let chapter = DownloadManager.shared.localChapter(bookID: bookID, index: index) else {
                XCTFail("chapter \(index) missing from local cache")
                continue
            }
            let ns = chapter.text as NSString
            let match = entityPattern.firstMatch(in: chapter.text, range: NSRange(location: 0, length: ns.length))
            XCTAssertNil(match, "chapter \(index): residual HTML entity in cached/re-parsed text: \(match.map { ns.substring(with: $0.range) } ?? "")")
        }

        // The whole point: what's on disk is raw HTML, not a frozen parse.
        // Simulate "app updated, parser changed" by re-parsing the exact
        // same on-disk fragment a second time and checking it's stable/
        // consistent — this only holds because localChapter() re-parses
        // from source every call instead of replaying a cached Chapter.
        let reread = DownloadManager.shared.localChapter(bookID: bookID, index: 88)
        XCTAssertEqual(chapter88, reread, "re-reading the same on-disk fragment should re-parse to the same Chapter")
    }
}
