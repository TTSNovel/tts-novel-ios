import XCTest

// Verifies two of the most recent fixes:
// 1. "Đăng xuất" moved out of LibraryView's toolbar into ReaderSettingsSheet.
// 2. Every screen's own content (not just Library's) reserves space for the
//    persistent PlaybackBar via its own .safeAreaInset attachment, so the
//    bar never overlaps the screen's last row/line of content.
final class SettingsAndPlaybarLayoutUITests: XCTestCase {

    private struct Config: Decodable {
        let username: String
        let password: String
    }

    private let config: Config? = {
        guard let data = FileManager.default.contents(atPath: "/tmp/tts_test_config.json") else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Guest mode (see WebnovelReaderApp) means the app always lands on
    /// Library first — this logs in via Settings ("Đăng nhập") rather than
    /// expecting a username field already on screen at launch.
    private func login(_ app: XCUIApplication) {
        app.launch()
        // May land on Library directly or auto-resume into ReaderView —
        // wait generously for either instead of assuming a fixed cutoff
        // distinguishes them (auto-resume can be slow to load chapter
        // content under system load). voiceMenuButton exists on both
        // screens (readerSettingsToolbar), so either is fine to proceed from.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if app.buttons["bookRow"].firstMatch.exists { break }
            if app.buttons["playPauseButton"].exists { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        app.buttons["voiceMenuButton"].tap()
        let settingsLoginButton = app.buttons["settingsLoginButton"]
        if settingsLoginButton.waitForExistence(timeout: 5) {
            settingsLoginButton.tap()
            let usernameField = app.textFields["usernameField"]
            if usernameField.waitForExistence(timeout: 5) {
                usernameField.tap()
                usernameField.typeText(config?.username ?? "")
                app.secureTextFields["passwordField"].tap()
                app.secureTextFields["passwordField"].typeText(config?.password ?? "")
                app.buttons["loginButton"].tap()
                _ = app.buttons["Đăng xuất"].waitForExistence(timeout: 10)
            }
        }
        if app.navigationBars["Cài đặt đọc"].exists {
            app.buttons["Xong"].tap()
        }

        if app.buttons["playPauseButton"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testLogoutButtonLivesInSettingsSheet() throws {
        let app = XCUIApplication()
        login(app)

        XCTAssertTrue(app.navigationBars["Novel Reader"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Đăng xuất"].exists, "Logout should no longer be a toolbar button on Library")

        app.buttons["voiceMenuButton"].tap()
        let logoutButton = app.buttons["Đăng xuất"]
        // The settings Form is taller than one screen (voice/speed/auto/
        // preload sections above it), so the Logout section starts below
        // the fold — scroll the sheet to reveal it instead of expecting it
        // to already be on-screen.
        for _ in 0..<5 where !logoutButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(logoutButton.waitForExistence(timeout: 5), "Logout should be inside the settings sheet")

        logoutButton.tap()
        // Logging out no longer dead-ends at a forced login screen — guest
        // mode (see WebnovelReaderApp) means the sheet just closes back to
        // whatever screen was underneath, and the app stays fully usable.
        XCTAssertFalse(app.navigationBars["Cài đặt đọc"].waitForExistence(timeout: 5), "Logging out should dismiss the settings sheet, not show a login wall")
        XCTAssertTrue(
            app.buttons["bookRow"].firstMatch.waitForExistence(timeout: 10) || app.buttons["playPauseButton"].exists,
            "App should remain usable as a guest after logout"
        )
    }

    func testReaderContentNotCoveredByPlaybackBar() throws {
        let app = XCUIApplication()
        login(app)

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 30))
        bookRow.tap()

        let startButton = app.buttons["startFromBeginningButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()

        // Generous timeout: a fresh install's first chapter load can be
        // much slower (offline voice model warm-up) than a warm relaunch.
        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 60))
        playButton.tap()

        let playingPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: playingPredicate, object: playButton)], timeout: 60),
            .completed, "Play button never switched to playing state"
        )

        // Bar is now in its taller 3-row state (title/chapter line, combined
        // progress bar, transport controls). Scroll the chapter content to
        // its true end and confirm the bar's own top edge sits at/after the
        // scroll view's bottom safe-area inset — i.e. content never renders
        // underneath it.
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            scrollView.swipeUp()
        }

        let bar = app.otherElements["playbackBar"].firstMatch
        XCTAssertTrue(bar.exists)
        let barTopY = bar.frame.minY

        // Every static text cell still on screen after scrolling to the end
        // must sit above the bar's top edge, not behind it.
        let texts = app.staticTexts.allElementsBoundByIndex
        for text in texts where text.isHittable {
            XCTAssertLessThanOrEqual(
                text.frame.maxY, barTopY + 4,
                "Text '\(text.label.prefix(30))' overlaps the playback bar (text bottom \(text.frame.maxY) vs bar top \(barTopY))"
            )
        }
    }
}
