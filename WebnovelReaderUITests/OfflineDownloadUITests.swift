import XCTest

// One-off helper test to prep a downloaded book for manual offline-mode
// verification (open first book -> download it fully). Guest mode (see
// WebnovelReaderApp) means this no longer needs to log in first — book
// browsing/covers/chapters/downloads are all public now (only TTS/
// progress-sync/bug-report require an account — see
// _is_public_reading_path in tts-webnovel's server.py).
final class OfflineDownloadUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDownloadFirstBook() throws {
        let app = XCUIApplication()
        app.launch()

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 20), "Library never showed a book row")
        bookRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let downloadButton = app.buttons["downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10), "BookDetailView never appeared")
        downloadButton.tap()

        let deleteButton = app.buttons["deleteDownloadButton"]
        // Long novels can run to thousands of chapters at concurrency 4 —
        // generous timeout rather than guessing a "small enough" book.
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: deleteButton)],
            timeout: 600
        )
        XCTAssertEqual(result, .completed, "Download never completed (downloadButton -> deleteDownloadButton)")
    }
}
