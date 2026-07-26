import AVFoundation
import FFmpegKit
import Libavcodec
@testable import Lumen
import XCTest

class ProAVEmbeddedSubtitleTest: XCTestCase {
    private func makeStore(with parts: [SubtitlePart]) -> ProAVSubtitlePartStore {
        let store = ProAVSubtitlePartStore()
        store.insert(parts: parts)
        return store
    }

    private func texts(_ parts: [SubtitlePart]) -> [String] {
        parts.map { $0.text?.string ?? "" }
    }

    private func makeSubtitleTrack() -> FFmpegAssetTrack? {
        var codecpar = AVCodecParameters()
        codecpar.codec_type = AVMEDIA_TYPE_SUBTITLE
        return FFmpegAssetTrack(codecpar: codecpar)
    }

    private func makeQueue() -> SyncPlayerItemTrack<SubtitleFrame> {
        SyncPlayerItemTrack<SubtitleFrame>(mediaType: .subtitle, frameCapacity: 8, options: KSOptions())
    }

    private func push(_ parts: [SubtitlePart], to queue: SyncPlayerItemTrack<SubtitleFrame>) {
        for part in parts {
            queue.outputRenderQueue.push(SubtitleFrame(part: part, timebase: .defaultValue))
        }
    }

    func testInsertKeepsPartsOrderedByStart() {
        let store = makeStore(with: [SubtitlePart(3, 4, "c"), SubtitlePart(1, 2, "a"), SubtitlePart(2, 3, "b")])
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(texts(store.search(for: 1.5)), ["a"])
        XCTAssertEqual(texts(store.search(for: 2.5)), ["b"])
        XCTAssertEqual(texts(store.search(for: 3.5)), ["c"])
    }

    func testDuplicateInsertIsIgnored() {
        let store = makeStore(with: [SubtitlePart(1, 2, "a")])
        store.insert(parts: [SubtitlePart(1, 2, "a")])
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(texts(store.search(for: 1.5)), ["a"])
    }

    func testDifferentTextAtTheSameStartIsKept() {
        let store = makeStore(with: [SubtitlePart(1, 2, "a"), SubtitlePart(1, 2, "b")])
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(texts(store.search(for: 1.5)).sorted(), ["a", "b"])
    }

    func testOpenEndedPartIsCappedByTheNextPart() {
        let store = makeStore(with: [SubtitlePart(1, .infinity, "a")])
        XCTAssertEqual(texts(store.search(for: 9)), ["a"])
        store.insert(parts: [SubtitlePart(3, 4, "b")])
        XCTAssertEqual(texts(store.search(for: 3.5)), ["b"])
        XCTAssertEqual(texts(store.search(for: 2)), ["a"])
    }

    func testOpenEndedPartSurvivesUntilASuccessorArrives() {
        let store = makeStore(with: [SubtitlePart(1, .infinity, "a"), SubtitlePart(1, .infinity, "b")])
        XCTAssertEqual(texts(store.search(for: 9)).sorted(), ["a", "b"])
        store.insert(parts: [SubtitlePart(5, 6, "c")])
        XCTAssertTrue(store.search(for: 9).isEmpty)
        XCTAssertEqual(texts(store.search(for: 5.5)), ["c"])
        XCTAssertEqual(texts(store.search(for: 4.9)).sorted(), ["a", "b"])
    }

    func testDuplicateWithFiniteEndTightensAnOpenEndedPart() {
        let store = makeStore(with: [SubtitlePart(1, .infinity, "a")])
        store.insert(parts: [SubtitlePart(1, 2, "a")])
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(store.search(for: 3).isEmpty)
        XCTAssertEqual(texts(store.search(for: 1.5)), ["a"])
    }

    func testSearchIsNotDestructive() {
        let store = makeStore(with: [SubtitlePart(1, 2, "a"), SubtitlePart(3, 4, "b")])
        XCTAssertEqual(texts(store.search(for: 1.5)), ["a"])
        XCTAssertEqual(texts(store.search(for: 3.5)), ["b"])
        XCTAssertEqual(texts(store.search(for: 1.5)), ["a"])
        XCTAssertEqual(store.count, 2)
    }

