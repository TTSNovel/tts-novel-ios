import XCTest

// Diagnosed a reported bug: BookDetailView's "Đọc từ đầu"/"Đọc tiếp"
// looked visually merged and didn't respond to taps reliably. Root cause
// (found by screenshotting the live simulator mid-test, not by trusting
// XCUIElement.frame alone): NavigationLink placed inside a List always
// renders with the system's row-disclosure chrome (a plain row + chevron)
// regardless of .buttonStyle — both were silently rendering as two
// side-by-side list-style rows, not button pills. Fixed by switching
// readingActions to plain Buttons + .navigationDestination(item:).
final class BookDetailActionsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStartAndContinueButtonsNavigateToReader() throws {
        let app = XCUIApplication()
        app.launch()

        // Guest mode (see WebnovelReaderApp): the app lands directly on
        // Library now, browsing/reading doesn't require login (only
        // TTS/progress-sync/bug-report do — see _is_public_reading_path in
        // tts-webnovel's server.py), so this test doesn't log in at all.

        // App may auto-resume straight into ReaderView (see LibraryView's
        // maybeAutoResume) — back out to Library if so, so this test always
        // starts from a known screen.
        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
        bookRow.tap()

        // Threshold is 24, not 44 — these are deliberately compact
        // (.controlSize(.small)) per later feedback, not full-size tap
        // targets. The original bug reported 17.67pt (bare text metrics,
        // no button chrome at all); anything with real button padding
        // clears 24 comfortably, so this still catches a regression back
        // to "NavigationLink silently rendering as a bare list row".
        let startButton = app.buttons["startFromBeginningButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10), "'Đọc từ đầu' button should exist on BookDetailView")
        XCTAssertGreaterThanOrEqual(startButton.frame.height, 24, "startButton looks squashed")

        let continueButton = app.buttons["continueReadingButton"]
        if continueButton.waitForExistence(timeout: 3) {
            XCTAssertGreaterThanOrEqual(continueButton.frame.height, 24, "continueButton looks squashed")
        }

        let downloadButton = app.buttons["downloadButton"]
        if downloadButton.waitForExistence(timeout: 3) {
            XCTAssertGreaterThanOrEqual(downloadButton.frame.height, 24, "downloadButton looks squashed")
        }

        startButton.tap()
        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 10), "Tapping 'Đọc từ đầu' should navigate to ReaderView")
    }
}
