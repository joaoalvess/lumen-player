import AVFoundation
import FFmpegKit
import Libavcodec
import Libavformat
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

    private func makeImageSubtitleTrack() -> FFmpegAssetTrack? {
        var codecpar = AVCodecParameters()
        codecpar.codec_type = AVMEDIA_TYPE_SUBTITLE
        codecpar.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        return FFmpegAssetTrack(codecpar: codecpar)
    }

    private func makeSubtitleTracks(count: Int) throws -> (context: UnsafeMutablePointer<AVFormatContext>, tracks: [FFmpegAssetTrack]) {
        let context = try XCTUnwrap(avformat_alloc_context())
        var tracks = [FFmpegAssetTrack]()
        for _ in 0 ..< count {
            let stream = try XCTUnwrap(avformat_new_stream(context, nil))
            stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
            tracks.append(try XCTUnwrap(FFmpegAssetTrack(stream: stream)))
        }
        return (context, tracks)
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

    func testBitmapProxyRequestsAHotSwitchOnlyWhenItsSelectionChanges() throws {
        let track = try XCTUnwrap(makeImageSubtitleTrack())
        var events = [(Int32, Bool)]()
        let info = ProAVEmbeddedSubtitleInfo(track: track) { events.append(($0, $1)) }

        info.isEnabled = true
        info.isEnabled = true
        info.isEnabled = false

        XCTAssertEqual(events.map(\.0), [track.trackID, track.trackID])
        XCTAssertEqual(events.map(\.1), [true, false])
    }

    func testTextProxyDoesNotRequestARemux() throws {
        let track = try XCTUnwrap(makeSubtitleTrack())
        var events = [(Int32, Bool)]()
        let info = ProAVEmbeddedSubtitleInfo(track: track) { events.append(($0, $1)) }

        info.isEnabled = true
        info.isEnabled = false

        XCTAssertTrue(events.isEmpty)
    }

    func testBitmapPreferenceSelectsExactlyTheRequestedTrack() {
        XCTAssertTrue(ProAVSubtitlePreference.automatic.enablesImageTrack(trackID: 1, defaultEnabled: true))
        XCTAssertFalse(ProAVSubtitlePreference.automatic.enablesImageTrack(trackID: 1, defaultEnabled: false))
        XCTAssertFalse(ProAVSubtitlePreference.disabled.enablesImageTrack(trackID: 1, defaultEnabled: true))
        XCTAssertTrue(ProAVSubtitlePreference.track(2).enablesImageTrack(trackID: 2, defaultEnabled: false))
        XCTAssertFalse(ProAVSubtitlePreference.track(2).enablesImageTrack(trackID: 1, defaultEnabled: true))
    }

    func testReconcileUsesNewTrackOrderAndRemovesMissingProxies() throws {
        let firstSource = try makeSubtitleTracks(count: 2)
        defer { avformat_free_context(firstSource.context) }
        let existing = firstSource.tracks.map { ProAVEmbeddedSubtitleInfo(track: $0) }

        let secondSource = try makeSubtitleTracks(count: 3)
        defer { avformat_free_context(secondSource.context) }
        let reconciled = ProAVEmbeddedSubtitleInfo.reconcile(existing: existing, tracks: Array(secondSource.tracks[1 ... 2]), preserveSelection: true) { _, _ in }

        XCTAssertEqual(reconciled.map(\.trackID), [1, 2])
        XCTAssertTrue(reconciled[0] === existing[1])
        XCTAssertFalse(reconciled[1] === existing[0])
        XCTAssertFalse(existing[0].isAttached)
    }
}
