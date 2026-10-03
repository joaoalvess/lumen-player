import AVFoundation
import AVKit
#if canImport(UIKit)
import UIKit
#else
import AppKit

public typealias UIImage = NSImage
#endif
import Combine
import CoreGraphics

enum KSAVSourceSwitchResult {
    case committed
    case failed(NSError?)
    case timedOut
    case cancelled

    var isCommitted: Bool {
        if case .committed = self {
            return true
        }
        return false
    }

    var diagnosticDescription: String {
        switch self {
        case .committed:
            return "committed"
        case let .failed(error):
            guard let error else { return "failed" }
            return "failed error=\(error.domain)/\(error.code) \(error.localizedDescription)"
        case .timedOut:
            return "timed-out"
        case .cancelled:
            return "cancelled"
        }
    }
}

enum KSAVFrameHandoffAction: Equatable {
    case wait
    case revealFirstFrame
    case revealOnTimeout
}

enum KSAVSourceOwnershipTransferAction: Equatable {
    case commit
    case retry
    case timedOut
    case cancelled
}

public final class KSAVPlayerView: UIView {
    public let player = AVQueuePlayer()
    private let freezeFrameLayer = CALayer()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        #if !canImport(UIKit)
        layer = AVPlayerLayer()
        #endif
        playerLayer.player = player
        player.automaticallyWaitsToMinimizeStalling = false
        freezeFrameLayer.isHidden = true
        freezeFrameLayer.masksToBounds = true
        #if canImport(UIKit)
        layer.addSublayer(freezeFrameLayer)
        #else
        layer?.addSublayer(freezeFrameLayer)
        #endif
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var contentMode: UIViewContentMode {
        get {
            switch playerLayer.videoGravity {
            case .resize:
                return .scaleToFill
            case .resizeAspect:
                return .scaleAspectFit
            case .resizeAspectFill:
                return .scaleAspectFill
            default:
                return .scaleAspectFit
            }
        }
        set {
            switch newValue {
            case .scaleToFill:
                playerLayer.videoGravity = .resize
                freezeFrameLayer.contentsGravity = .resize
            case .scaleAspectFit:
                playerLayer.videoGravity = .resizeAspect
                freezeFrameLayer.contentsGravity = .resizeAspect
            case .scaleAspectFill:
                playerLayer.videoGravity = .resizeAspectFill
                freezeFrameLayer.contentsGravity = .resizeAspectFill
            case .center:
                playerLayer.videoGravity = .resizeAspect
                freezeFrameLayer.contentsGravity = .resizeAspect
            default:
                break
            }
        }
    }

    #if canImport(UIKit)
    override public func layoutSubviews() {
        super.layoutSubviews()
        freezeFrameLayer.frame = bounds
    }
    #else
    override public func layout() {
        super.layout()
        freezeFrameLayer.frame = bounds
    }
    #endif

    fileprivate func showFreezeFrame(_ image: CGImage) {
        freezeFrameLayer.contents = image
        freezeFrameLayer.isHidden = false
    }

    fileprivate func hideFreezeFrame() {
        freezeFrameLayer.isHidden = true
        freezeFrameLayer.contents = nil
    }

    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVPlayerLayer.self }
    #endif
    fileprivate var playerLayer: AVPlayerLayer {
        // swiftlint:disable force_cast
        layer as! AVPlayerLayer
        // swiftlint:enable force_cast
    }
}

@MainActor
public class KSAVPlayer {
    private var cancellable: AnyCancellable?
    private var options: KSOptions {
        didSet {
            player.currentItem?.preferredForwardBufferDuration = options.preferredForwardBufferDuration
            cancellable = options.$preferredForwardBufferDuration.sink { [weak self] newValue in
                self?.player.currentItem?.preferredForwardBufferDuration = newValue
            }
        }
    }

    private let playerView = KSAVPlayerView()
    private var urlAsset: AVURLAsset
    private var cacheResourceLoader: DiskCacheResourceLoader?
    private var shouldSeekTo = TimeInterval(0)
    private var playerLooper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var loadedTimeRangesObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var bufferFullObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var loopCountObservation: NSKeyValueObservation?
    private var loopStatusObservation: NSKeyValueObservation?
    private var mediaPlayerTracks = [AVMediaPlayerTrack]()
    private let embedSubtitleDataSouce = AVSubtitleDataSouce()
    static var sourceSwitchTimeout = TimeInterval(10)
    static var sourceOwnershipTransferTimeout = TimeInterval(1)
    static var sourceOwnershipTransferRetryInterval = TimeInterval(1.0 / 60.0)
    static var frameHandoffTimeout = TimeInterval(2)
    static var restoreSeekTimeout = TimeInterval(2)
    private static let framePollInterval = TimeInterval(1.0 / 30.0)
    private struct PendingSourceSwitch {
        var item: AVPlayerItem
        let asset: AVURLAsset
        let loader: DiskCacheResourceLoader?
        var prewarmingPlayer: AVPlayer?
        let options: KSOptions
        let resumeShift: TimeInterval
        var videoOutput: AVPlayerItemVideoOutput
        let diagnosticLabel: String
        let startedAt: TimeInterval
        let completion: (KSAVSourceSwitchResult) -> Void
        var statusObservation: NSKeyValueObservation?
        var timeout: DispatchWorkItem?
    }

