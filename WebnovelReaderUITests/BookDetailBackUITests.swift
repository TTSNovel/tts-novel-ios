import XCTest

// Regression: the back button on BookDetailView needed two taps to return
// to Library after jumping into the reader via the PlaybackBar title —
// LibraryView appended book + chapter onto whatever was already on navPath,
// so a BookDetailView already on screen ended up on the stack twice.
final class BookDetailBackUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSingleBackTapReturnsToLibraryAfterPlaybackBarJump() throws {
        let app = XCUIApplication()
        app.launch()
        let back = app.navigationBars.buttons.element(boundBy: 0)

        // App may auto-resume into ReaderView — back out to Library first.
        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            back.tap()
            sleep(1)
            back.tap()
            sleep(1)
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15))
        bookRow.tap()

        let start = app.buttons["startFromBeginningButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["chapterListButton"].waitForExistence(timeout: 15))
        sleep(2)
        back.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Back from Reader should land on BookDetail")

        let barTitle = app.buttons["playbackBarTitle"]
        XCTAssertTrue(barTitle.waitForExistence(timeout: 10))
        barTitle.tap()
        XCTAssertTrue(app.buttons["chapterListButton"].waitForExistence(timeout: 15))
        sleep(2)

        back.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Back from Reader should land on BookDetail")
        sleep(1)
        back.tap()
        XCTAssertTrue(app.navigationBars["Novel Reader"].waitForExistence(timeout: 5),
                      "A single back tap on BookDetailView should return to Library")
    }
}
