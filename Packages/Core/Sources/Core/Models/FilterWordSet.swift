import Foundation

/// Matches app/server.py's `/api/filter-words` record shape exactly
/// (`{"rules": [...], "updated_at": ISO8601 UTC}`) — one shared list per
/// account (unlike `ReadingProgress`, which is keyed per book), synced
/// whole-list-at-once with last-write-wins on `updatedAt`.
public struct FilterWordSet: Codable, Equatable, Sendable {
    public var rules: [FilterWordRule]
    public var updatedAt: Date

    public init(rules: [FilterWordRule], updatedAt: Date) {
        self.rules = rules
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case rules
        case updatedAt = "updated_at"
    }
}
