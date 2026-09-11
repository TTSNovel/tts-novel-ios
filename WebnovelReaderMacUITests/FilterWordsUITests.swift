import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/FilterWordsUITests`
//
// macOS counterpart of WebnovelReaderUITests/FilterWordsUITests.swift.
// FilterWordsView deliberately avoids `.toolbar` for its "+ Add"/"Cancel"/
// "Save" buttons — on macOS any `.toolbar` item on a view pushed/presented
// inside this app's settings NavigationStack + .sheet renders into a bottom
// action bar that overlaps list content instead of reserving space for
// itself (real AppKit window chrome, confirmed across several failed
// workarounds — see FilterWordsView's doc comment). Screenshots here are
// attached with `.keepAlways` so they can be pulled from the .xcresult for a
// visual diff against the design mockup.
final class FilterWordsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openFilterWords(_ app: XCUIApplication) throws {
        app.launch()
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if app.buttons["bookRow"].firstMatch.exists { break }
            if app.buttons["voiceMenuButton"].firstMatch.exists { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        app.buttons["voiceMenuButton"].firstMatch.tap()
        let filterWordsLink = app.buttons["filterWordsLink"].firstMatch
        XCTAssertTrue(filterWordsLink.waitForExistence(timeout: 5))
        // ReaderSettingsSheet's content is taller than its fixed sheet
        // height (see ReaderSettingsSheet's `.frame`), so "Filter Words"
        // starts out clipped below the ScrollView's viewport — scroll it
        // into view first. `app.scrollViews.element(boundBy: 1)` is this
        // sheet's own ScrollView (index 0 is the main reader's chapter-text
        // ScrollView, behind this sheet) — see ReaderSettingsUITests for
        // why scrolling a "window" instead doesn't work here (the sheet
        // isn't exposed as its own top-level XCUIElementTypeWindow).
        // `isHittable` isn't a reliable gate here — it can report true for
        // an element that's actually clipped below the ScrollView's
        // viewport (confirmed empirically) — so scroll unconditionally
        // rather than relying on it.
        app.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: -400)
        XCTAssertTrue(filterWordsLink.waitForExistence(timeout: 5))
        filterWordsLink.tap()

        XCTAssertTrue(app.buttons["filterWordsAddButton"].firstMatch.waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        // app.screenshot() captures whatever's on screen at the app's frame,
        // not just its own content — without activate() first, a frontmost
        // terminal/editor window covering the display ends up in the
        // attachment instead of the app itself.
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testListShowsSeededRulesWithTags() throws {
        let app = XCUIApplication()
        try openFilterWords(app)

        let firstRow = app.buttons.matching(identifier: "filterWordRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "Seeded default rules should populate the list")
        attachScreenshot(app, named: "FilterWords-List-macOS")
    }

    func testAddSheetHeaderButtonsDoNotOverlapContent() throws {
        let app = XCUIApplication()
        try openFilterWords(app)

        app.buttons["filterWordsAddButton"].firstMatch.tap()
        let saveButton = app.buttons["filterWordSaveButton"].firstMatch
        let cancelButton = app.buttons["filterWordCancelButton"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertTrue(cancelButton.exists)
        XCTAssertFalse(saveButton.isEnabled, "Save should be disabled with an empty pattern")

        let patternField = app.textFields["filterWordPatternField"].firstMatch
        XCTAssertTrue(patternField.waitForExistence(timeout: 5))
        // The bug class this guards against: on macOS a `.toolbar`-based
        // header renders as AppKit chrome that can sit on top of the first
        // Form row instead of pushing it down — with the custom HStack
        // header this uses instead, the field must render fully below it.
        XCTAssertGreaterThan(
            patternField.frame.minY, cancelButton.frame.maxY - 4,
            "Pattern field should render below the header row, not underneath it"
        )
        attachScreenshot(app, named: "FilterWords-Add-macOS")

        cancelButton.tap()
        XCTAssertTrue(app.buttons["filterWordsAddButton"].firstMatch.waitForExistence(timeout: 5), "Cancel should return to the list without adding a row")
    }

    func testEditSheetPrefillsAndShowsDeleteRow() throws {
        let app = XCUIApplication()
        try openFilterWords(app)

        let firstRow = app.buttons.matching(identifier: "filterWordRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.tap()

        let patternField = app.textFields["filterWordPatternField"].firstMatch
        XCTAssertTrue(patternField.waitForExistence(timeout: 5))
        XCTAssertFalse((patternField.value as? String ?? "").isEmpty, "Editing an existing rule should prefill its pattern")
        XCTAssertTrue(app.buttons["filterWordDeleteButton"].firstMatch.exists, "Delete row should only show in Edit mode, not Add")
        attachScreenshot(app, named: "FilterWords-Edit-macOS")

        app.buttons["filterWordCancelButton"].firstMatch.tap()
    }
}
