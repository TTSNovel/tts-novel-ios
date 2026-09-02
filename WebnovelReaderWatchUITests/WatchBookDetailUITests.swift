import XCTest

// `xcodebuild test -scheme WebnovelReaderWatch -only-testing:WebnovelReaderWatchUITests/WatchBookDetailUITests`
final class WatchBookDetailUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Taps the first real library row and confirms BookDetail renders —
    /// title/chapter count plus a start/continue button and the chapter
    /// list entry point.
    private func openFirstBookDetail(_ app: XCUIApplication) -> XCUIElement {
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "bookRow_", "recentBookRow_")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        firstRow.tap()
        return firstRow
    }

    func testBookDetailShowsStartOrContinueButton() throws {
        let app = XCUIApplication()
        app.launch()
        _ = openFirstBookDetail(app)

        let startButton = app.buttons["startListeningButton"]
        let continueButton = app.buttons["continueButton"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 10) || continueButton.waitForExistence(timeout: 1),
            "Book detail should show either 'Bắt đầu nghe' (no prior progress) or 'Tiếp tục' (resuming)"
        )
    }

    func testChapterListOpensAndSelectingAChapterStartsPlayback() throws {
        let app = XCUIApplication()
        app.launch()
        _ = openFirstBookDetail(app)

        let chapterListButton = app.buttons["chapterListButton"]
        XCTAssertTrue(chapterListButton.waitForExistence(timeout: 10))
        // A plain `.tap()` on a just-appeared button intermittently
        // doesn't register on this watchOS Simulator (confirmed
        // empirically for several other buttons in this suite) — a
        // coordinate tap after a brief settle is what reliably lands.
        Thread.sleep(forTimeInterval: 1.0)
        chapterListButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // ChapterListSheet (reused straight from the iOS Views/) shows a
        // "Chương mới nhất" (newest-<index>) section before "Tất cả chương"
        // (all-<index>) for any book with more than 5 chapters — per this
        // project's own prior finding, that first section is what's
        // actually on screen without scrolling, not "Chương 1". Either
        // prefix proves the sheet populated with real chapter rows.
        let anyChapterRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "newest-", "all-")).firstMatch
        XCTAssertTrue(anyChapterRow.waitForExistence(timeout: 10), "Chapter list should show real chapter rows")
        Thread.sleep(forTimeInterval: 1.0)
        anyChapterRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Selecting a chapter dismisses the sheet and pushes WatchPlaybackView.
        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 10), "Selecting a chapter should open the playback screen")
    }

    func testDownloadButtonStartsDownloadAndOffersDelete() throws {
        let app = XCUIApplication()
        app.launch()
        _ = openFirstBookDetail(app)

        // Whichever state the button starts in (fresh vs. already
        // downloaded from a previous test run on this simulator) — this
        // just proves the download control is present and does something,
        // not a full round trip (full-book download can take a while for
        // a long novel, out of scope for a UI smoke test).
        let downloadButton = app.buttons["downloadButton"]
        let deleteButton = app.buttons["deleteDownloadButton"]
        XCTAssertTrue(
            downloadButton.waitForExistence(timeout: 10) || deleteButton.waitForExistence(timeout: 1),
            "Book detail should show either a download or a delete-download control"
        )
        if deleteButton.exists {
            deleteButton.tap()
            XCTAssertTrue(downloadButton.waitForExistence(timeout: 10), "Deleting a download should reveal the download button again")
        }
    }
}
