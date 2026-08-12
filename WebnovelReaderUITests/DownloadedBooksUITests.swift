import XCTest

// DownloadedBooksView, reached via LibraryView's toolbar button — separate
// from the download *action* itself (OfflineDownloadUITests). Works whether
// or not a book has actually been downloaded yet: asserts on whichever of
// the two valid states (empty-state message vs. a real row) is showing,
// rather than depending on OfflineDownloadUITests having run first.
final class DownloadedBooksUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDownloadedListShowsEmptyStateOrDownloadedBook() throws {
        let app = XCUIApplication()
        app.launch()

        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let downloadedButton = app.buttons["downloadedBooksButton"]
        XCTAssertTrue(downloadedButton.waitForExistence(timeout: 15))
        downloadedButton.tap()

        XCTAssertTrue(app.navigationBars["Đã tải xuống"].waitForExistence(timeout: 10))

        let emptyState = app.staticTexts["Chưa tải truyện nào"]
        let bookRow = app.buttons["bookRow"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !emptyState.exists, !bookRow.exists {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(emptyState.exists || bookRow.exists, "Should show either the empty state or at least one downloaded book row")

        if bookRow.exists {
            bookRow.tap()
            XCTAssertTrue(app.buttons["startFromBeginningButton"].waitForExistence(timeout: 10) || app.buttons["continueReadingButton"].waitForExistence(timeout: 5), "Tapping a downloaded book row should navigate to BookDetailView")
        }
    }
}