    private struct ActiveFrameHandoff {
        let generation: Int
        let item: AVPlayerItem
        let videoOutput: AVPlayerItemVideoOutput
        let diagnosticLabel: String
        let startedAt: TimeInterval
    }

    private struct ActiveSourceOwnershipTransfer {
        let generation: Int
        let pending: PendingSourceSwitch
        let currentItem: AVPlayerItem
        let startedAt: TimeInterval
        var attempts: Int
    }

    private struct ActiveSourceCommit {
        let generation: Int
        let pending: PendingSourceSwitch
    }

    private let sourceSwitchLock = NSLock()
    private var pendingSourceSwitch: PendingSourceSwitch?
    private var activeSourceOwnershipTransfer: ActiveSourceOwnershipTransfer?
    private var sourceOwnershipTransferGeneration = 0
    private var currentVideoOutput: AVPlayerItemVideoOutput?
    private var sourceCommitGeneration = 0
    private var activeSourceCommit: ActiveSourceCommit?
    private var frameHandoffGeneration = 0
    private var activeFrameHandoff: ActiveFrameHandoff?
    var isCommittingSourceSwitch: Bool {
        activeSourceCommit != nil
    }

    private var error: Error? {
        didSet {
            if let error {
                delegate?.finish(player: self, error: error)
            }
        }
    }

    private lazy var _pipController: Any? = {
        if #available(tvOS 14.0, *) {
            let pip = KSPictureInPictureController(playerLayer: playerView.playerLayer)
            return pip
        } else {
            return nil
        }
    }()

    @available(tvOS 14.0, *)
    public var pipController: KSPictureInPictureController? {
        _pipController as? KSPictureInPictureController
    }

    public var naturalSize: CGSize = .zero
    public let dynamicInfo: DynamicInfo? = nil
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator {
        playerView.player.playbackCoordinator
    }

    public private(set) var bufferingProgress = 0 {
        didSet {
            delegate?.changeBuffering(player: self, progress: bufferingProgress)
        }
    }

    public weak var delegate: MediaPlayerDelegate?
    public private(set) var duration: TimeInterval = 0
    public private(set) var fileSize: Double = 0
    public private(set) var playableTime: TimeInterval = 0
    public let chapters: [Chapter] = []
    public var playbackRate: Float = 1 {
        didSet {
            if playbackState == .playing {
                player.rate = playbackRate
            }
        }
    }

    public var playbackVolume: Float = 1.0 {
        didSet {
            if player.volume != playbackVolume {
                player.volume = playbackVolume
            }
        }
    }

    public private(set) var loadState = MediaLoadState.idle {
        didSet {
            if loadState != oldValue {
                playOrPause()
                if loadState == .loading || loadState == .idle {
                    bufferingProgress = 0
                }
            }
        }
    }

    public private(set) var playbackState = MediaPlaybackState.idle {
        didSet {
            if playbackState != oldValue {
                playOrPause()
                if playbackState == .finished {
                    delegate?.finish(player: self, error: nil)
                }
            }
        }
    }

    public private(set) var isReadyToPlay = false {
        didSet {
            if isReadyToPlay != oldValue {
                if isReadyToPlay {
                    options.readyTime = CACurrentMediaTime()
                    delegate?.readyToPlay(player: self)
                }
            }
        }
    }

    #if os(xrOS)
    public var allowsExternalPlayback = false
    public var usesExternalPlaybackWhileExternalScreenIsActive = false
    public let isExternalPlaybackActive = false
    #else
    public var allowsExternalPlayback: Bool {
        get {
            player.allowsExternalPlayback
        }
        set {
            player.allowsExternalPlayback = newValue
        }
    }

    #if os(macOS)
    public var usesExternalPlaybackWhileExternalScreenIsActive = false
    #else
    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool {
        get {
            player.usesExternalPlaybackWhileExternalScreenIsActive
        }
        set {
            player.usesExternalPlaybackWhileExternalScreenIsActive = newValue
        }
    }
    #endif

    public var isExternalPlaybackActive: Bool {
        player.isExternalPlaybackActive
    }
    #endif

    public required init(url: URL, options: KSOptions) {
        KSOptions.setAudioSession()
        let (asset, loader) = KSAVPlayer.makeAsset(url: url, options: options)
        urlAsset = asset
        cacheResourceLoader = loader
        self.options = options
        itemObservation = player.observe(\.currentItem) { [weak self] player, _ in
            guard let self else { return }
            self.observer(playerItem: player.currentItem)
        }
    }

    private static func makeAsset(url: URL, options: KSOptions) -> (AVURLAsset, DiskCacheResourceLoader?) {
        if let directory = options.diskCacheDirectory,
           let assetURL = DiskCacheResourceLoader.assetURL(for: url),
           let loader = DiskCacheResourceLoader(url: url, directory: directory, key: options.diskCacheKey(for: url), maxBytes: options.diskCacheMaxBytes, headers: options.diskCacheHTTPHeaders())
        {
            let asset = AVURLAsset(url: assetURL, options: options.avOptions)
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            return (asset, loader)
        }
        return (AVURLAsset(url: url, options: options.avOptions), nil)
    }

    private static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    }

    static func makeSourceSwitchPrewarmingPlayer(item: AVPlayerItem) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        return player
    }

    static func shouldHandlePlaybackNotification(item: AVPlayerItem?, currentItem: AVPlayerItem?) -> Bool {
        guard let item, let currentItem else { return false }
        return item === currentItem
    }

    static func sourceOwnershipTransferAction(
        canInsert: Bool,
        currentItemMatches: Bool,
        generationMatches: Bool,
        elapsed: TimeInterval,
        timeout: TimeInterval
    ) -> KSAVSourceOwnershipTransferAction {
        guard generationMatches, currentItemMatches else { return .cancelled }
        if canInsert {
            return .commit
        }
        if elapsed >= timeout {
            return .timedOut
        }
        return .retry
    }

    static func frameHandoffAction(hasFirstFrame: Bool, elapsed: TimeInterval, timeout: TimeInterval) -> KSAVFrameHandoffAction {
        if hasFirstFrame {
            return .revealFirstFrame
        }
        if elapsed >= timeout {
            return .revealOnTimeout
        }
        return .wait
    }
}

