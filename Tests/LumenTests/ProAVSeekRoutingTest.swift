@testable import Lumen
import XCTest

class ProAVSeekRoutingTest: XCTestCase {
    @MainActor
    func testTargetInsideTheWindowSeeksTheInnerPlayer() {
        let route = ProAVPlayer.seekRoute(target: 125, startOffset: 120, closedSegmentsDuration: 10)
        XCTAssertEqual(route, .inner(5))
    }

    @MainActor
    func testWindowBoundsAreInclusive() {
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 120, startOffset: 120, closedSegmentsDuration: 10), .inner(0))
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 130, startOffset: 120, closedSegmentsDuration: 10), .inner(10))
    }

    @MainActor
    func testTargetBeforeTheWindowRebuilds() {
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 119.9, startOffset: 120, closedSegmentsDuration: 10), .restart)
    }

    @MainActor
    func testTargetBeyondTheWindowRebuilds() {
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 130.1, startOffset: 120, closedSegmentsDuration: 10), .restart)
    }

    @MainActor
    func testEmptyWindowRebuilds() {
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 120, startOffset: 120, closedSegmentsDuration: 0), .restart)
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 0, startOffset: 0, closedSegmentsDuration: 0), .restart)
    }

    @MainActor
    func testWindowFromTheStartOfTheMedia() {
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 0, startOffset: 0, closedSegmentsDuration: 4), .inner(0))
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 3.5, startOffset: 0, closedSegmentsDuration: 4), .inner(3.5))
        XCTAssertEqual(ProAVPlayer.seekRoute(target: 4.5, startOffset: 0, closedSegmentsDuration: 4), .restart)
    }
}
