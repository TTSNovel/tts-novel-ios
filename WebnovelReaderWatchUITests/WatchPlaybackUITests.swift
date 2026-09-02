import XCTest

// Proves the real /api/tts flow works end-to-end from the Watch app.
// /api/tts stays behind login even though browsing is public (same as the
// iPhone app — see ReaderView's footnote), and login itself can't be
// automated on this watchOS Simulator (`typeText` on a watchOS TextField/
// SecureField reliably throws "Neither element nor any descendant has
// keyboard focus" — see WatchLoginFlowUITests' KNOWN LIMITATION), so
// `testPlayPauseTogglesPlayingState` skips unless the simulator already
// has a session (log in manually once, or receive one via the iPhone
// app's WCSession handoff, to exercise it).
// `xcodebuild test -scheme WebnovelReaderWatch -only-testing:WebnovelReaderWatchUITests/WatchPlaybackUITests`
final class WatchPlaybackUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func isLoggedIn(_ app: XCUIApplication) -> Bool {
        app.buttons["settingsButton"].firstMatch.tap()
        // watchOS Forms/Lists are virtualized — the login/logout section
        // (last in the Form) isn't materialized until scrolled into view;
        // Digital Crown rotation is what actually reveals it (confirmed
        // empirically, see WatchLoginFlowUITests' note).
        let settingsLoginButton = app.buttons["settingsLoginButton"]
        let logoutButton = app.buttons["logoutButton"]
        var attempts = 0
        while !settingsLoginButton.exists, !logoutButton.exists, attempts < 20 {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
            Thread.sleep(forTimeInterval: 0.3)
            attempts += 1
        }
        let loggedIn = logoutButton.exists
        app.buttons["settingsDoneButton"].firstMatch.tap()
        return loggedIn
    }

    private func openFirstBookAndStartListening(_ app: XCUIApplication) {
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "bookRow_", "recentBookRow_")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        firstRow.tap()

        let startButton = app.buttons["startListeningButton"]
        let continueButton = app.buttons["continueButton"]
        if startButton.waitForExistence(timeout: 5) {
            startButton.tap()
        } else {
            XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
            continueButton.tap()
        }
        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 10))
    }

    func testPlayPauseTogglesPlayingState() throws {
        let app = XCUIApplication()
        app.launch()
        guard isLoggedIn(app) else {
            throw XCTSkip("Not logged in, and login can't be automated on this watchOS Simulator — log in manually once to exercise this test.")
        }
        openFirstBookAndStartListening(app)

        let playPauseButton = app.buttons["playPauseButton"]
        playPauseButton.tap()

        // Real synthesis — generous timeout, same as the iPhone app's own
        // TTS UI tests. No reliable label to assert on (SF Symbol image,
        // not text) — `isPlaying` flips the icon, tapped again below
        // proves the control round-trips play -> pause without erroring.
        Thread.sleep(forTimeInterval: 5)
        let synthesisError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Không tạo được giọng đọc")).firstMatch
        XCTAssertFalse(synthesisError.exists, "Should not show a synthesis error for the default voice")
        playPauseButton.tap()
    }

    /// Chapter navigation itself needs no login (only the /api/tts audio
    /// does) — a guest can exercise this one.
    func testSkipChapterAdvancesChapterTitle() throws {
        let app = XCUIApplication()
        app.launch()
        openFirstBookAndStartListening(app)

        let chapterTitleLabel = app.staticTexts["chapterTitleLabel"]
        XCTAssertTrue(chapterTitleLabel.waitForExistence(timeout: 10))
        let initialTitle = chapterTitleLabel.label

        let nextButton = app.buttons["nextChapterButton"]
        guard nextButton.isEnabled else { return } // last chapter of a 1-chapter book — nothing to prove
        nextButton.tap()

        // Chapter fetch is a real network call — wait for the title to
        // actually change rather than asserting immediately.
        let titleChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", initialTitle), object: chapterTitleLabel
        )
        XCTAssertEqual(XCTWaiter().wait(for: [titleChanged], timeout: 15), .completed, "Chapter title should change after skipping forward")
    }
}
