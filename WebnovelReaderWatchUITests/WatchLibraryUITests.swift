import XCTest

// Drives the real Watch app UI end-to-end against the one deployed server
// (SessionStore.baseURL is hardcoded, same as the iPhone app's UI tests) —
// no mock server. Then:
// `xcodebuild test -scheme WebnovelReaderWatch -only-testing:WebnovelReaderWatchUITests/WatchLibraryUITests`
final class WatchLibraryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGuestLandsOnLibraryWithRealBooks() throws {
        let app = XCUIApplication()
        app.launch()

        // Guest mode: the server's book catalog is public (same as the
        // iPhone app — see WebnovelReaderApp's doc comment) — no login
        // needed to see real rows.
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "bookRow_", "recentBookRow_")).firstMatch.waitForExistence(timeout: 15),
            "Guest should see the real library, not an empty/error state"
        )
    }

    // KNOWN LIMITATION: watchOS Simulator's `.searchable` text field
    // doesn't reliably accept `typeText(_:)` via XCUITest — tapping it
    // consistently throws "Neither element nor any descendant has
    // keyboard focus" regardless of extra taps/delays. Real watchOS text
    // entry (Simulator included) opens a system dictation/scribble sheet
    // outside the app's own accessibility tree rather than focusing an
    // inline keyboard the way iOS does, so `typeText` — which requires
    // the *original* field element to hold focus — never has anything to
    // dispatch to. The feature itself works (manually verified: typing in
    // that field does filter the list); this is a testing-infrastructure
    // gap, not an app bug, so it's flagged rather than papered over with a
    // workaround that only sometimes helps — same call as
    // TTSPlaybackUITests' own KNOWN LIMITATION on iOS.
    func testSearchFieldIsReachable() throws {
        let app = XCUIApplication()
        app.launch()

        let anyBookRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "bookRow_", "recentBookRow_")).firstMatch
        XCTAssertTrue(anyBookRow.waitForExistence(timeout: 15))

        // watchOS's `.searchable` field sits *above* the list content and
        // only materializes once scrolled into view — Digital Crown
        // rotation, not a touch swipe (confirmed empirically: a
        // List/CollectionView swipeDown() didn't reveal it, crown rotation
        // did). It also isn't `XCUIElementTypeSearchField` on watchOS the
        // way it is on iOS — it's a plain `TextField`, queried by its
        // `.searchable(prompt:)` text.
        XCUIDevice.shared.rotateDigitalCrown(delta: -1.0)
        let searchField = app.textFields["Tìm sách"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Library should have a search field, revealed by scrolling up")
    }

    func testSettingsButtonOpensSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()

        // The gearshape toolbar button shows up as several nested
        // accessibility elements sharing the same identifier (a SwiftUI
        // watchOS toolbar quirk, confirmed via debugDescription) — take
        // the first match rather than asserting on a single unique one.
        let settingsButton = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["voicePicker"].waitForExistence(timeout: 5),
            "Settings sheet should open and show the voice picker"
        )
        app.buttons["settingsDoneButton"].firstMatch.tap()
    }
}
