@testable import Lumen
import XCTest

final class TrackLanguagePreferenceTests: XCTestCase {
    private typealias Candidate = TrackLanguagePreference.Candidate

    func testNormalizeMapsThreeLetterCodesToTheTwoLetterBase() {
        XCTAssertEqual(TrackLanguagePreference.normalize("por"), "pt")
        XCTAssertEqual(TrackLanguagePreference.normalize("eng"), "en")
        XCTAssertEqual(TrackLanguagePreference.normalize("fre"), "fr")
        XCTAssertEqual(TrackLanguagePreference.normalize("fra"), "fr")
        XCTAssertEqual(TrackLanguagePreference.normalize("ger"), "de")
        XCTAssertEqual(TrackLanguagePreference.normalize("deu"), "de")
        XCTAssertEqual(TrackLanguagePreference.normalize("chi"), "zh")
        XCTAssertEqual(TrackLanguagePreference.normalize("zho"), "zh")
        XCTAssertEqual(TrackLanguagePreference.normalize("dut"), "nl")
        XCTAssertEqual(TrackLanguagePreference.normalize("nob"), "no")
    }

    func testNormalizeStripsRegionAndScriptSubtags() {
        XCTAssertEqual(TrackLanguagePreference.normalize("pt-BR"), "pt")
        XCTAssertEqual(TrackLanguagePreference.normalize("pt_PT"), "pt")
        XCTAssertEqual(TrackLanguagePreference.normalize("zh-Hant-TW"), "zh")
        XCTAssertEqual(TrackLanguagePreference.normalize("en"), "en")
    }

    func testNormalizeIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(TrackLanguagePreference.normalize("POR"), "pt")
        XCTAssertEqual(TrackLanguagePreference.normalize(" Eng "), "en")
        XCTAssertEqual(TrackLanguagePreference.normalize("PT-br"), "pt")
    }

    func testNormalizeRejectsMissingOrUndeterminedCodes() {
        XCTAssertNil(TrackLanguagePreference.normalize(nil))
        XCTAssertNil(TrackLanguagePreference.normalize(""))
        XCTAssertNil(TrackLanguagePreference.normalize("   "))
        XCTAssertNil(TrackLanguagePreference.normalize("und"))
        XCTAssertNil(TrackLanguagePreference.normalize("mul"))
        XCTAssertNil(TrackLanguagePreference.normalize("zxx"))
    }

    func testNormalizeKeepsWellFormedUnknownCodesAndRejectsMalformedOnes() {
        XCTAssertEqual(TrackLanguagePreference.normalize("xq"), "xq")
        XCTAssertEqual(TrackLanguagePreference.normalize("XQZ"), "xqz")
        XCTAssertNil(TrackLanguagePreference.normalize("x"))
        XCTAssertNil(TrackLanguagePreference.normalize("english"))
        XCTAssertNil(TrackLanguagePreference.normalize("e1"))
    }

    func testPickIndexFollowsPreferenceOrder() {
        let candidates = [
            Candidate(languageCode: "eng"),
            Candidate(languageCode: "spa"),
            Candidate(languageCode: "por"),
        ]

        XCTAssertEqual(TrackLanguagePreference.pickIndex(preferred: ["pt", "en"], candidates: candidates), 2)
        XCTAssertEqual(TrackLanguagePreference.pickIndex(preferred: ["fr", "spa", "en"], candidates: candidates), 1)
        XCTAssertEqual(TrackLanguagePreference.pickIndex(preferred: ["pt-BR"], candidates: candidates), 2)
    }

    func testPickIndexReturnsTheFirstTrackWhenALanguageRepeats() {
        let candidates = [
            Candidate(languageCode: "eng"),
            Candidate(languageCode: "por"),
            Candidate(languageCode: "pt"),
        ]

        XCTAssertEqual(TrackLanguagePreference.pickIndex(preferred: ["pt"], candidates: candidates), 1)
    }

    func testPickIndexReturnsNilWithoutAMatch() {
        let candidates = [
            Candidate(languageCode: "eng"),
            Candidate(languageCode: "spa"),
        ]

        XCTAssertNil(TrackLanguagePreference.pickIndex(preferred: ["pt", "ja"], candidates: candidates))
        XCTAssertNil(TrackLanguagePreference.pickIndex(preferred: [], candidates: candidates))
        XCTAssertNil(TrackLanguagePreference.pickIndex(preferred: ["en"], candidates: []))
    }

    func testPickIndexPrefersTextOverImageBasedTracksOfTheSameLanguage() {
        let candidates = [
            Candidate(languageCode: "por", isImageBased: true),
            Candidate(languageCode: "eng"),
            Candidate(languageCode: "por"),
        ]

        XCTAssertEqual(TrackLanguagePreference.pickIndex(preferred: ["pt"], candidates: candidates), 2)
    }

    func testPickIndexFallsBackToAnImageBasedTrackWhenItIsTheOnlyMatch() {
        let candidates = [
            Candidate(languageCode: "eng"),
            Candidate(languageCode: "por", isImageBased: true),
        ]

        XCTAssertEqual(TrackLanguagePreference.pickIndex(preferred: ["pt", "en"], candidates: candidates), 1)
    }

    func testPickIndexSkipsCandidatesWithoutALanguage() {
        let candidates = [
            Candidate(languageCode: nil),
            Candidate(languageCode: "und"),
            Candidate(languageCode: "jpn"),
        ]

        XCTAssertEqual(TrackLanguagePreference.pickIndex(preferred: ["ja"], candidates: candidates), 2)
        XCTAssertNil(TrackLanguagePreference.pickIndex(preferred: ["und"], candidates: candidates))
        XCTAssertNil(TrackLanguagePreference.pickIndex(preferred: ["pt"], candidates: [Candidate(languageCode: nil)]))
    }
}
