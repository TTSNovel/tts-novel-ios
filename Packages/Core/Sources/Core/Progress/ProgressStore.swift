import Foundation

// Local-first reading-history tracker, same shape as DownloadManager:
// persists to Application Support so it survives relaunches.
//
// History is per chapter and event based (reading history v2, see
// docs/reading-history-sync.md): only a deliberate chapter change — picking
// one, auto-next, or an explicit restore — becomes an event for the
// server. Resuming at the saved chapter, pausing, backgrounding or
// following another device never writes anything. Each event carries the
// server rev this device knew (`base_rev`); the server applies it only if
// that's still the current rev, so a device that hasn't seen the latest
// position can't silently overwrite it (2026-11-03: a stale web tab on
// chapter 297 replaced 441 on every device). A rejected write comes back
// as a `ProgressConflict` for the user to settle on the device they're
// holding.
//
// Two views per book:
// - `progress`: the chapter this device shows (Library rows, "Đọc tiếp",
//   where the reader resumes). Moves immediately on a local action.
// - `serverProgress`: the last server position this device accepted — its
//   `rev` is the base of the next write.
@MainActor
public final class ProgressStore: ObservableObject {
    public static let shared = ProgressStore(
        sync: APIProgressSync(baseURL: SessionStore.baseURL),
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        deviceID: DeviceIdentity.id,
        deviceName: DeviceIdentity.name,
        // Guest (no login) can't write progress — /api/progress stays
        // behind auth (see tts-webnovel's server.py) even though book
        // browsing/reading itself is public.
        canSync: { SessionStore.shared.isLoggedIn },
        recordEvent: { EventLogStore.shared.record(.navigation, $0, detail: $1) }
    )

    /// The chapter shown on this device, per book.
    @Published public private(set) var progress: [Int: ReadingProgress] = [:]
    /// Writes the server rejected as stale, per book, waiting for the user
    /// (ReaderView's banner). Only the newest one per book is kept.
    @Published public private(set) var conflicts: [Int: ProgressConflict] = [:]
    /// Another device moved a book this device is listening to right now —
    /// shown instead of jumping (see ProgressReconciler.Decision.notify).
    @Published public private(set) var remoteNotices: [Int: RemoteProgressNotice] = [:]
    /// The book this device is actively listening to (playing, or between
    /// chapters during auto-next), set by the playback controller. A remote
    /// change to that book never moves it or advances its base rev.
    public var playingBookID: Int?

    private var serverProgress: [Int: ReadingProgress]
    /// Events not yet answered by the server, oldest first — replaces the
    /// old per-book `unsynced` flag. Sent strictly in order and retried
    /// with the same `id` after a network failure.
    private var outbox: [PendingReadingEvent]
    /// Highest notice rev the user dismissed per book, so the next refresh
    /// doesn't bring the same notice back.
    private var dismissedNoticeRevs: [Int: Int] = [:]
    private var isFlushing = false
    private var flushRequested = false

    private let sync: ProgressSyncing
    private let directory: URL
    private let deviceID: String
    private let deviceName: String
    private let canSync: @MainActor () -> Bool
    private let recordEvent: @MainActor (String, String?) -> Void

    init(
        sync: ProgressSyncing, directory: URL, deviceID: String, deviceName: String,
        canSync: @escaping @MainActor () -> Bool, recordEvent: @escaping @MainActor (String, String?) -> Void
    ) {
        self.sync = sync
        self.directory = directory
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.canSync = canSync
        self.recordEvent = recordEvent
        progress = StoredJSON.load([Int: ReadingProgress].self, from: directory.appendingPathComponent("progress.json"), decoder: .readingProgress) ?? [:]
        serverProgress = StoredJSON.load([Int: ReadingProgress].self, from: directory.appendingPathComponent("progress-server.json"), decoder: .readingProgress) ?? [:]
        outbox = StoredJSON.load([PendingReadingEvent].self, from: directory.appendingPathComponent("progress-outbox.json"), decoder: .readingProgress) ?? []
        // Pre-v2 builds kept a set of "changed but not pushed" books. Those
        // pushes have no base rev to send now; the first refresh after the
        // update brings the server position in instead.
        StoredJSON.remove(directory.appendingPathComponent("progress-unsynced.json"))
    }

    public func localProgress(bookID: Int) -> ReadingProgress? {
        progress[bookID]
    }

    public func mostRecentlyRead() -> (bookID: Int, progress: ReadingProgress)? {
        progress.max { $0.value.updatedAt < $1.value.updatedAt }
            .map { (bookID: $0.key, progress: $0.value) }
    }

