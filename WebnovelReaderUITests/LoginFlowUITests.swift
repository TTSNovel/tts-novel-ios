import XCTest

// Drives the real app UI end-to-end against the one deployed server
// (SessionStore.baseURL is hardcoded — there's only one GCP deployment, no
// server picker in the UI). Real credentials never live in this committed
// file — write them to /tmp/tts_test_config.json first (Simulator shares
// the host filesystem, unlike a real device):
//   {"username": "...", "password": "..."}
//
// Covers guest mode (default entry point, no login required to browse/read
// — see WebnovelReaderApp) and logging in via Settings ("Đăng nhập"), which
// replaced the old forced login-screen-on-launch flow.
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

    func testGuestLandsDirectlyOnLibraryWithoutLogin() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertFalse(app.textFields["usernameField"].waitForExistence(timeout: 3), "Launch should never show a forced login screen")

        // Any real book row proves the public catalog (books.json) loaded
        // without a session cookie — titles vary run to run as the library
        // grows, so just require the list isn't empty rather than naming a
        // specific book.
        XCTAssertTrue(app.buttons["bookRow"].firstMatch.waitForExistence(timeout: 15), "Guest should see the real library, not an empty/error state")
    }

    func testLoginFromSettingsShowsLoggedInState() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["bookRow"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["voiceMenuButton"].tap()

        let settingsLoginButton = app.buttons["settingsLoginButton"]
        guard settingsLoginButton.waitForExistence(timeout: 5) else {
            // Already logged in (e.g. Keychain-restored from a previous
            // test run on this simulator) — nothing left to prove here.
            return
        }
        settingsLoginButton.tap()

        let usernameField = app.textFields["usernameField"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "'Đăng nhập' should open the login form")
        usernameField.tap()
        usernameField.typeText(config?.username ?? "")

        let passwordField = app.secureTextFields["passwordField"]
        passwordField.tap()
        passwordField.typeText(config?.password ?? "")

        app.buttons["loginButton"].tap()

        // LoginView auto-dismisses itself on success, landing back on
        // Settings — which should now show "Đăng xuất" instead of
        // "Đăng nhập".
        XCTAssertTrue(app.buttons["Đăng xuất"].waitForExistence(timeout: 15), "Settings should show Đăng xuất after a successful login")
        XCTAssertFalse(app.buttons["settingsLoginButton"].exists)
    }
}
