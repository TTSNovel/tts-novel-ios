import XCTest

// One-off manual verification for the on-device VieNeu-TTS pipeline
// (VieNeuOfflineV2TTSService: sea-g2p -> llama.cpp GGUF backbone -> ONNX
// Runtime codec decode). Deliberately does NOT reuse
// TTSPlaybackUITests.login()/book navigation (that path needs real
// credentials in /tmp/tts_test_config.json and has a known "book row not
// hittable" flakiness, see its doc comment) — guest mode auto-resumes
// straight into ReaderView from local/synced progress when there already
// is some, which is all this needs: no network, no login, just the
// offline voice.
final class VieNeuOfflineV2UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testVieNeuOfflineV2Plays() throws {
        let app = XCUIApplication()
        app.launch()

        let playButton = app.buttons["playPauseButton"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 10), "expected guest-mode auto-resume into a chapter")

        app.buttons["voiceMenuButton"].tap()

        // modelPicker is a .menu-style Picker (a dropdown) — tapping it
        // only opens the popup list; the option itself is a separate tap
        // on the button that then appears.
        app.buttons["modelPicker"].tap()
        let option = app.buttons["VieNeu-TTS v2 (offline)"]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "vieNeuOfflineV2 voice option not in menu")
        option.tap()

        // Selecting vieNeuOfflineV2 should reveal the "Giọng đọc" preset
        // picker (ReaderSettingsSheet only shows it once the chosen model
        // actually has more than one voice) — exercise switching it too,
        // not just that it's present.
        let voicePicker = app.buttons["vieNeuOfflineV2VoicePicker"]
        XCTAssertTrue(voicePicker.waitForExistence(timeout: 5), "Giọng đọc preset picker should appear for vieNeuOfflineV2")
        voicePicker.tap()
        let presetOption = app.buttons["Xuân Vĩnh (Nam - Miền Nam)"]
        XCTAssertTrue(presetOption.waitForExistence(timeout: 5), "expected preset option not in Giọng đọc menu")
        presetOption.tap()

        // voiceMenuButton opens the full "Cài đặt đọc" sheet (ReaderSettingsSheet),
        // not a lightweight dropdown — selecting a Picker row does NOT
        // auto-dismiss it. Without this, the sheet stays on top and the
        // playButton tap below lands on whatever's underneath at that
        // screen position instead (observed: it opened the "Số câu tải
        // trước" preload-count picker, which sits roughly where the play
        // button is once the sheet covers the screen).
        app.buttons["Xong"].tap()

        playButton.tap()
        let playing = NSPredicate(format: "label CONTAINS[c] %@", "Tạm dừng")
        let expectation = XCTNSPredicateExpectation(predicate: playing, object: playButton)
        // Generous timeout: ~5-6s of CPU-bound autoregressive generation
        // per sentence (see VieNeuV2LlamaBackbone's n_gpu_layers=0 doc
        // comment — Metal offload is faster to dispatch but numerically
        // broken for this backbone, so this stays CPU-only), and
        // ReaderPlaybackController preloads up to preloadAhead (default
        // 10) sentences concurrently through the same serialized actor —
        // the sentence actually needed for playback can end up queued
        // behind several others.
        let result = XCTWaiter().wait(for: [expectation], timeout: 150)
        XCTAssertEqual(result, .completed, "vieNeuOfflineV2: play button never switched to the playing state")
    }
}
