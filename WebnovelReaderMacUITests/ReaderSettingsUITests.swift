import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/ReaderSettingsUITests`
//
// Covers the ReaderSettingsSheet redesign away from `Form`'s default macOS
// two-column style (see ReaderSettingsSheet's doc comment) — mainly a smoke
// test that the sheet opens, its rows render without the old duplicate-
// label/indentation look, and the "Done" toolbar button doesn't clip the
// last row (same AppKit bottom-bar-chrome concern as FilterWordsView).
final class ReaderSettingsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSettings(_ app: XCUIApplication) throws {
        app.launch()
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if app.buttons["bookRow"].firstMatch.exists { break }
            if app.buttons["voiceMenuButton"].firstMatch.exists { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        app.buttons["voiceMenuButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["filterWordsLink"].firstMatch.waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsRowsRenderAndLinksNavigate() throws {
        let app = XCUIApplication()
        try openSettings(app)

        let modelPicker = app.popUpButtons["modelPicker"].firstMatch
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))
        // SwiftUI's `.pickerStyle(.segmented)` exposes as an AX RadioGroup
        // on macOS, not SegmentedControl (confirmed via app.debugDescription).
        let fontSizePicker = app.radioGroups["fontSizePicker"].firstMatch
        XCTAssertTrue(fontSizePicker.waitForExistence(timeout: 5))
        let actionHistoryLink = app.buttons["actionHistoryLink"].firstMatch
        let filterWordsLink = app.buttons["filterWordsLink"].firstMatch
        XCTAssertTrue(actionHistoryLink.exists)
        XCTAssertTrue(filterWordsLink.exists)
        // These two rows previously duplicated their section header text in
        // Form's own label column — now the model picker sits directly
        // below its "Model" header instead of an indented "Model" row label.
        XCTAssertLessThan(modelPicker.frame.minY, fontSizePicker.frame.minY)
        attachScreenshot(app, named: "ReaderSettings-Root-macOS")

        // The sheet's fixed height (see ReaderSettingsSheet's `.frame`) is
        // shorter than all sections combined, so "Filter Words" starts out
        // clipped below the visible ScrollView viewport.
        //
        // Getting this scroll target right took some trial and error:
        // `app.windows` only ever reports ONE window here (the main reader
        // window) — the .sheet's content doesn't show up as its own
        // top-level `XCUIElementTypeWindow`, even though its rows are
        // directly queryable via `app.buttons`/`app.popUpButtons` etc, and
        // `app.windows.containing(...)` for an element that's actually in
        // the sheet silently resolves to that same single (wrong) window.
        // `app.scrollViews` does correctly report two distinct scroll
        // areas — index 0 is the main reader's chapter-text ScrollView,
        // index 1 is this sheet's ScrollView (confirmed by frame: 480pt
        // wide, matching the sheet's fixed width) — so scroll that one
        // directly instead of a window.
        let sheetScrollView = app.scrollViews.element(boundBy: 1)
        XCTAssertTrue(sheetScrollView.waitForExistence(timeout: 5))
        let modelPickerYBeforeScroll = modelPicker.frame.minY
        sheetScrollView.scroll(byDeltaX: 0, deltaY: -400)
        XCTAssertTrue(filterWordsLink.waitForExistence(timeout: 5))
        XCTAssertNotEqual(modelPicker.frame.minY, modelPickerYBeforeScroll, "Scrolling the sheet's ScrollView should move its content")
        XCTAssertTrue(filterWordsLink.isHittable, "Filter Words row should be scrolled into view before tapping")
        filterWordsLink.tap()
        XCTAssertTrue(app.buttons["filterWordsAddButton"].firstMatch.waitForExistence(timeout: 5), "Filter Words link should still navigate correctly after the layout rewrite")
    }
}
