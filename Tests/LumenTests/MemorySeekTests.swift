@testable import Lumen
import XCTest

private final class FakeQueueItem: ObjectQueueItem {
    let timebase: Timebase
    var timestamp: Int64
    var duration: Int64 = 0
    var position: Int64 = 0
    var size: Int32 = 0
    let isKey: Bool
    init(timestamp: Int64, timebase: Timebase = Timebase(num: 1, den: 1000), isKey: Bool = false) {
        self.timestamp = timestamp
        self.timebase = timebase
        self.isKey = isKey
    }
}

class MemorySeekTests: XCTestCase {
    private func makeQueue(_ items: [FakeQueueItem]) -> CircularBuffer<FakeQueueItem> {
        let queue = CircularBuffer<FakeQueueItem>()
        items.forEach { queue.push($0) }
        return queue
    }

    private func lastCandidate(in queue: CircularBuffer<FakeQueueItem>, upTo target: TimeInterval, needsKey: Bool) -> (item: FakeQueueItem, precedingCount: Int)? {
        var chosen: FakeQueueItem?
        var precedingCount = 0
        var index = 0
        queue.scan { item in
            if item.seconds <= target, item.isKey || needsKey == false {
                chosen = item
                precedingCount = index
            }
            index += 1
            return true
        }
        guard let chosen else {
            return nil
        }
        return (chosen, precedingCount)
    }

    func testPeekEdgesOnEmptyQueueReturnsNil() {
        let queue = CircularBuffer<FakeQueueItem>()
        XCTAssertNil(queue.peekEdges())
    }

    func testPeekEdgesReturnsHeadAndTailWithoutConsuming() {
        let items = (0 ..< 5).map { FakeQueueItem(timestamp: Int64($0) * 1000) }
        let queue = makeQueue(items)
        let edges = queue.peekEdges()
        XCTAssertTrue(edges?.head === items[0])
        XCTAssertTrue(edges?.tail === items[4])
        XCTAssertEqual(queue.count, 5)
    }

    func testPeekEdgesSingleItemReturnsSameItemTwice() {
        let item = FakeQueueItem(timestamp: 42)
        let queue = makeQueue([item])
        let edges = queue.peekEdges()
        XCTAssertTrue(edges?.head === item)
        XCTAssertTrue(edges?.tail === item)
    }

    func testScanOnEmptyQueueVisitsNothing() {
        let queue = CircularBuffer<FakeQueueItem>()
        var visited = 0
        queue.scan { _ in
            visited += 1
            return true
        }
        XCTAssertEqual(visited, 0)
    }

    func testScanVisitsHeadToTailWithoutConsuming() {
        let items = (0 ..< 4).map { FakeQueueItem(timestamp: Int64($0)) }
        let queue = makeQueue(items)
        var visited = [Int64]()
        queue.scan { item in
            visited.append(item.timestamp)
            return true
        }
        XCTAssertEqual(visited, [0, 1, 2, 3])
        XCTAssertEqual(queue.count, 4)
    }

    func testScanStopsWhenBodyReturnsFalse() {
        let items = (0 ..< 4).map { FakeQueueItem(timestamp: Int64($0)) }
        let queue = makeQueue(items)
        var visited = 0
        queue.scan { _ in
            visited += 1
            return visited < 2
        }
        XCTAssertEqual(visited, 2)
    }

    func testScanFindsLastKeyframeBeforeTarget() {
        let items = [
            FakeQueueItem(timestamp: 0, isKey: true),
            FakeQueueItem(timestamp: 1000),
            FakeQueueItem(timestamp: 2000, isKey: true),
            FakeQueueItem(timestamp: 3000),
            FakeQueueItem(timestamp: 4000, isKey: true),
            FakeQueueItem(timestamp: 5000),
        ]
        let queue = makeQueue(items)
        let candidate = lastCandidate(in: queue, upTo: 3.5, needsKey: true)
        XCTAssertTrue(candidate?.item === items[2])
        XCTAssertEqual(candidate?.precedingCount, 2)
    }

    func testScanFindsLastItemBeforeTargetWhenKeyframesDoNotMatter() {
        let items = [
            FakeQueueItem(timestamp: 0),
            FakeQueueItem(timestamp: 1000),
            FakeQueueItem(timestamp: 2000),
        ]
        let queue = makeQueue(items)
        let candidate = lastCandidate(in: queue, upTo: 1.5, needsKey: false)
        XCTAssertTrue(candidate?.item === items[1])
        XCTAssertEqual(candidate?.precedingCount, 1)
    }

