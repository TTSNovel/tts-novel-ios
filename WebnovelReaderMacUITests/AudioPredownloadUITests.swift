import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/AudioPredownloadUITests`
//
// End-to-end against the live server: downloads "Gatsby Vĩ Đại (SN)"
// (book 40 — 11 chapters, Vietnamese, so no translation step), pre-renders
// its audio with Piper VN until at least one chapter lands, checks Settings
// > Downloaded Audio lists it, then plays the book and expects the
// "downloaded audio" badge in PlaybackBar.
//
// Needs a logged-in session (online voice): the app's saved login, or
// `TEST_RUNNER_TTS_TEST_USER=… TEST_RUNNER_TTS_TEST_PASS=…` on a fresh VM.
final class AudioPredownloadUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPrerenderedChapterPlaysFromDownloadedAudio() throws {
        let app = XCUIApplication()
        app.launch()
        openBookDetail(app, title: "Gatsby Vĩ Đại (SN)")
        selectPiperVNLoggedIn(app)

        if !app.buttons["deleteDownloadButton"].firstMatch.exists {
            app.buttons["downloadButton"].firstMatch.click()
            XCTAssertTrue(app.buttons["deleteDownloadButton"].firstMatch.waitForExistence(timeout: 120), "Book should download")
        }

        let audioButton = app.buttons["audioPredownloadButton"].firstMatch
        XCTAssertTrue(audioButton.waitForExistence(timeout: 10), "Audio download button shows for a downloaded book")
        audioButton.click()
        let estimate = app.staticTexts["audioPredownloadEstimate"].firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 10))
        attachWindowScreenshot(app, named: "AudioSheet")

        let start = app.buttons["audioPredownloadStartButton"].firstMatch
        if start.exists, start.isEnabled { start.click() }
        let replace = app.buttons["Xoá và tải lại"].firstMatch
        if replace.waitForExistence(timeout: 2) { replace.click() }

        // At least one chapter rendered — "N/M chương" with N ≥ 1, or the
        // estimate reading "Đã tải hết" when an earlier run already did it.
        // (macOS exposes a SwiftUI Text's string as its AX value.)
        let completed = app.staticTexts["audioPredownloadCompleted"].firstMatch
        let rendered = NSPredicate { _, _ in
            if (estimate.value as? String) == "Đã tải hết" { return true }
            guard completed.exists, let value = completed.value as? String else { return false }
            return !value.hasPrefix("0/")
        }
        let landed = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 600) == .completed
        attachWindowScreenshot(app, named: "AudioSheet-Progress")
        XCTAssertTrue(landed, "A chapter should finish pre-rendering")
        let stop = app.buttons["audioPredownloadStopButton"].firstMatch
        if stop.exists { stop.click() }
        app.buttons["Đóng"].firstMatch.click()

        // Settings > Downloaded Audio lists the book with a size.
        app.buttons["voiceMenuButton"].firstMatch.click()
        let storageLink = app.buttons["audioStorageLink"].firstMatch
        XCTAssertTrue(storageLink.waitForExistence(timeout: 10))
        storageLink.click()
        XCTAssertTrue(app.descendants(matching: .any)["audioStorageRow_40"].firstMatch.waitForExistence(timeout: 10), "Book 40 should be listed")
        attachWindowScreenshot(app, named: "AudioStorage")
        // The sheet's own Back — the window behind it has one too.
        app.sheets.firstMatch.buttons["chevron.backward"].firstMatch.click()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.click()

        // Play from where the render started — that chapter's audio is on disk.
        let continueButton = app.buttons["continueReadingButton"].firstMatch
        if continueButton.exists { continueButton.click() } else { app.buttons["startFromBeginningButton"].firstMatch.click() }
        let play = app.buttons["playPauseButton"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        // A small VM screen can leave the window's bottom (PlaybackBar)
        // off screen — zoom it to fit.
        if !play.isHittable {
            app.menuBarItems["Window"].firstMatch.click()
            app.menuItems["Zoom"].firstMatch.click()
        }
        play.click()
        let badge = app.descendants(matching: .any)["prerenderedAudioIndicator"].firstMatch
        let playing = badge.waitForExistence(timeout: 30)
        attachWindowScreenshot(app, named: "Reader-PlayingDownloadedAudio")
        XCTAssertTrue(playing, "Playback should use the downloaded audio")
        play.click()
    }

    /// Library → book detail, from wherever the app resumed.
    private func openBookDetail(_ app: XCUIApplication, title: String) {
        if !app.windows.firstMatch.waitForExistence(timeout: 10) {
            app.typeKey("n", modifierFlags: .command)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "App should have a window")
        }
        if app.windows.firstMatch.frame.height < 700 {
            app.menuBarItems["Window"].firstMatch.click()
            app.menuItems["Zoom"].firstMatch.click()
        }
        for _ in 0..<4 {
            let back = app.buttons["chevron.backward"].firstMatch
            guard back.waitForExistence(timeout: 3) else { break }
            back.click()
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "Library search field should be reachable")
        search.click()
        search.typeText(title)
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'bookRow' AND label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(title) should show up in the library search")
        row.click()
        XCTAssertTrue(app.buttons["startFromBeginningButton"].firstMatch.waitForExistence(timeout: 15), "Book detail should open")
    }

    /// Settings: log in if this is a guest session, pick Piper VN.
    private func selectPiperVNLoggedIn(_ app: XCUIApplication) {
        app.buttons["voiceMenuButton"].firstMatch.click()
        let loginRow = app.buttons["settingsLoginButton"].firstMatch
        if loginRow.waitForExistence(timeout: 5) {
            let env = ProcessInfo.processInfo.environment
            guard let user = env["TTS_TEST_USER"], let pass = env["TTS_TEST_PASS"] else {
                XCTFail("Guest session, but TEST_RUNNER_TTS_TEST_USER/TEST_RUNNER_TTS_TEST_PASS aren't set")
                return
            }
            loginRow.click()
            let username = app.textFields["usernameField"].firstMatch
            XCTAssertTrue(username.waitForExistence(timeout: 5))
            username.click()
            username.typeText(user)
            let password = app.secureTextFields["passwordField"].firstMatch
            password.click()
            password.typeText(pass)
            app.buttons["loginButton"].firstMatch.click()
            XCTAssertTrue(
                XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: username)], timeout: 20) == .completed,
                "Login should succeed"
            )
            // Logging in leaves the sheet scrolled to the bottom — reopen it
            // so the voice picker (top section) is on screen again.
            app.buttons["Done"].firstMatch.click()
            app.buttons["voiceMenuButton"].firstMatch.click()
        }
        let picker = app.popUpButtons["modelPicker"].firstMatch
        // Right after logging in, the login view is still transitioning out.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: picker)
        let reachable = XCTWaiter().wait(for: [hittable], timeout: 15) == .completed
        if !reachable {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Screen-VoicePickerUnreachable"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(reachable, "Voice picker should be reachable")
        picker.click()
        let piper = app.menuItems["Piper VN"].firstMatch
        XCTAssertTrue(piper.waitForExistence(timeout: 5))
        piper.click()
        app.buttons["Done"].firstMatch.click()
    }
}
