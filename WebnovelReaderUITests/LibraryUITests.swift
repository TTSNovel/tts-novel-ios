import XCTest

// Covers LibraryView's own navigation surface (book list + toolbar), as
// opposed to what happens after tapping into a book (BookDetailActionsUITests)
// or the downloaded/history destinations themselves (DownloadedBooksUITests,
// HistoryUITests).
final class LibraryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLibraryShowsBooksAndOpensDownloadedList() throws {
        let app = XCUIApplication()
        app.launch()

        // May auto-resume straight into ReaderView (see LibraryView's
        // maybeAutoResume) — back out to Library if so.
        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")

        let downloadedButton = app.buttons["downloadedBooksButton"]
        XCTAssertTrue(downloadedButton.waitForExistence(timeout: 5))
        downloadedButton.tap()

        XCTAssertTrue(app.navigationBars["Đã tải xuống"].waitForExistence(timeout: 10), "Should navigate to the Downloaded Books screen")
    }
}
