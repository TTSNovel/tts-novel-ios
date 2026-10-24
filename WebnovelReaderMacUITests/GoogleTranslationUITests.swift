import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/GoogleTranslationUITests`
//
// End-to-end against the live server (no mock server — same as the other
// UI tests): opens "Defiance of the Fall" (book 119, English, has its own
// glossary terms on the server), switches the translation engine to Google,
// and checks the chapter ends up in Vietnamese and the "Saved translations"
// row reports stored chapters.
//
// Needs a logged-in session: the app's saved Keychain login, or — on a
// fresh machine/VM — credentials passed to the runner as
// `TEST_RUNNER_TTS_TEST_USER=… TEST_RUNNER_TTS_TEST_PASS=… xcodebuild test …`.
final class GoogleTranslationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
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
        attachWindowScreenshot(app, named: "Settings-GoogleEngine")
        app.buttons["Done"].firstMatch.click()

        XCTAssertTrue(vietnameseTextAppears(app, timeout: 60), "Chapter text should switch to Vietnamese")
        attachWindowScreenshot(app, named: "Reader-Book119-Translated")

        // The chapter just translated is now stored on the server.
        app.buttons["voiceMenuButton"].firstMatch.click()
        XCTAssertTrue(stored.waitForExistence(timeout: 10))
        // macOS exposes a SwiftUI Text's string as its AX value, not label.
        let storedChapters = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'chapter'"), object: stored)
        XCTAssertEqual(
            XCTWaiter().wait(for: [storedChapters], timeout: 15), .completed,
            "Saved translations should count stored chapters, got \(String(describing: stored.value))"
        )
        attachWindowScreenshot(app, named: "Settings-StoredCount")
        app.buttons["Done"].firstMatch.click()
    }
}

/// Shared by the translation UI tests (this file and GlossaryUITests).
extension XCTestCase {
    func attachWindowScreenshot(_ app: XCUIApplication, named name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A guest session (fresh machine/VM — no saved login) logs in from
    /// Settings → "Log In", using TTS_TEST_USER / TTS_TEST_PASS from
    /// the runner's environment. Expects ReaderView to be showing.
    func loginIfGuest(_ app: XCUIApplication) {
        // ChapterPageContent's footnote only shows for a guest (with an
        // online voice selected) — skip opening Settings otherwise.
        let guestNote = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Chế độ khách'")).firstMatch
        guard guestNote.waitForExistence(timeout: 5) else { return }
        app.buttons["voiceMenuButton"].firstMatch.click()
        let loginRow = app.buttons["settingsLoginButton"].firstMatch
        guard loginRow.waitForExistence(timeout: 15) else {
            app.buttons["Done"].firstMatch.click()
            return
        }
        let env = ProcessInfo.processInfo.environment
        guard let user = env["TTS_TEST_USER"], let pass = env["TTS_TEST_PASS"] else {
            XCTFail("Guest session, but TEST_RUNNER_TTS_TEST_USER/TEST_RUNNER_TTS_TEST_PASS aren't set")
            return
        }
        loginRow.click()
        let username = app.textFields["usernameField"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.click()
        username.typeText(user)
        let password = app.secureTextFields["passwordField"].firstMatch
        password.click()
        password.typeText(pass)
        app.buttons["loginButton"].firstMatch.click()
        XCTAssertTrue(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: username)], timeout: 20) == .completed,
            "Login should succeed"
        )
        app.buttons["Done"].firstMatch.click()
    }

    /// Lands in ReaderView on book 119, logged in — directly if the app
    /// auto-resumed there (it resumes the last-read book, see
    /// ChapterListUITests), otherwise back to the library and via search.
    func openBook119(_ app: XCUIApplication) {
        // A previous run that ended with the window closed can leave the
        // relaunched app windowless (seen in a fresh VM) — open one.
        if !app.windows.firstMatch.waitForExistence(timeout: 10) {
            app.typeKey("n", modifierFlags: .command)
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "App should have a window")
        }
        // The Settings sheet is taller than a small default window (a VM's
        // 900×450), which pushes its Log In/Done buttons out of reach.
        let window = app.windows.firstMatch
        if window.frame.height < 700 {
            app.menuBarItems["Window"].firstMatch.click()
            app.menuItems["Zoom"].firstMatch.click()
        }
        let readerWindow = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'Defiance of the Fall: A LitRPG'")).firstMatch
        if app.buttons["voiceMenuButton"].firstMatch.waitForExistence(timeout: 10) {
            loginIfGuest(app)
            if readerWindow.exists { return }
            // A different book — back to the library (reader → book detail
            // → library; the search field shows in every one of them on macOS).
            // Library rows stay in the AX tree under pushed views, so pop
            // until there's no Back button left instead of looking for them.
            for _ in 0..<4 {
                let back = app.buttons["chevron.backward"].firstMatch
                guard back.waitForExistence(timeout: 3) else { break }
                back.click()
            }
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "Library search field should be reachable")
        search.click()
        search.typeText("Defiance of the Fall")
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'bookRow' AND label CONTAINS 'Defiance of the Fall: A LitRPG'")).firstMatch
        let found = row.waitForExistence(timeout: 15)
        if !found { attachWindowScreenshot(app, named: "Library-Search") }
        XCTAssertTrue(found, "Book 119 should show up in the library search")
        row.click()

        let startButton = app.buttons["startFromBeginningButton"]
        let continueButton = app.buttons["continueReadingButton"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 15) || continueButton.waitForExistence(timeout: 1),
            "Book detail should show either a start or continue button"
        )
        (continueButton.exists ? continueButton : startButton).click()
        if app.buttons["voiceMenuButton"].firstMatch.waitForExistence(timeout: 20) {
            loginIfGuest(app)
        }
    }
}
