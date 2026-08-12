import XCTest

// HistoryView ("Xem tất cả" from LibraryView's "Đọc gần đây" section) —
// self-contained rather than depending on another test file to have
// generated reading progress first: opens a chapter itself (which records
// local progress on load — see ReaderPlaybackController.loadChapter), then
// backs out and follows "Xem tất cả" into the full history list.
final class HistoryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSeeAllHistoryOpensFullListAndNavigatesBackIntoBook() throws {
        let app = XCUIApplication()
        app.launch()

        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
        bookRow.tap()

        let startButton = app.buttons["startFromBeginningButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 10), "Opening a chapter should reach ReaderView and record progress")

        // Back out: ReaderView -> BookDetailView -> Library.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let seeAllButton = app.buttons["seeAllHistoryButton"]
        XCTAssertTrue(seeAllButton.waitForExistence(timeout: 10), "Đọc gần đây' section should now show 'Xem tất cả' after opening a chapter")
        seeAllButton.tap()

        XCTAssertTrue(app.navigationBars["Lịch sử đọc"].waitForExistence(timeout: 10))
        let historyRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 10), "History list should show the just-read book")
        historyRow.tap()

        XCTAssertTrue(
            app.buttons["startFromBeginningButton"].waitForExistence(timeout: 10) || app.buttons["continueReadingButton"].waitForExistence(timeout: 5),
            "Tapping a history row should navigate to BookDetailView"
        )
    }
}
