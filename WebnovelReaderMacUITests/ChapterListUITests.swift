import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/ChapterListUITests`
//
// Regression test for ChapterListSheet rendering empty on macOS: List +
// ScrollViewReader.scrollTo shortly after the List appears is a known
// SwiftUI/AppKit bug that blanks the whole List on macOS instead of just
// scrolling imprecisely like it does on iOS (see
// https://developer.apple.com/forums/thread/650233). ChapterListSheet.swift
// now skips the auto-scroll on macOS (#if os(iOS)) — this test proves the
// sheet actually shows chapter rows there.
final class ChapterListUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testChapterListSheetShowsRowsOnMac() throws {
        let app = XCUIApplication()
        app.launch()

        // The app persists playback state across launches (see
        // ReaderPlaybackController) and shares its Application Support
        // container across debug builds regardless of DerivedData path — a
        // fresh build here can still auto-resume straight into ReaderView
        // from a previous run, same as the iOS UI test handles. Either way
        // we just need to land somewhere ReaderView's chapterListButton is
        // reachable.
        if !app.buttons["chapterListButton"].waitForExistence(timeout: 3) {
            let bookRow = app.buttons["bookRow"].firstMatch
            XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
            bookRow.tap()

            let startButton = app.buttons["startFromBeginningButton"]
            let continueButton = app.buttons["continueReadingButton"]
            XCTAssertTrue(
                startButton.waitForExistence(timeout: 10) || continueButton.waitForExistence(timeout: 1),
                "Book detail should show either a start or continue button"
            )
            (startButton.exists ? startButton : continueButton).tap()
        }

        // macOS toolbar buttons come back as a nested pair sharing the same
        // identifier (outer toolbar item + inner control) — .firstMatch
        // picks either one since both respond to tap().
        let chapterListButton = app.buttons["chapterListButton"].firstMatch
        XCTAssertTrue(chapterListButton.waitForExistence(timeout: 10), "ReaderView should expose its own chapter-list toolbar button")
        chapterListButton.tap()

        // The bug this guards against: the sheet opens (title/search field
        // show) but the List itself renders with zero rows. Assert on the
        // row count directly rather than just "exists" so a regression
        // that brings back an empty-but-present List still fails loudly.
        let chapterRows = app.buttons.matching(identifier: "chapterListRow")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: chapterRows)], timeout: 15),
            .completed,
            "ChapterListSheet rendered with no chapter rows on macOS"
        )

        app.buttons["Đóng"].tap()
        XCTAssertTrue(app.buttons["chapterListButton"].waitForExistence(timeout: 5), "Closing the sheet should return to ReaderView")
    }
}