    /// Every book with saved progress, most-recently-updated first — backs
    /// both the Library's "Đọc gần đây" preview (capped) and the full
    /// History screen (uncapped). `limit: nil` returns everything.
    public func recentEntries(limit: Int? = nil) -> [(bookID: Int, progress: ReadingProgress)] {
        let sorted = progress.sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map { (bookID: $0.key, progress: $0.value) }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    /// A deliberate chapter change on this device. Moving to the chapter
    /// already shown is a no-op (that's a resume, not a choice) — except
    /// `.restore`, which is an explicit resolution and is always sent.
    public func record(bookID: Int, chapterIndex: Int, kind: ReadingEventKind) {
        if kind != .restore, progress[bookID]?.chapterIndex == chapterIndex { return }
        progress[bookID] = ReadingProgress(
            chapterIndex: chapterIndex, updatedAt: Date(), rev: serverProgress[bookID]?.rev ?? 0,
            deviceID: deviceID, deviceName: deviceName
        )
        defer { persist() }
        guard canSync() else { return }
        // Auto-next while a conflict is still unanswered stays local: the
        // 409 already told this device about the other one's position, so
        // the next write would be accepted — but nobody chose to override
        // it, the playlist just moved on. The banner keeps offering "read
        // it here" with the chapter actually playing.
        if kind == .autoNext, var conflict = conflicts[bookID] {
            conflict.attemptedChapter = chapterIndex
            conflicts[bookID] = conflict
            return
        }
        // Any other action is the user choosing with the conflict in view.
        conflicts[bookID] = nil
        outbox.append(PendingReadingEvent(bookID: bookID, chapter: chapterIndex, kind: kind, baseRev: serverProgress[bookID]?.rev ?? 0))
        Task { await flush() }
    }

    /// "Đọc chương M ở đây" — send this device's chapter again, now based on
    /// the server position the conflict revealed, so it's applied.
    public func keepLocal(bookID: Int) {
        guard let chapterIndex = progress[bookID]?.chapterIndex else { return }
        let server = conflicts[bookID]?.server
        conflicts[bookID] = nil
        recordEvent("Kept this device's chapter over another device's", "chapter \(chapterIndex + 1) over \(server.map { "\($0.chapterIndex + 1) (\($0.deviceName ?? "?"), rev \($0.rev))" } ?? "?")")
        record(bookID: bookID, chapterIndex: chapterIndex, kind: .restore)
    }

    /// "Chuyển tới chương N" — show the server's chapter here without
    /// writing anything (it already is the position). Drops this book's
    /// unsent events: the user just chose the other device's chapter over
    /// them. Returns the chapter to navigate to.
    @discardableResult
    public func adoptServer(bookID: Int) -> Int? {
        let candidates = [remoteNotices[bookID]?.server, conflicts[bookID]?.server, serverProgress[bookID]].compactMap { $0 }
        guard let server = candidates.max(by: { $0.rev < $1.rev }) else { return nil }
        serverProgress[bookID] = server
        progress[bookID] = server
        outbox.removeAll { $0.bookID == bookID }
        conflicts[bookID] = nil
        remoteNotices[bookID] = nil
        recordEvent("Moved to another device's chapter", "chapter \(server.chapterIndex + 1) from \(server.deviceName ?? "?"), rev \(server.rev)")
        persist()
        return server.chapterIndex
    }

    /// Hides a remote notice without acting on it. The base rev stays old,
    /// so this device's next write still gets asked about (409).
    public func dismissNotice(bookID: Int) {
        guard let notice = remoteNotices[bookID] else { return }
        dismissedNoticeRevs[bookID] = notice.server.rev
        remoteNotices[bookID] = nil
    }

    /// Sends queued events in order. Stops at the first network/server
    /// failure (retried on the next record/refresh/milestone with the same
    /// event ids); a 409 is an answer, not a failure — see handleConflict.
    public func flush() async {
        guard canSync() else { return }
        guard !isFlushing else {
            flushRequested = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushRequested = false
            while let event = outbox.first {
                let outcome: ReadingEventOutcome
                do {
                    outcome = try await sync.postEvent(event)
                } catch APIError.httpStatus(400) {
                    // A body the server will never accept — retrying would
                    // block every later event behind it.
                    Log.error(.sync, "Reading event rejected as invalid, dropped", error: APIError.httpStatus(400), ["book": "\(event.bookID)", "chapter": "\(event.chapter)", "id": event.id])
                    outbox.removeAll { $0.id == event.id }
                    persist()
                    continue
                } catch {
                    // Offline or server hiccup — the event stays queued.
                    Log.notice(.sync, "Reading event not sent, will retry", ["book": "\(event.bookID)", "chapter": "\(event.chapter)", "error": ErrorInfo(error).summary])
                    return
                }
                // adoptServer may have dropped it while the request was in
                // flight; the server's answer still tells us its position.
                guard outbox.contains(where: { $0.id == event.id }) else {
                    let position = outcome.response.position
                    if position.rev > serverProgress[event.bookID]?.rev ?? 0 { serverProgress[event.bookID] = position }
                    persist()
                    continue
                }
                outbox.removeAll { $0.id == event.id }
                switch outcome {
                case .accepted(let response): handleAccepted(event, response)
                case .conflict(let response): handleConflict(event, response)
                }
                persist()
            }
        } while flushRequested
    }

    private func handleAccepted(_ event: PendingReadingEvent, _ response: ReadingEventResponse) {
        let bookID = event.bookID
        let position = response.position
        if position.rev >= serverProgress[bookID]?.rev ?? 0 { serverProgress[bookID] = position }
        if response.event.applied {
            // Later events of this book were decided on top of this one, so
            // they know the position it just created.
            for index in outbox.indices where outbox[index].bookID == bookID && outbox[index].baseRev == event.baseRev {
                outbox[index].baseRev = position.rev
            }
            if let notice = remoteNotices[bookID], notice.server.rev <= position.rev { remoteNotices[bookID] = nil }
        }
        // Nothing else queued and the server agrees: take its copy, so the
        // timestamp comes from the server clock like everyone else's.
        if !outbox.contains(where: { $0.bookID == bookID }), progress[bookID]?.chapterIndex == position.chapterIndex {
            progress[bookID] = position
        }
        Log.info(.sync, "Reading event accepted", [
            "book": "\(bookID)", "chapter": "\(event.chapter)", "kind": event.kind.rawValue,
            "applied": "\(response.event.applied)", "rev": "\(position.rev)",
        ])
    }

    /// 409: another device moved the book after this one last looked. The
    /// position stays the other device's; this device keeps showing its own
    /// chapter (audio isn't interrupted) and the user is asked. Accepting
    /// the server position as known is what lets "read it here" succeed.
    private func handleConflict(_ event: PendingReadingEvent, _ response: ReadingEventResponse) {
        let bookID = event.bookID
        let server = response.position
        serverProgress[bookID] = server
        // Queued events of this book were based on the rejected one — they
        // would be rejected too. The banner offers the latest chapter.
        let dropped = outbox.filter { $0.bookID == bookID }
        outbox.removeAll { $0.bookID == bookID }
        remoteNotices[bookID] = nil
        let attempted = progress[bookID]?.chapterIndex ?? event.chapter
        let context = [
            "book": "\(bookID)", "attempted": "\(attempted)", "kind": (dropped.last ?? event).kind.rawValue,
            "baseRev": "\(event.baseRev)", "serverChapter": "\(server.chapterIndex)", "serverRev": "\(server.rev)",
            "serverDevice": server.deviceName ?? "?",
        ]
        guard attempted != server.chapterIndex else {
            // A later local move already landed where the server is.
            progress[bookID] = server
            Log.info(.sync, "Reading event rejected, but this device already shows the server's chapter", context)
            return
        }
        conflicts[bookID] = ProgressConflict(bookID: bookID, attemptedChapter: attempted, kind: (dropped.last ?? event).kind, server: server)
        Log.notice(.sync, "Reading event rejected as stale", context)
        recordEvent(
            "Chapter change conflicts with another device",
            "chapter \(attempted + 1) here vs \(server.chapterIndex + 1) on \(server.deviceName ?? "?") (rev \(server.rev), base \(event.baseRev))"
        )
    }

    /// Pulls every book's server position and reconciles it (see
    /// ProgressReconciler) — this is what brings in progress made on
    /// another device sharing the same login.
    ///
    /// Returns the books whose displayed chapter changed (book ID → the
    /// remote chapter), so an idle reader can follow along — forward or
    /// back.
    @discardableResult
    public func refreshFromServer() async -> [Int: Int] {
        guard let remote = try? await sync.fetchProgress() else { return [:] } // nolog: APIClient logs the failed request
        var changedChapters: [Int: Int] = [:]
        for (bookID, position) in remote {
            if let chapter = reconcile(bookID: bookID, remote: position) { changedChapters[bookID] = chapter }
        }
        persist()
        // Anything still queued (offline earlier) goes out now, based on
        // what it was decided on — a stale one gets asked about.
        Task { await flush() }
        return changedChapters
    }

    /// One book's event timeline, newest first. Its position is reconciled
    /// like a refresh, so restoring from the timeline is based on what the
    /// user is looking at.
    public func fetchHistory(bookID: Int) async throws -> ReadingHistory {
        let history = try await sync.fetchHistory(bookID: bookID)
        if let position = history.position {
            _ = reconcile(bookID: bookID, remote: position)
            persist()
        }
        return history
    }

    /// Returns the new displayed chapter when it changed.
    private func reconcile(bookID: Int, remote: ReadingProgress) -> Int? {
        let decision = ProgressReconciler.decide(
            knownRev: serverProgress[bookID]?.rev ?? 0, displayedChapter: progress[bookID]?.chapterIndex, remote: remote,
            hasPendingEvents: outbox.contains { $0.bookID == bookID }, isPlaying: playingBookID == bookID, selfDeviceID: deviceID
        )
        let detail = "book \(bookID): chapter \(remote.chapterIndex + 1) from \(remote.deviceName ?? "?"), rev \(remote.rev)"
        switch decision {
        case .ignore:
            return nil
        case .acknowledge:
            serverProgress[bookID] = remote
            let hasPending = outbox.contains { $0.bookID == bookID }
            if progress[bookID] == nil || (!hasPending && progress[bookID]?.chapterIndex == remote.chapterIndex) {
                progress[bookID] = remote
            }
            Log.debug(.sync, "Remote chapter acknowledged", ["book": "\(bookID)", "chapter": "\(remote.chapterIndex)", "rev": "\(remote.rev)", "device": remote.deviceName ?? "?"])
            return nil
        case .follow:
            serverProgress[bookID] = remote
            progress[bookID] = remote
            conflicts[bookID] = nil
            remoteNotices[bookID] = nil
            Log.info(.sync, "Remote chapter followed", ["book": "\(bookID)", "chapter": "\(remote.chapterIndex)", "rev": "\(remote.rev)", "device": remote.deviceName ?? "?"])
            recordEvent("Remote chapter followed", detail)
            return remote.chapterIndex
        case .notify:
            guard remote.rev > dismissedNoticeRevs[bookID] ?? 0, remoteNotices[bookID]?.server != remote else { return nil }
            remoteNotices[bookID] = RemoteProgressNotice(bookID: bookID, server: remote)
            Log.info(.sync, "Remote chapter not followed while playing", ["book": "\(bookID)", "chapter": "\(remote.chapterIndex)", "rev": "\(remote.rev)", "device": remote.deviceName ?? "?"])
            recordEvent("Remote chapter not followed while playing", detail)
            return nil
        }
    }

    private func persist() {
        StoredJSON.save(progress, to: directory.appendingPathComponent("progress.json"), encoder: .readingProgress)
        StoredJSON.save(serverProgress, to: directory.appendingPathComponent("progress-server.json"), encoder: .readingProgress)
        StoredJSON.save(outbox, to: directory.appendingPathComponent("progress-outbox.json"), encoder: .readingProgress)
    }
}

/// A write of this device the server rejected because another device moved
/// the book first (409) — the reader shows it as a banner.
public struct ProgressConflict: Equatable, Sendable, Identifiable {
    public let bookID: Int
    /// The chapter this device shows (and would keep with "read it here").
    public var attemptedChapter: Int
    public let kind: ReadingEventKind
    /// The position as the server has it — the other device's chapter.
    public let server: ReadingProgress

