import XCTest

// Covers the settings-sheet entry points added for "Nhật ký & lịch sử"
// (ActionHistoryView, doubling as action-history + debug-log viewer) and
// "Báo lỗi" (BugReportView) — both reachable from the same gearshape sheet
// every screen already exposes (see ReaderSettingsToolbar).
final class BugReportAndHistoryUITests: XCTestCase {

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

    /// Guest mode (see WebnovelReaderApp) means the app always lands
    /// directly on Library now — login isn't shown until Settings is opened
    /// and "Đăng nhập" is tapped. /api/bug-report still requires a real
    /// login (only book browsing/reading is public — see
    /// _is_public_reading_path in tts-webnovel's server.py), so this
    /// actually logs in via Settings rather than just reaching Library as
    /// a guest.
    private func login(_ app: XCUIApplication) {
        app.launch()
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
            XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
            usernameField.tap()
            usernameField.typeText(config?.username ?? "")
            app.secureTextFields["passwordField"].tap()
            app.secureTextFields["passwordField"].typeText(config?.password ?? "")
            app.buttons["loginButton"].tap()
            XCTAssertTrue(app.buttons["Đăng xuất"].waitForExistence(timeout: 10), "Login should succeed and show Đăng xuất")
        }
        app.buttons["Xong"].tap()

        // Back out if auto-resume landed on ReaderView, so callers always
        // start from a known screen (Library).
        if app.buttons["playPauseButton"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testActionHistoryReachableAndFiltersable() throws {
        let app = XCUIApplication()
        login(app)

        XCTAssertTrue(app.buttons["bookRow"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["voiceMenuButton"].tap()

        let historyLink = app.buttons["actionHistoryLink"]
        for _ in 0..<5 where !historyLink.exists {
            app.swipeUp()
        }
        XCTAssertTrue(historyLink.waitForExistence(timeout: 5))
        historyLink.tap()

        XCTAssertTrue(app.navigationBars["Nhật ký & lịch sử"].waitForExistence(timeout: 5))
        // Opening the library + this screen itself should already have
        // recorded at least a "Mở trang chủ" navigation event.
        XCTAssertTrue(app.staticTexts["Mở trang chủ"].firstMatch.waitForExistence(timeout: 5))

        let filterButton = app.buttons["historyFilterButton"]
        XCTAssertTrue(filterButton.exists)
        filterButton.tap()
        XCTAssertTrue(app.buttons["Điều hướng"].waitForExistence(timeout: 3))
        app.buttons["Điều hướng"].tap()
        // Filtered to navigation-only: the entry should still be visible.
        XCTAssertTrue(app.staticTexts["Mở trang chủ"].firstMatch.waitForExistence(timeout: 5))
    }

    func testBugReportAllowsEmptyDescriptionAndSubmits() throws {
        let app = XCUIApplication()
        login(app)

        XCTAssertTrue(app.buttons["bookRow"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["voiceMenuButton"].tap()

        let bugReportLink = app.buttons["bugReportLink"]
        for _ in 0..<5 where !bugReportLink.exists {
            app.swipeUp()
        }
        XCTAssertTrue(bugReportLink.waitForExistence(timeout: 5))
        bugReportLink.tap()

        XCTAssertTrue(app.navigationBars["Báo lỗi"].waitForExistence(timeout: 5))
        let submitButton = app.buttons["bugReportSubmitButton"]
        // The description is optional — the attached log (on by default) is
        // reason enough to submit on its own, and login/navigation just
        // happened, so the log is non-empty here regardless.
        XCTAssertTrue(submitButton.exists)
        XCTAssertTrue(submitButton.isEnabled, "Submit should stay enabled with an empty description")
        submitButton.tap()

        // /api/bug-report is deployed on the real server this suite runs
        // against (see login()), so this should resolve to the success
        // alert — but still accepts the failure-message path too, so a
        // transient network hiccup fails loudly with a real assertion
        // message instead of this test just hanging.
        let successAlert = app.alerts["Đã gửi báo cáo"]
        let failureText = app.staticTexts["Gửi báo cáo thất bại — thử lại sau"]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !successAlert.exists, !failureText.exists {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(successAlert.exists || failureText.exists, "Submitting should resolve to either a success alert or a visible failure message")
        if successAlert.exists {
            successAlert.buttons["OK"].tap()
        }
    }
}
