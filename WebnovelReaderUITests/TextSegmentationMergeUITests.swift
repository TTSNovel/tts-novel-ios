import XCTest

/// Regression test for the TextSegmentation redesign (element/paragraph-
/// first splitting — see TextSegmentation.swift's doc comment): a paragraph
/// stays one reading unit as long as it fits within `maxChars`, even if it
/// internally contains a quoted line broken across a period. The real
/// repro case lives in "Thiên Tai, Trọng Sinh Trở Lại Mạt Thế Mới Bắt Đầu",
/// chapter index 4 (displayed "Chương 5") — one paragraph reads "...liền
/// hiện ra trước mắt. "Di..." Hướng Du khẽ thốt lên, bởi vì lần này...". The
/// old whole-chapter-flattened `.!?` splitter used to cut the closing curly
/// quote away from its opening one, producing two odd-quote-count fragments
/// that made VieNeuOfflineV2's llama.cpp backbone fail to ever sample its
/// stop token (see TextSegmentation.swift's mergeUnbalancedQuotes doc
/// comment) — audible as a long meaningless "moan" instead of speech.
///
/// Relies on guest-mode auto-resume (see VieNeuOfflineV2UITests' doc
/// comment) landing straight in ReaderView on whatever book a prior manual/
/// test session left progress on — sidesteps the flaky book-row tap
/// documented in TTSPlaybackUITests' KNOWN LIMITATION.
final class TextSegmentationMergeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testQuotedSentenceStaysMergedInChapterFive() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 10), "expected guest-mode auto-resume into a chapter")

        app.buttons["chapterListButton"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        // Search by the chapter's own real title text, not its number —
        // the in-content <h1> the server embeds is numbered independently
        // of (off by one from) the app's own chapterIndex/footer counter
        // (chapter index 4's <h1> reads "Chương 4", but the footer shows
        // "5/665" since that's index+1) — searching "5" would filter on
        // the wrong number entirely.
        searchField.typeText("Thức tỉnh không gian")

        let chapterFiveRow = app.buttons.matching(identifier: "chapterListRow")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Thức tỉnh không gian"))
            .firstMatch
        XCTAssertTrue(chapterFiveRow.waitForExistence(timeout: 10), "expected the target chapter's row in the filtered chapter list")
        chapterFiveRow.tap()

        // ChapterListSheet's onSelect calls goTo(index) asynchronously
        // (network fetch for the new chapter's content) — wait for
        // playbackBarTitle to actually reflect chapter 5 before pressing
        // Play, otherwise Play can race ahead and start playing whatever
        // chapter was still loaded at tap time.
        let titleLabel = app.buttons["playbackBarTitle"]
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 10))
        let chapterLoadDeadline = Date().addingTimeInterval(15)
        while Date() < chapterLoadDeadline, !titleLabel.label.contains("· 5/") {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(titleLabel.label.contains("· 5/"), "expected playbackBarTitle to show chapter 5 after selecting it, got: \(titleLabel.label)")

        // goTo() (manual chapter-list navigation) loads the chapter without
        // auto-playing — `sentences` stays empty (plain-text fallback
        // rendering) until Play is actually pressed. beginChapter()
        // populates `sentences` synchronously the moment playback starts,
        // so there's no need to wait for actual audio to check the text.
        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        playButton.tap()

        // Each sentence row is a real Button now (see ChapterPagerView's
        // doc comment on why), not a StaticText.
        let quotedSentence = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Hướng Du khẽ thốt lên"))
            .firstMatch
        XCTAssertTrue(quotedSentence.waitForExistence(timeout: 10), "expected the sentence containing 'Hướng Du khẽ thốt lên'")
        XCTAssertTrue(
            quotedSentence.label.contains("Di"),
            "the quoted \"Di...\" fragment should stay merged with \"Hướng Du khẽ thốt lên\" in the same sentence row, not split off on its own: \(quotedSentence.label)"
        )

        playButton.tap() // pause before ending the test
    }
}
