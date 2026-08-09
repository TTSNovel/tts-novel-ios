import XCTest

// Verifies the launch-time resume feature end-to-end against the real
// deployed server: seed a saved chapter/sentence via POST /api/progress
// (see the manual curl steps used while building this), then confirm the
// app opens directly into that chapter with that sentence highlighted, and
// that pressing Play continues from it instead of restarting at sentence 1.
// Sidesteps the documented book-row tap flakiness (see TTSPlaybackUITests)
// entirely — the app auto-resumes straight into ReaderView, no list
// navigation needed. Requires /tmp/tts_test_config.json (see
// LoginFlowUITests) AND that this device is already logged in (run
// LoginFlowUITests first) with server-side progress already seeded for the
// book that ends up "most recently read".
final class ResumeFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchResumesAtSavedSentence() throws {
        let app = XCUIApplication()
        app.launch()

        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 15), "Should land directly in ReaderView, not Library")

        let sentenceProgress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Câu ")).firstMatch
        XCTAssertTrue(sentenceProgress.waitForExistence(timeout: 10))
        XCTAssertFalse(
            sentenceProgress.label.hasPrefix("Câu 1/"),
            "Resumed chapter shouldn't be showing sentence 1 — expected the saved mid-chapter position, got: \(sentenceProgress.label)"
        )

        let resumedLabel = sentenceProgress.label
        playButton.tap()

        let playing = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
        let expectation = XCTNSPredicateExpectation(predicate: playing, object: playButton)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "Play button never switched to playing state")

        XCTAssertEqual(
            sentenceProgress.label, resumedLabel,
            "Pressing Play right after resume should start at the saved sentence, not jump elsewhere"
        )
    }

    func testSettingsSheetShowsAllControls() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsButton = app.buttons["voiceMenuButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()

        XCTAssertTrue(app.navigationBars["Cài đặt đọc"].waitForExistence(timeout: 5), "Settings sheet should open")
        let voiceOption = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Piper VN")).firstMatch
        XCTAssertTrue(voiceOption.waitForExistence(timeout: 5), "Voice options should be visible, not nested in a submenu")
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 5), "Auto-next toggle should be visible")
        let sleepTimerLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Hẹn giờ tắt")).firstMatch
        XCTAssertTrue(sleepTimerLabel.exists)

        app.buttons["Xong"].tap()
        XCTAssertFalse(app.navigationBars["Cài đặt đọc"].waitForExistence(timeout: 3), "Sheet should dismiss")
    }
}
