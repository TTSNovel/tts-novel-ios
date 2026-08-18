import XCTest

// Regression coverage for "preload chưa hoạt động đúng": on a cold chapter
// (no cache at all yet), playback used to start on sentence 1 immediately
// and only then race the fetch queue, instead of buffering the configured
// "Số câu tải trước" window first. ReaderPlaybackController.beginChapter now
// awaits waitForInitialBuffer() before playing the first sentence — this
// proves that gate actually holds against the real preload/synthesis
// pipeline (not just against a mocked one). Explicitly selects "Piper
// (offline)" rather than relying on guest mode to force the offline path
// (makeFetchTask only falls back to offline when logged out/disconnected —
// a session left logged in from an earlier test run makes it go straight
// to the real online API instead, and that backend's Cloud Run cold-starts
// measured ~15s/request under a 3-way concurrent burst, which starves this
// test's timeout with no logic bug involved). On-device synthesis keeps
// this fast and deterministic regardless of network/login state.
final class PreloadBufferingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Extracts the leading integer from labels shaped like "12/34" or
    /// "⇩12/34" (PlaybackBar's readPositionText/preloadPositionText).
    private func leadingCount(_ label: String) -> Int? {
        let digits = label.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func testColdChapterWaitsForPreloadWindowBeforePlaying() throws {
        let app = XCUIApplication()
        app.launch()

        // Guest mode may auto-resume straight into ReaderView from a prior
        // session's progress — back out to Library so this always starts
        // from a known screen (same pattern as BookDetailActionsUITests).
        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
        bookRow.tap()

        // Deliberately do NOT use "Đọc từ đầu" (chapter 0) here: if a prior
        // test run/manual session left saved progress on this exact book's
        // chapter 0, landing there re-triggers applyResumeIfNeeded ->
        // prepareResume, which immediately kicks off *real* CPU-bound
        // offline-synthesis fetches for whatever sentences follow the saved
        // position. Navigating away afterward doesn't stop them (Piper/
        // VieNeu don't check Task.isCancelled — see
        // cancelInFlightFetches()'s doc comment) — they keep burning CPU in
        // the background and starve the chapter this test actually cares
        // about, observed as a single sentence taking 20+ seconds instead
        // of a fraction of that. Tapping a chapter row further into the
        // book from BookDetailView's own list instead lands on a chapter
        // `open()` has never seen before, so applyResumeIfNeeded's
        // `saved.chapterIndex == chapterIndex` guard can't match — no
        // resume, no head-start fetches, no contention. This also
        // incidentally reaches a chapter with more real content than the
        // book's often-short first chapter (foreword/synopsis).
        let chapterRows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chương"))
        let enoughChapters = NSPredicate(format: "count > 5")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enoughChapters, object: chapterRows)], timeout: 15),
            .completed,
            "Book should list more than 5 chapters to reach a guaranteed-cold, real-content one"
        )
        chapterRows.element(boundBy: 5).tap()

        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 15), "Should reach ReaderView")
        XCTAssertFalse(playButton.label.contains("Tạm dừng"), "Should not already be playing on a freshly-navigated chapter")

        let preloadTarget = 20
        app.buttons["voiceMenuButton"].tap()
        XCTAssertTrue(app.navigationBars["Cài đặt đọc"].waitForExistence(timeout: 5))

        // Force the on-device voice explicitly — see the class doc comment
        // for why relying on guest-mode's offline fallback isn't reliable
        // here.
        app.buttons["modelPicker"].tap()
        let offlineOption = app.buttons["Piper (offline)"]
        XCTAssertTrue(offlineOption.waitForExistence(timeout: 5), "Piper (offline) voice option not in menu")
        offlineOption.tap()

        // Set "Số câu tải trước" (preloadAhead) to its max option — matches
        // the exact scenario reported ("preload 20 câu").
        let preloadRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Số câu tải trước")).firstMatch
        XCTAssertTrue(preloadRow.waitForExistence(timeout: 5))
        tapWhenHittable(preloadRow)

        // Exact match, not CONTAINS: "5 câu" is a substring of "15 câu" —
        // see SleepTimerUITests' identical pitfall with "5 phút"/"15 phút".
        let option = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "\(preloadTarget) câu")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Picker should offer a \(preloadTarget)-sentence option")
        option.tap()

        // Picker style pushes to a sub-screen for selection — back out to
        // the settings sheet if so (same as SleepTimerUITests).
        if !app.navigationBars["Cài đặt đọc"].exists, app.navigationBars.buttons.element(boundBy: 0).exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["Xong"].tap()

        playButton.tap()
        let playing = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
        let expectation = XCTNSPredicateExpectation(predicate: playing, object: playButton)
        // preloadAhead=20 means beginChapter's wait (see
        // waitForInitialBuffer, itself capped at 60s) may need to synthesize
        // up to 20 sentences offline (3 at a time — maxConcurrentFetches)
        // before the first one plays — generous but bounded margin above
        // that 60s internal cap.
        let result = XCTWaiter().wait(for: [expectation], timeout: 90)
        XCTAssertEqual(result, .completed, "Playback never actually started")

        // The core assertion: by the moment the very first sentence starts
        // playing, the preload window must already have reached its
        // configured target — proving beginChapter() waited instead of
        // playing sentence 1 immediately and catching up afterward.
        let readPositionText = app.staticTexts["readPositionText"]
        XCTAssertTrue(readPositionText.waitForExistence(timeout: 2))
        let preloadPositionText = app.staticTexts["preloadPositionText"]
        XCTAssertTrue(preloadPositionText.waitForExistence(timeout: 2), "Preload indicator should be visible once playback has started")

        guard let totalSentences = leadingCount(String(readPositionText.label.split(separator: "/").last ?? "")) else {
            XCTFail("Could not parse total sentence count from '\(readPositionText.label)'")
            return
        }
        let expectedMinimum = min(preloadTarget, totalSentences)

        guard let preloadedCount = leadingCount(preloadPositionText.label.trimmingCharacters(in: CharacterSet(charactersIn: "⇩"))) else {
            XCTFail("Could not parse preload count from '\(preloadPositionText.label)'")
            return
        }
        XCTAssertGreaterThanOrEqual(
            preloadedCount, expectedMinimum,
            "Playback started with only \(preloadedCount) sentence(s) preloaded — expected at least \(expectedMinimum) (preloadAhead=\(preloadTarget)) before the first sentence plays"
        )
        // <= 2, not == 1: sentence 1 here is the chapter title, whose audio
        // can be short enough to already finish and auto-advance to
        // sentence 2 in the gap between the "Tạm dừng" predicate firing and
        // this line actually reading the label — harmless UI-read race, not
        // a sign preload was skipped (preloadedCount above is monotonic and
        // already reflects the state at the moment sentence 1 started).
        let positionAtCheck = leadingCount(readPositionText.label)
        XCTAssertNotNil(positionAtCheck)
        XCTAssertLessThanOrEqual(positionAtCheck ?? .max, 2, "Should still be at/near sentence 1 right as playback starts")
    }
}
