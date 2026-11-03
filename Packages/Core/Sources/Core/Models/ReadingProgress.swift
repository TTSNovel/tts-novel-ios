import Foundation

// app/server.py's /api/progress position shape
// ({"chapter", "sentence", "updated_at", "rev", "device_id", "device_name"})
// minus "sentence": reading history is per chapter only, so the server's
// sentence field is ignored on decode. The server stamps `updated_at`
// itself, so every timestamp shown/sorted on was issued by the same clock
// regardless of which device made the request.
//
// `rev` is the server's per-book revision, bumped each time the position
// actually changes — a write is only applied when the writer's `base_rev`
// equals it (see ProgressStore/ProgressReconciler). Positions saved by an
// older build (local progress.json) or served before the server learned
// revisions decode with rev 0 and no device.
public struct ReadingProgress: Codable, Equatable, Sendable {
    public var chapterIndex: Int
    public var updatedAt: Date
    public var rev: Int
    public var deviceID: String?
    public var deviceName: String?

    public init(chapterIndex: Int, updatedAt: Date, rev: Int = 0, deviceID: String? = nil, deviceName: String? = nil) {
        self.chapterIndex = chapterIndex
        self.updatedAt = updatedAt
        self.rev = rev
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterIndex = try container.decode(Int.self, forKey: .chapterIndex)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        rev = try container.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
    }

    enum CodingKeys: String, CodingKey {
        case chapterIndex = "chapter"
        case updatedAt = "updated_at"
        case rev
        case deviceID = "device_id"
        case deviceName = "device_name"
    }
}

public extension JSONDecoder {
    /// The server's `updated_at` includes fractional seconds
    /// (`datetime.now(timezone.utc).isoformat()`), which the plain
    /// `.iso8601` strategy can't parse — needs `withFractionalSeconds`.
    static let readingProgress: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISO8601DateFormatter.fractionalSeconds.date(from: string)
                ?? ISO8601DateFormatter.wholeSeconds.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
            }
            return date
        }
        return decoder
    }()
}

public extension JSONEncoder {
    static let readingProgress: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.fractionalSeconds.string(from: date))
        }
        return encoder
    }()
}

private extension ISO8601DateFormatter {
    // nonisolated(unsafe): only ever read after creation (format/parse
    // calls on ISO8601DateFormatter don't mutate shared state), never
    // written again — Swift 6 can't see that from a plain `static let`.
    nonisolated(unsafe) static let fractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static let wholeSeconds = ISO8601DateFormatter()
}
