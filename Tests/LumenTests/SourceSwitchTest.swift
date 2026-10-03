import AVFoundation
import Combine
import CoreGraphics
@testable import Lumen
import XCTest

private final class AudioSelectionFakeTrack: MediaPlayerTrack {
    let trackID: Int32
    let name: String
    let languageCode: String?
    let mediaType = AVMediaType.audio
    var nominalFrameRate: Float = 0
    let bitRate: Int64 = 0
    let bitDepth: Int32 = 0
    var isEnabled: Bool
    let isImageSubtitle = false
    let rotation: Int16 = 0
    let dovi: DOVIDecoderConfigurationRecord? = nil
    let fieldOrder = FFmpegFieldOrder.unknown
    let formatDescription: CMFormatDescription? = nil
    var description: String { name }

    init(trackID: Int32, name: String, isEnabled: Bool = false) {
        self.trackID = trackID
        self.name = name
        languageCode = name
        self.isEnabled = isEnabled
    }
}

class SourceSwitchFakeEngineBase {
    weak var delegate: MediaPlayerDelegate?
    private(set) var url: URL
    private(set) var options: KSOptions
    private(set) var replacedURLs = [URL]()
    private(set) var prepareToPlayCount = 0
    private(set) var shutdownCount = 0
    private(set) var seekTimes = [TimeInterval]()
    var completesSeekImmediately = true
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
    private var pendingSeekCompletions = [((Bool) -> Void)]()

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

    func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        seekTimes.append(time)
        playbackState = .seeking
        if completesSeekImmediately {
            completion(true)
        } else {
            pendingSeekCompletions.append(completion)
        }
    }

    func completeSeek(at index: Int = 0, success: Bool) {
        guard pendingSeekCompletions.indices.contains(index) else { return }
        let completion = pendingSeekCompletions.remove(at: index)
        completion(success)
    }

    func thumbnailImageAtCurrentTime() async -> CGImage? { nil }

    func tracks(mediaType _: AVFoundation.AVMediaType) -> [MediaPlayerTrack] { [] }

    func select(track _: some MediaPlayerTrack) {}
}

final class ColdOnlyFakeEngine: SourceSwitchFakeEngineBase, MediaPlayerProtocol {}

final class FallbackFakeEngine: SourceSwitchFakeEngineBase, MediaPlayerProtocol {}

final class AsyncAudioFakeEngine: SourceSwitchFakeEngineBase, MediaPlayerProtocol, AsyncAudioTrackSelecting {
    private(set) var audioSelectionRequests = [Int32]()
    private var audioSelectionCompletion: ((ProAVAudioSelectionResult) -> Void)?

    func selectAudioTrack(trackID: Int32, completion: @escaping (ProAVAudioSelectionResult) -> Void) {
        audioSelectionRequests.append(trackID)
        audioSelectionCompletion = completion
    }

