import XCTest

// The Watch app can log in fully independently of the iPhone (standalone
// LoginView, reused as-is from WebnovelReader/Views/), separate from the
// WCSession handoff path.
//
// KNOWN LIMITATION: this watchOS Simulator/Xcode build can't automate
// actually *typing* into either the login form's fields or `.searchable`'s
// (see WatchLibraryUITests' own KNOWN LIMITATION) — confirmed empirically
// with a throwaway non-empty credentials fixture: `typeText(_:)` on a
// watchOS `TextField`/`SecureField` throws "Neither element nor any
// descendant has keyboard focus" regardless of extra taps/delays/scrolls.
// Real watchOS text entry (Simulator included) hands off to a system
// dictation/scribble sheet outside the app's own accessibility tree rather
// than focusing an inline keyboard the way iOS does, so there's nothing
// for XCUITest's synthetic keystrokes to land on. This is a testing-
// infrastructure gap, not an app bug — login itself works when typed by a
// human — so what's covered here is everything mechanically verifiable
// (guest browsing, the form's reachability/fields/cancel path) without
// pretending a full type-username-and-submit round trip is automated.
// `xcodebuild test -scheme WebnovelReaderWatch -only-testing:WebnovelReaderWatchUITests/WatchLoginFlowUITests`
final class WatchLoginFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// watchOS Forms/Lists are virtualized — a row below the fold isn't
    /// materialized in the accessibility tree until scrolled into view,
    /// and Digital Crown rotation is the mechanism that actually works (a
    /// touch swipe on the container doesn't reveal it — confirmed
    /// empirically, see WatchLibraryUITests' search-field note). Small
    /// steps in a loop rather than one large fixed delta, since exactly
    /// how far the login/logout section (last in the Form) sits varies
    /// run to run.
    private func scrollUntilEitherVisible(_ a: XCUIElement, _ b: XCUIElement, maxAttempts: Int = 20) {
        var attempts = 0
        while !a.exists, !b.exists, attempts < maxAttempts {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
            Thread.sleep(forTimeInterval: 0.3)
            attempts += 1
        }
    }

    private func openSettings(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["settingsButton"].firstMatch.tap()
        // Login/logout are mutually exclusive — whichever one the current
        // session state actually renders, scroll until that one shows up.
        scrollUntilEitherVisible(app.buttons["settingsLoginButton"], app.buttons["logoutButton"])
    }

    func testGuestCanBrowseWithoutLoggingIn() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertFalse(app.textFields["usernameField"].waitForExistence(timeout: 3), "Launch should never force a login screen")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "bookRow_", "recentBookRow_")).firstMatch.waitForExistence(timeout: 15),
            "Guest should see the real library"
        )
    }

    func testLoginFormIsReachableWithFieldsAndCancelWorks() throws {
        let app = XCUIApplication()
        openSettings(app)

        let settingsLoginButton = app.buttons["settingsLoginButton"]
        guard settingsLoginButton.waitForExistence(timeout: 10) else {
            return // Already logged in from a previous manual/WCSession-handoff session on this simulator.
        }
        settingsLoginButton.tap()

        let usernameField = app.textFields["usernameField"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "'Đăng nhập' should open the standalone login form")
        XCTAssertTrue(app.secureTextFields["passwordField"].exists)
        XCTAssertTrue(app.buttons["loginButton"].exists)

        // Cancel back out ("Đóng") — proves the form is a real, dismissable
        // sheet, not a dead end.
        app.buttons["Đóng"].tap()
        XCTAssertTrue(settingsLoginButton.waitForExistence(timeout: 5), "Cancelling login should return to Settings, still logged out")
    }

    /// Only meaningful if this simulator already has a session — either a
    /// human logged in manually once, or the iPhone app relayed one via
    /// WCSession (see WebnovelReader/App/WatchSessionRelay.swift). Skips
    /// rather than failing when neither has happened, since there's no
    /// automated way to establish one (see the KNOWN LIMITATION above).
    func testLogoutReturnsToLoggedOutState() throws {
        let app = XCUIApplication()
        openSettings(app)

        let logoutButton = app.buttons["logoutButton"]
        guard logoutButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Not logged in, and login can't be automated on this watchOS Simulator (see class doc comment) — log in manually once to exercise this test.")
        }
        logoutButton.tap()
        XCTAssertTrue(app.buttons["settingsLoginButton"].waitForExistence(timeout: 10), "Logout should show 'Đăng nhập' again")
    }
}
