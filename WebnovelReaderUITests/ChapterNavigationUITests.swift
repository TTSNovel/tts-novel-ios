import XCTest

// PlaybackBar's prev/next-chapter transport buttons (see goTo() call sites
// in PlaybackBar.swift) — previously untested; only the lock-screen/remote
// skip path (remoteSkip(by:)) and ChapterListSheet-based jumps had coverage.
// Reads PlaybackBar's title row ("<book> · N/total", identifier
// "playbackBarTitle") to confirm the chapter index actually changed.
final class ChapterNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNextAndPreviousChapterButtonsChangeChapter() throws {
        let app = XCUIApplication()
        app.launch()

        let bookRow = app.buttons["bookRow"].firstMatch
        if bookRow.waitForExistence(timeout: 10) {
            bookRow.tap()
            let startButton = app.buttons["startFromBeginningButton"]
            if startButton.waitForExistence(timeout: 5) {
                startButton.tap()
            }
        }
        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 15), "Should reach ReaderView")

        let title = app.buttons["playbackBarTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let initialLabel = title.label

        let nextButton = app.buttons["nextChapterButton"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
        guard nextButton.isEnabled else {
            throw XCTSkip("Book only has one chapter — next-chapter button is disabled")
        }
        nextButton.tap()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, title.label == initialLabel {
            Thread.sleep(forTimeInterval: 0.3)
        }
        let afterNextLabel = title.label
        XCTAssertNotEqual(afterNextLabel, initialLabel, "playbackBarTitle should update after tapping next-chapter")

        let previousButton = app.buttons["previousChapterButton"]
        XCTAssertTrue(previousButton.waitForExistence(timeout: 5))
        XCTAssertTrue(previousButton.isEnabled, "Should be back on a chapter > 0 now, so previous should be enabled")
        previousButton.tap()

        let backDeadline = Date().addingTimeInterval(15)
        while Date() < backDeadline, title.label == afterNextLabel {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(title.label, initialLabel, "Tapping previous-chapter should return to the original chapter")
    }
}
