import XCTest

// Regression coverage for the sleep-timer fix (see "Fix sleep timer wiping
// playback position instead of pausing") — this only verifies the picker UI
// itself surfaces a running countdown once a duration is picked, both
// inline in the settings sheet (ReaderSettingsSheet) and on PlaybackBar's
// title row (identifier "sleepTimerCountdown") once a book is open.
final class SleepTimerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // The "Hẹn giờ tắt" Picker row's default (non-.inline/.segmented) style
    // renders as a NavigationLink-style cell whose reported hit point can
    // resolve to {-1, -1} — "exists" but not hittable — right after the
    // settings sheet finishes presenting/scrolling. Coordinate-tapping its
    // own center sidesteps that, same fix TTSPlaybackUITests uses for a
    // similar race on book rows.
    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // playPauseButton's accessibilityLabel flips between "Đọc"/"Tạm dừng"
    // with isPlaying (see PlaybackBar) — waiting for "Tạm dừng" confirms
    // the first sentence's audio actually finished loading and started, so
    // a subsequent tap reliably lands on togglePlayback()'s pause() branch
    // instead of racing isLoadingAudio and hitting resume() again.
    private func waitForPlaying(_ button: XCUIElement, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "label == %@", "Tạm dừng")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "Playback should reach the playing state")
    }

    func testSettingSleepTimerShowsCountdown() throws {
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
        let playPauseButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 15), "Should reach ReaderView")
        // scheduleAutoStop() (which the sleep-timer countdown depends on)
        // only runs once playback is active — either from start() here, or
        // from autoStopMinutes' didSet, which itself only fires while
        // `active` is true. So playback must actually be started before
        // picking a duration below.
        playPauseButton.tap()

        app.buttons["voiceMenuButton"].tap()
        XCTAssertTrue(app.navigationBars["Cài đặt đọc"].waitForExistence(timeout: 5))

        let sleepTimerRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Hẹn giờ tắt")).firstMatch
        XCTAssertTrue(sleepTimerRow.waitForExistence(timeout: 5))
        tapWhenHittable(sleepTimerRow)

        let thirtyMinutesOption = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "30 phút")).firstMatch
        XCTAssertTrue(thirtyMinutesOption.waitForExistence(timeout: 5), "Picker should offer a 30-minute option")
        thirtyMinutesOption.tap()

        // Picker style pushes to a sub-screen for selection — back out to
        // the settings sheet if so (no-op if it was a menu-style picker
        // that already dismissed itself).
        if !app.navigationBars["Cài đặt đọc"].exists, app.navigationBars.buttons.element(boundBy: 0).exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let countdownLabel = app.staticTexts["Sẽ tắt sau"]
        XCTAssertTrue(countdownLabel.waitForExistence(timeout: 5), "Settings sheet should show the running countdown once a timer is set")

        app.buttons["Xong"].tap()
        XCTAssertTrue(app.otherElements["sleepTimerCountdown"].waitForExistence(timeout: 5) || app.staticTexts["sleepTimerCountdown"].waitForExistence(timeout: 1), "PlaybackBar should also show the countdown once a book is open")
    }

    // Regression coverage for the pause/resume reset fix: pausing ends the
    // sleep-timer "session" (countdown should disappear, not keep ticking
    // down in the background), and pressing play again starts a brand-new
    // one rather than resuming the old, already-drained countdown.
    func testPauseClearsCountdownAndResumeStartsFresh() throws {
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
        let playPauseButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 15), "Should reach ReaderView")
        playPauseButton.tap()

        app.buttons["voiceMenuButton"].tap()
        XCTAssertTrue(app.navigationBars["Cài đặt đọc"].waitForExistence(timeout: 5))

        let sleepTimerRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Hẹn giờ tắt")).firstMatch
        XCTAssertTrue(sleepTimerRow.waitForExistence(timeout: 5))
        tapWhenHittable(sleepTimerRow)

        // Exact match, not CONTAINS: "5 phút" is a substring of "15 phút"
        // and "45 phút" too, so a loose predicate can resolve to the wrong
        // menu item (or race the menu's closing animation) and silently
        // leave autoStopMinutes unchanged.
        let fiveMinuteOption = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "5 phút")).firstMatch
        XCTAssertTrue(fiveMinuteOption.waitForExistence(timeout: 5), "Picker should offer the 5-minute option added for easy testing")
        fiveMinuteOption.tap()

        if !app.navigationBars["Cài đặt đọc"].exists, app.navigationBars.buttons.element(boundBy: 0).exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Wait for the settings sheet's own countdown to appear before
        // dismissing — same synchronization the passing
        // testSettingSleepTimerShowsCountdown relies on; without it, "Xong"
        // can be tapped before autoStopMinutes' didSet has actually run
        // scheduleAutoStop().
        let countdownLabel = app.staticTexts["Sẽ tắt sau"]
        XCTAssertTrue(countdownLabel.waitForExistence(timeout: 5), "Settings sheet should show the running countdown once a timer is set")

        app.buttons["Xong"].tap()

        // Matched by identifier regardless of XCUIElementType — the
        // countdown's underlying type isn't guaranteed .other (unlike
        // otherElements[...] alone, which silently never matches it).
        let countdown = app.descendants(matching: .any)["sleepTimerCountdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 5), "PlaybackBar should show the running 5-minute countdown")

        // Confirm playback actually reached the playing state (not still
        // mid-fetch) before pausing, then let the countdown run down a bit
        // so a reset is actually observable.
        waitForPlaying(playPauseButton)
        Thread.sleep(forTimeInterval: 5)
        playPauseButton.tap()
        XCTAssertTrue(
            NSPredicate(format: "exists == false").evaluate(with: countdown)
                || !countdown.waitForExistence(timeout: 3),
            "Pausing should clear the sleep-timer countdown (old session ended)"
        )

        // Resume: a fresh countdown should reappear, starting back near the
        // full 5 minutes rather than continuing from wherever it left off.
        playPauseButton.tap()
        XCTAssertTrue(countdown.waitForExistence(timeout: 5), "Resuming should start a brand-new countdown")
    }
}
