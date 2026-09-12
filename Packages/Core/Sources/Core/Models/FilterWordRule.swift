import Foundation

/// A single text-filtering rule from the reader's "Filter Words" settings —
/// matched text is stripped before it reaches TTS synthesis (see
/// `TextSegmentation.cleaned(_:filterRules:)`). `id` is stable across edits
/// so a rule survives round-tripping through the server's whole-list sync.
public struct FilterWordRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var pattern: String
    public var isRegex: Bool
    /// Optional human-readable name for the rule, editable by the user in
    /// the Add/Edit sheet. Shown alongside the raw pattern in the list row.
    /// Set for the shipped defaults (see `DefaultFilterWords`); `nil` when
    /// left blank.
    public var label: String?

    public init(id: UUID = UUID(), pattern: String, isRegex: Bool, label: String? = nil) {
        self.id = id
        self.pattern = pattern
        self.isRegex = isRegex
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case id, pattern, label
        case isRegex = "is_regex"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        pattern = try container.decode(String.self, forKey: .pattern)
        isRegex = try container.decode(Bool.self, forKey: .isRegex)
        // Absent from older locally-persisted files and from the server
        // (which round-trips whatever it's given but never invented this
        // key) — decode leniently rather than failing the whole list.
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }
}