    public var id: Int { bookID }

    public init(bookID: Int, attemptedChapter: Int, kind: ReadingEventKind, server: ReadingProgress) {
        self.bookID = bookID
        self.attemptedChapter = attemptedChapter
        self.kind = kind
        self.server = server
    }
}

/// Another device moved a book while this one is listening to it.
public struct RemoteProgressNotice: Equatable, Sendable, Identifiable {
    public let bookID: Int
    public let server: ReadingProgress

    public var id: Int { bookID }

    public init(bookID: Int, server: ReadingProgress) {
        self.bookID = bookID
        self.server = server
    }
}

/// ProgressStore's network seam — the live one is APIProgressSync; unit
/// tests inject a fake so they never touch the real server.
public protocol ProgressSyncing: Sendable {
    func fetchProgress() async throws -> [Int: ReadingProgress]
    func postEvent(_ event: PendingReadingEvent) async throws -> ReadingEventOutcome
    func fetchHistory(bookID: Int) async throws -> ReadingHistory
}

struct APIProgressSync: ProgressSyncing {
    let baseURL: URL

    func fetchProgress() async throws -> [Int: ReadingProgress] {
        try await APIClient.shared.fetchProgress(baseURL: baseURL)
    }

    func postEvent(_ event: PendingReadingEvent) async throws -> ReadingEventOutcome {
        try await APIClient.shared.postProgressEvent(baseURL: baseURL, event: event)
    }

    func fetchHistory(bookID: Int) async throws -> ReadingHistory {
        try await APIClient.shared.fetchProgressHistory(baseURL: baseURL, bookID: bookID)
    }
}

extension ReadingEventOutcome {
    var response: ReadingEventResponse {
        switch self {
        case .accepted(let response), .conflict(let response): return response
        }
    }
}
