import XCTest
import Core
@testable import WebnovelReader

/// The audio pre-download job's per-chapter state machine as it's saved to
/// and read back from `job.json` — what lets a job killed with the app
/// carry on where it stopped.
final class AudioPredownloadJobTests: XCTestCase {
    private let voice = PrerenderVoice(voice: .piperVi, vieNeuOfflineV2Voice: .bichNgoc, vieNeuOfflineV3Voice: .minhDuc, gwenTTSSpeaker: .yenNhi)

    private func makeJob() -> PredownloadJob {
        let failure = PredownloadChapterFailure(
            step: .synthesizing, reason: "The request timed out.", attempts: 3,
            sentenceIndex: 12, sentenceText: "Câu thứ mười ba."
        )
        var job = PredownloadJob(
            bookID: 40, bookTitle: "Gatsby", voice: voice, chapters: [0, 1, 2, 3, 4],
            states: [0: .done, 1: .failed(failure), 2: .synthesizing, 3: .pending],
            wantsToRun: true, stopReason: nil
        )
        job.isRunning = true
        job.stepDone = 5
        job.stepTotal = 10
        return job
    }

    func testDerivedProgress() {
        let job = makeJob()
        XCTAssertEqual(job.completed, 1)
        XCTAssertEqual(job.failedChapters, [1])
        XCTAssertEqual(job.currentChapter, 2)
        XCTAssertEqual(job.state(4), .pending, "A chapter without a state is pending")
        XCTAssertFalse(job.isFinished)
        XCTAssertEqual(job.progressValue, 1.5, accuracy: 0.001, "1 done + half of the synthesizing chapter")
    }

    func testRoundTripKeepsStatesAndFailureDetails() throws {
        let data = try JSONEncoder().encode(makeJob())
        let loaded = try JSONDecoder().decode(PredownloadJob.self, from: data)

        XCTAssertEqual(loaded.state(0), .done)
        let failure = try XCTUnwrap(loaded.state(1).failure)
        XCTAssertEqual(failure.step, .synthesizing)
        XCTAssertEqual(failure.reason, "The request timed out.")
        XCTAssertEqual(failure.attempts, 3)
        XCTAssertEqual(failure.sentenceIndex, 12)
        XCTAssertEqual(failure.sentenceText, "Câu thứ mười ba.")
        XCTAssertTrue(loaded.wantsToRun, "An interrupted job is still meant to run")
        XCTAssertEqual(loaded.voice, voice)
        // Runtime-only fields don't survive a relaunch.
        XCTAssertFalse(loaded.isRunning)
        XCTAssertEqual(loaded.stepDone, 0)
        XCTAssertEqual(loaded.stepTotal, 0)
    }

    func testRelaunchRestartsTheChapterThatWasInFlight() throws {
        let data = try JSONEncoder().encode(makeJob())
        var loaded = try JSONDecoder().decode(PredownloadJob.self, from: data)
        loaded.resetActiveChapters()

        XCTAssertEqual(loaded.state(2), .pending, "Its in-memory clips are gone — it starts over")
        XCTAssertNil(loaded.currentChapter)
        XCTAssertEqual(loaded.state(0), .done, "Finished chapters stay done")
        XCTAssertNotNil(loaded.state(1).failure, "Failed chapters wait for Thử lại")
    }

    func testFinishedWithFailures() {
        var job = makeJob()
        job.states[2] = .done
        job.states[3] = .done
        job.states[4] = .done
        XCTAssertTrue(job.isFinished, "A failed chapter doesn't keep the job open")
        XCTAssertEqual(job.failedChapters, [1])
    }
}