    func testEmptyPartCoexistsWithTextParts() {
        let store = makeStore(with: [SubtitlePart(1, 2, "a"), SubtitlePart(3, 4, attributedString: nil)])
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(texts(store.search(for: 3.5)), [""])
    }

    func testRemoveAllClearsTheStore() {
        let store = makeStore(with: [SubtitlePart(1, 2, "a")])
        store.removeAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.search(for: 1.5).isEmpty)
    }

    func testProxyDrainsTheTrackQueueOnSearch() throws {
        let track = try XCTUnwrap(makeSubtitleTrack())
        let queue = makeQueue()
        track.subtitle = queue
        let info = ProAVEmbeddedSubtitleInfo(track: track)
        push([SubtitlePart(1, 2, "a"), SubtitlePart(3, 4, "b")], to: queue)
        XCTAssertEqual(texts(info.search(for: 1.5)), ["a"])
        XCTAssertEqual(queue.outputRenderQueue.count, 0)
        XCTAssertEqual(texts(info.search(for: 3.5)), ["b"])
        XCTAssertEqual(texts(info.search(for: 1.5)), ["a"])
    }

    func testProxyKeepsPartsWhenTheQueueIsFlushed() throws {
        let track = try XCTUnwrap(makeSubtitleTrack())
        let queue = makeQueue()
        track.subtitle = queue
        let info = ProAVEmbeddedSubtitleInfo(track: track)
        push([SubtitlePart(1, 2, "a")], to: queue)
        XCTAssertEqual(texts(info.search(for: 1.5)), ["a"])
        queue.outputRenderQueue.flush()
        XCTAssertEqual(texts(info.search(for: 1.5)), ["a"])
    }

    func testProxyRebindDoesNotDuplicateRedecodedParts() throws {
        let track = try XCTUnwrap(makeSubtitleTrack())
        let queue = makeQueue()
        track.subtitle = queue
        let info = ProAVEmbeddedSubtitleInfo(track: track)
        push([SubtitlePart(1, 2, "a"), SubtitlePart(3, 4, "b")], to: queue)
        info.detach()
        let restarted = try XCTUnwrap(makeSubtitleTrack())
        let restartedQueue = makeQueue()
        restarted.subtitle = restartedQueue
        info.bind(track: restarted)
        push([SubtitlePart(1, 2, "a"), SubtitlePart(3, 4, "b"), SubtitlePart(5, 6, "c")], to: restartedQueue)
        XCTAssertEqual(texts(info.search(for: 5.5)), ["c"])
        XCTAssertEqual(texts(info.search(for: 1.5)), ["a"])
        XCTAssertEqual(texts(info.search(for: 3.5)), ["b"])
    }

    func testDetachedProxyStillAnswersFromTheStore() throws {
        let track = try XCTUnwrap(makeSubtitleTrack())
        let queue = makeQueue()
        track.subtitle = queue
        let info = ProAVEmbeddedSubtitleInfo(track: track)
        push([SubtitlePart(1, 2, "a")], to: queue)
        info.detach()
        info.isEnabled = true
        XCTAssertTrue(info.isEnabled)
        XCTAssertEqual(texts(info.search(for: 1.5)), ["a"])
    }

    func testProxyKeepsTheSelectionAcrossRebind() throws {
        let track = try XCTUnwrap(makeSubtitleTrack())
        let info = ProAVEmbeddedSubtitleInfo(track: track)
        XCTAssertEqual(info.subtitleID, String(track.trackID))
        info.isEnabled = true
        let restarted = try XCTUnwrap(makeSubtitleTrack())
        info.bind(track: restarted)
        XCTAssertTrue(info.isEnabled)
        info.isEnabled = false
        XCTAssertFalse(info.isEnabled)
    }

    func testResetClearsThePartsKeptForTheProxy() throws {
        let track = try XCTUnwrap(makeSubtitleTrack())
        let queue = makeQueue()
        track.subtitle = queue
        let info = ProAVEmbeddedSubtitleInfo(track: track)
        push([SubtitlePart(1, 2, "a")], to: queue)
        XCTAssertEqual(texts(info.search(for: 1.5)), ["a"])
        info.reset()
        XCTAssertTrue(info.search(for: 1.5).isEmpty)
    }
}