extension KSAVPlayer {
    public var player: AVQueuePlayer { playerView.player }
    public var playerLayer: AVPlayerLayer { playerView.playerLayer }
    @objc private func moviePlayDidEnd(notification: Notification) {
        guard Self.shouldHandlePlaybackNotification(item: notification.object as? AVPlayerItem, currentItem: player.currentItem) else { return }
        if !options.isLoopPlay {
            playbackState = .finished
        }
    }

    @objc private func playerItemFailedToPlayToEndTime(notification: Notification) {
        guard Self.shouldHandlePlaybackNotification(item: notification.object as? AVPlayerItem, currentItem: player.currentItem) else { return }
        var playError: Error?
        if let userInfo = notification.userInfo {
            if let error = userInfo["error"] as? Error {
                playError = error
            } else if let error = userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError {
                playError = error
            } else if let errorCode = (userInfo["error"] as? NSNumber)?.intValue {
                playError = NSError(domain: "AVMoviePlayer", code: errorCode, userInfo: nil)
            }
        }
        delegate?.finish(player: self, error: playError)
    }

    private func updateStatus(item: AVPlayerItem) {
        if item.status == .readyToPlay {
            options.findTime = CACurrentMediaTime()
            mediaPlayerTracks = item.tracks.map {
                AVMediaPlayerTrack(track: $0)
            }
            let playableVideo = mediaPlayerTracks.first {
                $0.mediaType == .video && $0.isPlayable
            }
            if let playableVideo {
                naturalSize = playableVideo.naturalSize
            } else if !mediaPlayerTracks.isEmpty {
                error = NSError(errorCode: .videoTracksUnplayable)
                return
            }
            // 默认选择第一个声道
            let audioItemTracks = item.tracks.filter { $0.assetTrack?.mediaType.rawValue == AVMediaType.audio.rawValue }
            if let wantedIndex = options.wantedAudio(tracks: audioItemTracks.map { AVMediaPlayerTrack(track: $0) }),
               audioItemTracks.indices.contains(wantedIndex)
            {
                audioItemTracks.enumerated().forEach { $0.element.isEnabled = $0.offset == wantedIndex }
            } else {
                audioItemTracks.dropFirst().forEach { $0.isEnabled = false }
            }
            duration = item.duration.seconds
            let estimatedDataRates = item.tracks.compactMap { $0.assetTrack?.estimatedDataRate }
            fileSize = Double(estimatedDataRates.reduce(0, +)) * duration / 8
            embedSubtitleDataSouce.load(playerItem: item)
            isReadyToPlay = true
        } else if item.status == .failed {
            error = item.error
        }
    }

    private func updatePlayableDuration(item: AVPlayerItem) {
        let first = item.loadedTimeRanges.first { CMTimeRangeContainsTime($0.timeRangeValue, time: item.currentTime()) }
        if let first {
            playableTime = first.timeRangeValue.end.seconds
            guard playableTime > 0 else { return }
            let loadedTime = playableTime - currentPlaybackTime
            guard loadedTime > 0 else { return }
            bufferingProgress = Int(min(loadedTime * 100 / item.preferredForwardBufferDuration, 100))
            if bufferingProgress >= 100 {
                loadState = .playable
            }
        }
    }

    private func playOrPause() {
        if playbackState == .playing {
            if loadState == .playable {
                player.play()
                player.rate = playbackRate
            }
        } else {
            player.pause()
        }
        delegate?.changeLoadState(player: self)
    }

    private func replaceCurrentItem(playerItem: AVPlayerItem?) {
        player.currentItem?.cancelPendingSeeks()
        if options.isLoopPlay {
            loopCountObservation?.invalidate()
            loopStatusObservation?.invalidate()
            playerLooper?.disableLooping()
            guard let playerItem else {
                playerLooper = nil
                return
            }
            playerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
            loopCountObservation = playerLooper?.observe(\.loopCount) { [weak self] playerLooper, _ in
                guard let self else { return }
                self.delegate?.playBack(player: self, loopCount: playerLooper.loopCount)
            }
            loopStatusObservation = playerLooper?.observe(\.status) { [weak self] playerLooper, _ in
                guard let self else { return }
                if playerLooper.status == .failed {
                    self.error = playerLooper.error
                }
            }
        } else {
            player.replaceCurrentItem(with: playerItem)
        }
    }

