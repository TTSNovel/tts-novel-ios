import XCTest

// Regression coverage for swipe-left/right chapter navigation: ReaderView's
// content is now a 3-slot TabView(.page) pager (see ReaderView's slotPage/
// syncPager/handlePagerSettle, and ReaderPlaybackController's
// cachedChapter/prefetchChapter/beginNextChapterAudioWarmup/skipChapter)
// instead of a plain ScrollView. This drives the actual finger-swipe
// gesture end to end and checks the reported chapter position actually
// moves, rather than just asserting the pager compiles.
final class SwipeChapterNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Extracts "X/Y" out of PlaybackBar's `playbackBarTitle` accessibility
    /// label, e.g. "Truyện mẫu · 6/34" -> (6, 34).
    private func chapterPosition(_ label: String) -> (current: Int, total: Int)? {
        guard let range = label.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) else { return nil }
        let parts = label[range].split(separator: "/")
        guard parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (current, total)
    }

    func testSwipeNavigatesBetweenChapters() throws {
        let app = XCUIApplication()
        app.launch()

        // Guest mode may auto-resume straight into ReaderView from a prior
        // session's progress — back out to Library so this always starts
        // from a known screen (same pattern as PreloadBufferingUITests).
        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
        bookRow.tap()

        // Land a few chapters in (not chapter 0) so there's room to swipe
        // backward too, same rationale as PreloadBufferingUITests.
        let chapterRows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chương"))
        let enoughChapters = NSPredicate(format: "count > 5")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enoughChapters, object: chapterRows)], timeout: 15),
            .completed,
            "Book should list more than 5 chapters to have room to swipe both directions"
        )
        chapterRows.element(boundBy: 5).tap()

        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 15), "Should reach ReaderView")

        let title = app.buttons["playbackBarTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        guard let start = chapterPosition(title.label) else {
            XCTFail("Could not parse chapter position from '\(title.label)'")
            return
        }

        app.swipeLeft()
        let advanced = NSPredicate(format: "label CONTAINS[c] %@", "\(start.current + 1)/\(start.total)")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: title)], timeout: 15),
            .completed,
            "Swiping left should advance to the next chapter — was '\(title.label)'"
        )

        app.swipeRight()
        let backAgain = NSPredicate(format: "label CONTAINS[c] %@", "\(start.current)/\(start.total)")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: backAgain, object: title)], timeout: 15),
            .completed,
            "Swiping right should return to the previous chapter — was '\(title.label)'"
        )
    }
}
