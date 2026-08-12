import XCTest

// Proves the real /api/tts flow works end-to-end for every voice in the
// picker, against the one deployed server (SessionStore.baseURL is
// hardcoded — no server picker in the UI anymore). Real credentials never
// live in this committed file — write them to /tmp/tts_test_config.json
// first (Simulator shares the host filesystem, unlike a real device):
//   {"username": "...", "password": "...",
//    "bookTitle": "...", "chapterHeading": "..."}
// (bookTitle/chapterHeading: pick a book that ISN'T first in the library
// list — see KNOWN LIMITATION below.)
//
// KNOWN LIMITATION: login and the library list (real books, real covers)
// work, but tapping into a book to reach the chapter/play-button screen
// does not reliably — every tap strategy tried (element.tap(), coordinate
// taps, root-window taps, scroll-then-tap) either throws "not hittable" or
// silently no-ops on these real rows (Button merging title+author+
// chapter-count+cover into one accessibility element), while the exact
// same interaction works fine against a no-cover single-book fixture.
// Whether that's a Simulator/SwiftUI List quirk on this Xcode/iOS combo or
// something more specific hasn't been root-caused — flagging rather than
// papering over it with a workaround that only sometimes helps.
final class TTSPlaybackUITests: XCTestCase {

    private struct Config: Decodable {
        let username: String
        let password: String
        let bookTitle: String
        let chapterHeading: String
    }

    private let config: Config? = {
        guard let data = FileManager.default.contents(atPath: "/tmp/tts_test_config.json") else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlayAudioForEveryVoice() throws {
        let app = XCUIApplication()
        app.launch()

        try login(app)

        // Guest mode (see WebnovelReaderApp) may have already auto-resumed
        // straight into ReaderView using local/synced progress before login
        // even ran — back out to Library so the title lookup below has a
        // known screen to search.
        if app.buttons["playPauseButton"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let titleText = config?.bookTitle ?? ""
        let bookRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", titleText)).firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15))
        tapWhenHittable(bookRow)

        let firstChapter = app.staticTexts["Chương 1"]
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 10))
        tapWhenHittable(firstChapter)

        let chapterHeading = app.staticTexts[config?.chapterHeading ?? ""]
        XCTAssertTrue(chapterHeading.waitForExistence(timeout: 15))

        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 5))

        for voice in ["Piper VN", "Google Cloud TTS", "VieNeu-TTS", "Piper (offline)"] {
            selectVoice(voice, app: app)

            playButton.tap()
            let playing = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
            let expectation = XCTNSPredicateExpectation(predicate: playing, object: playButton)
            // Real synthesis (Google/VieNeu especially) is slower than a
            // stub's instant canned response — generous timeout.
            let result = XCTWaiter().wait(for: [expectation], timeout: 30)
            XCTAssertEqual(result, .completed, "\(voice): play button never switched to the playing state")

            playButton.tap() // pause before switching voices / ending the test
        }
    }

    /// A real (non-mock) List row can report `exists == true` slightly
    /// before it's `hittable` — e.g. while its AsyncImage cover is still
    /// laying out — where a plain `.tap()` throws "Failed to not
    /// hittable". Coordinate-tapping its own center sidesteps that
    /// specific race; see the class doc comment for the harder unsolved
    /// case (some production book rows not being tappable at all).
    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func selectVoice(_ name: String, app: XCUIApplication) {
        // Both Pickers inside the Menu render as one flat list of Cells
        // (voice options, a divider, then speed options) rather than
        // nested submenus — no intermediate "Giọng đọc" tap needed.
        app.buttons["voiceMenuButton"].tap()
        let option = app.buttons[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "voice option '\(name)' not found in menu")
        option.tap()
    }

    /// Guest mode (see WebnovelReaderApp) means the app lands directly on
    /// Library without ever showing the login form — this test needs an
    /// actual account (online voices require /api/tts, which stays behind
    /// login even though browsing/reading is now public), so it opens
    /// Settings and taps "Đăng nhập" explicitly instead of finding a
    /// username field already on screen.
    private func login(_ app: XCUIApplication) throws {
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
    }
}