    private func observer(playerItem: AVPlayerItem?) {
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        statusObservation?.invalidate()
        loadedTimeRangesObservation?.invalidate()
        bufferEmptyObservation?.invalidate()
        likelyToKeepUpObservation?.invalidate()
        bufferFullObservation?.invalidate()
        guard let playerItem else {
            currentVideoOutput = nil
            return
        }
        if let existingOutput = playerItem.outputs.first(where: { $0 is AVPlayerItemVideoOutput }) as? AVPlayerItemVideoOutput {
            currentVideoOutput = existingOutput
        } else {
            let videoOutput = Self.makeVideoOutput()
            playerItem.add(videoOutput)
            currentVideoOutput = videoOutput
        }
        NotificationCenter.default.addObserver(self, selector: #selector(moviePlayDidEnd), name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemFailedToPlayToEndTime), name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
        statusObservation = playerItem.observe(\.status) { [weak self] item, _ in
            guard let self else { return }
            self.updateStatus(item: item)
        }
        loadedTimeRangesObservation = playerItem.observe(\.loadedTimeRanges) { [weak self] item, _ in
            guard let self else { return }
            // 计算缓冲进度
            self.updatePlayableDuration(item: item)
        }

        let changeHandler: (AVPlayerItem, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] _, _ in
            guard let self else { return }
            // 在主线程更新进度
            if playerItem.isPlaybackBufferEmpty {
                self.loadState = .loading
            } else if playerItem.isPlaybackLikelyToKeepUp || playerItem.isPlaybackBufferFull {
                self.loadState = .playable
            }
        }
        bufferEmptyObservation = playerItem.observe(\.isPlaybackBufferEmpty, changeHandler: changeHandler)
        likelyToKeepUpObservation = playerItem.observe(\.isPlaybackLikelyToKeepUp, changeHandler: changeHandler)
        bufferFullObservation = playerItem.observe(\.isPlaybackBufferFull, changeHandler: changeHandler)
    }
}

extension KSAVPlayer: @preconcurrency MediaPlayerProtocol {
    public var subtitleDataSouce: SubtitleDataSouce? { embedSubtitleDataSouce }
    public var isPlaying: Bool { player.rate > 0 ? true : playbackState == .playing }
    public var view: UIView? { playerView }
    public var currentPlaybackTime: TimeInterval {
        get {
            if shouldSeekTo > 0 {
                return TimeInterval(shouldSeekTo)
            } else {
                // 防止卡主
                return isReadyToPlay ? player.currentTime().seconds : 0
            }
        }
        set {
            seek(time: newValue) { _ in
            }
        }
    }

