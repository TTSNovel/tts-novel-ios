import XCTest

/// Investigation harness for a reported bug: tapping a sentence to select
/// works right after opening a chapter, but stops responding "after a
/// while" of active auto-advancing playback. Uses Piper (offline) — fast
/// synthesis — instead of VieNeu, so many auto-advances/scrollTo cycles
/// happen within a short, practical test window.
///
/// Select is a pure "move the highlight/position here" action (see
/// ReaderPlaybackController.seek's doc comment) — it does NOT start audio
/// on its own, so this test explicitly presses Play after each select to
/// actually verify/exercise playback, matching real usage.
final class TapSeekAfterAutoAdvanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTapSeekStillWorksAfterSeveralAutoAdvances() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 10), "expected guest-mode auto-resume into a chapter")

        app.buttons["voiceMenuButton"].tap()
        app.buttons["modelPicker"].tap()
        let piperOption = app.buttons["Piper (offline)"]
        XCTAssertTrue(piperOption.waitForExistence(timeout: 5))
        piperOption.tap()
        app.buttons["Xong"].tap()

        // Tap-select sentence 3 BEFORE playback has auto-advanced at all —
        // this is the "works at first" baseline. Each sentence row is a
        // real Button now (see ChapterPagerView's doc comment), not a
        // StaticText.
        let sentence3 = app.buttons["sentenceText_3"]
        XCTAssertTrue(sentence3.waitForExistence(timeout: 10))
        sentence3.tap()

        let readPosition = app.staticTexts["readPositionText"]
        XCTAssertTrue(readPosition.waitForExistence(timeout: 5))
        let baselineDeadline = Date().addingTimeInterval(10)
        while Date() < baselineDeadline, !readPosition.label.hasPrefix("4/") {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(readPosition.label.hasPrefix("4/"), "baseline tap-select of sentence 3 (0-based) should show position 4/N even without pressing Play, got: \(readPosition.label)")

        let playButton = app.buttons["playPauseButton"]
        playButton.tap() // select alone never plays audio — explicitly start it so playback actually auto-advances + auto-scrolls repeatedly

        // Let it auto-advance for a while — Piper is fast, this should cover
        // many sentences/scrollTo cycles.
        Thread.sleep(forTimeInterval: 25)

        let midLabel = readPosition.label
        print("DEBUG position after 25s of auto-advance: \(midLabel)")

        // Now try tap-selecting again, to a sentence index far from wherever
        // auto-advance currently is, and see if it still registers.
        let sentence15 = app.buttons["sentenceText_15"]
        XCTAssertTrue(sentence15.waitForExistence(timeout: 5), "sentence 15 should exist in the rendered list")
        sentence15.tap()

        Thread.sleep(forTimeInterval: 1.5)
        let afterTapLabel = readPosition.label
        print("DEBUG position right after tapping sentence 15 (should show 16/N or very close): \(afterTapLabel)")

        XCTAssertTrue(
            afterTapLabel.hasPrefix("16/"),
            "tap-select of sentence 15 (0-based) after 25s of auto-advance should jump position to 16/N, but got: \(afterTapLabel) (was \(midLabel) right before the tap) — reproduces the reported 'tap stops working after a while' bug if this fails"
        )
    }
}
