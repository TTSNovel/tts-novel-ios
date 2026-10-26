import XCTest

final class ResumeFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
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
