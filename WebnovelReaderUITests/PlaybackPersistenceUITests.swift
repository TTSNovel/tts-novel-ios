import XCTest

// Verifies the core ask behind promoting ReaderPlaybackController to an
// app-wide singleton (see its doc comment): audio must keep playing when
// navigating back to BookDetailView/Library, like Music/Podcasts — not
// stop the moment ReaderView leaves the screen.
final class PlaybackPersistenceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlaybackSurvivesNavigatingBackToLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        // Guest mode (see WebnovelReaderApp): playback works without login
        // — a guest just gets the on-device voice instead of an online one
        // (ReaderPlaybackController.makeFetchTask), which is irrelevant to
        // what this test actually checks (does the play *state* persist
        // across navigation) — no login step needed here.

        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15))
        bookRow.tap()

        let startButton = app.buttons["startFromBeginningButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()

        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        playButton.tap()

        let playingPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: playingPredicate, object: playButton)], timeout: 15),
            .completed, "Play button never switched to playing state"
        )

        // Back out two screens: ReaderView -> BookDetailView -> Library.
        // The old behavior (playback.stop() in ReaderView.onDisappear)
        // would silently kill audio here.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Novel Reader"].waitForExistence(timeout: 5), "Should be back at the Library")

        // Re-enter the same book/chapter and confirm playback never
        // stopped — the play button should already read "Tạm dừng"
        // (playing) the instant the screen reappears, not "Đọc" (would
        // mean it got reset).
        bookRow.tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(
            playButton.label.contains("Tạm dừng"),
            "Playback should still be running after navigating away and back — got label: \(playButton.label)"
        )
    }
}