    public var numberOfBytesTransferred: Int64 {
        guard let playerItem = player.currentItem, let accesslog = playerItem.accessLog(), let event = accesslog.events.first else {
            return 0
        }
        return event.numberOfBytesTransferred
    }

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        guard let playerItem = player.currentItem, isReadyToPlay else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            urlAsset.thumbnailImage(currentTime: playerItem.currentTime()) { result in
                continuation.resume(returning: result)
            }
        }
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        let time = max(time, 0)
        shouldSeekTo = time
        playbackState = .seeking
        runOnMainThread { [weak self] in
            self?.bufferingProgress = 0
        }
        let tolerance: CMTime = options.isAccurateSeek ? .zero : .positiveInfinity
        player.seek(to: CMTime(seconds: time), toleranceBefore: tolerance, toleranceAfter: tolerance) {
            [weak self] finished in
            guard let self else { return }
            self.shouldSeekTo = 0
            completion(finished)
        }
    }

    public func prepareToPlay() {
        KSLog("prepareToPlay \(self)")
        options.prepareTime = CACurrentMediaTime()
        runOnMainThread { [weak self] in
            guard let self else { return }
            self.bufferingProgress = 0
            let playerItem = AVPlayerItem(asset: self.urlAsset)
            self.options.openTime = CACurrentMediaTime()
            self.replaceCurrentItem(playerItem: playerItem)
            self.player.actionAtItemEnd = .pause
            self.player.volume = self.playbackVolume
        }
    }

    public func play() {
        KSLog("play \(self)")
        playbackState = .playing
    }

    public func pause() {
        KSLog("pause \(self)")
        playbackState = .paused
    }

    public func shutdown() {
        KSLog("shutdown \(self)")
        abandonPendingSourceSwitch(result: .cancelled)
        sourceCommitGeneration &+= 1
        cancelActiveSourceCommit()
        finishFrameHandoff(result: .cancelled, renderedFirstFrame: false)
        isReadyToPlay = false
        playbackState = .stopped
        loadState = .idle
        urlAsset.cancelLoading()
        replaceCurrentItem(playerItem: nil)
    }

    public func replace(url: URL, options: KSOptions) {
        KSLog("replaceUrl \(self)")
        shutdown()
        cacheResourceLoader?.close()
        let (asset, loader) = KSAVPlayer.makeAsset(url: url, options: options)
        urlAsset = asset
        cacheResourceLoader = loader
        self.options = options
    }

    public func switchSource(url: URL, options: KSOptions, completion: @escaping ((Bool) -> Void)) {
        switchSourceDetailed(url: url, options: options, resumeShift: 0, diagnosticLabel: "source-switch") { result in
            completion(result.isCommitted)
        }
    }

    func switchSourceDetailed(
        url: URL,
        options: KSOptions,
        resumeShift: TimeInterval,
        diagnosticLabel: String,
        completion: @escaping ((KSAVSourceSwitchResult) -> Void)
    ) {
        abandonPendingSourceSwitch(result: .cancelled)
        finishFrameHandoff(result: .committed, renderedFirstFrame: false)
        guard !options.isLoopPlay, playerLooper == nil, let currentItem = player.currentItem else {
            completion(.failed(NSError(description: "AVPlayer source switch is unavailable")))
            return
        }
        let (asset, loader) = KSAVPlayer.makeAsset(url: url, options: options)
        let candidate = AVPlayerItem(asset: asset)
        candidate.preferredForwardBufferDuration = options.preferredForwardBufferDuration
        let candidateVideoOutput = Self.makeVideoOutput()
        candidate.add(candidateVideoOutput)
        guard player.canInsert(candidate, after: currentItem) else {
            asset.cancelLoading()
            loader?.close()
            completion(.failed(NSError(description: "AVPlayer rejected the source-switch candidate")))
            return
        }
        let prewarmingPlayer = Self.makeSourceSwitchPrewarmingPlayer(item: candidate)
        let startedAt = CACurrentMediaTime()
        KSLog("[\(diagnosticLabel)] av-item prewarm started position=\(currentPlaybackTime) playing=\(isPlaying)")
        var pending = PendingSourceSwitch(
            item: candidate,
            asset: asset,
            loader: loader,
            prewarmingPlayer: prewarmingPlayer,
            options: options,
            resumeShift: resumeShift,
            videoOutput: candidateVideoOutput,
            diagnosticLabel: diagnosticLabel,
            startedAt: startedAt,
            completion: completion
        )
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let error = candidate.error.map { " error=\(($0 as NSError).domain)/\(($0 as NSError).code) \($0.localizedDescription)" } ?? ""
            KSLog("[\(diagnosticLabel)] av-item prewarm timed out status=\(candidate.status.rawValue) elapsed=\(CACurrentMediaTime() - startedAt)\(error)")
            self.abandonPendingSourceSwitch(result: .timedOut)
        }
        pending.timeout = timeout
        sourceSwitchLock.lock()
        pendingSourceSwitch = pending
        sourceSwitchLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + KSAVPlayer.sourceSwitchTimeout, execute: timeout)
        let statusObservation = candidate.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            runOnMainThread {
                guard let self else { return }
                if status == .readyToPlay {
                    KSLog("[\(diagnosticLabel)] av-item prewarm ready elapsed=\(CACurrentMediaTime() - startedAt)")
                    self.commitPendingSourceSwitch()
                } else if status == .failed {
                    self.abandonPendingSourceSwitch(result: .failed(item.error.map { $0 as NSError }))
                }
            }
        }
        sourceSwitchLock.lock()
        pendingSourceSwitch?.statusObservation = statusObservation
        sourceSwitchLock.unlock()
    }

    public func cancelSourceSwitch() {
        abandonPendingSourceSwitch(result: .cancelled)
    }

    private func takePendingSourceSwitch() -> PendingSourceSwitch? {
        sourceSwitchLock.lock()
        defer { sourceSwitchLock.unlock() }
        let pending = pendingSourceSwitch
        pendingSourceSwitch = nil
        return pending
    }

    private func commitPendingSourceSwitch() {
        guard var pending = takePendingSourceSwitch() else { return }
        let candidateTracks = pending.item.tracks.map { AVMediaPlayerTrack(track: $0) }
        guard candidateTracks.isEmpty || candidateTracks.contains(where: { $0.mediaType == .video && $0.isPlayable }) else {
            discardSourceSwitch(pending, result: .failed(NSError(description: "AVPlayer source-switch candidate has no playable video track")))
            return
        }
        pending.statusObservation?.invalidate()
        pending.timeout?.cancel()
        guard let currentItem = player.currentItem else {
            discardSourceSwitch(pending, result: .failed(NSError(description: "AVPlayer lost its current item before source-switch ownership transfer")))
            return
        }
        pending.prewarmingPlayer?.replaceCurrentItem(with: nil)
        pending.prewarmingPlayer = nil
        let promotionItem = AVPlayerItem(asset: pending.asset)
        promotionItem.preferredForwardBufferDuration = pending.options.preferredForwardBufferDuration
        let promotionVideoOutput = Self.makeVideoOutput()
        promotionItem.add(promotionVideoOutput)
        pending.item = promotionItem
        pending.videoOutput = promotionVideoOutput
        sourceOwnershipTransferGeneration &+= 1
        let generation = sourceOwnershipTransferGeneration
        activeSourceOwnershipTransfer = ActiveSourceOwnershipTransfer(
            generation: generation,
            pending: pending,
            currentItem: currentItem,
            startedAt: CACurrentMediaTime(),
            attempts: 0
        )
        KSLog("[\(pending.diagnosticLabel)] ownership release started promotion=fresh-item")
        attemptSourceOwnershipTransfer(generation: generation)
    }

    private func attemptSourceOwnershipTransfer(generation: Int) {
        guard var transfer = activeSourceOwnershipTransfer else { return }
        transfer.attempts += 1
        activeSourceOwnershipTransfer = transfer
        let elapsed = CACurrentMediaTime() - transfer.startedAt
        let generationMatches = transfer.generation == generation && sourceOwnershipTransferGeneration == generation
        let currentItemMatches = player.currentItem === transfer.currentItem
        let canInsert = currentItemMatches && player.canInsert(transfer.pending.item, after: transfer.currentItem)
        let action = Self.sourceOwnershipTransferAction(
            canInsert: canInsert,
            currentItemMatches: currentItemMatches,
            generationMatches: generationMatches,
            elapsed: elapsed,
            timeout: Self.sourceOwnershipTransferTimeout
        )
        switch action {
        case .commit:
            activeSourceOwnershipTransfer = nil
            sourceOwnershipTransferGeneration &+= 1
            KSLog("[\(transfer.pending.diagnosticLabel)] ownership release ready attempts=\(transfer.attempts) elapsed=\(elapsed)")
            commitTransferredSourceSwitch(transfer.pending, after: transfer.currentItem)
        case .retry:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sourceOwnershipTransferRetryInterval) { [weak self] in
                self?.attemptSourceOwnershipTransfer(generation: generation)
            }
        case .timedOut:
            activeSourceOwnershipTransfer = nil
            sourceOwnershipTransferGeneration &+= 1
            KSLog("[\(transfer.pending.diagnosticLabel)] ownership release timed out attempts=\(transfer.attempts) elapsed=\(elapsed)")
            discardSourceSwitch(transfer.pending, result: .timedOut)
        case .cancelled:
            activeSourceOwnershipTransfer = nil
            sourceOwnershipTransferGeneration &+= 1
            KSLog("[\(transfer.pending.diagnosticLabel)] ownership release cancelled attempts=\(transfer.attempts) elapsed=\(elapsed)")
            discardSourceSwitch(transfer.pending, result: .cancelled)
        }
    }

    private func commitTransferredSourceSwitch(_ pending: PendingSourceSwitch, after currentItem: AVPlayerItem) {
        cancelActiveSourceCommit()
        let previousAsset = urlAsset
        let previousLoader = cacheResourceLoader
        let currentTime = player.currentTime()
        let resumeTime = currentTime.isNumeric ? CMTime(seconds: currentTime.seconds + pending.resumeShift) : currentTime
        sourceCommitGeneration &+= 1
        let commitGeneration = sourceCommitGeneration
        activeSourceCommit = ActiveSourceCommit(generation: commitGeneration, pending: pending)
        if let freezeFrame = captureCurrentFrame() {
            playerView.showFreezeFrame(freezeFrame)
        }
        urlAsset = pending.asset
        cacheResourceLoader = pending.loader
        options = pending.options
        currentItem.cancelPendingSeeks()
        player.insert(pending.item, after: currentItem)
        player.advanceToNextItem()
        currentVideoOutput = pending.videoOutput
        updateStatus(item: pending.item)
        previousAsset.cancelLoading()
        previousLoader?.close()
        let restoreTimeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            KSLog("[\(pending.diagnosticLabel)] restore seek timed out target=\(resumeTime.seconds)")
            self.finishSourceSwitchCommit(
                pending: pending,
                resumeTime: resumeTime,
                generation: commitGeneration,
                seekFinished: false
            )
        }
        if resumeTime.isNumeric, resumeTime.seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreSeekTimeout, execute: restoreTimeout)
            player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                runOnMainThread {
                    restoreTimeout.cancel()
                    self?.finishSourceSwitchCommit(
                        pending: pending,
                        resumeTime: resumeTime,
                        generation: commitGeneration,
                        seekFinished: finished
                    )
                }
            }
        } else {
            finishSourceSwitchCommit(
                pending: pending,
                resumeTime: resumeTime,
                generation: commitGeneration,
                seekFinished: true
            )
        }
    }

    private func finishSourceSwitchCommit(
        pending: PendingSourceSwitch,
        resumeTime: CMTime,
        generation: Int,
        seekFinished: Bool
    ) {
        guard sourceCommitGeneration == generation else { return }
        sourceCommitGeneration &+= 1
        if playbackState == .playing {
            playOrPause()
        } else {
            player.pause()
        }
        guard activeSourceCommit?.generation == generation else { return }
        KSLog("[\(pending.diagnosticLabel)] restore seek finished=\(seekFinished) target=\(resumeTime.seconds) elapsed=\(CACurrentMediaTime() - pending.startedAt)")
        beginFrameHandoff(pending: pending)
        activeSourceCommit = nil
        pending.completion(.committed)
    }

    private func cancelActiveSourceCommit() {
        guard let commit = activeSourceCommit else { return }
        activeSourceCommit = nil
        KSLog("[\(commit.pending.diagnosticLabel)] restore seek cancelled elapsed=\(CACurrentMediaTime() - commit.pending.startedAt)")
        commit.pending.completion(.cancelled)
    }

    func abandonPendingSourceSwitch(result: KSAVSourceSwitchResult = .cancelled) {
        if let pending = takePendingSourceSwitch() {
            discardSourceSwitch(pending, result: result)
        }
        abandonActiveSourceOwnershipTransfer(result: result)
    }

    private func abandonActiveSourceOwnershipTransfer(result: KSAVSourceSwitchResult) {
        guard let transfer = activeSourceOwnershipTransfer else { return }
        activeSourceOwnershipTransfer = nil
        sourceOwnershipTransferGeneration &+= 1
        KSLog("[\(transfer.pending.diagnosticLabel)] ownership release cancelled attempts=\(transfer.attempts) elapsed=\(CACurrentMediaTime() - transfer.startedAt)")
        discardSourceSwitch(transfer.pending, result: result)
    }

    private func discardSourceSwitch(_ pending: PendingSourceSwitch, result: KSAVSourceSwitchResult) {
        pending.statusObservation?.invalidate()
        pending.timeout?.cancel()
        pending.prewarmingPlayer?.replaceCurrentItem(with: nil)
        if player.items().contains(where: { $0 === pending.item }) {
            player.remove(pending.item)
        }
        pending.asset.cancelLoading()
        pending.loader?.close()
        KSLog("[\(pending.diagnosticLabel)] av-item finished result=\(result.diagnosticDescription) elapsed=\(CACurrentMediaTime() - pending.startedAt)")
        pending.completion(result)
    }

    private func captureCurrentFrame() -> CGImage? {
        guard let currentVideoOutput else { return nil }
        let hostTime = CACurrentMediaTime()
        let outputTime = currentVideoOutput.itemTime(forHostTime: hostTime)
        if let pixelBuffer = currentVideoOutput.copyPixelBuffer(forItemTime: outputTime, itemTimeForDisplay: nil),
           let image = pixelBuffer.cgImage()
        {
            return image
        }
        guard let currentTime = player.currentItem?.currentTime(), currentTime.isNumeric,
              let pixelBuffer = currentVideoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil)
        else {
            return nil
        }
        return pixelBuffer.cgImage()
    }

    private func beginFrameHandoff(pending: PendingSourceSwitch) {
        frameHandoffGeneration &+= 1
        let generation = frameHandoffGeneration
        activeFrameHandoff = ActiveFrameHandoff(
            generation: generation,
            item: pending.item,
            videoOutput: pending.videoOutput,
            diagnosticLabel: pending.diagnosticLabel,
            startedAt: CACurrentMediaTime()
        )
        pollFrameHandoff(generation: generation)
    }

    private func pollFrameHandoff(generation: Int) {
        guard let handoff = activeFrameHandoff,
              handoff.generation == generation
        else {
            return
        }
        guard player.currentItem === handoff.item else {
            finishFrameHandoff(result: .cancelled, renderedFirstFrame: false)
            return
        }
        let itemTime = handoff.videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        let hasFirstFrame = handoff.videoOutput.hasNewPixelBuffer(forItemTime: itemTime)
        let elapsed = CACurrentMediaTime() - handoff.startedAt
        switch Self.frameHandoffAction(hasFirstFrame: hasFirstFrame, elapsed: elapsed, timeout: Self.frameHandoffTimeout) {
        case .wait:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.framePollInterval) { [weak self] in
                self?.pollFrameHandoff(generation: generation)
            }
        case .revealFirstFrame:
            _ = handoff.videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
            finishFrameHandoff(result: .committed, renderedFirstFrame: true)
        case .revealOnTimeout:
            finishFrameHandoff(result: .committed, renderedFirstFrame: false)
        }
    }

    private func finishFrameHandoff(result: KSAVSourceSwitchResult, renderedFirstFrame: Bool) {
        guard let handoff = activeFrameHandoff else {
            playerView.hideFreezeFrame()
            return
        }
        activeFrameHandoff = nil
        frameHandoffGeneration &+= 1
        playerView.hideFreezeFrame()
        KSLog("[\(handoff.diagnosticLabel)] first-frame rendered=\(renderedFirstFrame) result=\(result.diagnosticDescription) elapsed=\(CACurrentMediaTime() - handoff.startedAt)")
    }

    public var contentMode: UIViewContentMode {
        get {
            playerView.contentMode
        }
        set {
            playerView.contentMode = newValue
        }
    }

    public func enterBackground() {
        playerView.playerLayer.player = nil
    }

    public func enterForeground() {
        playerView.playerLayer.player = playerView.player
    }

    public var seekable: Bool {
        !(player.currentItem?.seekableTimeRanges.isEmpty ?? true)
    }

    public var isMuted: Bool {
        get {
            player.isMuted
        }
        set {
            player.isMuted = newValue
        }
    }

    public func tracks(mediaType: AVFoundation.AVMediaType) -> [MediaPlayerTrack] {
        player.currentItem?.tracks.filter { $0.assetTrack?.mediaType == mediaType }.map { AVMediaPlayerTrack(track: $0) } ?? []
    }

    public func select(track: some MediaPlayerTrack) {
        player.currentItem?.tracks.filter { $0.assetTrack?.mediaType == track.mediaType }.forEach { $0.isEnabled = false }
        track.isEnabled = true
    }
}

