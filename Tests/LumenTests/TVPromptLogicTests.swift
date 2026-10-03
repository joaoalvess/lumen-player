#if os(tvOS)
@testable import Lumen
import XCTest

final class TVPromptLogicTests: XCTestCase {
    private let intro = TVSkipSegment(range: 10 ... 70, kind: .intro)
    private let credits = TVSkipSegment(range: 2_800 ... 2_950, kind: .credits)

    func testUpNextRequiresFinitePositiveDuration() {
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 10, duration: 0, leadTime: 30, startTime: nil))
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 10, duration: -5, leadTime: 30, startTime: nil))
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 10, duration: .nan, leadTime: 30, startTime: nil))
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 10, duration: .infinity, leadTime: 30, startTime: nil))
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: .nan, duration: 3_000, leadTime: 30, startTime: nil))
    }

    func testUpNextWindowOpensLeadTimeBeforeTheEnd() {
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 2_969, duration: 3_000, leadTime: 30, startTime: nil))
        XCTAssertTrue(TVUpNextTiming.isVisible(currentTime: 2_970, duration: 3_000, leadTime: 30, startTime: nil))
        XCTAssertTrue(TVUpNextTiming.isVisible(currentTime: 3_000, duration: 3_000, leadTime: 30, startTime: nil))
    }

    func testUpNextStartTimeOverridesLeadTime() {
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 2_699, duration: 3_000, leadTime: 30, startTime: 2_700))
        XCTAssertTrue(TVUpNextTiming.isVisible(currentTime: 2_700, duration: 3_000, leadTime: 30, startTime: 2_700))
        XCTAssertTrue(TVUpNextTiming.isVisible(currentTime: 2_970, duration: 3_000, leadTime: 30, startTime: .nan))
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 2_969, duration: 3_000, leadTime: 30, startTime: .nan))
    }

    func testUpNextWindowNeverOpensBeforeHalfTheDuration() {
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 19, duration: 40, leadTime: 30, startTime: nil))
        XCTAssertTrue(TVUpNextTiming.isVisible(currentTime: 20, duration: 40, leadTime: 30, startTime: nil))
        XCTAssertFalse(TVUpNextTiming.isVisible(currentTime: 49, duration: 100, leadTime: 30, startTime: 5))
        XCTAssertTrue(TVUpNextTiming.isVisible(currentTime: 50, duration: 100, leadTime: 30, startTime: 5))
    }

    func testRemainingSecondsRoundsUpAndNeverGoesNegative() {
        XCTAssertEqual(TVUpNextTiming.remainingSeconds(currentTime: 2_970, duration: 3_000), 30)
        XCTAssertEqual(TVUpNextTiming.remainingSeconds(currentTime: 2_970.2, duration: 3_000), 30)
        XCTAssertEqual(TVUpNextTiming.remainingSeconds(currentTime: 2_999.5, duration: 3_000), 1)
        XCTAssertEqual(TVUpNextTiming.remainingSeconds(currentTime: 3_000, duration: 3_000), 0)
        XCTAssertEqual(TVUpNextTiming.remainingSeconds(currentTime: 3_001, duration: 3_000), 0)
        XCTAssertEqual(TVUpNextTiming.remainingSeconds(currentTime: 10, duration: .nan), 0)
        XCTAssertEqual(TVUpNextTiming.remainingSeconds(currentTime: 10, duration: .infinity), 0)
    }

    func testCountdownProgressSpansTheWindow() {
        XCTAssertEqual(TVUpNextTiming.progress(currentTime: 2_960, duration: 3_000, leadTime: 30, startTime: nil), 0)
        XCTAssertEqual(TVUpNextTiming.progress(currentTime: 2_985, duration: 3_000, leadTime: 30, startTime: nil), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TVUpNextTiming.progress(currentTime: 3_010, duration: 3_000, leadTime: 30, startTime: nil), 1)
        XCTAssertEqual(TVUpNextTiming.progress(currentTime: 10, duration: 0, leadTime: 30, startTime: nil), 0)
    }

    func testSkipIntervalIsClosed() {
        let segments = [intro]
        XCTAssertNil(TVSkipTiming.active(at: 9.99, segments: segments, dismissed: [], hidingCredits: false))
        XCTAssertEqual(TVSkipTiming.active(at: 10, segments: segments, dismissed: [], hidingCredits: false)?.index, 0)
        XCTAssertEqual(TVSkipTiming.active(at: 70, segments: segments, dismissed: [], hidingCredits: false)?.segment, intro)
        XCTAssertNil(TVSkipTiming.active(at: 70.01, segments: segments, dismissed: [], hidingCredits: false))
        XCTAssertNil(TVSkipTiming.active(at: .nan, segments: segments, dismissed: [], hidingCredits: false))
    }

    func testSkipIgnoresDismissedSegments() {
        XCTAssertNil(TVSkipTiming.active(at: 30, segments: [intro, credits], dismissed: [0], hidingCredits: false))
        XCTAssertEqual(TVSkipTiming.active(at: 2_900, segments: [intro, credits], dismissed: [0], hidingCredits: false)?.index, 1)
    }

    func testHidingCreditsOnlySuppressesCredits() {
        let segments = [intro, credits]
        XCTAssertNil(TVSkipTiming.active(at: 2_900, segments: segments, dismissed: [], hidingCredits: true))
        XCTAssertEqual(TVSkipTiming.active(at: 2_900, segments: segments, dismissed: [], hidingCredits: false)?.index, 1)
        XCTAssertEqual(TVSkipTiming.active(at: 30, segments: segments, dismissed: [], hidingCredits: true)?.index, 0)
    }

    func testOverlappingSegmentsResolveInOrderAndFallBackAfterDismissal() {
        let recap = TVSkipSegment(range: 0 ... 60, kind: .recap)
        let overlappingIntro = TVSkipSegment(range: 50 ... 120, kind: .intro, label: "Pular tema")
        let segments = [recap, overlappingIntro]
        XCTAssertEqual(TVSkipTiming.active(at: 55, segments: segments, dismissed: [], hidingCredits: false)?.segment, recap)
        XCTAssertEqual(TVSkipTiming.active(at: 55, segments: segments, dismissed: [0], hidingCredits: false)?.segment, overlappingIntro)
    }

    func testResolverPrefersUpNextOverSkip() {
        let preview = TVSkipSegment(range: 2_960 ... 3_000, kind: .preview)
        let prompt = TVPromptResolver.active(currentTime: 2_980,
                                             duration: 3_000,
                                             upNext: (leadTime: 30, startTime: nil),
                                             isUpNextDismissed: false,
                                             segments: [preview],
                                             dismissedSkips: [])
        XCTAssertEqual(prompt, .upNext)
    }

    func testResolverKeepsCreditsHiddenInsideTheUpNextWindowEvenAfterDismissal() {
        let segments = [intro, credits]
        let dismissed = TVPromptResolver.active(currentTime: 2_900,
                                                duration: 3_000,
                                                upNext: (leadTime: 30, startTime: 2_800),
                                                isUpNextDismissed: true,
                                                segments: segments,
                                                dismissedSkips: [])
        XCTAssertNil(dismissed)
        let withoutUpNext = TVPromptResolver.active(currentTime: 2_900,
                                                    duration: 3_000,
                                                    upNext: nil,
                                                    isUpNextDismissed: false,
                                                    segments: segments,
                                                    dismissedSkips: [])
        XCTAssertEqual(withoutUpNext, .skip(index: 1, segment: credits))
    }

    func testResolverShowsSkipBeforeTheUpNextWindow() {
        let prompt = TVPromptResolver.active(currentTime: 30,
                                             duration: 3_000,
                                             upNext: (leadTime: 30, startTime: nil),
                                             isUpNextDismissed: false,
                                             segments: [intro, credits],
                                             dismissedSkips: [])
        XCTAssertEqual(prompt, .skip(index: 0, segment: intro))
    }
}
#endif
