import XCTest
@testable import Core

/// In-memory stand-in for tts-webnovel's /api/progress v2 — implements the
/// contract's event rules (idempotent id, same-chapter no-op, base_rev ==
/// rev applies, otherwise 409) so ProgressStore is tested against the same
/// behaviour without ever touching the real server.
private actor FakeProgressServer: ProgressSyncing {
    private(set) var positions: [Int: ReadingProgress] = [:]
    private(set) var received: [PendingReadingEvent] = []
    /// Every POST, including ones that "failed in transit".
    private(set) var attemptedIDs: [String] = []
    private var outcomes: [String: ReadingEventOutcome] = [:]
    var failNextPosts = 0

    func setFailures(_ count: Int) { failNextPosts = count }

    /// Another device writing with an up-to-date base.
    func otherDeviceMoves(bookID: Int, to chapter: Int, device: String = "iphone-id", name: String = "iPhone") {
        let rev = (positions[bookID]?.rev ?? 0) + 1
        positions[bookID] = ReadingProgress(chapterIndex: chapter, updatedAt: Date(), rev: rev, deviceID: device, deviceName: name)
    }

    func fetchProgress() async throws -> [Int: ReadingProgress] { positions }

    func postEvent(_ event: PendingReadingEvent) async throws -> ReadingEventOutcome {
        attemptedIDs.append(event.id)
        if failNextPosts > 0 {
            failNextPosts -= 1
            throw URLError(.notConnectedToInternet)
        }
        received.append(event)
        if let stored = outcomes[event.id] { return stored }
        let current = positions[event.bookID]
        let outcome: ReadingEventOutcome
        if current?.chapterIndex == event.chapter {
            outcome = .accepted(response(event, position: current!, applied: false, conflict: false))
        } else if event.baseRev == current?.rev ?? 0 {
            let position = ReadingProgress(
                chapterIndex: event.chapter, updatedAt: Date(), rev: (current?.rev ?? 0) + 1,
                deviceID: "mac-id", deviceName: "Mac"
            )
            positions[event.bookID] = position
            outcome = .accepted(response(event, position: position, applied: true, conflict: false))
        } else {
            outcome = .conflict(response(event, position: current!, applied: false, conflict: true))
        }
        outcomes[event.id] = outcome
        return outcome
    }

    func fetchHistory(bookID: Int) async throws -> ReadingHistory {
        ReadingHistory(position: positions[bookID], events: [])
    }

    private func response(_ event: PendingReadingEvent, position: ReadingProgress, applied: Bool, conflict: Bool) -> ReadingEventResponse {
        ReadingEventResponse(position: position, event: ReadingHistoryEvent(
            id: event.id, bookID: event.bookID, chapter: event.chapter, kind: event.kind, baseRev: event.baseRev,
            deviceID: "mac-id", deviceName: "Mac", serverTS: Date(), applied: applied, conflict: conflict, rev: position.rev
        ))
    }
}

@MainActor
final class ProgressStoreTests: XCTestCase {
    private var directory: URL!
    private var server: FakeProgressServer!
    private var loggedIn = true

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProgressStoreTests-\(UUID().uuidString)")
        server = FakeProgressServer()
        loggedIn = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ProgressStore {
        ProgressStore(
            sync: server, directory: directory, deviceID: "mac-id", deviceName: "Mac",
            canSync: { [unowned self] in loggedIn }, recordEvent: { _, _ in }
        )
    }

    func testSelectIsAppliedAndBecomesTheKnownPosition() async {
        await server.otherDeviceMoves(bookID: 1, to: 10)
        let store = makeStore()
        await store.refreshFromServer()
        store.record(bookID: 1, chapterIndex: 11, kind: .select)
        await store.flush()

        let position = await server.positions[1]
        XCTAssertEqual(position?.chapterIndex, 11)
        XCTAssertEqual(position?.rev, 2)
        XCTAssertEqual(store.localProgress(bookID: 1)?.rev, 2)
        XCTAssertTrue(store.conflicts.isEmpty)
    }

    func testRecordingTheDisplayedChapterSendsNothing() async {
        await server.otherDeviceMoves(bookID: 1, to: 10)
        let store = makeStore()
        await store.refreshFromServer()
        store.record(bookID: 1, chapterIndex: 10, kind: .select)
        store.record(bookID: 1, chapterIndex: 10, kind: .autoNext)
        await store.flush()
        let received = await server.received
        XCTAssertTrue(received.isEmpty)
    }

    func testRestoreIsSentEvenForTheDisplayedChapter() async {
        let store = makeStore()
        store.record(bookID: 1, chapterIndex: 5, kind: .select)
        await store.flush()
        store.record(bookID: 1, chapterIndex: 5, kind: .restore)
        await store.flush()
        let kinds = await server.received.map(\.kind)
        XCTAssertEqual(kinds, [.select, .restore])
    }

