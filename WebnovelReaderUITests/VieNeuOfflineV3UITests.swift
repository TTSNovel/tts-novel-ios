import XCTest

// One-off manual verification for the on-device VieNeu-TTS v3-Turbo pipeline
// (VieNeuOfflineV3TTSService: sea-g2p -> BPE tokenize -> ONNX backbone
// prefill/decode_step + acoustic decoder -> MOSS codec decode). Same guest-
// mode auto-resume trick as VieNeuOfflineV2UITests — see its doc comment.
final class VieNeuOfflineV3UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testVieNeuOfflineV3Plays() throws {
        let app = XCUIApplication()
        app.launch()

        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 10), "expected guest-mode auto-resume into a chapter")

        app.buttons["voiceMenuButton"].tap()
        app.buttons["modelPicker"].tap()
        let option = app.buttons["VieNeu-TTS v3 (offline)"]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "vieNeuOfflineV3 voice option not in menu")
        option.tap()

        let voicePicker = app.buttons["vieNeuOfflineV3VoicePicker"]
        XCTAssertTrue(voicePicker.waitForExistence(timeout: 5), "Giọng đọc preset picker should appear for vieNeuOfflineV3")
        voicePicker.tap()
        let presetOption = app.buttons["Đoan Trang (Nữ - Miền Bắc - Tự nhiên)"]
        XCTAssertTrue(presetOption.waitForExistence(timeout: 5), "expected preset option not in Giọng đọc menu")
        presetOption.tap()

        app.buttons["Xong"].tap()

        playButton.tap()
        let playing = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
        let expectation = XCTNSPredicateExpectation(predicate: playing, object: playButton)
        // Very generous timeout: the autoregressive acoustic loop is up to
        // 600 frames * 16 tiny ORT calls + 600 decode_step calls per
        // sentence chunk — first real on-device run, actual latency
        // unmeasured, so this errs wide rather than false-failing on a
        // slow-but-working first pass.
        let result = XCTWaiter().wait(for: [expectation], timeout: 280)
        XCTAssertEqual(result, .completed, "vieNeuOfflineV3: play button never switched to the playing state")
    }
}
