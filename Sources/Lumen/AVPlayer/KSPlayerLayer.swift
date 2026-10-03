//
//  KSPlayerLayerView.swift
//  Pods
//
//  Created by kintan on 16/4/28.
//
//
import AVFoundation
import AVKit
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/**
 Player status emun
 - setURL:      set url
 - readyToPlay:    player ready to play
 - buffering:      player buffering
 - bufferFinished: buffer finished
 - playedToTheEnd: played to the End
 - error:          error with playing
 */
public enum KSPlayerState: CustomStringConvertible {
    case initialized
    case preparing
    case readyToPlay
    case buffering
    case bufferFinished
    case paused
    case playedToTheEnd
    case error
    public var description: String {
        switch self {
        case .initialized:
            return "initialized"
        case .preparing:
            return "preparing"
        case .readyToPlay:
            return "readyToPlay"
        case .buffering:
            return "buffering"
        case .bufferFinished:
            return "bufferFinished"
        case .paused:
            return "paused"
        case .playedToTheEnd:
            return "playedToTheEnd"
        case .error:
            return "error"
        }
    }

    public var isPlaying: Bool { self == .buffering || self == .bufferFinished }
}

@MainActor
public protocol KSPlayerLayerDelegate: AnyObject {
    func player(layer: KSPlayerLayer, state: KSPlayerState)
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval)
    func player(layer: KSPlayerLayer, finish error: Error?)
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval)
}

open class KSPlayerLayer: NSObject {
    private final class SeekCompletion {
        private let lock = NSLock()
        private var handler: ((Bool) -> Void)?

        init(_ handler: @escaping (Bool) -> Void) {
            self.handler = handler
        }

        func resolve(_ result: Bool) {
            lock.lock()
            let handler = handler
            self.handler = nil
            lock.unlock()
            handler?(result)
        }
    }

    private struct SeekIntent {
        let generation: Int
        let time: TimeInterval
        let autoPlay: Bool
    }