    /// The 2026-11-03 incident from the stale writer's side: this device
    /// last saw chapter 297, another one has since moved to 441. Its write
    /// must be rejected, the server keep 441, and the user be asked.
    func testStaleWriteIsRejectedAndSurfacedAsConflict() async {
        await server.otherDeviceMoves(bookID: 1, to: 296)
        let store = makeStore()
        await store.refreshFromServer()
        await server.otherDeviceMoves(bookID: 1, to: 440)

        store.record(bookID: 1, chapterIndex: 297, kind: .autoNext)
        await store.flush()

        let position = await server.positions[1]
        XCTAssertEqual(position?.chapterIndex, 440)
        XCTAssertEqual(store.localProgress(bookID: 1)?.chapterIndex, 297, "displayed chapter is kept")
        XCTAssertEqual(store.conflicts[1], ProgressConflict(bookID: 1, attemptedChapter: 297, kind: .autoNext, server: position!))

        // "Đọc chương 298 ở đây": re-sent with the base the 409 revealed.
        store.keepLocal(bookID: 1)
        await store.flush()
        let after = await server.positions[1]
        XCTAssertEqual(after?.chapterIndex, 297)
        XCTAssertEqual(after?.rev, 3)
        XCTAssertTrue(store.conflicts.isEmpty)
        let lastKind = await server.received.last?.kind
        XCTAssertEqual(lastKind, .restore)
    }

    func testAdoptServerMovesWithoutWriting() async {
        await server.otherDeviceMoves(bookID: 1, to: 296)
        let store = makeStore()
        await store.refreshFromServer()
        await server.otherDeviceMoves(bookID: 1, to: 440)
        store.record(bookID: 1, chapterIndex: 297, kind: .select)
        await store.flush()
        let sentBefore = await server.received.count

        XCTAssertEqual(store.adoptServer(bookID: 1), 440)
        XCTAssertEqual(store.localProgress(bookID: 1)?.chapterIndex, 440)
        XCTAssertTrue(store.conflicts.isEmpty)
        // Navigating there afterwards is a no-op record.
        store.record(bookID: 1, chapterIndex: 440, kind: .select)
        await store.flush()
        let sentAfter = await server.received.count
        XCTAssertEqual(sentBefore, sentAfter)
    }

    /// Re-reading an older chapter with an up-to-date base is legitimate.
    func testGoingBackWithCurrentBaseIsApplied() async {
        await server.otherDeviceMoves(bookID: 1, to: 440)
        let store = makeStore()
        await store.refreshFromServer()
        store.record(bookID: 1, chapterIndex: 296, kind: .select)
        await store.flush()
        let position = await server.positions[1]
        XCTAssertEqual(position?.chapterIndex, 296)
        XCTAssertTrue(store.conflicts.isEmpty)
    }

    func testOutboxRetriesWithTheSameIDAfterNetworkFailure() async {
        let store = makeStore()
        await server.setFailures(100)
        store.record(bookID: 1, chapterIndex: 3, kind: .select)
        await store.flush()
        var position = await server.positions[1]
        XCTAssertNil(position)

        await server.setFailures(0)
        await store.flush()
        position = await server.positions[1]
        XCTAssertEqual(position?.chapterIndex, 3)
        let ids = await server.attemptedIDs
        XCTAssertGreaterThan(ids.count, 1)
        XCTAssertEqual(Set(ids).count, 1)
    }

    /// Several chapters changed while offline: each later event was decided
    /// on top of the earlier one, so they must all apply, in order.
    func testQueuedEventsOfOneBookAreRebasedAfterEachOther() async {
        let store = makeStore()
        await server.setFailures(10)
        store.record(bookID: 1, chapterIndex: 5, kind: .select)
        store.record(bookID: 1, chapterIndex: 6, kind: .autoNext)
        store.record(bookID: 1, chapterIndex: 7, kind: .autoNext)
        await store.flush()
        await server.setFailures(0)
        await store.flush()

        let position = await server.positions[1]
        XCTAssertEqual(position?.chapterIndex, 7)
        XCTAssertEqual(position?.rev, 3)
        XCTAssertTrue(store.conflicts.isEmpty)
    }

    func testOutboxSurvivesRelaunch() async {
        let store = makeStore()
        await server.setFailures(100)
        store.record(bookID: 1, chapterIndex: 3, kind: .select)
        await store.flush()
        await server.setFailures(0)

        let relaunched = makeStore()
        await relaunched.flush()
        let position = await server.positions[1]
        XCTAssertEqual(position?.chapterIndex, 3)
        XCTAssertEqual(relaunched.localProgress(bookID: 1)?.chapterIndex, 3)
    }

