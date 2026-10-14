import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/GoogleTranslationUITests`
//
// End-to-end against the live server (no mock server — same as the other
// UI tests): opens "Defiance of the Fall" (book 119, English, has a Google
// glossary — see tts-webnovel's tools/data/glossaries/119.en-vi.tsv),
// switches the translation engine to Google, and checks the chapter ends up
// in Vietnamese and the "Saved translations" row reports stored chapters.
// Needs a logged-in session (the app's saved Keychain login).
final class GoogleTranslationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openBook119(_ app: XCUIApplication) {
        // The app auto-resumes the last-read book straight into ReaderView
        // (see ChapterListUITests) — nothing to do if that's already book 119.
        let readerWindow = app.windows.matching(NSPredicate(format: "title CONTAINS 'Defiance'")).firstMatch
        if app.buttons["voiceMenuButton"].firstMatch.waitForExistence(timeout: 10), readerWindow.exists {
            return
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "Library search field should be reachable")
        search.click()
        search.typeText("Defiance of the Fall")
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'bookRow' AND label CONTAINS 'Defiance'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Book 119 should show up in the library search")
        row.click()

        let startButton = app.buttons["startFromBeginningButton"]
        let continueButton = app.buttons["continueReadingButton"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 15) || continueButton.waitForExistence(timeout: 1),
            "Book detail should show either a start or continue button"
        )
        (continueButton.exists ? continueButton : startButton).click()
    }

    /// ChapterPagerView renders each sentence as a Button `sentenceText_<n>`
    /// whose label is the displayed (original or translated) text.
    private func vietnameseTextAppears(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let vietnamese = NSPredicate(
            format: "identifier BEGINSWITH 'sentenceText_' AND label MATCHES %@",
            "(?s).*[ạảãầấậẩẫằắặẳẵẹẻẽềếệểễịọỏõồốộổỗờớợởỡụủừứựửữỵỷỹđ].*"
        )
        let texts = app.buttons.matching(vietnamese)
        return XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 3"), object: texts)],
            timeout: timeout
        ) == .completed
    }

    func testGoogleEngineTranslatesBook119() throws {
        let app = XCUIApplication()
        app.launch()
        openBook119(app)
        XCTAssertTrue(app.buttons["voiceMenuButton"].firstMatch.waitForExistence(timeout: 20), "Reader should open")

        app.buttons["voiceMenuButton"].firstMatch.click()
        let enginePicker = app.popUpButtons["translationEnginePicker"].firstMatch
        XCTAssertTrue(enginePicker.waitForExistence(timeout: 10))
        enginePicker.click()
        let googleItem = app.menuItems["Google Translate (glossary)"].firstMatch
        XCTAssertTrue(googleItem.waitForExistence(timeout: 5))
        googleItem.click()

        let stored = app.staticTexts["storedTranslationsCount"].firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 10), "Saved translations row should appear for the Google engine")
        attachScreenshot(app, named: "Settings-GoogleEngine")
        app.buttons["Done"].firstMatch.click()

        XCTAssertTrue(vietnameseTextAppears(app, timeout: 60), "Chapter text should switch to Vietnamese")
        attachScreenshot(app, named: "Reader-Book119-Translated")

        // The chapter just translated is now stored on the server.
        app.buttons["voiceMenuButton"].firstMatch.click()
        XCTAssertTrue(stored.waitForExistence(timeout: 10))
        // macOS exposes a SwiftUI Text's string as its AX value, not label.
        let storedChapters = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'chapter'"), object: stored)
        XCTAssertEqual(
            XCTWaiter().wait(for: [storedChapters], timeout: 15), .completed,
            "Saved translations should count stored chapters, got \(String(describing: stored.value))"
        )
        attachScreenshot(app, named: "Settings-StoredCount")
        app.buttons["Done"].firstMatch.click()
    }
}
