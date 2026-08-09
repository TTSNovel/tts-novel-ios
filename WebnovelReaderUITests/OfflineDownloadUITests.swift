import XCTest

// One-off helper test to prep a downloaded book for manual offline-mode
// verification (login -> open first book -> download it fully). Shares
// TTSPlaybackUITests' /tmp/tts_test_config.json convention for real
// credentials (never committed with real values).
final class OfflineDownloadUITests: XCTestCase {

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

    func testDownloadFirstBook() throws {
        let app = XCUIApplication()
        app.launch()

        let usernameField = app.textFields["usernameField"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
        usernameField.tap()
        usernameField.typeText(config?.username ?? "")

        app.secureTextFields["passwordField"].tap()
        app.secureTextFields["passwordField"].typeText(config?.password ?? "")

        app.buttons["loginButton"].tap()

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 20), "Library never showed a book row")
        bookRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let downloadButton = app.buttons["downloadButton"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10), "BookDetailView never appeared")
        downloadButton.tap()

        let deleteButton = app.buttons["deleteDownloadButton"]
        // Long novels can run to thousands of chapters at concurrency 4 —
        // generous timeout rather than guessing a "small enough" book.
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: deleteButton)],
            timeout: 600
        )
        XCTAssertEqual(result, .completed, "Download never completed (downloadButton -> deleteDownloadButton)")
    }
}
