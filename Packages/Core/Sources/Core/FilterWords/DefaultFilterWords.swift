import Foundation

/// Seeded into `FilterWordsStore` on first launch — text that Vietnamese TTS
/// backbones either can't read meaningfully (URLs, CJK leftovers, emoji) or
/// shouldn't read at all (scraped-in domain/watermark/credit-line text).
/// Fixed UUIDs so a fresh install always produces the same rule identities.
/// Each carries a `label` — the raw pattern (especially the CJK/emoji
/// Unicode ranges) renders as unreadable tofu boxes in the settings list
/// otherwise.
public enum DefaultFilterWords {
    public static let seed: [FilterWordRule] = [
        FilterWordRule(
            id: UUID(uuidString: "8FE527A7-15D5-4A03-AB9D-F3DD3232A9F1")!,
            pattern: #"https?://\S+"#, isRegex: true,
            label: "Full link (http/https)"
        ),
        FilterWordRule(
            id: UUID(uuidString: "C94BD679-4E42-47C2-9D62-22BD2F4E0B87")!,
            pattern: #"\bwww\.[^\s]+\b"#, isRegex: true,
            label: "Web address starting with www."
        ),
        // Runs BEFORE the bare-domain rule below, on purpose: an email's
        // "user@example.com" contains a bare domain too, so stripping the
        // whole email first keeps the domain rule from only eating the
        // "example.com" half and leaving a dangling "user@" behind.
        FilterWordRule(
            id: UUID(uuidString: "BBEB29F0-D7A7-4A98-8DFB-ABD07B7837B0")!,
            pattern: #"[\w.+-]+@[\w-]+\.[\w.-]+"#, isRegex: true,
            label: "Email address"
        ),
        // Bare domains without a scheme/"www." prefix — the "regex domain"
        // default this feature was originally requested for. Includes a few
        // common link-shortener TLDs (ly/gg/io) so e.g. bit.ly links are
        // caught by this one rule instead of needing dedicated shortener
        // patterns.
        FilterWordRule(
            id: UUID(uuidString: "7A1D84D0-86FB-4676-9C6D-5E5A9F6A4CF8")!,
            pattern: #"\b[a-zA-Z0-9-]+\.(com|net|org|vn|info|me|tv|club|xyz|top|shop|ly|gg|io)\b"#, isRegex: true,
            label: "Website domain (.com, .vn, .net, ...)"
        ),
        // Untranslated CJK leftovers (CJK Unified Ideographs, Hiragana/
        // Katakana, Hangul) some scraped/converted novels still carry.
        FilterWordRule(
            id: UUID(uuidString: "4AF37E7E-64FB-4D46-8835-4B4DD3C24A4D")!,
            pattern: "[\u{4E00}-\u{9FFF}\u{3040}-\u{30FF}\u{AC00}-\u{D7A3}]+", isRegex: true,
            label: "Leftover Chinese/Japanese/Korean characters"
        ),
        FilterWordRule(
            id: UUID(uuidString: "9776BAC8-077C-4E98-A167-960BCCFEF569")!,
            pattern: "[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]", isRegex: true,
            label: "Emoji"
        ),
        // Scanlation/convert credit lines — anchored to the start of a line
        // and requiring a colon right after the label, so it only matches
        // the "Nguồn: ...", "Convert: ...", "Editor: ...", "Beta: ..." style
        // credit line scraped-in novels carry, not ordinary prose that
        // happens to contain one of these words.
        FilterWordRule(
            id: UUID(uuidString: "683274C8-6B36-4F1A-9B20-D9A4628F4681")!,
            pattern: #"(?m)^(Nguồn|Convert|Editor|Beta)\s*:.*$"#, isRegex: true,
            label: "Converter credit line (Nguồn/Convert/Editor/Beta:)"
        ),
        // Translator/editor notes in parentheses, e.g. "(TN: ...)" / "(ND: ...)".
        FilterWordRule(
            id: UUID(uuidString: "F0521A04-221E-4A36-9F54-C8598B7C6E9B")!,
            pattern: #"\((?:TN|ND)[:\-][^)]*\)"#, isRegex: true,
            label: "Translator note (TN/ND: ...)"
        ),
        FilterWordRule(
            id: UUID(uuidString: "E2BE60AC-DD40-4466-BAFF-11F3E3E85E6D")!,
            pattern: "Đọc truyện tại", isRegex: false,
            label: "Promo phrase \u{201c}Đọc truyện tại\u{201d}"
        ),
        FilterWordRule(
            id: UUID(uuidString: "636B5567-A8FA-449B-96B8-A62993293D52")!,
            pattern: "Group đọc truyện", isRegex: false,
            label: "Promo phrase \u{201c}Group đọc truyện\u{201d}"
        ),
        FilterWordRule(
            id: UUID(uuidString: "835D1C01-B7CB-4398-8561-94D289DCD3F3")!,
            pattern: #"#\w+"#, isRegex: true,
            label: "Hashtag (#...)"
        ),
        // Runs after the email rule above (array order), so an email's
        // "@host" has already been stripped by the time this runs — it
        // only ever catches standalone @mentions, not email addresses.
        FilterWordRule(
            id: UUID(uuidString: "F22EB11F-E905-4E4D-83E0-D20B01891367")!,
            pattern: #"@\w+"#, isRegex: true,
            label: "Mention (@...)"
        ),
    ]
}
