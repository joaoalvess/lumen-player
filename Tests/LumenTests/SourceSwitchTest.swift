import AVFoundation
import CoreGraphics
@testable import Lumen
import XCTest

class SourceSwitchFakeEngineBase {
    weak var delegate: MediaPlayerDelegate?
    private(set) var url: URL
    private(set) var options: KSOptions
    private(set) var replacedURLs = [URL]()
    private(set) var prepareToPlayCount = 0
    private(set) var shutdownCount = 0
    var isReadyToPlay = false
    var duration: TimeInterval = 0
    var fileSize: Double = 0
    var naturalSize: CGSize = .zero
    var chapters: [Chapter] = []
    var currentPlaybackTime: TimeInterval = 0
    var playableTime: TimeInterval = 0
    var playbackState = MediaPlaybackState.idle
    var loadState = MediaLoadState.idle
    var seekable = true
    var isMuted = false
    var allowsExternalPlayback = false
    var usesExternalPlaybackWhileExternalScreenIsActive = false
    var isExternalPlaybackActive = false
    var playbackRate: Float = 1
    var playbackVolume: Float = 1
    var contentMode = UIViewContentMode.scaleAspectFit
    var view: UIView? { nil }
    var subtitleDataSouce: SubtitleDataSouce? { nil }
    var dynamicInfo: DynamicInfo? { nil }
    var isPlaying: Bool { playbackState == .playing }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    var playbackCoordinator: AVPlaybackCoordinator { AVPlayer().playbackCoordinator }

    @available(tvOS 14.0, *)
    var pipController: KSPictureInPictureController? { nil }

    required init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
    }

    func prepareToPlay() {
        prepareToPlayCount += 1
    }

    func shutdown() {
        shutdownCount += 1
        isReadyToPlay = false
    }

    func replace(url: URL, options: KSOptions) {
        replacedURLs.append(url)
        self.url = url
        self.options = options
    }

    func play() {
        playbackState = .playing
    }

    func pause() {
        playbackState = .paused
    }

    func enterBackground() {}

    func enterForeground() {}

    func seek(time _: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        completion(true)
    }

    func thumbnailImageAtCurrentTime() async -> CGImage? { nil }

    func tracks(mediaType _: AVFoundation.AVMediaType) -> [MediaPlayerTrack] { [] }

    func select(track _: some MediaPlayerTrack) {}
}

final class ColdOnlyFakeEngine: SourceSwitchFakeEngineBase, MediaPlayerProtocol {}

final class SwitchableFakeEngine: SourceSwitchFakeEngineBase, MediaPlayerProtocol {
    private(set) var switchRequests = [URL]()
    private(set) var cancelCount = 0
    private var pendingSwitchCompletion: ((Bool) -> Void)?

    func switchSource(url: URL, options _: KSOptions, completion: @escaping ((Bool) -> Void)) {
        let previous = pendingSwitchCompletion
        pendingSwitchCompletion = nil
        previous?(false)
        switchRequests.append(url)
        pendingSwitchCompletion = completion
    }

    func cancelSourceSwitch() {
        guard let completion = pendingSwitchCompletion else { return }
        pendingSwitchCompletion = nil
        cancelCount += 1
        completion(false)
    }

    func completePendingSwitch(success: Bool) {
        let completion = pendingSwitchCompletion
        pendingSwitchCompletion = nil
        completion?(success)
    }
}

@MainActor
final class LayerStateSpy: KSPlayerLayerDelegate {
    private(set) var states = [KSPlayerState]()

    func player(layer _: KSPlayerLayer, state: KSPlayerState) {
        states.append(state)
    }

    func player(layer _: KSPlayerLayer, currentTime _: TimeInterval, totalTime _: TimeInterval) {}

    func player(layer _: KSPlayerLayer, finish _: Error?) {}

    func player(layer _: KSPlayerLayer, bufferedCount _: Int, consumeTime _: TimeInterval) {}
}

class SourceSwitchTest: XCTestCase {
    private var savedFirstPlayerType: MediaPlayerProtocol.Type?
    private var savedSecondPlayerType: MediaPlayerProtocol.Type?

