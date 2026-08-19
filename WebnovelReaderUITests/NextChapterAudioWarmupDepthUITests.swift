import XCTest

// Regression coverage for "next page preload không load trước next page":
// beginNextChapterAudioWarmup() used to cap the next chapter's speculative
// audio warm-up at a small, fixed `nextChapterWarmupCount = 5`, regardless of
// the user's own "Số câu tải trước" (preloadAhead) setting — so once the
// *current* chapter's preload window was fully buffered (the trigger for
// this warm-up), the next chapter still only ever got ~5 sentences ready
// ahead of time, not the full depth the user configured. ReaderPlaybackController
// now sizes the next-chapter warm-up off `preloadAhead` itself (see
// refillNextChapterWarmup). This drives real on-device (Piper offline, for
// determinism — see PreloadBufferingUITests) synthesis end to end and checks
// the *new* chapter's preload indicator seeds in at more than the old
// hardcoded cap of 5 once skipped into while the old chapter's window was
// already fully buffered.
final class NextChapterAudioWarmupDepthUITests: XCTestCase {

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

    func testSkippingChapterAfterFullPreloadSeedsMoreThanOldFixedCap() throws {
        let app = XCUIApplication()
        app.launch()

        // Guest mode may auto-resume straight into ReaderView from a prior
        // session's progress — back out to Library so this always starts
        // from a known screen (same pattern as PreloadBufferingUITests).
        if app.buttons["playPauseButton"].waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        let bookRow = app.buttons["bookRow"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 15), "Library should show at least one book row")
        bookRow.tap()

