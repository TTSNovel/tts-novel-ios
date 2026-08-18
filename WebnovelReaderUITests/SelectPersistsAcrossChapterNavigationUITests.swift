import XCTest

/// Regression coverage for two reported bugs: the tap-to-select sentence
/// rows (see ReaderPlaybackController.seek / ChapterPagerView's per-sentence
/// Button) used to disappear after swiping to a neighboring chapter, or
/// after picking a different chapter from ChapterListSheet — in both cases
/// whenever nothing was actively playing at the time, which is now the
/// common case since selecting a sentence no longer auto-plays it (see
/// TapSeekAfterAutoAdvanceUITests' doc comment).
///
/// Root cause was `sentences` only ever getting populated by
/// `beginChapter()` (Play, or continuing playback into the next chapter)
/// — `ReaderPlaybackController.prepareSentencesForDisplay` now runs
/// unconditionally on every chapter load instead, independent of playback
/// state.
final class SelectPersistsAcrossChapterNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSelectableRowsSurviveSwipeAndChapterListNavigation() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 10), "expected guest-mode auto-resume into a chapter")

        // Baseline: sentence rows exist without ever having pressed Play —
        // prepareSentencesForDisplay should have already populated
        // `sentences` on the very first chapter load of this session.
        XCTAssertTrue(app.buttons["sentenceText_1"].waitForExistence(timeout: 10), "expected selectable sentence rows on first chapter load, without pressing Play")

        let title = app.buttons["playbackBarTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let beforeSwipeLabel = title.label

        // Swipe to the next chapter WITHOUT ever pressing Play — this used
        // to leave the reader on the plain-text fallback (no selectable
        // rows) because skipChapter()'s not-playing branch (goTo) never
        // repopulated `sentences`.
        app.swipeLeft()
        let chapterChanged = NSPredicate(format: "label != %@", beforeSwipeLabel)
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: chapterChanged, object: title)], timeout: 15),
            .completed,
            "swipe should have changed chapter — still on '\(title.label)'"
        )
        XCTAssertTrue(app.buttons["sentenceText_1"].waitForExistence(timeout: 10), "sentence rows should still be selectable right after swiping to a new chapter without playing")

        // Now pick a chapter from ChapterListSheet — the other reported
        // path (goTo(), same as manual chapter-list navigation).
        app.buttons["chapterListButton"].tap()
        let firstRow = app.buttons["chapterListRow"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        XCTAssertTrue(app.buttons["sentenceText_1"].waitForExistence(timeout: 10), "sentence rows should still be selectable right after picking a chapter from ChapterListSheet")
    }
}