    override func setUp() {
        super.setUp()
        savedFirstPlayerType = KSOptions.firstPlayerType
        savedSecondPlayerType = KSOptions.secondPlayerType
    }

    override func tearDown() {
        if let savedFirstPlayerType {
            KSOptions.firstPlayerType = savedFirstPlayerType
        }
        KSOptions.secondPlayerType = savedSecondPlayerType
        super.tearDown()
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 2)
    }

    @MainActor
    func testDefaultSwitchSourceFallsBackToColdPath() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        let urlA = try XCTUnwrap(URL(string: "https://example.com/a.m3u8"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/b.m3u8"))
        let options = KSOptions()
        let layer = KSPlayerLayer(url: urlA, isAutoPlay: false, options: options)
        guard let engine = layer.player as? ColdOnlyFakeEngine else {
            XCTFail("expected the fake engine")
            return
        }
        engine.isReadyToPlay = true
        layer.readyToPlay(player: engine)
        engine.loadState = .playable
        layer.play()
        var results = [Bool]()
        layer.switchSource(url: urlB, options: options) { success in
            results.append(success)
        }
        drainMainQueue()
        XCTAssertEqual(engine.replacedURLs, [urlB])
        XCTAssertEqual(engine.prepareToPlayCount, 1)
        XCTAssertEqual(engine.shutdownCount, 1)
        XCTAssertEqual(results, [false])
        XCTAssertEqual(layer.url, urlB)
        XCTAssertNil(layer.pendingSourceSwitchURL)
        XCTAssertEqual(layer.state, .preparing)
    }

    @MainActor
    func testSwitchSourceKeepsStateAndSkipsPreparing() throws {
        KSOptions.firstPlayerType = SwitchableFakeEngine.self
        let urlA = try XCTUnwrap(URL(string: "https://example.com/a.m3u8"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/b.m3u8"))
        let options = KSOptions()
        let layer = KSPlayerLayer(url: urlA, isAutoPlay: false, options: options)
        guard let engine = layer.player as? SwitchableFakeEngine else {
            XCTFail("expected the fake engine")
            return
        }
        let spy = LayerStateSpy()
        layer.delegate = spy
        engine.isReadyToPlay = true
        layer.readyToPlay(player: engine)
        XCTAssertEqual(layer.state, .readyToPlay)
        var results = [Bool]()
        layer.switchSource(url: urlB, options: options) { success in
            results.append(success)
        }
        XCTAssertEqual(engine.switchRequests, [urlB])
        XCTAssertEqual(layer.url, urlA)
        XCTAssertEqual(layer.pendingSourceSwitchURL, urlB)
        XCTAssertEqual(layer.state, .readyToPlay)
        engine.completePendingSwitch(success: true)
        drainMainQueue()
        XCTAssertEqual(layer.url, urlB)
        XCTAssertNil(layer.pendingSourceSwitchURL)
        XCTAssertEqual(layer.state, .readyToPlay)
        XCTAssertEqual(engine.replacedURLs, [])
        XCTAssertEqual(engine.prepareToPlayCount, 0)
        XCTAssertEqual(engine.shutdownCount, 0)
        XCTAssertEqual(results, [true])
        XCTAssertFalse(spy.states.contains(.preparing))
    }

    @MainActor
    func testFailedSwitchSourceDegradesToColdPath() throws {
        KSOptions.firstPlayerType = SwitchableFakeEngine.self
        let urlA = try XCTUnwrap(URL(string: "https://example.com/a.m3u8"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/b.m3u8"))
        let options = KSOptions()
        let layer = KSPlayerLayer(url: urlA, isAutoPlay: false, options: options)
        guard let engine = layer.player as? SwitchableFakeEngine else {
            XCTFail("expected the fake engine")
            return
        }
        engine.isReadyToPlay = true
        layer.readyToPlay(player: engine)
        engine.loadState = .playable
        layer.play()
        XCTAssertEqual(layer.state, .bufferFinished)
        var results = [Bool]()
        layer.switchSource(url: urlB, options: options) { success in
            results.append(success)
        }
        engine.completePendingSwitch(success: false)
        drainMainQueue()
        XCTAssertEqual(results, [false])
        XCTAssertEqual(layer.url, urlB)
        XCTAssertNil(layer.pendingSourceSwitchURL)
        XCTAssertEqual(engine.replacedURLs, [urlB])
        XCTAssertEqual(engine.prepareToPlayCount, 1)
        XCTAssertEqual(layer.state, .preparing)
    }

    @MainActor
    func testNewSwitchSupersedesPendingCandidate() throws {
        KSOptions.firstPlayerType = SwitchableFakeEngine.self
        let urlA = try XCTUnwrap(URL(string: "https://example.com/a.m3u8"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/b.m3u8"))
        let urlC = try XCTUnwrap(URL(string: "https://example.com/c.m3u8"))
        let options = KSOptions()
        let layer = KSPlayerLayer(url: urlA, isAutoPlay: false, options: options)
        guard let engine = layer.player as? SwitchableFakeEngine else {
            XCTFail("expected the fake engine")
            return
        }
        engine.isReadyToPlay = true
        layer.readyToPlay(player: engine)
        var results = [Bool]()
        layer.switchSource(url: urlB, options: options) { success in
            results.append(success)
        }
        layer.switchSource(url: urlC, options: options) { success in
            results.append(success)
        }
        XCTAssertEqual(engine.switchRequests, [urlB, urlC])
        engine.completePendingSwitch(success: true)
        drainMainQueue()
        XCTAssertEqual(layer.url, urlC)
        XCTAssertNil(layer.pendingSourceSwitchURL)
        XCTAssertEqual(engine.replacedURLs, [])
        XCTAssertEqual(results, [false, true])
        XCTAssertEqual(layer.state, .readyToPlay)
    }

    @MainActor
    func testReselectingCurrentSourceCancelsPendingCandidate() throws {
        KSOptions.firstPlayerType = SwitchableFakeEngine.self
        let urlA = try XCTUnwrap(URL(string: "https://example.com/a.m3u8"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/b.m3u8"))
        let options = KSOptions()
        let layer = KSPlayerLayer(url: urlA, isAutoPlay: false, options: options)
        guard let engine = layer.player as? SwitchableFakeEngine else {
            XCTFail("expected the fake engine")
            return
        }
        engine.isReadyToPlay = true
        layer.readyToPlay(player: engine)
        var candidateResults = [Bool]()
        layer.switchSource(url: urlB, options: options) { success in
            candidateResults.append(success)
        }
        var reselectResults = [Bool]()
        layer.switchSource(url: urlA, options: options) { success in
            reselectResults.append(success)
        }
        drainMainQueue()
        XCTAssertEqual(engine.switchRequests, [urlB])
        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertEqual(reselectResults, [true])
        XCTAssertEqual(candidateResults, [false])
        XCTAssertEqual(layer.url, urlA)
        XCTAssertNil(layer.pendingSourceSwitchURL)
        XCTAssertEqual(engine.replacedURLs, [])
        XCTAssertEqual(engine.shutdownCount, 0)
        XCTAssertEqual(layer.state, .readyToPlay)
    }

    @MainActor
    func testCoalescedSwitchRequestsShareTheCandidateResult() throws {
        KSOptions.firstPlayerType = SwitchableFakeEngine.self
        let urlA = try XCTUnwrap(URL(string: "https://example.com/a.m3u8"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/b.m3u8"))
        let options = KSOptions()
        let layer = KSPlayerLayer(url: urlA, isAutoPlay: false, options: options)
        guard let engine = layer.player as? SwitchableFakeEngine else {
            XCTFail("expected the fake engine")
            return
        }
        engine.isReadyToPlay = true
        layer.readyToPlay(player: engine)
        var results = [Bool]()
        layer.switchSource(url: urlB, options: options) { success in
            results.append(success)
        }
        layer.switchSource(url: urlB, options: options) { success in
            results.append(success)
        }
        XCTAssertEqual(engine.switchRequests, [urlB])
        engine.completePendingSwitch(success: true)
        drainMainQueue()
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(layer.url, urlB)
        XCTAssertNil(layer.pendingSourceSwitchURL)
    }
}
