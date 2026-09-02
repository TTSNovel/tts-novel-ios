import XCTest

// `xcodebuild test -scheme WebnovelReaderWatch -only-testing:WebnovelReaderWatchUITests/WatchSettingsUITests`
final class WatchSettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSettings(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["settingsButton"].firstMatch.tap()
    }

    /// watchOS Forms/Lists are virtualized — a row below the fold isn't
    /// materialized in the accessibility tree (so `waitForExistence` alone
    /// never finds it) until scrolled into view, and Digital Crown
    /// rotation is the mechanism that actually works (a touch swipe on the
    /// container doesn't reveal it — confirmed empirically). Small steps
    /// in a loop rather than one large fixed delta, since exactly how far
    /// a given row sits depends on which optional sections (e.g. the Gwen
    /// speaker picker) are currently showing above it.
    private func scrollUntilVisible(_ element: XCUIElement, maxAttempts: Int = 20) {
        var attempts = 0
        while !element.exists, attempts < maxAttempts {
            // A too-large step can jump straight over a row's narrow
            // materialization window without ever finding it (confirmed
            // empirically: delta 1.5 skipped clean over `autoNextToggle`,
            // delta 0.5 didn't) — small steps, more of them, not fewer big
            // ones.
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
            Thread.sleep(forTimeInterval: 0.3)
            attempts += 1
        }
    }

    /// Default-style `Picker` inside a `Form` on watchOS pushes a new
    /// screen listing each option as its own row when tapped, rather than
    /// popping an inline menu the way iOS's `.menu` style does.
    private func selectPickerOption(_ pickerIdentifier: String, optionLabel: String, app: XCUIApplication) {
        let picker = app.descendants(matching: .any)[pickerIdentifier]
        scrollUntilVisible(picker)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Picker '\(pickerIdentifier)' not found")
        // Settle + coordinate tap, not a plain `.tap()` right after
        // scrolling — confirmed empirically elsewhere in this suite that a
        // bare tap right after a crown scroll intermittently doesn't land.
        Thread.sleep(forTimeInterval: 1.0)
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let option = app.buttons[optionLabel]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Option '\(optionLabel)' not found in '\(pickerIdentifier)'")
        Thread.sleep(forTimeInterval: 0.5)
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func testVoicePickerOffersOnlyTheFourOnlineVoices() throws {
        let app = XCUIApplication()
        openSettings(app)

        let picker = app.descendants(matching: .any)["voicePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        for label in ["Piper VN", "Google Cloud TTS", "VieNeu-TTS", "Gwen-TTS (voice clone)"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "Voice option '\(label)' should be offered")
        }
        // The 3 offline voices must never appear — this target doesn't
        // link the offline engines at all.
        XCTAssertFalse(app.buttons["Piper (offline)"].exists)
        XCTAssertFalse(app.buttons["VieNeu-TTS v2 (offline)"].exists)
        XCTAssertFalse(app.buttons["VieNeu-TTS v3 (offline)"].exists)

        app.buttons["Piper VN"].tap()
    }

    func testSelectingGwenTTSRevealsSpeakerPicker() throws {
        let app = XCUIApplication()
        openSettings(app)

        selectPickerOption("voicePicker", optionLabel: "Gwen-TTS (voice clone)", app: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["gwenSpeakerPicker"].waitForExistence(timeout: 5),
            "Speaker picker should appear once Gwen-TTS is selected"
        )

        // Reset back to the default voice so this test doesn't leave
        // state behind for the others.
        selectPickerOption("voicePicker", optionLabel: "Piper VN", app: app)
        XCTAssertFalse(app.descendants(matching: .any)["gwenSpeakerPicker"].exists, "Speaker picker should disappear once a non-Gwen voice is selected")
    }

    func testAutoNextChapterToggleFlips() throws {
        let app = XCUIApplication()
        openSettings(app)

        let toggle = app.switches["autoNextToggle"]
        scrollUntilVisible(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let initialValue = toggle.value as? String
        // A plain `.tap()` on the identified outer Switch element doesn't
        // register as a toggle press on watchOS (confirmed empirically —
        // the value never flips) — SwiftUI's actual switch knob is a
        // second, unidentified nested Switch near the row's trailing
        // edge; a coordinate tap there is what a real tap gesture hits.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(toggle.value as? String, initialValue, "Toggling auto-next should flip its value")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap() // restore
    }

    func testSleepTimerShowsCountdownOnceSet() throws {
        let app = XCUIApplication()
        openSettings(app)

        selectPickerOption("sleepTimerPicker", optionLabel: "5 phút", app: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["sleepTimerCountdown"].waitForExistence(timeout: 5),
            "A countdown row should appear once a sleep timer is set"
        )

        selectPickerOption("sleepTimerPicker", optionLabel: "Tắt", app: app)
        XCTAssertFalse(app.descendants(matching: .any)["sleepTimerCountdown"].exists, "Countdown should disappear once the timer is turned off")
    }

    func testPreloadPickerChangesSelection() throws {
        let app = XCUIApplication()
        openSettings(app)

        selectPickerOption("preloadPicker", optionLabel: "2 câu", app: app)
        // Round-trip back to the default so repeated test runs are stable.
        selectPickerOption("preloadPicker", optionLabel: "5 câu", app: app)
    }
}
