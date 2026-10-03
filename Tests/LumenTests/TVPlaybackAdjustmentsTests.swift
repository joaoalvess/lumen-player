@testable import Lumen
import XCTest

final class TVPlaybackAdjustmentsTests: XCTestCase {
    func testSubtitleDelayStepsByTenthsOfASecond() {
        XCTAssertEqual(TVSubtitleDelay.adjusted(0, by: 0.1), 0.1)
        XCTAssertEqual(TVSubtitleDelay.adjusted(0.1, by: 0.1), 0.2)
        XCTAssertEqual(TVSubtitleDelay.adjusted(0.2, by: 0.1), 0.3)
        XCTAssertEqual(TVSubtitleDelay.adjusted(0.3, by: 0.5), 0.8)
    }

    func testSubtitleDelayRoundsToTheNearestTenth() {
        XCTAssertEqual(TVSubtitleDelay.adjusted(1.04, by: 0), 1.0)
        XCTAssertEqual(TVSubtitleDelay.adjusted(1.06, by: 0.5), 1.6)
        XCTAssertEqual(TVSubtitleDelay.adjusted(-1.06, by: 0), -1.1)
    }

    func testRepeatedStepsDoNotAccumulateFloatingPointError() {
        var delay: TimeInterval = 0
        for _ in 0 ..< 30 {
            delay = TVSubtitleDelay.adjusted(delay, by: 0.1)
        }
        XCTAssertEqual(delay, 3)
        for _ in 0 ..< 30 {
            delay = TVSubtitleDelay.adjusted(delay, by: -0.1)
        }
        XCTAssertEqual(delay, 0)
        XCTAssertEqual(delay.sign, .plus)
    }

    func testNegativeStepsMoveTheSubtitleEarlier() {
        XCTAssertEqual(TVSubtitleDelay.adjusted(0, by: -0.1), -0.1)
        XCTAssertEqual(TVSubtitleDelay.adjusted(-0.1, by: -0.5), -0.6)
        XCTAssertEqual(TVSubtitleDelay.adjusted(0.5, by: -0.5), 0)
        XCTAssertEqual(TVSubtitleDelay.adjusted(0.5, by: -0.5).sign, .plus)
    }

    func testSubtitleDelayIsClampedToThirtySeconds() {
        XCTAssertEqual(TVSubtitleDelay.adjusted(29.8, by: 0.5), 30)
        XCTAssertEqual(TVSubtitleDelay.adjusted(30, by: 0.1), 30)
        XCTAssertEqual(TVSubtitleDelay.adjusted(-29.9, by: -0.5), -30)
        XCTAssertEqual(TVSubtitleDelay.adjusted(-30, by: -0.1), -30)
        XCTAssertEqual(TVSubtitleDelay.adjusted(-30, by: 0.1), -29.9)
        XCTAssertEqual(TVSubtitleDelay.adjusted(120, by: 0), 30)
    }

    func testSubtitleDelayIgnoresNonFiniteInput() {
        XCTAssertEqual(TVSubtitleDelay.adjusted(.nan, by: 0.1), 0.1)
        XCTAssertEqual(TVSubtitleDelay.adjusted(1, by: .nan), 1)
        XCTAssertEqual(TVSubtitleDelay.adjusted(.infinity, by: 0.5), 0.5)
    }

    func testSubtitleDelayLabelUsesDecimalCommaAndSign() {
        XCTAssertEqual(TVSubtitleDelay.label(0), "0,0 s")
        XCTAssertEqual(TVSubtitleDelay.label(-0.0), "0,0 s")
        XCTAssertEqual(TVSubtitleDelay.label(0.04), "0,0 s")
        XCTAssertEqual(TVSubtitleDelay.label(-0.04), "0,0 s")
        XCTAssertEqual(TVSubtitleDelay.label(0.5), "+0,5 s")
        XCTAssertEqual(TVSubtitleDelay.label(-1.2), "\u{2212}1,2 s")
        XCTAssertEqual(TVSubtitleDelay.label(12.3), "+12,3 s")
        XCTAssertEqual(TVSubtitleDelay.label(45), "+30,0 s")
        XCTAssertEqual(TVSubtitleDelay.label(-45), "\u{2212}30,0 s")
    }

    func testSubtitleDelayStepLabels() {
        XCTAssertEqual(TVSubtitleDelay.stepLabel(-0.5), "\u{2212}0,5")
        XCTAssertEqual(TVSubtitleDelay.stepLabel(-0.1), "\u{2212}0,1")
        XCTAssertEqual(TVSubtitleDelay.stepLabel(0.1), "+0,1")
        XCTAssertEqual(TVSubtitleDelay.stepLabel(0.5), "+0,5")
    }

    func testPlaybackRateStepsAreAscendingAndIncludeNormalSpeed() {
        XCTAssertEqual(TVPlaybackRate.steps, [0.75, 1, 1.25, 1.5, 2])
        XCTAssertEqual(TVPlaybackRate.steps, TVPlaybackRate.steps.sorted())
        XCTAssertTrue(TVPlaybackRate.steps.contains(1))
    }

    func testPlaybackRateLabelsUseDecimalComma() {
        XCTAssertEqual(TVPlaybackRate.steps.map(TVPlaybackRate.label), ["0,75\u{00D7}", "1\u{00D7}", "1,25\u{00D7}", "1,5\u{00D7}", "2\u{00D7}"])
        XCTAssertEqual(TVPlaybackRate.label(0.5), "0,5\u{00D7}")
        XCTAssertEqual(TVPlaybackRate.label(.nan), "1\u{00D7}")
    }

    func testPlaybackRateSelectionToleratesFloatDrift() {
        XCTAssertTrue(TVPlaybackRate.isSelected(1.25, current: 1.2500001))
        XCTAssertFalse(TVPlaybackRate.isSelected(1.25, current: 1.5))
    }
}