    func testScanFindsNothingWhenNoKeyframePrecedesTarget() {
        let items = [
            FakeQueueItem(timestamp: 2000),
            FakeQueueItem(timestamp: 3000, isKey: true),
        ]
        let queue = makeQueue(items)
        XCTAssertNil(lastCandidate(in: queue, upTo: 1.0, needsKey: true))
        XCTAssertEqual(queue.count, 2)
    }

    func testPopCountLeavesKeyframeAtHead() {
        let items = [
            FakeQueueItem(timestamp: 0, isKey: true),
            FakeQueueItem(timestamp: 1000),
            FakeQueueItem(timestamp: 2000, isKey: true),
            FakeQueueItem(timestamp: 3000),
        ]
        let queue = makeQueue(items)
        guard let candidate = lastCandidate(in: queue, upTo: 2.5, needsKey: true) else {
            XCTFail("expected a keyframe candidate")
            return
        }
        XCTAssertEqual(queue.pop(count: candidate.precedingCount), 2)
        XCTAssertTrue(queue.peekEdges()?.head === items[2])
        XCTAssertEqual(queue.count, 2)
    }

    func testPopCountBeyondQueueSizeDrainsEverything() {
        let items = (0 ..< 3).map { FakeQueueItem(timestamp: Int64($0)) }
        let queue = makeQueue(items)
        XCTAssertEqual(queue.pop(count: 10), 3)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.peekEdges())
    }

    func testPopCountZeroPopsNothing() {
        let queue = makeQueue([FakeQueueItem(timestamp: 0)])
        XCTAssertEqual(queue.pop(count: 0), 0)
        XCTAssertEqual(queue.count, 1)
    }

    private let videoTimebase = Timebase(num: 1, den: 1000)
    private let audioTimebase = Timebase(num: 1, den: 48000)

    func testWindowCoversTargetInsideVideoWindow() {
        let head = FakeQueueItem(timestamp: 5000, timebase: videoTimebase)
        let tail = FakeQueueItem(timestamp: 35000, timebase: videoTimebase)
        XCTAssertTrue(packetWindowCovers(target: 20, head: head, tail: tail))
        XCTAssertTrue(packetWindowCovers(target: 34, head: head, tail: tail))
    }

    func testWindowCoversTargetInsideAudioWindow() {
        let head = FakeQueueItem(timestamp: 240_000, timebase: audioTimebase)
        let tail = FakeQueueItem(timestamp: 1_680_000, timebase: audioTimebase)
        XCTAssertTrue(packetWindowCovers(target: 20, head: head, tail: tail))
        XCTAssertTrue(packetWindowCovers(target: 34, head: head, tail: tail))
    }

    func testWindowRejectsTargetAtOrBeforeHead() {
        let head = FakeQueueItem(timestamp: 5000, timebase: videoTimebase)
        let tail = FakeQueueItem(timestamp: 35000, timebase: videoTimebase)
        XCTAssertFalse(packetWindowCovers(target: 5, head: head, tail: tail))
        XCTAssertFalse(packetWindowCovers(target: 4, head: head, tail: tail))
    }

    func testWindowRejectsTargetInsideTailMargin() {
        let head = FakeQueueItem(timestamp: 240_000, timebase: audioTimebase)
        let tail = FakeQueueItem(timestamp: 1_680_000, timebase: audioTimebase)
        XCTAssertFalse(packetWindowCovers(target: 34.5, head: head, tail: tail))
        XCTAssertFalse(packetWindowCovers(target: 35, head: head, tail: tail))
    }

    func testWindowRejectsTargetBeyondTail() {
        let head = FakeQueueItem(timestamp: 5000, timebase: videoTimebase)
        let tail = FakeQueueItem(timestamp: 35000, timebase: videoTimebase)
        XCTAssertFalse(packetWindowCovers(target: 60, head: head, tail: tail))
    }

    func testWindowMarginIsConfigurable() {
        let head = FakeQueueItem(timestamp: 5000, timebase: videoTimebase)
        let tail = FakeQueueItem(timestamp: 35000, timebase: videoTimebase)
        XCTAssertTrue(packetWindowCovers(target: 34.5, head: head, tail: tail, margin: 0))
        XCTAssertFalse(packetWindowCovers(target: 34.5, head: head, tail: tail, margin: 2))
    }
}
