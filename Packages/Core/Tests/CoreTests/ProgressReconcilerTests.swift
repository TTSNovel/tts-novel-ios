import XCTest
@testable import Core

final class ProgressReconcilerTests: XCTestCase {
    private let me = "this-device"

    private func remote(chapter: Int, rev: Int, device: String? = "other-device") -> ReadingProgress {
        ReadingProgress(chapterIndex: chapter, updatedAt: Date(), rev: rev, deviceID: device, deviceName: "iPhone")
    }

    private func decide(
        knownRev: Int = 3, displayed: Int? = 440, remote: ReadingProgress, pending: Bool = false, playing: Bool = false
    ) -> ProgressReconciler.Decision {
        ProgressReconciler.decide(
            knownRev: knownRev, displayedChapter: displayed, remote: remote,
            hasPendingEvents: pending, isPlaying: playing, selfDeviceID: me
        )
    }

    func testNotNewerIsIgnored() {
        XCTAssertEqual(decide(knownRev: 5, remote: remote(chapter: 296, rev: 5)), .ignore)
        XCTAssertEqual(decide(knownRev: 5, remote: remote(chapter: 296, rev: 4)), .ignore)
    }

    func testOwnWriteOnlyAdvancesTheKnownRev() {
        XCTAssertEqual(decide(remote: remote(chapter: 296, rev: 4, device: me)), .acknowledge)
    }

    func testPendingEventsKeepTheDisplayedChapter() {
        XCTAssertEqual(decide(remote: remote(chapter: 296, rev: 4), pending: true), .acknowledge)
        XCTAssertEqual(decide(remote: remote(chapter: 296, rev: 4), pending: true, playing: true), .acknowledge)
    }

    func testSameChapterIsAcknowledged() {
        XCTAssertEqual(decide(remote: remote(chapter: 440, rev: 4)), .acknowledge)
        XCTAssertEqual(decide(remote: remote(chapter: 440, rev: 4), playing: true), .acknowledge)
    }

    /// Direction is not a signal — re-reading an older chapter elsewhere is
    /// followed just like reading ahead.
    func testIdleDeviceFollowsForwardAndBackward() {
        XCTAssertEqual(decide(remote: remote(chapter: 441, rev: 4)), .follow)
        XCTAssertEqual(decide(remote: remote(chapter: 296, rev: 4)), .follow)
    }

    func testNeverReadBookIsFollowed() {
        XCTAssertEqual(decide(knownRev: 0, displayed: nil, remote: remote(chapter: 10, rev: 1)), .follow)
    }

    func testListeningDeviceIsNotifiedInsteadOfMoved() {
        XCTAssertEqual(decide(remote: remote(chapter: 296, rev: 4), playing: true), .notify)
    }

    func testLegacyMigratedPositionWithoutDeviceIsFollowed() {
        XCTAssertEqual(decide(knownRev: 0, remote: remote(chapter: 296, rev: 1, device: nil)), .follow)
    }
}
