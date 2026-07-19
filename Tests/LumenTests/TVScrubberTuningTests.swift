@testable import Lumen
import XCTest

final class TVScrubberTuningTests: XCTestCase {
    func testSlowMovementProvidesFinePrecisionForFeatureLengthContent() {
        let duration: TimeInterval = 2 * 60 * 60
        let delta = TVScrubberTuning.panDelta(
            points: 50,
            trackWidth: 1_000,
            duration: duration,
            velocity: 100
        )

        XCTAssertEqual(delta, 1.5, accuracy: 0.001)
    }

    func testFastFullWidthMovementCannotCrossFeatureLengthContent() {
        let duration: TimeInterval = 2 * 60 * 60
        let delta = TVScrubberTuning.panDelta(
            points: 1_000,
            trackWidth: 1_000,
            duration: duration,
            velocity: 2_000
        )

        XCTAssertEqual(delta, 126, accuracy: 0.001)
        XCTAssertLessThan(delta, duration * 0.02)
    }

    func testPanDeltaCapsSingleEventSpikes() {
        let duration: TimeInterval = 90 * 60
        let regular = TVScrubberTuning.panDelta(
            points: 350,
            trackWidth: 1_000,
            duration: duration,
            velocity: 1_000
        )
        let spike = TVScrubberTuning.panDelta(
            points: 5_000,
            trackWidth: 1_000,
            duration: duration,
            velocity: 1_000
        )

        XCTAssertEqual(spike, regular, accuracy: 0.001)
    }

    func testShortContentFastSpanIsLimitedToTwentyPercent() {
        let duration: TimeInterval = 30
        let span = TVScrubberTuning.secondsPerTrack(
            duration: duration,
            velocity: 2_000
        )

        XCTAssertEqual(span, duration * 0.2, accuracy: 0.001)
    }

    func testArrowHoldAcceleratesInBoundedSteps() {
        XCTAssertEqual(TVScrubberTuning.repeatedArrowStep(heldFor: 0.5), 10)
        XCTAssertEqual(TVScrubberTuning.repeatedArrowStep(heldFor: 2), 30)
        XCTAssertEqual(TVScrubberTuning.repeatedArrowStep(heldFor: 4), 60)
    }

    func testElapsedLabelFollowsPlayheadAndStaysClearOfRemainingTime() {
        XCTAssertEqual(
            TVScrubberTuning.elapsedLabelLeadingX(
                playheadX: 300,
                trackWidth: 1_000,
                elapsedWidth: 80,
                remainingWidth: 100
            ),
            260
        )
        XCTAssertEqual(
            TVScrubberTuning.elapsedLabelLeadingX(
                playheadX: 990,
                trackWidth: 1_000,
                elapsedWidth: 80,
                remainingWidth: 100
            ),
            796
        )
    }
}