extension AVFoundation.AVMediaType {
    var mediaCharacteristic: AVMediaCharacteristic {
        switch self {
        case .video:
            return .visual
        case .audio:
            return .audible
        case .subtitle:
            return .legible
        default:
            return .easyToRead
        }
    }
}

class AVMediaPlayerTrack: @preconcurrency MediaPlayerTrack {
    let formatDescription: CMFormatDescription?
    let description: String
    private let track: AVPlayerItemTrack
    var nominalFrameRate: Float
    let trackID: Int32
    let rotation: Int16 = 0
    let bitDepth: Int32
    let bitRate: Int64
    let name: String
    let languageCode: String?
    let mediaType: AVFoundation.AVMediaType
    let isImageSubtitle = false
    var dovi: DOVIDecoderConfigurationRecord?
    let fieldOrder: FFmpegFieldOrder = .unknown
    var isPlayable: Bool
    @MainActor
    var isEnabled: Bool {
        get {
            track.isEnabled
        }
        set {
            track.isEnabled = newValue
        }
    }

    init(track: AVPlayerItemTrack) {
        self.track = track
        trackID = track.assetTrack?.trackID ?? 0
        mediaType = track.assetTrack?.mediaType ?? .video
        name = track.assetTrack?.languageCode ?? ""
        languageCode = track.assetTrack?.languageCode
        nominalFrameRate = track.assetTrack?.nominalFrameRate ?? 24.0
        bitRate = Int64(track.assetTrack?.estimatedDataRate ?? 0)
        #if os(xrOS)
        isPlayable = false
        #else
        isPlayable = track.assetTrack?.isPlayable ?? false
        #endif
        // swiftlint:disable force_cast
        if let first = track.assetTrack?.formatDescriptions.first {
            formatDescription = first as! CMFormatDescription
        } else {
            formatDescription = nil
        }
        bitDepth = formatDescription?.bitDepth ?? 0
        // swiftlint:enable force_cast
        description = (formatDescription?.mediaSubType ?? .boxed).rawValue.string
        #if os(xrOS)
        Task {
            isPlayable = await (try? track.assetTrack?.load(.isPlayable)) ?? false
        }
        #endif
    }
}

