import Foundation

/// One entry of the server's translation glossary (app/translation.py in the
/// tts-webnovel repo), used by `GoogleCloudTranslationEngine`: `source` is
/// always translated as `target`. `bookID == nil` applies to every book;
/// otherwise only to that book (and wins over a shared term with the same
/// `source`). A `target` equal to `source` keeps the term untranslated —
/// what the server stores when the translation is left blank.
public struct GlossaryTerm: Codable, Equatable, Identifiable, Sendable {
    /// Assigned by the server; nil for a term not saved yet.
    public var serverID: String?
    public var source: String
    public var target: String
    public var bookID: Int?
    /// Stable identity for SwiftUI lists, including unsaved terms.
    public let id: UUID

    public init(source: String, target: String, bookID: Int?, serverID: String? = nil) {
        self.serverID = serverID
        self.source = source
        self.target = target
        self.bookID = bookID
        self.id = UUID()
    }

    public var keepsOriginal: Bool { target == source }

    enum CodingKeys: String, CodingKey {
        case serverID = "id"
        case source, target
        case bookID = "book_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decodeIfPresent(String.self, forKey: .serverID)
        source = try container.decode(String.self, forKey: .source)
        target = try container.decode(String.self, forKey: .target)
        bookID = try container.decodeIfPresent(Int.self, forKey: .bookID)
        id = UUID()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(serverID, forKey: .serverID)
        try container.encode(source, forKey: .source)
        try container.encode(target, forKey: .target)
        // Explicit null (not omitted) — the server reads a missing book_id
        // as shared too, but this keeps the payload unambiguous.
        try container.encode(bookID, forKey: .bookID)
    }
}