    func testGuestRecordsLocallyOnly() async {
        loggedIn = false
        let store = makeStore()
        store.record(bookID: 1, chapterIndex: 3, kind: .select)
        await store.flush()
        let received = await server.received
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(store.localProgress(bookID: 1)?.chapterIndex, 3)
    }

    func testIdleRefreshFollowsAnotherDeviceBackward() async {
        await server.otherDeviceMoves(bookID: 1, to: 440)
        let store = makeStore()
        await store.refreshFromServer()
        await server.otherDeviceMoves(bookID: 1, to: 296)
        let changed = await store.refreshFromServer()
        XCTAssertEqual(changed, [1: 296])
        XCTAssertEqual(store.localProgress(bookID: 1)?.chapterIndex, 296)
    }

    /// Listening here while another device moves: no jump, a notice — and
    /// the base rev stays old, so the next auto-next is asked about (409)
    /// instead of silently overwriting the other device.
    func testPlayingBookGetsANoticeAndNextAutoNextConflicts() async {
        await server.otherDeviceMoves(bookID: 1, to: 100)
        let store = makeStore()
        await store.refreshFromServer()
        store.playingBookID = 1
        await server.otherDeviceMoves(bookID: 1, to: 300)

        let changed = await store.refreshFromServer()
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(store.localProgress(bookID: 1)?.chapterIndex, 100)
        XCTAssertEqual(store.remoteNotices[1]?.server.chapterIndex, 300)

        store.record(bookID: 1, chapterIndex: 101, kind: .autoNext)
        await store.flush()
        let position = await server.positions[1]
        XCTAssertEqual(position?.chapterIndex, 300)
        XCTAssertEqual(store.conflicts[1]?.attemptedChapter, 101)
        XCTAssertNil(store.remoteNotices[1])

        // Auto-next keeps playing on while the conflict is unanswered, but
        // doesn't override the other device behind the user's back.
        store.record(bookID: 1, chapterIndex: 102, kind: .autoNext)
        await store.flush()
        let stillServer = await server.positions[1]
        XCTAssertEqual(stillServer?.chapterIndex, 300)
        XCTAssertEqual(store.conflicts[1]?.attemptedChapter, 102)
    }

    func testDismissedNoticeDoesNotComeBackForTheSameRev() async {
        await server.otherDeviceMoves(bookID: 1, to: 100)
        let store = makeStore()
        await store.refreshFromServer()
        store.playingBookID = 1
        await server.otherDeviceMoves(bookID: 1, to: 300)
        await store.refreshFromServer()
        store.dismissNotice(bookID: 1)
        await store.refreshFromServer()
        XCTAssertNil(store.remoteNotices[1])
    }

    func testOldProgressFileWithoutRevStillLoads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"7": {"chapter": 12, "updated_at": "2026-11-01T10:00:00.123Z"}}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("progress.json"))
        try Data("[7]".utf8).write(to: directory.appendingPathComponent("progress-unsynced.json"))

        let store = makeStore()
        XCTAssertEqual(store.localProgress(bookID: 7)?.chapterIndex, 12)
        XCTAssertEqual(store.localProgress(bookID: 7)?.rev, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("progress-unsynced.json").path))
    }

    func testPositionDecodesDeviceAndRev() throws {
        let json = #"{"chapter": 440, "sentence": 0, "updated_at": "2026-11-03T11:19:21.5Z", "rev": 9, "device_id": "abc", "device_name": "iPhone"}"#
        let position = try JSONDecoder.readingProgress.decode(ReadingProgress.self, from: Data(json.utf8))
        XCTAssertEqual(position.rev, 9)
        XCTAssertEqual(position.deviceID, "abc")
        XCTAssertEqual(position.deviceName, "iPhone")
    }

    func testEventBodyMatchesTheContract() throws {
        let event = PendingReadingEvent(id: "e1", bookID: 3, chapter: 4, kind: .autoNext, baseRev: 2, clientTS: Date(timeIntervalSince1970: 0))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.readingProgress.encode(event)) as? [String: Any]
        XCTAssertEqual(object?["id"] as? String, "e1")
        XCTAssertEqual(object?["book_id"] as? Int, 3)
        XCTAssertEqual(object?["chapter"] as? Int, 4)
        XCTAssertEqual(object?["kind"] as? String, "auto_next")
        XCTAssertEqual(object?["base_rev"] as? Int, 2)
        XCTAssertEqual(object?["client_ts"] as? String, "1970-01-01T00:00:00.000Z")
    }
}