final class AVSubtitleInfo: SubtitleInfo {
    let subtitleID: String
    let name: String
    var delay: TimeInterval = 0
    private let option: AVMediaSelectionOption
    private let group: AVMediaSelectionGroup
    private weak var dataSouce: AVSubtitleDataSouce?
    init(option: AVMediaSelectionOption, group: AVMediaSelectionGroup, subtitleID: String, dataSouce: AVSubtitleDataSouce) {
        self.option = option
        self.group = group
        self.subtitleID = subtitleID
        self.dataSouce = dataSouce
        name = option.displayName
    }

    var isEnabled: Bool {
        get {
            dataSouce?.isSelected(option: option, in: group) ?? false
        }
        set {
            if newValue {
                dataSouce?.select(option: option, in: group)
            } else if isEnabled {
                dataSouce?.select(option: nil, in: group)
            }
        }
    }

    func search(for time: TimeInterval) -> [SubtitlePart] {
        guard isEnabled, let dataSouce else {
            return []
        }
        return dataSouce.parts.filter { $0 == time }
    }
}

final class AVSubtitleDataSouce: NSObject, SubtitleDataSouce {
    private(set) var infos = [any SubtitleInfo]()
    fileprivate var parts = [SubtitlePart]()
    private weak var playerItem: AVPlayerItem?
    private var output: AVPlayerItemLegibleOutput?

