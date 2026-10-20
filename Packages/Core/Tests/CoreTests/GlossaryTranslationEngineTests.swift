import XCTest
@testable import Core

final class GlossaryTranslationEngineTests: XCTestCase {
    private let en = Locale.Language(identifier: "en")
    private let vi = Locale.Language(identifier: "vi")

    private let glossary = Glossary(entries: [
        "Dao": "Đạo",
        "Dao Seed": "Đạo Chủng",
        "Dao Seed of Heaviness": "Đạo Chủng Trọng Lực",
        "Strength": "Sức Mạnh",
        "Hatchetman": "Phủ Binh",
        "class": "class",
        "Super Brother-Man": "Super Brother-Man",
    ])

    func testBracketsTermsLongestFirstCaseSensitiveWholeWords() {
        let protected = glossary.protect("His Dao Seed of Heaviness and Dao gave strength to his Strength, not Daoist tricks.")
        XCTAssertEqual(protected.text, "His [Đạo Chủng Trọng Lực] and [Đạo] gave strength to his [Sức Mạnh], not Daoist tricks.")
    }

    func testRestoreStripsAddedBracketsAndPutsBackTermText() {
        let protected = glossary.protect("His class was Hatchetman.")
        XCTAssertEqual(protected.text, "His [class] was [Phủ Binh].")
        // What Apple Translate actually does: translates the keep-original
        // English word and changes the diacritics of the Vietnamese one.
        XCTAssertEqual(glossary.restore("[Lớp học] của anh ấy là [Phủ Bình].", from: protected), "class của anh ấy là Phủ Binh.")
    }

    func testRestorePairsByContentWhenTheEngineReorders() {
        let protected = glossary.protect("Strength of the Hatchetman")
        XCTAssertEqual(glossary.restore("[phủ binh] với [Sức mạnh]", from: protected), "Phủ Binh với Sức Mạnh")
    }

    func testExistingBracketsAreKeptAndTermsInsideThemNested() {
        let protected = glossary.protect("[Strength] rose. [Fire Bolt] hit. [class: Hatchetman, Epic] Super Brother-Man laughed.")
        XCTAssertEqual(
            protected.text,
            "[Sức Mạnh] rose. [Fire Bolt] hit. [[class]: [Phủ Binh], Epic] [Super Brother-Man] laughed."
        )
        // Real Apple Translate output for a status line like this one.
        let translated = "[Sức mạnh] đã tăng. [Tia Lửa] trúng. [[Lớp học]: [Phủ Bình], Sử thi] [Siêu Anh Trai] cười."
        XCTAssertEqual(
            glossary.restore(translated, from: protected),
            "[Sức Mạnh] đã tăng. [Tia Lửa] trúng. [class: Phủ Binh, Sử thi] Super Brother-Man cười."
        )
    }

    func testTidiesSpaceBeforePunctuation() {
        let protected = glossary.protect("He chose Strength.")
        XCTAssertEqual(glossary.restore("Anh ấy chọn [Sức Mạnh] .", from: protected), "Anh ấy chọn Sức Mạnh.")
    }

    func testTextWithoutTermsIsUntouched() {
        let protected = glossary.protect("Nothing [here] to see.")
        XCTAssertEqual(protected.text, "Nothing [here] to see.")
        XCTAssertEqual(glossary.restore("Không có gì [ở đây].", from: protected), "Không có gì [ở đây].")
    }

    func testResolvesBookTermsOverSharedAndOnlyForVietnamese() {
        let terms = [
            GlossaryTerm(source: "Dao", target: "Đạo", bookID: nil),
            GlossaryTerm(source: "Tutorial", target: "Hướng dẫn", bookID: nil),
            GlossaryTerm(source: "Tutorial", target: "Tân Thủ Thôn", bookID: 119),
            GlossaryTerm(source: "Ladder", target: "Thang Thiên", bookID: 7),
            GlossaryTerm(source: "道", target: "Đạo", bookID: nil),
        ]
        XCTAssertEqual(Glossary(terms: terms, bookID: 119, source: en, target: vi).entries, ["Dao": "Đạo", "Tutorial": "Tân Thủ Thôn"])
        XCTAssertEqual(Glossary(terms: terms, bookID: 119, source: Locale.Language(identifier: "zh-Hans"), target: vi).entries, ["道": "Đạo"])
        XCTAssertTrue(Glossary(terms: terms, bookID: 119, source: en, target: Locale.Language(identifier: "ja")).isEmpty)
    }

    func testEngineProtectsBeforeAndRestoresAfter() async throws {
        let base = EchoEngine { "[\($0.dropFirst(1).dropLast(1))]!" }
        let engine = GlossaryTranslationEngine(base: base, glossary: glossary)
        var results: [Int: String] = [:]
        for try await (index, text) in engine.translate(texts: ["Strength", "plain"], source: en, target: vi) {
            results[index] = text
        }
        XCTAssertEqual(base.received.value, ["[Sức Mạnh]", "plain"])
        XCTAssertEqual(results, [0: "Sức Mạnh!", 1: "[lai]!"])
    }
}

/// Records what it was asked to translate and answers with `transform`.
private final class EchoEngine: TranslationEngine, @unchecked Sendable {
    let transform: @Sendable (String) -> String
    let received = Locked<[String]>([])

    init(transform: @escaping @Sendable (String) -> String) { self.transform = transform }

    var displayName: String { "Echo" }
    func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool { true }
    func translate(texts: [String], source: Locale.Language, target: Locale.Language) -> AsyncThrowingStream<(index: Int, text: String), Error> {
        received.value = texts
        return AsyncThrowingStream { continuation in
            for (index, text) in texts.enumerated() { continuation.yield((index, transform(text))) }
            continuation.finish()
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
