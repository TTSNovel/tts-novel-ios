import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/VietPhraseTranslationUITests`
//
// End-to-end check of the VietPhrase (Hán Việt) engine against a real
// Chinese book on the server (万界守门人): picking the engine in Reader
// Settings should turn the chapter's Chinese text into its Hán Việt
// reading, and the toolbar translate button should flip back to the
// original. Needs network access to SERVER_BASE_URL.
final class VietPhraseTranslationUITests: XCTestCase {
    private let chineseBookTitle = "万界守门人"

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

    /// Sentence 0 — the chapter title (see ChapterPageContent's
    /// `sentenceText_<index>` buttons).
    private func chapterTitle(_ app: XCUIApplication, matching predicate: String) -> XCUIElement {
        app.buttons.matching(identifier: "sentenceText_0").matching(NSPredicate(format: predicate)).firstMatch
    }

    func testVietPhraseEngineConvertsChineseChapter() throws {
        let app = XCUIApplication()
        app.launch()

        // The app may auto-resume straight into whatever book was open last
        // (see ChapterListUITests) — back out to the library first.
        // NavigationStack's own back button — identified by its SF Symbol
        // (its "Back" label is shared with prevChapterButton). Reader ->
        // book detail -> library, so keep going until there's none left.
        _ = app.buttons["chapterListButton"].waitForExistence(timeout: 5)
        let back = app.toolbars.buttons["chevron.backward"].firstMatch
        while back.waitForExistence(timeout: 2) {
            back.click()
        }
        let search = app.searchFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Tìm truyện'")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Library search field should exist")
        search.click()
        search.typeText(chineseBookTitle)

        let bookRow = app.buttons.matching(identifier: "bookRow")
            .matching(NSPredicate(format: "label CONTAINS %@", chineseBookTitle)).firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "\(chineseBookTitle) should be in the library")
        bookRow.tap()

        let startButton = app.buttons["startFromBeginningButton"]
        let continueButton = app.buttons["continueReadingButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10) || continueButton.waitForExistence(timeout: 1))
        (startButton.exists ? startButton : continueButton).tap()

        // Pick VietPhrase in Reader Settings -> Translation -> Engine.
        let settingsButton = app.buttons["voiceMenuButton"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()
        let enginePicker = app.popUpButtons["translationEnginePicker"].firstMatch
        XCTAssertTrue(enginePicker.waitForExistence(timeout: 5))
        enginePicker.click()
        app.menuItems["VietPhrase (Hán Việt)"].click()
        attachScreenshot(app, named: "VietPhrase-Settings")
        app.buttons["Done"].firstMatch.tap()

        // Auto-translate defaults on, so the Hán Việt reading should replace
        // the Chinese title: 第N章 -> "Đệ N chương", or 简介 -> "Giản giới"
        // when the book opens on its intro.
        let translatedTitle = chapterTitle(app, matching: "label BEGINSWITH 'Đệ' OR label == 'Giản giới'")
        XCTAssertTrue(translatedTitle.waitForExistence(timeout: 20), "Chapter should show its Hán Việt reading")
        attachScreenshot(app, named: "VietPhrase-Translated")

        // The toolbar translate button flips back to the original Chinese.
        let translateButton = app.buttons["translateChapterButton"].firstMatch
        XCTAssertTrue(translateButton.waitForExistence(timeout: 5), "Translate button should show on a Chinese chapter")
        translateButton.tap()
        let originalTitle = chapterTitle(app, matching: "label BEGINSWITH '第' OR label == '简介'")
        XCTAssertTrue(originalTitle.waitForExistence(timeout: 10), "Toggling should show the original Chinese")
        attachScreenshot(app, named: "VietPhrase-Original")
        translateButton.tap()
    }
}
