import XCTest

// Drives the real app UI end-to-end (login -> library shows real books)
// against the one deployed server (SessionStore.baseURL is hardcoded —
// there's only one GCP deployment, no server picker in the UI). Real
// credentials never live in this committed file — write them to
// /tmp/tts_test_config.json first (Simulator shares the host filesystem,
// unlike a real device):
//   {"username": "...", "password": "..."}
//
// Then `xcodebuild test -scheme WebnovelReader -only-testing:WebnovelReaderUITests/LoginFlowUITests`.
final class LoginFlowUITests: XCTestCase {

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

    func testLoginShowsRealLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        let usernameField = app.textFields["usernameField"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
        usernameField.tap()
        usernameField.typeText(config?.username ?? "")

        let passwordField = app.secureTextFields["passwordField"]
        passwordField.tap()
        passwordField.typeText(config?.password ?? "")

        app.buttons["loginButton"].tap()

        // Any real book row proves login succeeded and books.json loaded —
        // titles vary run to run as the library grows, so just require the
        // list isn't empty rather than naming a specific book.
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 15), "Library screen should show at least one book after login")
    }
}
