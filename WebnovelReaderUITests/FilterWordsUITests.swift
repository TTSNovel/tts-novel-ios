import XCTest

// `xcodebuild test -scheme WebnovelReader -only-testing:WebnovelReaderUITests/FilterWordsUITests`
//
// Regression test for the "Filter Words" list + shared Add/Edit sheet
// (FilterWordsView.swift). Screenshots are attached with `.keepAlways` so
// they can be pulled out of the resulting .xcresult for a visual diff
// against the design mockup — this feature deliberately avoids `.toolbar`
// for its Add/Cancel/Save buttons (see FilterWordsView's doc comment), so a
// real screenshot is the only way to confirm nothing overlaps.
final class FilterWordsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openFilterWords(_ app: XCUIApplication) throws {
        app.launch()
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if app.buttons["bookRow"].firstMatch.exists { break }
            if app.buttons["voiceMenuButton"].exists { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        app.buttons["voiceMenuButton"].tap()
        let filterWordsLink = app.buttons["filterWordsLink"]
        XCTAssertTrue(filterWordsLink.waitForExistence(timeout: 5))
        filterWordsLink.tap()

        XCTAssertTrue(app.buttons["filterWordsAddButton"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testListShowsSeededRulesWithTags() throws {
        let app = XCUIApplication()
        try openFilterWords(app)

        let firstRow = app.buttons.matching(identifier: "filterWordRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "Seeded default rules should populate the list")
        XCTAssertTrue(app.staticTexts["REGEX"].firstMatch.exists || app.staticTexts["PLAIN TEXT"].firstMatch.exists)
        attachScreenshot(app, named: "FilterWords-List")
    }

    func testAddSheetShowsCustomHeaderNotToolbar() throws {
        let app = XCUIApplication()
        try openFilterWords(app)

        app.buttons["filterWordsAddButton"].tap()
        let saveButton = app.buttons["filterWordSaveButton"]
        let cancelButton = app.buttons["filterWordCancelButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertTrue(cancelButton.exists)
        XCTAssertFalse(saveButton.isEnabled, "Save should be disabled with an empty pattern")
        attachScreenshot(app, named: "FilterWords-Add-Empty")

        let patternField = app.textFields["filterWordPatternField"]
        XCTAssertTrue(patternField.waitForExistence(timeout: 5))
        patternField.tap()
        patternField.typeText("spoilcontent123")
        XCTAssertTrue(saveButton.isEnabled)
        attachScreenshot(app, named: "FilterWords-Add-Filled")

        cancelButton.tap()
        XCTAssertTrue(app.buttons["filterWordsAddButton"].waitForExistence(timeout: 5), "Cancel should return to the list without adding a row")
    }

    func testEditSheetPrefillsAndShowsDeleteRow() throws {
        let app = XCUIApplication()
        try openFilterWords(app)

        let firstRow = app.buttons.matching(identifier: "filterWordRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.tap()

        let patternField = app.textFields["filterWordPatternField"]
        XCTAssertTrue(patternField.waitForExistence(timeout: 5))
        XCTAssertFalse((patternField.value as? String ?? "").isEmpty, "Editing an existing rule should prefill its pattern")
        XCTAssertTrue(app.buttons["filterWordDeleteButton"].exists, "Delete row should only show in Edit mode, not Add")
        attachScreenshot(app, named: "FilterWords-Edit")

        app.buttons["filterWordCancelButton"].tap()
    }
}
