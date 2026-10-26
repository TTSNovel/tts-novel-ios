import XCTest
@testable import WebnovelReader

final class PiperEnglishTransliteratorTests: XCTestCase {
    /// espeak-ng `en` output for the words these tests use, captured with
    /// `espeak-ng -v en -q --ipa --sep=_ <word>`.
    private static let cannedIPA: [String: String] = [
        "Hogwarts": "h_ˈɒ_ɡ_w_ɔː_t_s",
        "Dumbledore": "d_ˈʌ_m_əl_d_ˌɔː",
        "Potter": "p_ˈɒ_t_ə",
        "Mike": "m_ˈaɪ_k",
        "Strength": "s_t_ɹ_ˈɛ_ŋ_θ",
        "Quidditch": "k_w_ˈɪ_d_ɪ_tʃ",
        "Galadriel": "ɡ_a_l_ˈa_d_ɹ_iːʲ_əl",
    ]

    private func transliterator(dictionary: [String: String] = [:]) -> PiperEnglishTransliterator {
        PiperEnglishTransliterator(dictionary: dictionary) { words in
            words.map { Self.cannedIPA[$0] ?? "" }
        }
    }

    func testIPAFallbackSpellsVietnameseSyllables() {
        let t = transliterator()
        XCTAssertEqual(t.transliterate("Hogwarts"), "hóc uót")
        XCTAssertEqual(t.transliterate("Dumbledore"), "đăm mơn đo")
        XCTAssertEqual(t.transliterate("Potter"), "pót tơ")
        XCTAssertEqual(t.transliterate("Mike"), "mai cơ")
        XCTAssertEqual(t.transliterate("Strength"), "xơ treng")
        XCTAssertEqual(t.transliterate("Quidditch"), "quít đít")
        XCTAssertEqual(t.transliterate("Galadriel"), "ga lát ri ơn")
    }

    func testVietnameseTextIsUntouched() {
        let t = transliterator()
        let text = "Anh Minh bước vào phòng, nhìn quanh rồi ngồi xuống."
        XCTAssertEqual(t.transliterate(text), text)
    }

    func testMixedSentenceKeepsPunctuationAndVietnamese() {
        let t = transliterator(dictionary: ["harry": "ha ri"])
        XCTAssertEqual(
            t.transliterate("Harry Potter bước vào Hogwarts."),
            "ha ri pót tơ bước vào hóc uót."
        )
    }

    func testAcronymsUseVietnameseLetterNames() {
        XCTAssertEqual(transliterator().transliterate("gọi cho FBI"), "gọi cho ép bi ai")
    }

    func testDictionaryWinsOverIPA() {
        let t = transliterator(dictionary: ["potter": "pốt tơ"])
        XCTAssertEqual(t.transliterate("Potter"), "pốt tơ")
    }

    func testMostlyEnglishSentenceAlsoMapsVietnameseLookingWords() {
        let t = transliterator(dictionary: ["the": "đơ", "welcome": "oen căm", "kingdom": "king đom"])
        XCTAssertEqual(t.transliterate("Welcome to the Kingdom"), "oen căm to đơ king đom")
        // ...but not in a Vietnamese sentence with a single English word.
        XCTAssertEqual(t.transliterate("Anh ta đi the Kingdom về nhà ngay"), "Anh ta đi the king đom về nhà ngay")
    }

    func testPhonemizerIsCalledOncePerWord() {
        var calls: [String] = []
        let t = PiperEnglishTransliterator(dictionary: [:]) { words in
            calls += words
            return words.map { Self.cannedIPA[$0] ?? "" }
        }
        _ = t.transliterate("Hogwarts, Hogwarts")
        _ = t.transliterate("Hogwarts")
        XCTAssertEqual(calls, ["Hogwarts"])
    }

    /// End to end through the espeak-ng linked inside sherpa-onnx.
    func testPiperServiceTransliteratesWithBundledEspeak() async throws {
        let spoken = try await PiperOfflineTTSService.shared.spokenText(
            for: "Harry Potter bước vào Hogwarts cùng Dumbledore."
        )
        XCTAssertEqual(spoken, "ha ri pót tơ bước vào hóc uót cùng đăm mơn đo.")
        let wav = try await PiperOfflineTTSService.shared.synthesize(text: "Xin chào Hogwarts.", speed: 1.0)
        XCTAssertGreaterThan(wav.count, 10_000)
    }

    func testBundledDictionaryLoads() {
        let dictionary = PiperEnglishTransliterator.loadBundledDictionary()
        XCTAssertGreaterThan(dictionary.count, 15_000)
        XCTAssertEqual(dictionary["harry"], "ha ri")
        XCTAssertEqual(dictionary["potter"], "pót tơ")
    }
}
