import AVFoundation
@testable import Lumen
import XCTest

class KSAVPlayerTest: XCTestCase {
    private var readyToPlayExpectation: XCTestExpectation?
    @MainActor
    func testPlayer() {
        if let path = Bundle(for: type(of: self)).path(forResource: "h264", ofType: "MP4") {
            set(path: path)
        }
        //        if let path = Bundle(for: type(of: self)).path(forResource: "google-help-vr", ofType: "mp4") {
        //            set(path: path)
        //        }
        if let path = Bundle(for: type(of: self)).path(forResource: "mjpeg", ofType: "flac") {
            set(path: path)
        }
        if let path = Bundle(for: type(of: self)).path(forResource: "hevc", ofType: "mkv") {
            set(path: path)
        }
    }

    @MainActor
    func set(path: String) {
        let play = KSAVPlayer(url: URL(fileURLWithPath: path), options: KSOptions())
        play.delegate = self
        play.prepareToPlay()
        readyToPlayExpectation = expectation(description: "openVideo")
        waitForExpectations(timeout: 10)
        if play.isReadyToPlay {
            play.play()
        }
        play.shutdown()
    }

    @MainActor
    func testFrameHandoffWaitsForTheCandidateFrame() {
        XCTAssertEqual(KSAVPlayer.frameHandoffAction(hasFirstFrame: false, elapsed: 0.5, timeout: 2), .wait)
        XCTAssertEqual(KSAVPlayer.frameHandoffAction(hasFirstFrame: true, elapsed: 0.5, timeout: 2), .revealFirstFrame)
    }

    @MainActor
    func testFrameHandoffHasABoundedVisualTimeout() {
        XCTAssertEqual(KSAVPlayer.frameHandoffAction(hasFirstFrame: false, elapsed: 1.99, timeout: 2), .wait)
        XCTAssertEqual(KSAVPlayer.frameHandoffAction(hasFirstFrame: false, elapsed: 2, timeout: 2), .revealOnTimeout)
    }

    func testDetailedSourceSwitchResultPreservesTheOriginalError() {
        let error = NSError(domain: "audio-test", code: 17, userInfo: [NSLocalizedDescriptionKey: "candidate failed"])
        let result = KSAVSourceSwitchResult.failed(error)

        XCTAssertFalse(result.isCommitted)
        XCTAssertTrue(result.diagnosticDescription.contains("audio-test/17"))
        XCTAssertTrue(result.diagnosticDescription.contains("candidate failed"))
        XCTAssertTrue(KSAVSourceSwitchResult.committed.isCommitted)
    }

    @MainActor
    func testSourceSwitchPrewarmsCandidateWithoutTouchingActiveQueue() throws {
        let activeURL = try XCTUnwrap(URL(string: "https://example.com/active.m3u8"))
        let candidateURL = try XCTUnwrap(URL(string: "https://example.com/candidate.m3u8"))
        let activeItem = AVPlayerItem(url: activeURL)
        let candidateItem = AVPlayerItem(url: candidateURL)
        let activeQueue = AVQueuePlayer(items: [activeItem])

        let prewarmingPlayer = KSAVPlayer.makeSourceSwitchPrewarmingPlayer(item: candidateItem)

        XCTAssertTrue(activeQueue.currentItem === activeItem)
        XCTAssertFalse(activeQueue.items().contains(where: { $0 === candidateItem }))
        XCTAssertTrue(prewarmingPlayer.currentItem === candidateItem)
        XCTAssertTrue(prewarmingPlayer.isMuted)
    }

    @MainActor
    func testFreshItemFromPrewarmedAssetCanJoinTheActiveQueue() throws {
        let activeURL = try XCTUnwrap(URL(string: "https://example.com/active.m3u8"))
        let candidateURL = try XCTUnwrap(URL(string: "https://example.com/candidate.m3u8"))
        let activeItem = AVPlayerItem(url: activeURL)
        let activeQueue = AVQueuePlayer(items: [activeItem])
        let candidateAsset = AVURLAsset(url: candidateURL)
        let probeItem = AVPlayerItem(asset: candidateAsset)
        let prewarmingPlayer = KSAVPlayer.makeSourceSwitchPrewarmingPlayer(item: probeItem)
        let promotionItem = AVPlayerItem(asset: candidateAsset)

        XCTAssertFalse(activeQueue.canInsert(probeItem, after: activeItem))
        XCTAssertTrue(activeQueue.canInsert(promotionItem, after: activeItem))
        XCTAssertTrue(activeQueue.currentItem === activeItem)
        XCTAssertEqual(activeQueue.items().count, 1)
        _ = prewarmingPlayer
    }

    @MainActor
    func testPlaybackNotificationsOnlyBelongToTheCurrentItem() throws {
        let activeURL = try XCTUnwrap(URL(string: "https://example.com/active.m3u8"))
        let staleURL = try XCTUnwrap(URL(string: "https://example.com/stale.m3u8"))
        let activeItem = AVPlayerItem(url: activeURL)
        let staleItem = AVPlayerItem(url: staleURL)

        XCTAssertTrue(KSAVPlayer.shouldHandlePlaybackNotification(item: activeItem, currentItem: activeItem))
        XCTAssertFalse(KSAVPlayer.shouldHandlePlaybackNotification(item: staleItem, currentItem: activeItem))
        XCTAssertFalse(KSAVPlayer.shouldHandlePlaybackNotification(item: nil, currentItem: activeItem))
    }

    @MainActor
    func testOwnershipTransferCommitsAsSoonAsInsertionIsAllowed() {
        XCTAssertEqual(
            KSAVPlayer.sourceOwnershipTransferAction(
                canInsert: true,
                currentItemMatches: true,
                generationMatches: true,
                elapsed: 0,
                timeout: 1
            ),
            .commit
        )
    }

    @MainActor
    func testOwnershipTransferRetriesUntilItsBoundedTimeout() {
        XCTAssertEqual(
            KSAVPlayer.sourceOwnershipTransferAction(
                canInsert: false,
                currentItemMatches: true,
                generationMatches: true,
                elapsed: 0.5,
                timeout: 1
            ),
            .retry
        )
        XCTAssertEqual(
            KSAVPlayer.sourceOwnershipTransferAction(
                canInsert: false,
                currentItemMatches: true,
                generationMatches: true,
                elapsed: 1,
                timeout: 1
            ),
            .timedOut
        )
    }

    @MainActor
    func testOwnershipTransferCancelsForAChangedItemOrStaleGeneration() {
        XCTAssertEqual(
            KSAVPlayer.sourceOwnershipTransferAction(
                canInsert: false,
                currentItemMatches: false,
                generationMatches: true,
                elapsed: 0,
                timeout: 1
            ),
            .cancelled
        )
        XCTAssertEqual(
            KSAVPlayer.sourceOwnershipTransferAction(
                canInsert: false,
                currentItemMatches: true,
                generationMatches: false,
                elapsed: 0,
                timeout: 1
            ),
            .cancelled
        )
    }
}

extension KSAVPlayerTest: MediaPlayerDelegate {
    func readyToPlay(player _: some MediaPlayerProtocol) {
        readyToPlayExpectation?.fulfill()
    }

    func changeLoadState(player _: some MediaPlayerProtocol) {}

    func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}

    func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

    func finish(player _: some MediaPlayerProtocol, error: Error?) {
        if error != nil {
            readyToPlayExpectation?.fulfill()
        }
    }
}
