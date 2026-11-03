import Foundation

// Reading history v2 (tts-webnovel's /api/progress/events and
// /api/progress/<id>/history): every deliberate chapter change is an
// append-only event on the server, so a position can always be restored,
// and a write made without knowing the latest position is rejected (409)
// instead of silently winning. See docs/reading-history-sync.md.

/// Why a book's chapter changed. Only these create events — resuming at the
/// saved chapter, pausing, backgrounding or following another device never
/// do. `legacy` is server-side only: a POST from a build that predates
/// events.
public enum ReadingEventKind: String, Codable, Sendable {
    /// The user picked a chapter (list, prev/next, swipe, remote skip).
    case select
    /// A chapter finished playing and auto-next moved on.
    case autoNext = "auto_next"
    /// An explicit resolution — "read it here" after a conflict, or picking
    /// a row in the book's history. Always sent, even for the chapter this
    /// device already shows.
    case restore
    case legacy
}

/// One queued write — persisted in ProgressStore's outbox until the server
/// answers, and re-sent with the same `id` after a network failure so the
/// server can recognise a retry (it returns the stored outcome instead of
/// writing twice). Also the exact `POST /api/progress/events` body.
public struct PendingReadingEvent: Codable, Equatable, Sendable {
    public let id: String
    public let bookID: Int
    public let chapter: Int
    public let kind: ReadingEventKind
    /// The server revision this device knew when the user acted. Fixed at
    /// enqueue time — except when an earlier queued event of the same book
    /// is applied first, see ProgressStore.flush.
    public var baseRev: Int
    public let clientTS: Date

    public init(id: String = UUID().uuidString.lowercased(), bookID: Int, chapter: Int, kind: ReadingEventKind, baseRev: Int, clientTS: Date = Date()) {
        self.id = id
        self.bookID = bookID
        self.chapter = chapter
        self.kind = kind
        self.baseRev = baseRev
        self.clientTS = clientTS
    }

    enum CodingKeys: String, CodingKey {
        case id, chapter, kind
        case bookID = "book_id"
        case baseRev = "base_rev"
        case clientTS = "client_ts"
    }
}

/// A stored event as the server returns it (history rows, and the `event`
/// half of a POST response).
public struct ReadingHistoryEvent: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let bookID: Int
    public let chapter: Int
    public let prevChapter: Int?
    /// Raw kind string — an unknown future kind still decodes (and shows)
    /// instead of failing the whole history list.
    public let kindRaw: String
    public let baseRev: Int?
    public let deviceID: String?
    public let deviceName: String?
    public let serverTS: Date
    /// False when the event didn't move the position: either it was already
    /// there (no-op) or it was rejected as stale (`conflict`).
    public let applied: Bool
    public let conflict: Bool
    /// The position's rev after this event was processed.
    public let rev: Int

    public var kind: ReadingEventKind? { ReadingEventKind(rawValue: kindRaw) }

    public init(
        id: String, bookID: Int, chapter: Int, prevChapter: Int? = nil, kind: ReadingEventKind, baseRev: Int?,
        deviceID: String?, deviceName: String?, serverTS: Date, applied: Bool, conflict: Bool, rev: Int
    ) {
        self.id = id
        self.bookID = bookID
        self.chapter = chapter
        self.prevChapter = prevChapter
        self.kindRaw = kind.rawValue
        self.baseRev = baseRev
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.serverTS = serverTS
        self.applied = applied
        self.conflict = conflict
        self.rev = rev
    }

    enum CodingKeys: String, CodingKey {
        case id, chapter, applied, conflict, rev
        case bookID = "book_id"
        case prevChapter = "prev_chapter"
        case kindRaw = "kind"
        case baseRev = "base_rev"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case serverTS = "server_ts"
    }
}

/// `POST /api/progress/events` reply, for both 200 and 409.
public struct ReadingEventResponse: Decodable, Equatable, Sendable {
    public let position: ReadingProgress
    public let event: ReadingHistoryEvent

    public init(position: ReadingProgress, event: ReadingHistoryEvent) {
        self.position = position
        self.event = event
    }
}

public enum ReadingEventOutcome: Equatable, Sendable {
    /// 200 — applied, or a no-op because the position already was there.
    case accepted(ReadingEventResponse)
    /// 409 — `base_rev` was stale; the position is unchanged.
    case conflict(ReadingEventResponse)
}

/// `GET /api/progress/<id>/history` — events newest first.
public struct ReadingHistory: Decodable, Equatable, Sendable {
    public let position: ReadingProgress?
    public let events: [ReadingHistoryEvent]

    public init(position: ReadingProgress?, events: [ReadingHistoryEvent]) {
        self.position = position
        self.events = events
    }
}
