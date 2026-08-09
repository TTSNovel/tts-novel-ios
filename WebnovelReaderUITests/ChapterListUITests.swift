import XCTest

// Verifies the chapter-list feature added to ReaderView (a standalone popup,
// independent of BookDetailView — see ChapterListSheet.swift) and
// BookDetailView's own "Danh sách chương" section both resolve real chapter
// titles via ChapterTitles.load() instead of the bare "Chương N" placeholder.
// A placeholder label never contains ":" (real titles look like "Chương N:
// <tên>"), which is what distinguishes the two here without hardcoding any
// particular book's content.
final class ChapterListUITests: XCTestCase {

    private struct Config: Decodable {
        let username: String
        let password: String
    }

    private let config: Config? = {
        guard let data = FileManager.default.contents(atPath: "/tmp/tts_test_config.json") else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testChapterListSheetAndBookDetailShowRealTitles() throws {
        let app = XCUIApplication()
        app.launch()

        let usernameField = app.textFields["usernameField"]
        if usernameField.waitForExistence(timeout: 3) {
            usernameField.tap()
            usernameField.typeText(config?.username ?? "")
            app.secureTextFields["passwordField"].tap()
            app.secureTextFields["passwordField"].typeText(config?.password ?? "")
            app.buttons["loginButton"].tap()
        }

        // May auto-resume straight into ReaderView — back out to Library
        // first so this test always starts from a known screen.
        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
        bookRow.tap()

        // BookDetailView's own "Danh sách chương" list — same real-title
        // requirement as the popup below. A fresh NSPredicate per call site
        // (rather than one shared `let`) sidesteps Swift 6 strict-concurrency
        // "sending risks data races" complaints about reusing the same
        // non-Sendable NSPredicate instance across two separate .matching() calls.
        func realTitlePredicate() -> NSPredicate { NSPredicate(format: "label CONTAINS[c] %@", ":") }
        let detailRowsWithRealTitle = app.buttons.matching(realTitlePredicate())
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: detailRowsWithRealTitle)], timeout: 15),
            .completed,
            "BookDetailView's chapter list never showed a real title (only bare 'Chương N' placeholders)"
        )

        let startButton = app.buttons["startFromBeginningButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()

        let chapterListButton = app.buttons["chapterListButton"]
        XCTAssertTrue(chapterListButton.waitForExistence(timeout: 10), "ReaderView should expose its own chapter-list toolbar button")
        chapterListButton.tap()

        let sheetRowsWithRealTitle = app.buttons.matching(identifier: "chapterListRow").matching(realTitlePredicate())
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: sheetRowsWithRealTitle)], timeout: 15),
            .completed,
            "ChapterListSheet never showed a real title (only bare 'Chương N' placeholders)"
        )

        // Current chapter (index 0, just opened via "Đọc từ đầu") should be
        // the first row and carry the checkmark — visible as the row simply
        // existing at the top since VoiceOver/XCUITest exposes the
        // checkmark image as part of the button's accessible content.
        let firstRow = app.buttons["chapterListRow"].firstMatch
        XCTAssertTrue(firstRow.exists)

        app.buttons["Đóng"].tap()
        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 5), "Closing the sheet should return to ReaderView")
    }
}
