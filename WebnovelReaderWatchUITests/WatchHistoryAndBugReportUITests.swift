import XCTest

// Covers Settings' "Nhật ký" (ActionHistoryView, reused as-is from
// WebnovelReader/Views/ with a watchOS-specific filter sheet swapped in for
// iOS's Menu — see that file's `#if os(watchOS)` branch) and "Báo lỗi"
// (BugReportView, also reused as-is). Neither needs login — both are
// reachable and functional as a guest.
// `xcodebuild test -scheme WebnovelReaderWatch -only-testing:WebnovelReaderWatchUITests/WatchHistoryAndBugReportUITests`
final class WatchHistoryAndBugReportUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// watchOS Forms/Lists are virtualized — a row below the fold isn't
    /// materialized in the accessibility tree until scrolled into view,
    /// and Digital Crown rotation is the mechanism that actually works (a
    /// touch swipe on the container doesn't reveal it — confirmed
    /// empirically). Small steps in a loop rather than one large fixed
    /// delta, since exactly how far a row sits varies run to run.
    private func scrollUntilVisible(_ element: XCUIElement, maxAttempts: Int = 20) {
        var attempts = 0
        while !element.exists, attempts < maxAttempts {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
            Thread.sleep(forTimeInterval: 0.3)
            attempts += 1
        }
    }

    private func openSettings(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["settingsButton"].firstMatch.tap()
    }

    func testHistoryReachableAndFilterSheetListsEveryCategory() throws {
        let app = XCUIApplication()
        openSettings(app)

        let historyLink = app.buttons["historyLink"]
        scrollUntilVisible(historyLink)
        XCTAssertTrue(historyLink.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0) // let the crown scroll settle before tapping
        historyLink.tap()
        XCTAssertTrue(app.staticTexts["Nhật ký"].waitForExistence(timeout: 10))

        // A plain `.tap()` right after landing on this screen intermittently
        // doesn't register (confirmed empirically, same class of issue as
        // WatchSettingsUITests' toggle — a coordinate tap is what actually
        // lands) — settle first, then tap by coordinate.
        let filterButton = app.buttons["historyFilterButton"].firstMatch
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        filterButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Lọc theo loại"].waitForExistence(timeout: 10), "Filter should open as a sheet on watchOS, not a Menu (unavailable there)")
        // Every AppEventCategory should be listed, regardless of whether
        // any events of that category have actually happened yet.
        for label in ["Tất cả", "Điều hướng", "Phát audio", "Tải xuống", "Đăng nhập", "Dịch chương", "Lỗi"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "Filter sheet should list '\(label)'")
        }
    }

    func testBugReportAllowsEmptyDescriptionAndSubmits() throws {
        let app = XCUIApplication()
        openSettings(app)

        let bugReportLink = app.buttons["bugReportLink"]
        scrollUntilVisible(bugReportLink)
        XCTAssertTrue(bugReportLink.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0) // let the crown scroll settle before tapping
        bugReportLink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.staticTexts["Báo lỗi"].waitForExistence(timeout: 10))
        let submitButton = app.buttons["bugReportSubmitButton"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        XCTAssertTrue(submitButton.isEnabled, "Submit should stay enabled with an empty description")
        submitButton.tap()

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