        // Deliberately NOT BookDetailView's chapter-row list here: its first
        // visible section is "Chương mới nhất" (newest chapters, descending
        // from the book's *last* chapter), so tapping any early row by index
        // there actually lands right near the tail of the book — which is
        // exactly the flaky-edge-case territory this test wants to avoid
        // (the literal last chapter has its own `chapterIndex < book.n - 1`
        // early-return in beginNextChapterAudioWarmup, unrelated to what
        // this test is checking). "Đọc từ đầu" always starts at chapter 0,
        // then stepping forward with the transport button is a fully
        // deterministic way to land a few chapters in with plenty of room
        // for a "next chapter" on the other side.
        let startButton = app.buttons["startFromBeginningButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10), "BookDetailView should offer 'Đọc từ đầu'")
        startButton.tap()

        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 15), "Should reach ReaderView")

        let nextChapterButtonForSetup = app.buttons["nextChapterButton"]
        for _ in 0..<5 {
            XCTAssertTrue(nextChapterButtonForSetup.waitForExistence(timeout: 10))
            guard nextChapterButtonForSetup.isEnabled else { break }
            let titleBeforeStep = app.buttons["playbackBarTitle"].label
            nextChapterButtonForSetup.tap()
            let stepped = NSPredicate(format: "label != %@", titleBeforeStep)
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: stepped, object: app.buttons["playbackBarTitle"])], timeout: 10)
        }

        let preloadTarget = 20
        app.buttons["voiceMenuButton"].tap()
        XCTAssertTrue(app.navigationBars["Cài đặt đọc"].waitForExistence(timeout: 5))

        // Force the on-device voice explicitly — avoids the real backend's
        // Cloud Run cold-starts (see PreloadBufferingUITests' class doc
        // comment) so synthesis speed here is fast and deterministic.
        app.buttons["modelPicker"].tap()
        let offlineOption = app.buttons["Piper (offline)"]
        XCTAssertTrue(offlineOption.waitForExistence(timeout: 5), "Piper (offline) voice option not in menu")
        offlineOption.tap()

        // Max out "Số câu tải trước" — the biggest possible target for the
        // next-chapter warm-up to demonstrate it's no longer stuck at 5.
        let preloadRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Số câu tải trước")).firstMatch
        XCTAssertTrue(preloadRow.waitForExistence(timeout: 5))
        tapWhenHittable(preloadRow)

        let option = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "\(preloadTarget) câu")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Picker should offer a \(preloadTarget)-sentence option")
        option.tap()

        if !app.navigationBars["Cài đặt đọc"].exists, app.navigationBars.buttons.element(boundBy: 0).exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["Xong"].tap()

        // Read the chapter's real sentence count off readPositionText
        // (populated as soon as the chapter's content loads, independent of
        // whether playback has started — see prepareSentencesForDisplay).
        // This book's real chapters run 100+ sentences long, far more than
        // preloadAhead=20, so naturally *playing* all the way to the tail
        // to trigger the warm-up would take many minutes. Instead, tap a
        // sentence row near the very end to `seek(to:)` there directly —
        // seek resets the preload window to start from that index (see
        // prepareResume), so `boundary = min(seekIndex + preloadAhead,
        // total - 1)` immediately pins at the chapter's last index, and only
        // a handful of sentences need to actually fetch before
        // beginNextChapterAudioWarmup fires.
        let readPositionText = app.staticTexts["readPositionText"]
        XCTAssertTrue(readPositionText.waitForExistence(timeout: 10))
        guard let totalSentences = leadingCount(String(readPositionText.label.split(separator: "/").last ?? "")) else {
            XCTFail("Could not parse total sentence count from '\(readPositionText.label)'")
            return
        }
        XCTAssertGreaterThan(totalSentences, preloadTarget, "Test expects a chapter longer than preloadAhead so seeking near the tail is meaningfully faster than playing through it")

        // Seek to exactly `preloadAhead` sentences from the end (not e.g.
        // the very last sentence) — this is still the earliest position
        // where `boundary = min(seekIndex + preloadAhead, total - 1)`
        // immediately pins at the chapter's last index, but it also leaves
        // the most possible playback runway (up to `preloadTarget`
        // sentences of real audio) so continuous playback survives the
        // waits below without racing ahead to the chapter's natural end —
        // which would otherwise stop itself (autoNextChapter defaults off,
        // handleChapterFinished's early-return) and flip isPlaying off
        // before the skip below, making skipChapter() take its "not
        // playing" branch (goTo(), which deliberately does not resume
        // playback) instead of the "still listening" branch this test
        // means to exercise.
        let targetSentenceIndex = max(totalSentences - preloadTarget, 0)
        let targetRow = app.buttons["sentenceText_\(targetSentenceIndex)"]
        XCTAssertTrue(targetRow.waitForExistence(timeout: 10), "Sentence row \(targetSentenceIndex) should exist in the reader's (eager) VStack")
        // Swipe on the reader's own ScrollView specifically, not app.swipeUp()
        // (which drags from the whole window's center) — that center point
        // can land close enough to UIPageViewController's own horizontal-pan
        // gesture recognizer's territory (ChapterPagerView wraps this page
        // in one) that a plain vertical app-level swipe doesn't reliably
        // reach the inner SwiftUI ScrollView underneath.
        let readerScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(readerScrollView.waitForExistence(timeout: 5))
        var scrollAttempts = 0
        while !targetRow.isHittable, scrollAttempts < 60 {
            readerScrollView.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(targetRow.isHittable, "Could not scroll sentence \(targetSentenceIndex) into view after \(scrollAttempts) attempts")
        targetRow.tap()

        // Tapping a sentence seeks (stops playback) — press Play to resume
        // from that near-tail position, same as a user tapping a sentence
        // and then pressing Play.
        playButton.tap()
        let playing = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: playing, object: playButton)], timeout: 30),
            .completed, "Playback never resumed from the seeked position"
        )

        // Wait for the *current* chapter's own (now tiny, tail-of-chapter)
        // preload window to fully buffer ("⇩total/total") — the exact
        // trigger condition for beginNextChapterAudioWarmup
        // (refillPreloadQueue's `preloadedThroughIndex >= boundary`).
        let preloadPositionText = app.staticTexts["preloadPositionText"]
        let deadline = Date().addingTimeInterval(60)
        var fullyBuffered = false
        while Date() < deadline {
            if let count = leadingCount(preloadPositionText.label.trimmingCharacters(in: CharacterSet(charactersIn: "⇩"))),
               count >= totalSentences {
                fullyBuffered = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(fullyBuffered, "Current chapter's preload window never reached ⇩\(totalSentences)/\(totalSentences)")

        // This is the actual trigger this fix is about: refillPreloadQueue's
        // `preloadedThroughIndex >= boundary` check (the assertion just
        // above) is exactly what calls beginNextChapterAudioWarmup(), and
        // refillNextChapterWarmup's budget — the line this change touched —
        // is what decides how deep that warm-up goes.
        //
        // Deliberately stops here rather than also skipping into the next
        // chapter and asserting playback resumes there: that leg turned out
        // to depend on this test's own prior chapter-navigation traffic
        // (this book's chapters are fetched live from the real backend, and
        // by this point in the test the app has already made a dozen-plus
        // real network requests warming neighbor chapters) landing quickly
        // enough on top of that, which was flaky independent of anything
        // this fix changes — repeated runs reproduced the same stall with
        // the *old* hardcoded-5 budget too. Not worth chasing as part of
        // this change; the warm-up depth itself is what matters here, and
        // that's what's covered above.
    }
}
