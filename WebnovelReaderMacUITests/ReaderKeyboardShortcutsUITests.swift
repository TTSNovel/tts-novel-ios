import XCTest

// `xcodebuild test -scheme WebnovelReaderMac -only-testing:WebnovelReaderMacUITests/ReaderKeyboardShortcutsUITests`
//
// Regression test for the macOS reader's hotkeys: ←/→ for prev/next
// chapter, Page Up/Page Down to scroll a page (see ChapterPagerView.swift
// and ScrollPageCoordinator.swift — SwiftUI's ScrollView never becomes
// first responder on macOS, so Page Up/Down need explicit wiring, unlike
// what a plain AppKit ScrollView would give for free).
final class ReaderKeyboardShortcutsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Same "land in ReaderView regardless of resumed session" dance as
    /// ChapterListUITests.testChapterListSheetShowsRowsOnMac.
    private func openReader(_ app: XCUIApplication) throws {
        app.launch()
        if app.buttons["nextChapterButton"].waitForExistence(timeout: 3) { return }
        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
        bookRow.tap()

        let startButton = app.buttons["startFromBeginningButton"]
        let continueButton = app.buttons["continueReadingButton"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 10) || continueButton.waitForExistence(timeout: 1),
            "Book detail should show either a start or continue button"
        )
        (startButton.exists ? startButton : continueButton).tap()
        XCTAssertTrue(app.buttons["nextChapterButton"].firstMatch.waitForExistence(timeout: 10))
    }

    func testArrowKeysNavigateChapters() throws {
        let app = XCUIApplication()
        try openReader(app)

        let prev = app.buttons["prevChapterButton"].firstMatch
        let next = app.buttons["nextChapterButton"].firstMatch
        XCTAssertTrue(next.isEnabled, "Book needs 2+ chapters for this test to mean anything")

        // Playback state persists across launches (see ChapterListUITests'
        // doc comment), so this can resume mid-book — rewind with the same
        // ← this test is about to verify, to land on a known chapter 0
        // regardless of where the session left off.
        for _ in 0..<500 where prev.isEnabled {
            app.typeKey(.leftArrow, modifierFlags: [])
            usleep(50_000)
        }
        XCTAssertFalse(prev.isEnabled, "Should be on chapter 0 with prev disabled after rewinding")

        app.typeKey(.rightArrow, modifierFlags: [])
        let becameEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: prev)
        XCTAssertEqual(XCTWaiter().wait(for: [becameEnabled], timeout: 5), .completed, "→ should advance to chapter 1, enabling prevChapterButton")

        app.typeKey(.leftArrow, modifierFlags: [])
        let becameDisabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: prev)
        XCTAssertEqual(XCTWaiter().wait(for: [becameDisabled], timeout: 5), .completed, "← should return to chapter 0, disabling prevChapterButton")
    }

    /// Page Up/Page Down are meaningless on a chapter that fits in one
    /// screen — real webnovel chapters usually run long, but the library's
    /// first chapter isn't guaranteed to, so hop forward (bounded) until
    /// one has enough sentences to actually need paging.
    private func findChapterTallEnoughToPage(_ app: XCUIApplication) throws {
        let next = app.buttons["nextChapterButton"].firstMatch
        for _ in 0..<30 {
            if app.buttons["sentenceText_30"].firstMatch.waitForExistence(timeout: 2) { return }
            guard next.isEnabled else { break }
            next.tap()
        }
        XCTFail("Could not find a chapter with 30+ sentences within 30 chapters to test paging against")
    }

    func testPageDownAndPageUpScrollContent() throws {
        let app = XCUIApplication()
        try openReader(app)
        try findChapterTallEnoughToPage(app)

        let firstSentence = app.buttons["sentenceText_0"].firstMatch
        XCTAssertTrue(firstSentence.waitForExistence(timeout: 10), "Chapter title (sentenceText_0) should be rendered")
        let originalY = firstSentence.frame.origin.y

        app.typeKey(.pageDown, modifierFlags: [])
        // ScrollView content isn't lazy (plain VStack), so sentenceText_0
        // stays in the accessibility tree the whole time — only its frame
        // moves as the page scrolls. XCUIElement.frame isn't KVO-observable,
        // so poll it directly instead of using an XCTNSPredicateExpectation.
        var scrolledDownOK = false
        for _ in 0..<50 {
            if firstSentence.frame.origin.y < originalY - 20 { scrolledDownOK = true; break }
            usleep(100_000)
        }
        XCTAssertTrue(scrolledDownOK, "Page Down should scroll the chapter content up by roughly a page")

        app.typeKey(.pageUp, modifierFlags: [])
        var scrolledBackOK = false
        var lastY: CGFloat = .nan
        // ScrollViewReader's `anchor: .top` settles a few points off the
        // page's true resting position (padding/animation rounding), so
        // this checks "back near the top", not a pixel-exact match.
        for _ in 0..<50 {
            lastY = firstSentence.frame.origin.y
            if abs(lastY - originalY) < 30 { scrolledBackOK = true; break }
            usleep(100_000)
        }
        XCTAssertTrue(scrolledBackOK, "Page Up should scroll the chapter content back near the top (originalY=\(originalY), lastY=\(lastY))")
    }
}
