import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/GlossaryUITests`
//
// End-to-end against the live server, like GoogleTranslationUITests: on
// book 119 with the Google engine, adds a book-only glossary term from
// Settings → Glossary, checks the open chapter re-translates with it, then
// deletes the term again (restoring the shared glossary's "Hệ Thống").
final class GlossaryUITests: XCTestCase {

    private let testTarget = "HETHONGUITEST"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func sentences(containing text: String, _ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sentenceText_' AND label CONTAINS %@", text))
    }

    private func waitForCount(_ query: XCUIElementQuery, _ format: String, timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: query)], timeout: timeout
        ) == .completed
    }

    private func openGlossary(_ app: XCUIApplication) {
        // A click on the settings button right after the reader appears is
        // sometimes dropped (same flakiness as the older Mac UI tests) —
        // click again only once a sheet clearly isn't coming.
        let enginePicker = app.popUpButtons["translationEnginePicker"].firstMatch
        for _ in 0..<3 {
            app.buttons["voiceMenuButton"].firstMatch.click()
            if enginePicker.waitForExistence(timeout: 12) || app.sheets.firstMatch.exists { break }
        }
        if !enginePicker.waitForExistence(timeout: 10) { attachWindowScreenshot(app, named: "Settings-NotOpening") }
        XCTAssertTrue(enginePicker.exists, "Reader Settings should open")
        if enginePicker.value as? String != "Google Translate (glossary)" {
            enginePicker.click()
            app.menuItems["Google Translate (glossary)"].firstMatch.click()
        }
        let link = app.buttons["glossaryLink"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Glossary link should show for the Google engine")
        link.click()
        _ = app.buttons["glossaryAddButton"].firstMatch.waitForExistence(timeout: 10)
        attachWindowScreenshot(app, named: "Glossary-Opened")
        XCTAssertTrue(
            waitForCount(app.buttons.matching(identifier: "glossaryRow"), "count > 0", timeout: 20),
            "Book 119 should have its own glossary terms"
        )
    }

    private func closeSettings(_ app: XCUIApplication) {
        // Back out of the pushed Glossary view, then dismiss the sheet —
        // whichever of the two is still needed (⌘[ sometimes closes the
        // whole sheet).
        let sheet = app.sheets.firstMatch
        let back = sheet.buttons.matching(NSPredicate(format: "label IN {'Back', 'Reader Settings'}")).firstMatch
        if back.waitForExistence(timeout: 5) { back.click() }
        let done = sheet.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.click() }
        let closed = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)], timeout: 10
        ) == .completed
        if !closed { attachWindowScreenshot(app, named: "Settings-NotClosing") }
        XCTAssertTrue(closed, "Settings should be closed")
    }

    func testAddingATermRetranslatesTheChapter() throws {
        let app = XCUIApplication()
        app.launch()
        openBook119(app)
        XCTAssertTrue(app.buttons["voiceMenuButton"].firstMatch.waitForExistence(timeout: 20), "Reader should open")

        openGlossary(app)
        attachWindowScreenshot(app, named: "Glossary-Book119")
        app.buttons["glossaryAddButton"].firstMatch.click()
        let source = app.textFields["glossarySourceField"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        source.typeText("System")
        let target = app.textFields["glossaryTargetField"].firstMatch
        target.click()
        target.typeText(testTarget)
        app.buttons["glossarySaveButton"].firstMatch.click()

        let addedRow = app.buttons.matching(NSPredicate(format: "identifier == 'glossaryRow' AND label CONTAINS %@", testTarget)).firstMatch
        XCTAssertTrue(addedRow.waitForExistence(timeout: 10))
        // Saving publishes to Google before the view lets go of "Saving…".
        XCTAssertTrue(app.buttons["glossaryAddButton"].firstMatch.waitForEnabled(timeout: 90), "Save should finish")
        XCTAssertFalse(app.staticTexts["glossaryError"].exists, "Save should succeed")
        closeSettings(app)

        XCTAssertTrue(
            waitForCount(sentences(containing: testTarget, app), "count > 0", timeout: 90),
            "The open chapter should re-translate with the new term"
        )
        attachWindowScreenshot(app, named: "Reader-NewTermApplied")

        // Clean up: delete the term again.
        openGlossary(app)
        XCTAssertTrue(addedRow.waitForExistence(timeout: 10))
        addedRow.click()
        let delete = app.buttons["glossaryDeleteButton"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(waitForCount(app.buttons.matching(NSPredicate(format: "identifier == 'glossaryRow' AND label CONTAINS %@", testTarget)), "count == 0", timeout: 10))
        XCTAssertTrue(app.buttons["glossaryAddButton"].firstMatch.waitForEnabled(timeout: 90))
        closeSettings(app)
        XCTAssertTrue(
            waitForCount(sentences(containing: "Hệ Thống", app), "count > 0", timeout: 90),
            "With the test term gone, the shared glossary's translation should be back"
        )
    }
}

private extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: self)], timeout: timeout
        ) == .completed
    }
}