    func completeAudioSelection(_ result: ProAVAudioSelectionResult) {
        let completion = audioSelectionCompletion
        audioSelectionCompletion = nil
        completion?(result)
    }
}

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

    @MainActor
    func testCoordinatorPublishesAudioSelectionAndBlocksRepeatedRequests() throws {
        KSOptions.firstPlayerType = AsyncAudioFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let engine = try XCTUnwrap(layer.player as? AsyncAudioFakeEngine)
        let coordinator = KSVideoPlayer.Coordinator()
        coordinator.playerLayer = layer
        let english = AudioSelectionFakeTrack(trackID: 2, name: "en")
        let spanish = AudioSelectionFakeTrack(trackID: 3, name: "es")

        coordinator.selectAudioTrack(english)

        XCTAssertEqual(coordinator.audioTrackSelectionState, .switching(trackID: 2))
        XCTAssertEqual(engine.audioSelectionRequests, [2])

        coordinator.selectAudioTrack(spanish)

        XCTAssertEqual(coordinator.audioTrackSelectionState, .switching(trackID: 2))
        XCTAssertEqual(engine.audioSelectionRequests, [2])

        engine.completeAudioSelection(.committed)
        drainMainQueue()

        XCTAssertEqual(coordinator.audioTrackSelectionState, .idle)

        coordinator.selectAudioTrack(spanish)
        XCTAssertEqual(coordinator.audioTrackSelectionState, .switching(trackID: 3))
        engine.completeAudioSelection(.failed)
        drainMainQueue()

        XCTAssertEqual(coordinator.audioTrackSelectionState, .idle)
    }

    @MainActor
    func testAssigningTheInitialPlayerLayerDoesNotRepublishIdleAudioSelection() throws {
        KSOptions.firstPlayerType = AsyncAudioFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let coordinator = KSVideoPlayer.Coordinator()
        var publishedStates = [AudioTrackSelectionState]()
        let observation = coordinator.$audioTrackSelectionState.dropFirst().sink { state in
            publishedStates.append(state)
        }

        coordinator.playerLayer = layer

        XCTAssertTrue(publishedStates.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testStaleAudioSelectionCompletionCannotClearTheNewPlayerState() throws {
        KSOptions.firstPlayerType = AsyncAudioFakeEngine.self
        let urlA = try XCTUnwrap(URL(string: "https://example.com/a.mkv"))
        let urlB = try XCTUnwrap(URL(string: "https://example.com/b.mkv"))
        let oldLayer = KSPlayerLayer(url: urlA, isAutoPlay: false, options: KSOptions())
        let oldEngine = try XCTUnwrap(oldLayer.player as? AsyncAudioFakeEngine)
        let newLayer = KSPlayerLayer(url: urlB, isAutoPlay: false, options: KSOptions())
        let newEngine = try XCTUnwrap(newLayer.player as? AsyncAudioFakeEngine)
        let coordinator = KSVideoPlayer.Coordinator()
        let english = AudioSelectionFakeTrack(trackID: 2, name: "en")
        let spanish = AudioSelectionFakeTrack(trackID: 3, name: "es")

        coordinator.playerLayer = oldLayer
        coordinator.selectAudioTrack(english)
        coordinator.playerLayer = newLayer
        coordinator.selectAudioTrack(spanish)

        oldEngine.completeAudioSelection(.failed)
        drainMainQueue()

        XCTAssertEqual(coordinator.audioTrackSelectionState, .switching(trackID: 3))

        newEngine.completeAudioSelection(.committed)
        drainMainQueue()

        XCTAssertEqual(coordinator.audioTrackSelectionState, .idle)
    }

    @MainActor
    func testPausedSeekFinishesPaused() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let engine = try XCTUnwrap(layer.player as? ColdOnlyFakeEngine)
        engine.isReadyToPlay = true
        layer.readyToPlay(player: engine)

        var result: Bool?
        layer.seek(time: 42, autoPlay: false) { result = $0 }

        XCTAssertEqual(result, true)
        XCTAssertEqual(engine.seekTimes, [42])
        XCTAssertEqual(engine.playbackState, .paused)
        XCTAssertEqual(layer.state, .paused)
    }

    @MainActor
    func testSeekToZeroWithAutoPlayFinishesPlaying() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let engine = try XCTUnwrap(layer.player as? ColdOnlyFakeEngine)
        engine.isReadyToPlay = true
        engine.loadState = .playable
        layer.readyToPlay(player: engine)

        var result: Bool?
        layer.seek(time: 0, autoPlay: true) { result = $0 }

        XCTAssertEqual(result, true)
        XCTAssertEqual(engine.seekTimes, [0])
        XCTAssertEqual(engine.playbackState, .playing)
        XCTAssertEqual(layer.state, .bufferFinished)
    }

    @MainActor
    func testStaleSeekCompletionCannotOverrideTheLatestIntent() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let engine = try XCTUnwrap(layer.player as? ColdOnlyFakeEngine)
        engine.isReadyToPlay = true
        engine.completesSeekImmediately = false
        layer.readyToPlay(player: engine)
        var results = [Bool]()

        layer.seek(time: 10, autoPlay: true) { results.append($0) }
        layer.seek(time: 20, autoPlay: false) { results.append($0) }
        XCTAssertEqual(results, [false])
        engine.completeSeek(at: 1, success: true)

        XCTAssertEqual(results, [false, true])
        XCTAssertEqual(engine.playbackState, .paused)
        XCTAssertEqual(layer.state, .paused)

        engine.completeSeek(success: true)

        XCTAssertEqual(results, [false, true])
        XCTAssertEqual(engine.seekTimes, [10, 20])
        XCTAssertEqual(engine.playbackState, .paused)
        XCTAssertEqual(layer.state, .paused)
    }

    @MainActor
    func testTransportChangeDuringSeekWinsOverOriginalAutoPlayIntent() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let engine = try XCTUnwrap(layer.player as? ColdOnlyFakeEngine)
        engine.isReadyToPlay = true
        engine.completesSeekImmediately = false
        layer.readyToPlay(player: engine)

        layer.seek(time: 30, autoPlay: true) { _ in }
        layer.pause()
        engine.completeSeek(success: true)

        XCTAssertEqual(engine.playbackState, .paused)
        XCTAssertEqual(layer.state, .paused)
    }

    @MainActor
    func testPausedFailurePreparesFallbackAndRestoresPendingSeek() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        KSOptions.secondPlayerType = FallbackFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let primary = try XCTUnwrap(layer.player as? ColdOnlyFakeEngine)
        primary.isReadyToPlay = true
        primary.completesSeekImmediately = false
        layer.readyToPlay(player: primary)
        var seekResult: Bool?
        layer.seek(time: 75, autoPlay: false) { seekResult = $0 }

        layer.finish(player: primary, error: NSError(domain: "test", code: 1))

        let fallback = try XCTUnwrap(layer.player as? FallbackFakeEngine)
        XCTAssertEqual(seekResult, false)
        XCTAssertEqual(fallback.prepareToPlayCount, 1)
        XCTAssertEqual(layer.state, .preparing)
        fallback.isReadyToPlay = true
        layer.readyToPlay(player: fallback)

        XCTAssertEqual(fallback.seekTimes, [75])
        XCTAssertEqual(fallback.playbackState, .paused)
        XCTAssertEqual(layer.state, .paused)
    }

    @MainActor
    func testFiniteFallbackWaitsUntilItBecomesSeekableBeforeRestoringPosition() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        KSOptions.secondPlayerType = FallbackFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let primary = try XCTUnwrap(layer.player as? ColdOnlyFakeEngine)
        primary.currentPlaybackTime = 50
        layer.finish(player: primary, error: NSError(domain: "test", code: 3))

        let fallback = try XCTUnwrap(layer.player as? FallbackFakeEngine)
        fallback.isReadyToPlay = true
        fallback.duration = 120
        fallback.seekable = false
        layer.readyToPlay(player: fallback)

        XCTAssertEqual(fallback.seekTimes, [])
        XCTAssertEqual(layer.state, .readyToPlay)

        fallback.seekable = true
        fallback.loadState = .playable
        layer.changeLoadState(player: fallback)

        XCTAssertEqual(fallback.seekTimes, [50])
        XCTAssertEqual(fallback.playbackState, .paused)
        XCTAssertEqual(layer.state, .paused)
    }

    @MainActor
    func testAutoPlayingFailurePreparesFallbackAndResumesPendingSeek() throws {
        KSOptions.firstPlayerType = ColdOnlyFakeEngine.self
        KSOptions.secondPlayerType = FallbackFakeEngine.self
        let url = try XCTUnwrap(URL(string: "https://example.com/movie.mkv"))
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        let primary = try XCTUnwrap(layer.player as? ColdOnlyFakeEngine)
        primary.isReadyToPlay = true
        primary.completesSeekImmediately = false
        layer.readyToPlay(player: primary)
        layer.seek(time: 90, autoPlay: true) { _ in }

        layer.finish(player: primary, error: NSError(domain: "test", code: 2))

        let fallback = try XCTUnwrap(layer.player as? FallbackFakeEngine)
        XCTAssertEqual(fallback.prepareToPlayCount, 1)
        fallback.isReadyToPlay = true
        fallback.loadState = .playable
        layer.readyToPlay(player: fallback)

        XCTAssertEqual(fallback.seekTimes, [90])
        XCTAssertEqual(fallback.playbackState, .playing)
        XCTAssertEqual(layer.state, .bufferFinished)
    }
}
