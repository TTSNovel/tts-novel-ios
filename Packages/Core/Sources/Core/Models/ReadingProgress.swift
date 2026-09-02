import Foundation

// Matches app/server.py's /api/progress record shape exactly
// ({"chapter": Int, "sentence": Int, "updated_at": ISO8601 UTC}) — the
// server stamps `updated_at` itself so every timestamp compared during
// last-write-wins merging (ProgressStore.refreshFromServer) was issued by
// the same clock, regardless of which device made the request.
public struct ReadingProgress: Codable, Equatable, Sendable {
    public var chapterIndex: Int
    public var sentenceIndex: Int
    public var updatedAt: Date

    public init(chapterIndex: Int, sentenceIndex: Int, updatedAt: Date) {
        self.chapterIndex = chapterIndex
        self.sentenceIndex = sentenceIndex
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case chapterIndex = "chapter"
        case sentenceIndex = "sentence"
        case updatedAt = "updated_at"
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