    public weak var delegate: KSPlayerLayerDelegate?
    @Published
    public var bufferingProgress: Int = 0
    @Published
    public var loopCount: Int = 0
    @Published
    public var isPipActive = false {
        didSet {
            if #available(tvOS 14.0, *) {
                guard let pipController = player.pipController else {
                    return
                }

                if isPipActive {
                    // 一定要async才不会pip之后就暂停播放
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        pipController.start(view: self)
                    }
                } else {
                    pipController.stop(restoreUserInterface: true)
                }
            }
        }
    }

    public private(set) var options: KSOptions

    public var player: MediaPlayerProtocol {
        didSet {
            KSLog("player is \(player)")
            state = .initialized
            runOnMainThread { [weak self] in
                guard let self else { return }
                if let oldView = oldValue.view, let superview = oldView.superview, let view = player.view {
                    #if canImport(UIKit)
                    superview.insertSubview(view, belowSubview: oldView)
                    #else
                    superview.addSubview(view, positioned: .below, relativeTo: oldView)
                    #endif
                    view.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        view.topAnchor.constraint(equalTo: superview.topAnchor),
                        view.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
                        view.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
                        view.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
                    ])
                }
                oldValue.view?.removeFromSuperview()
            }
            player.playbackRate = oldValue.playbackRate
            player.playbackVolume = oldValue.playbackVolume
            player.delegate = self
            player.contentMode = .scaleAspectFit
            if isAutoPlay {
                prepareToPlay()
            }
        }
    }

    public private(set) var url: URL {
        didSet {
            guard !isCommittingSourceSwitch else { return }
            let firstPlayerType: MediaPlayerProtocol.Type
            if isWirelessRouteActive {
                // airplay的话，默认使用KSAVPlayer
                firstPlayerType = KSAVPlayer.self
            } else if options.display != .plane {
                // AR模式只能用KSMEPlayer
                firstPlayerType = KSMEPlayer.self
            } else {
                firstPlayerType = KSOptions.firstPlayerType
            }
            if type(of: player) == firstPlayerType {
                if url == oldValue {
                    if isAutoPlay {
                        play()
                    }
                } else {
                    stop()
                    player.replace(url: url, options: options)
                    if isAutoPlay {
                        prepareToPlay()
                    }
                }
            } else {
                stop()
                player = firstPlayerType.init(url: url, options: options)
            }
        }
    }

    /// 播发器的几种状态

    public private(set) var state = KSPlayerState.initialized {
        willSet {
            if state != newValue {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    KSLog("playerStateDidChange - \(newValue)")
                    self.delegate?.player(layer: self, state: newValue)
                }
            }
        }
    }

    private var timer: Timer?

    private var urls = [URL]()
    private var isAutoPlay: Bool
    private var isWirelessRouteActive = false
    private var bufferedCount = 0
    private var seekGeneration = 0
    private var pendingSeekIntent: SeekIntent?
    private var activeSeekGeneration: Int?
    private var activeSeekCompletion: SeekCompletion?
    private var lastKnownPlaybackTime = TimeInterval(0)
    private var startTime: TimeInterval = 0
    private var sourceSwitchGeneration = 0
    private var isCommittingSourceSwitch = false
    private var pendingSourceSwitchCompletions = [(Bool) -> Void]()
    public private(set) var pendingSourceSwitchURL: URL?
    public init(url: URL, isAutoPlay: Bool = KSOptions.isAutoPlay, options: KSOptions, delegate: KSPlayerLayerDelegate? = nil) {
        self.url = url
        self.options = options
        self.delegate = delegate
        let firstPlayerType: MediaPlayerProtocol.Type
        if options.display != .plane {
            // AR模式只能用KSMEPlayer
            firstPlayerType = KSMEPlayer.self
        } else {
            firstPlayerType = KSOptions.firstPlayerType
        }
        player = firstPlayerType.init(url: url, options: options)
        self.isAutoPlay = isAutoPlay
        super.init()
        player.playbackRate = options.startPlayRate
        if options.registerRemoteControll {
            registerRemoteControllEvent()
        }
        player.delegate = self
        player.contentMode = .scaleAspectFit
        if isAutoPlay {
            prepareToPlay()
        }
        #if canImport(UIKit)
        runOnMainThread { [weak self] in
            guard let self else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(enterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(enterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        #if !os(xrOS)
        NotificationCenter.default.addObserver(self, selector: #selector(wirelessRouteActiveDidChange(notification:)), name: .MPVolumeViewWirelessRouteActiveDidChange, object: nil)
        #endif
        #endif
        #if !os(macOS)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted), name: AVAudioSession.interruptionNotification, object: nil)
        #endif
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            player.pipController?.contentSource = nil
        }
        NotificationCenter.default.removeObserver(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPRemoteCommandCenter.shared().playCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().pauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().stopCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().nextTrackCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().previousTrackCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().changePlaybackRateCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().skipForwardCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().skipBackwardCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().enableLanguageOptionCommand.removeTarget(nil)
        KSOptions.deactivateAudioSession()
        options.playerLayerDeinit()
    }

    public func set(url: URL, options: KSOptions) {
        cancelPendingSourceSwitch()
        self.options = options
        runOnMainThread {
            self.url = url
        }
    }

    public func set(urls: [URL], options: KSOptions) {
        cancelPendingSourceSwitch()
        self.options = options
        self.urls.removeAll()
        self.urls.append(contentsOf: urls)
        if let first = urls.first {
            runOnMainThread {
                self.url = first
            }
        }
    }

    public func switchSource(url: URL, options: KSOptions, completion: ((Bool) -> Void)? = nil) {
        if pendingSourceSwitchURL == url {
            if let completion {
                pendingSourceSwitchCompletions.append(completion)
            }
            return
        }
        if pendingSourceSwitchURL != nil {
            cancelPendingSourceSwitch()
        }
        if url == self.url {
            completion?(true)
            return
        }
        sourceSwitchGeneration += 1
        let generation = sourceSwitchGeneration
        pendingSourceSwitchURL = url
        player.switchSource(url: url, options: options) { [weak self] success in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == self.sourceSwitchGeneration else {
                    completion?(false)
                    return
                }
                self.pendingSourceSwitchURL = nil
                if success {
                    self.commitSourceSwitch(url: url, options: options)
                } else {
                    self.set(url: url, options: options)
                }
                completion?(success)
                self.resolvePendingSourceSwitchCompletions(success)
            }
        }
    }

    private func commitSourceSwitch(url: URL, options: KSOptions) {
        self.options = options
        isCommittingSourceSwitch = true
        self.url = url
        isCommittingSourceSwitch = false
    }

    private func cancelPendingSourceSwitch() {
        sourceSwitchGeneration += 1
        pendingSourceSwitchURL = nil
        player.cancelSourceSwitch()
        resolvePendingSourceSwitchCompletions(false)
    }

    private func resolvePendingSourceSwitchCompletions(_ success: Bool) {
        let completions = pendingSourceSwitchCompletions
        pendingSourceSwitchCompletions.removeAll()
        for completion in completions {
            completion(success)
        }
    }

    private func startTimer() {
        if timer == nil {
            timer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.player.isReadyToPlay else {
                    return
                }
                let currentTime = self.player.currentPlaybackTime
                if currentTime.isFinite, currentTime >= 0 {
                    self.lastKnownPlaybackTime = currentTime
                }
                self.delegate?.player(
                    layer: self,
                    currentTime: currentTime,
                    totalTime: self.player.duration
                )
                if self.player.playbackState == .playing, self.player.loadState == .playable, self.state == .buffering {
                    // 一个兜底保护，正常不能走到这里
                    self.state = .bufferFinished
                }
                if self.player.isPlaying {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
                }
            }
        }
        timer?.fireDate = Date.distantPast
    }

    open func play() {
        runOnMainThread {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        isAutoPlay = true
        updatePendingSeekIntent(autoPlay: true)
        if state == .error || state == .initialized {
            prepareToPlay()
        }
        if player.isReadyToPlay {
            if state == .playedToTheEnd {
                player.seek(time: 0) { [weak self] finished in
                    guard let self else { return }
                    if finished {
                        self.player.play()
                    }
                }
            } else {
                player.play()
            }
            startTimer()
        }
        state = player.loadState == .playable ? .bufferFinished : .buffering
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if #available(tvOS 14.0, *) {
            KSPictureInPictureController.mute()
        }
    }

    open func pause() {
        isAutoPlay = false
        updatePendingSeekIntent(autoPlay: false)
        player.pause()
        timer?.fireDate = Date.distantFuture
        state = .paused
        MPNowPlayingInfoCenter.default().playbackState = .paused
        runOnMainThread {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    public func stop() {
        KSLog("stop Player")
        cancelPendingSourceSwitch()
        state = .initialized
        seekGeneration &+= 1
        pendingSeekIntent = nil
        activeSeekCompletion?.resolve(false)
        activeSeekCompletion = nil
        activeSeekGeneration = nil
        lastKnownPlaybackTime = 0
        player.delegate = nil
        player.shutdown()
        player.delegate = self
        bufferedCount = 0
        player.playbackRate = 1
        player.playbackVolume = 1
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        runOnMainThread {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    open func seek(time: TimeInterval, autoPlay: Bool, completion: @escaping ((Bool) -> Void)) {
        if time.isInfinite || time.isNaN {
            completion(false)
            return
        }
        activeSeekCompletion?.resolve(false)
        activeSeekCompletion = nil
        activeSeekGeneration = nil
        seekGeneration &+= 1
        let intent = SeekIntent(generation: seekGeneration, time: max(time, 0), autoPlay: autoPlay)
        pendingSeekIntent = intent
        isAutoPlay = autoPlay
        if player.isReadyToPlay, player.seekable {
            performSeek(intent, completion: SeekCompletion(completion))
        } else {
            completion(false)
        }
    }

    private func performSeek(_ intent: SeekIntent, completion: SeekCompletion) {
        guard activeSeekGeneration != intent.generation else {
            completion.resolve(false)
            return
        }
        let seekingPlayer = player
        activeSeekGeneration = intent.generation
        activeSeekCompletion = completion
        seekingPlayer.seek(time: intent.time) { [weak self, weak seekingPlayer] finished in
            guard let self else {
                completion.resolve(false)
                return
            }
            if self.activeSeekGeneration == intent.generation {
                self.activeSeekGeneration = nil
                self.activeSeekCompletion = nil
            }
            guard let seekingPlayer,
                  (self.player as AnyObject) === (seekingPlayer as AnyObject),
                  self.pendingSeekIntent?.generation == intent.generation
            else {
                completion.resolve(false)
                return
            }
            if finished {
                self.lastKnownPlaybackTime = intent.time
                let autoPlay = self.pendingSeekIntent?.autoPlay ?? intent.autoPlay
                self.pendingSeekIntent = nil
                if autoPlay {
                    self.play()
                } else {
                    self.pause()
                }
            }
            completion.resolve(finished)
        }
    }

    private func updatePendingSeekIntent(autoPlay: Bool) {
        guard let intent = pendingSeekIntent else { return }
        pendingSeekIntent = SeekIntent(generation: intent.generation, time: intent.time, autoPlay: autoPlay)
    }
}

// MARK: - MediaPlayerDelegate

extension KSPlayerLayer: MediaPlayerDelegate {
    public func readyToPlay(player: some MediaPlayerProtocol) {
        guard (self.player as AnyObject) === (player as AnyObject) else { return }
        state = .readyToPlay
        #if os(macOS)
        runOnMainThread { [weak self] in
            guard let self else { return }
            if let window = player.view?.window {
                window.isMovableByWindowBackground = true
                if options.automaticWindowResize {
                    let naturalSize = player.naturalSize
                    if naturalSize.width > 0, naturalSize.height > 0 {
                        window.aspectRatio = naturalSize
                        var frame = window.frame
                        frame.size.height = frame.width * naturalSize.height / naturalSize.width
                        window.setFrame(frame, display: true)
                    }
                }
            }
        }
        #endif
        #if !os(macOS) && !os(tvOS)
        if #available(iOS 14.2, *) {
            if options.canStartPictureInPictureAutomaticallyFromInline {
                player.pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            }
        }
        #endif
        updateNowPlayingInfo()
        if let intent = pendingSeekIntent {
            if player.seekable {
                performSeek(intent, completion: SeekCompletion { _ in })
            } else if !player.duration.isFinite || player.duration <= 0 {
                pendingSeekIntent = nil
                if intent.autoPlay {
                    play()
                } else {
                    pause()
                }
            }
        } else if isAutoPlay {
            play()
        }
    }

    public func changeLoadState(player: some MediaPlayerProtocol) {
        guard (self.player as AnyObject) === (player as AnyObject) else { return }
        if player.isReadyToPlay, player.seekable, let intent = pendingSeekIntent {
            performSeek(intent, completion: SeekCompletion { _ in })
            return
        }
        guard player.playbackState != .seeking else { return }
        if player.loadState == .playable, startTime > 0 {
            let diff = CACurrentMediaTime() - startTime
            runOnMainThread { [weak self] in
                guard let self else { return }
                delegate?.player(layer: self, bufferedCount: bufferedCount, consumeTime: diff)
            }
            if bufferedCount == 0 {
                var dic = ["firstTime": diff]
                if options.tcpConnectedTime > 0 {
                    dic["initTime"] = options.dnsStartTime - startTime
                    dic["dnsTime"] = options.tcpStartTime - options.dnsStartTime
                    dic["tcpTime"] = options.tcpConnectedTime - options.tcpStartTime
                    dic["openTime"] = options.openTime - options.tcpConnectedTime
                    dic["findTime"] = options.findTime - options.openTime
                } else {
                    dic["openTime"] = options.openTime - startTime
                }
                dic["findTime"] = options.findTime - options.openTime
                dic["readyTime"] = options.readyTime - options.findTime
                dic["readVideoTime"] = options.readVideoTime - options.readyTime
                dic["readAudioTime"] = options.readAudioTime - options.readyTime
                dic["decodeVideoTime"] = options.decodeVideoTime - options.readVideoTime
                dic["decodeAudioTime"] = options.decodeAudioTime - options.readAudioTime
                KSLog(dic)
            }
            bufferedCount += 1
            startTime = 0
        }
        guard state.isPlaying else { return }
        if player.loadState == .playable {
            state = .bufferFinished
        } else {
            if state == .bufferFinished {
                startTime = CACurrentMediaTime()
            }
            state = .buffering
        }
    }

    public func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {
        guard (self.player as AnyObject) === (player as AnyObject) else { return }
        bufferingProgress = progress
    }

    public func playBack(player: some MediaPlayerProtocol, loopCount: Int) {
        guard (self.player as AnyObject) === (player as AnyObject) else { return }
        self.loopCount = loopCount
    }

    public func finish(player: some MediaPlayerProtocol, error: Error?) {
        guard (self.player as AnyObject) === (player as AnyObject) else { return }
        if let error {
            if type(of: player) != KSOptions.secondPlayerType, let secondPlayerType = KSOptions.secondPlayerType {
                let currentTime = player.currentPlaybackTime
                let fallbackTime = pendingSeekIntent?.time ?? (
                    (currentTime.isFinite && currentTime > 0) ? currentTime : lastKnownPlaybackTime
                )
                let fallbackAutoPlay = pendingSeekIntent?.autoPlay ?? isAutoPlay
                if pendingSeekIntent == nil {
                    seekGeneration &+= 1
                    pendingSeekIntent = SeekIntent(
                        generation: seekGeneration,
                        time: max(fallbackTime, 0),
                        autoPlay: fallbackAutoPlay
                    )
                }
                activeSeekCompletion?.resolve(false)
                activeSeekCompletion = nil
                activeSeekGeneration = nil
                timer?.fireDate = Date.distantFuture
                let nsError = error as NSError
                KSLog(
                    "player fallback from \(type(of: player)) to \(secondPlayerType), "
                        + "state: \(state), time: \(fallbackTime), autoPlay: \(fallbackAutoPlay), "
                        + "error: \(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription), "
                        + "userInfo: \(nsError.userInfo)"
                )
                player.delegate = nil
                player.shutdown()
                isAutoPlay = false
                self.player = secondPlayerType.init(url: url, options: options)
                isAutoPlay = fallbackAutoPlay
                prepareToPlay()
                return
            }
            state = .error
            KSLog(error as CustomStringConvertible)
        } else {
            let duration = player.duration
            runOnMainThread { [weak self] in
                guard let self else { return }
                delegate?.player(layer: self, currentTime: duration, totalTime: duration)
            }
            state = .playedToTheEnd
        }
        timer?.fireDate = Date.distantFuture
        bufferedCount = 1
        runOnMainThread { [weak self] in
            guard let self else { return }
            delegate?.player(layer: self, finish: error)
        }
        if error == nil {
            nextPlayer()
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

@available(tvOS 14.0, *)
extension KSPlayerLayer: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        player.pipController?.stop(restoreUserInterface: false)
    }

    public func pictureInPictureController(_: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler _: @escaping (Bool) -> Void) {
        isPipActive = false
    }
}

// MARK: - private functions

extension KSPlayerLayer {
    open func prepareToPlay() {
        state = .preparing
        startTime = CACurrentMediaTime()
        bufferedCount = 0
        player.prepareToPlay()
    }

    private func updateNowPlayingInfo() {
        if MPNowPlayingInfoCenter.default().nowPlayingInfo == nil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyPlaybackDuration: player.duration]
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] == nil, let title = player.dynamicInfo?.metadata["title"] {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] = title
        }
        if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] == nil, let artist = player.dynamicInfo?.metadata["artist"] {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] = artist
        }
        var current: [MPNowPlayingInfoLanguageOption] = []
        var langs: [MPNowPlayingInfoLanguageOptionGroup] = []
        for track in player.tracks(mediaType: .audio) {
            if let lang = track.language {
                let audioLang = MPNowPlayingInfoLanguageOption(type: .audible, languageTag: lang, characteristics: nil, displayName: track.name, identifier: track.name)
                let audioGroup = MPNowPlayingInfoLanguageOptionGroup(languageOptions: [audioLang], defaultLanguageOption: nil, allowEmptySelection: false)
                langs.append(audioGroup)
                if track.isEnabled {
                    current.append(audioLang)
                }
            }
        }
        if !langs.isEmpty {
            MPRemoteCommandCenter.shared().enableLanguageOptionCommand.isEnabled = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyAvailableLanguageOptions] = langs
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyCurrentLanguageOptions] = current
    }

    private func nextPlayer() {
        if urls.count > 1, let index = urls.firstIndex(of: url), index < urls.count - 1 {
            isAutoPlay = true
            url = urls[index + 1]
        }
    }

    private func previousPlayer() {
        if urls.count > 1, let index = urls.firstIndex(of: url), index > 0 {
            isAutoPlay = true
            url = urls[index - 1]
        }
    }

    func seek(time: TimeInterval) {
        seek(time: time, autoPlay: options.isSeekedAutoPlay) { _ in
        }
    }

    public func registerRemoteControllEvent() {
        let remoteCommand = MPRemoteCommandCenter.shared()
        remoteCommand.playCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.play()
            return .success
        }
        remoteCommand.pauseCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.pause()
            return .success
        }
        remoteCommand.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            if self.state.isPlaying {
                self.pause()
            } else {
                self.play()
            }
            return .success
        }
        remoteCommand.stopCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.player.shutdown()
            return .success
        }
        remoteCommand.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.nextPlayer()
            return .success
        }
        remoteCommand.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.previousPlayer()
            return .success
        }
        remoteCommand.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            self.options.isLoopPlay = event.repeatType != .off
            return .success
        }
        remoteCommand.changeShuffleModeCommand.isEnabled = false
        // remoteCommand.changeShuffleModeCommand.addTarget {})
        remoteCommand.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
        remoteCommand.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            self.player.playbackRate = event.playbackRate
            return .success
        }
        remoteCommand.skipForwardCommand.preferredIntervals = [15]
        remoteCommand.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self.seek(time: self.player.currentPlaybackTime + event.interval)
            return .success
        }
        remoteCommand.skipBackwardCommand.preferredIntervals = [15]
        remoteCommand.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self.seek(time: self.player.currentPlaybackTime - event.interval)
            return .success
        }
        remoteCommand.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(time: event.positionTime)
            return .success
        }
        remoteCommand.enableLanguageOptionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeLanguageOptionCommandEvent else {
                return .commandFailed
            }
            let selectLang = event.languageOption
            if selectLang.languageOptionType == .audible,
               let trackToSelect = self.player.tracks(mediaType: .audio).first(where: { $0.name == selectLang.displayName })
            {
                self.player.select(track: trackToSelect)
            }
            return .success
        }
    }

    @objc private func enterBackground() {
        guard state.isPlaying, !player.isExternalPlaybackActive else {
            return
        }
        if #available(tvOS 14.0, *), player.pipController?.isPictureInPictureActive == true {
            return
        }

        if KSOptions.canBackgroundPlay {
            player.enterBackground()
            return
        }
        pause()
    }

    @objc private func enterForeground() {
        if KSOptions.canBackgroundPlay {
            player.enterForeground()
        }
    }

    #if canImport(UIKit) && !os(xrOS)
    @MainActor
    @objc private func wirelessRouteActiveDidChange(notification: Notification) {
        guard let volumeView = notification.object as? MPVolumeView, isWirelessRouteActive != volumeView.isWirelessRouteActive else { return }
        if volumeView.isWirelessRouteActive {
            if !player.allowsExternalPlayback {
                isWirelessRouteActive = true
            }
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
        }
        isWirelessRouteActive = volumeView.isWirelessRouteActive
    }
    #endif
    #if !os(macOS)
    @objc private func audioInterrupted(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }
        switch type {
        case .began:
            pause()

        case .ended:
            // An interruption ended. Resume playback, if appropriate.

            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                play()
            }

        default:
            break
        }
    }
    #endif
}