    func load(playerItem: AVPlayerItem) {
        guard self.playerItem !== playerItem else {
            return
        }
        detachOutput()
        self.playerItem = playerItem
        var newInfos = [any SubtitleInfo]()
        if let group = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            for (index, option) in group.options.enumerated() {
                newInfos.append(AVSubtitleInfo(option: option, group: group, subtitleID: "\(index) \(option.displayName)", dataSouce: self))
            }
        }
        infos = newInfos
    }

    fileprivate func isSelected(option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) -> Bool {
        playerItem?.currentMediaSelection.selectedMediaOption(in: group) == option
    }

    fileprivate func select(option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        guard let playerItem else {
            return
        }
        if let option {
            attachOutput(playerItem: playerItem)
            playerItem.select(option, in: group)
        } else {
            playerItem.select(nil, in: group)
            detachOutput()
        }
    }

    private func attachOutput(playerItem: AVPlayerItem) {
        guard output == nil else {
            return
        }
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        playerItem.add(output)
        self.output = output
    }

    private func detachOutput() {
        parts = []
        if let output, let playerItem {
            playerItem.remove(output)
        }
        output = nil
    }
}

extension AVSubtitleDataSouce: AVPlayerItemLegibleOutputPushDelegate {
    func legibleOutput(_: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers _: [Any], forItemTime itemTime: CMTime) {
        parts = strings.filter { $0.length > 0 }.map { SubtitlePart(itemTime.seconds, .infinity, attributedString: $0) }
    }
}

public extension AVAsset {
    func createImageGenerator() -> AVAssetImageGenerator {
        let imageGenerator = AVAssetImageGenerator(asset: self)
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        return imageGenerator
    }

    func thumbnailImage(currentTime: CMTime, handler: @escaping (CGImage?) -> Void) {
        let imageGenerator = createImageGenerator()
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: currentTime)]) { _, cgImage, _, _, _ in
            if let cgImage {
                handler(cgImage)
            } else {
                handler(nil)
            }
        }
    }
}
