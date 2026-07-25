import AVFoundation
import Foundation
#if os(tvOS) || os(xrOS)
import DisplayCriteria
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
public final class ProAVPlayer {
    public static var segmentDuration = TimeInterval(2)
    public static var minimumSegmentsBeforeReady = 2
    public static var serverFactory: () -> ProAVLocalServer = { ProAVLoopbackHTTPServer() }

    private let innerPlayer: KSAVPlayer
    private let server: ProAVLocalServer
    private let workspaceURL: URL
    private var url: URL
    private var options: KSOptions
    private var remuxItem: MEPlayerItem?
    private var session: ProAVRemuxSession?
    private var serverBaseURL: URL?
    private var startOffset = TimeInterval(0)
    private var pendingSeekCompletion: ((Bool) -> Void)?
    private var launchIndex = 0
    private var activeLaunchIndex = 0
    private var delegateProxy: ProAVLaunchDelegateProxy?
    private var pendingSourceSwitch: PendingSourceSwitch?
    private var preferredAudioTrackID: Int32?
    private var reportedReady = false
    private var didFail = false
    public weak var delegate: MediaPlayerDelegate?

    private struct RemuxLaunch {
        let index: Int
        let directoryName: String
        let session: ProAVRemuxSession
        let item: MEPlayerItem
        let proxy: ProAVLaunchDelegateProxy
    }

    private struct PendingSourceSwitch {
        let launch: RemuxLaunch
        let url: URL
        let options: KSOptions
        let startOffset: TimeInterval
        let completion: (Bool) -> Void
        var innerSwitchStarted = false
    }

    public required init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
        server = ProAVPlayer.serverFactory()
        innerPlayer = KSAVPlayer(url: url, options: options)
        ProAVPlayer.purgeWorkspaces()
        workspaceURL = ProAVPlayer.workspaceRoot.appendingPathComponent(UUID().uuidString)
        innerPlayer.delegate = self
    }

    private static var workspaceRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lumen-ProAV")
    }

    private static func purgeWorkspaces() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: workspaceRoot, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func makeLaunch(url: URL, options: KSOptions, at time: TimeInterval, audioTrackID: Int32?) -> RemuxLaunch {
        launchIndex += 1
        let directoryName = "launch\(launchIndex)"
        let directory = workspaceURL.appendingPathComponent(directoryName)
        let configuration = ProAVRemuxSession.Configuration(directory: directory, targetSegmentDuration: ProAVPlayer.segmentDuration, minimumSegmentsBeforeReady: ProAVPlayer.minimumSegmentsBeforeReady)
        let session = ProAVRemuxSession(configuration: configuration)
        session.preferredAudioTrackID = audioTrackID
        options.startPlayTime = time
        let item = MEPlayerItem(url: url, options: options, remuxSession: session)
        let proxy = ProAVLaunchDelegateProxy(target: self, launch: launchIndex)
        item.delegate = proxy
        return RemuxLaunch(index: launchIndex, directoryName: directoryName, session: session, item: item, proxy: proxy)
    }

    private func startRemux(at time: TimeInterval) {
        let launch = makeLaunch(url: url, options: options, at: time, audioTrackID: preferredAudioTrackID)
        launch.session.onReady = { [weak self, weak session = launch.session, directoryName = launch.directoryName] _ in
            runOnMainThread {
                guard let self, let session, self.session === session else { return }
                self.remuxDidBecomeReady(directoryName: directoryName)
            }
        }
        launch.session.onFailure = { [weak self, weak session = launch.session] sessionError in
            runOnMainThread {
                guard let self, let session, self.session === session else { return }
                self.fail(error: sessionError)
            }
        }
        session = launch.session
        remuxItem = launch.item
        delegateProxy = launch.proxy
        activeLaunchIndex = launch.index
        startOffset = time
        launch.item.prepareToPlay()
    }

    private func remuxDidBecomeReady(directoryName: String) {
        guard !didFail else { return }
        applyDisplayCriteria()
        if let serverBaseURL {
            attach(baseURL: serverBaseURL, directoryName: directoryName)
        } else {
            server.start(rootDirectory: workspaceURL) { [weak self] result in
                runOnMainThread {
                    guard let self else { return }
                    switch result {
                    case let .success(baseURL):
                        self.serverBaseURL = baseURL
                        self.attach(baseURL: baseURL, directoryName: directoryName)
                    case let .failure(serverError):
                        self.fail(error: NSError(description: "ProAV server start failed: \(serverError.localizedDescription)"))
                    }
                }
            }
        }
    }

    private func attach(baseURL: URL, directoryName: String) {
        guard !didFail else { return }
        let masterURL = baseURL.appendingPathComponent(directoryName).appendingPathComponent(ProAVRemuxSession.masterPlaylistName)
        innerPlayer.replace(url: masterURL, options: options)
        innerPlayer.prepareToPlay()
    }

    private func applyDisplayCriteria() {
        #if os(tvOS) || os(xrOS)
        guard let displayManager = UIApplication.shared.windows.first?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled,
              let signaling = session?.videoSignaling
        else {
            return
        }
        let refreshRate = remuxItem?.assetTracks.first(where: { $0.mediaType == .video && $0.isEnabled })?.nominalFrameRate ?? 0
        guard refreshRate > 0 else { return }
        displayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refreshRate, videoDynamicRange: signaling.preferredDynamicRange.rawValue)
        #endif
    }

    private func fail(error: NSError) {
        abortPendingSourceSwitch()
        guard !didFail else { return }
        didFail = true
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        seekCompletion?(false)
        remuxItem?.delegate = nil
        innerPlayer.shutdown()
        remuxItem?.shutdown()
        session?.requestCleanup()
        server.stop()
        serverBaseURL = nil
        delegate?.finish(player: self, error: error)
    }

    private func restart(at time: TimeInterval, completion: ((Bool) -> Void)?) {
        abortPendingSourceSwitch()
        let previousCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        previousCompletion?(false)
        pendingSeekCompletion = completion
        didFail = false
        remuxItem?.delegate = nil
        innerPlayer.shutdown()
        remuxItem?.shutdown()
        session?.requestCleanup()
        startRemux(at: time)
    }

    private func pendingSourceSwitchDidBecomeReady() {
        guard let pending = pendingSourceSwitch else { return }
        guard let serverBaseURL else {
            abortPendingSourceSwitch()
            return
        }
        let masterURL = serverBaseURL.appendingPathComponent(pending.launch.directoryName).appendingPathComponent(ProAVRemuxSession.masterPlaylistName)
        pendingSourceSwitch?.innerSwitchStarted = true
        innerPlayer.switchSource(url: masterURL, options: pending.options) { [weak self] success in
            runOnMainThread {
                guard let self, self.pendingSourceSwitch?.launch.session === pending.launch.session else { return }
                if success {
                    self.commitPendingSourceSwitch()
                } else {
                    self.abortPendingSourceSwitch()
                }
            }
        }
    }

    private func commitPendingSourceSwitch() {
        guard let pending = pendingSourceSwitch else { return }
        pendingSourceSwitch = nil
        let previousSession = session
        let previousItem = remuxItem
        let previousDynamicRange = previousSession?.videoSignaling?.preferredDynamicRange
        previousItem?.delegate = nil
        url = pending.url
        options = pending.options
        preferredAudioTrackID = nil
        session = pending.launch.session
        remuxItem = pending.launch.item
        delegateProxy = pending.launch.proxy
        activeLaunchIndex = pending.launch.index
        startOffset = pending.startOffset
        pending.launch.session.onReady = nil
        pending.launch.session.onFailure = { [weak self, weak session = pending.launch.session] sessionError in
            runOnMainThread {
                guard let self, let session, self.session === session else { return }
                self.fail(error: sessionError)
            }
        }
        previousItem?.shutdown()
        previousSession?.requestCleanup()
        if session?.videoSignaling?.preferredDynamicRange != previousDynamicRange {
            applyDisplayCriteria()
        }
        pending.completion(true)
    }

    private func abortPendingSourceSwitch() {
        guard let pending = pendingSourceSwitch else { return }
        pendingSourceSwitch = nil
        if pending.innerSwitchStarted {
            innerPlayer.abandonPendingSourceSwitch()
        }
        pending.launch.item.delegate = nil
        pending.launch.item.shutdown()
        pending.launch.session.requestCleanup()
        pending.completion(false)
    }

    fileprivate func launchDidFail(index: Int, error: NSError?) {
        if let pending = pendingSourceSwitch, pending.launch.index == index {
            abortPendingSourceSwitch()
            return
        }
        guard index == activeLaunchIndex else { return }
        fail(error: error ?? NSError(errorCode: .formatOpenInput))
    }
}

extension ProAVPlayer: MediaPlayerProtocol {
    public var view: UIView? { innerPlayer.view }
    public var playableTime: TimeInterval { startOffset + innerPlayer.playableTime }
    public var isReadyToPlay: Bool { innerPlayer.isReadyToPlay }
    public var playbackState: MediaPlaybackState { innerPlayer.playbackState }
    public var loadState: MediaLoadState { innerPlayer.loadState }
    public var isPlaying: Bool { innerPlayer.isPlaying }
    public var seekable: Bool { true }
    public var duration: TimeInterval { remuxItem?.duration ?? innerPlayer.duration }
    public var fileSize: Double { remuxItem?.fileSize ?? innerPlayer.fileSize }
    public var naturalSize: CGSize { remuxItem?.naturalSize ?? innerPlayer.naturalSize }
    public var chapters: [Chapter] { remuxItem?.chapters ?? [] }
    public var currentPlaybackTime: TimeInterval { startOffset + innerPlayer.currentPlaybackTime }
    public var dynamicInfo: DynamicInfo? { remuxItem?.dynamicInfo }
    public var subtitleDataSouce: SubtitleDataSouce? { nil }

    public var isMuted: Bool {
        get { innerPlayer.isMuted }
        set { innerPlayer.isMuted = newValue }
    }

    public var allowsExternalPlayback: Bool {
        get { innerPlayer.allowsExternalPlayback }
        set { innerPlayer.allowsExternalPlayback = newValue }
    }

    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool {
        get { innerPlayer.usesExternalPlaybackWhileExternalScreenIsActive }
        set { innerPlayer.usesExternalPlaybackWhileExternalScreenIsActive = newValue }
    }

    public var isExternalPlaybackActive: Bool { innerPlayer.isExternalPlaybackActive }

    public var playbackRate: Float {
        get { innerPlayer.playbackRate }
        set { innerPlayer.playbackRate = newValue }
    }

    public var playbackVolume: Float {
        get { innerPlayer.playbackVolume }
        set { innerPlayer.playbackVolume = newValue }
    }

    public var contentMode: UIViewContentMode {
        get { innerPlayer.contentMode }
        set { innerPlayer.contentMode = newValue }
    }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator { innerPlayer.playbackCoordinator }

    @available(tvOS 14.0, *)
    public var pipController: KSPictureInPictureController? { innerPlayer.pipController }

    public func prepareToPlay() {
        didFail = false
        startRemux(at: options.startPlayTime)
    }

    public func replace(url: URL, options: KSOptions) {
        shutdown()
        didFail = false
        reportedReady = false
        preferredAudioTrackID = nil
        self.url = url
        self.options = options
    }

    public func play() {
        innerPlayer.play()
    }

    public func pause() {
        innerPlayer.pause()
    }

    public func switchSource(url: URL, options: KSOptions, completion: @escaping ((Bool) -> Void)) {
        abortPendingSourceSwitch()
        guard !didFail, reportedReady, session != nil, serverBaseURL != nil else {
            completion(false)
            return
        }
        let time = currentPlaybackTime
        let launch = makeLaunch(url: url, options: options, at: time, audioTrackID: nil)
        pendingSourceSwitch = PendingSourceSwitch(launch: launch, url: url, options: options, startOffset: time, completion: completion)
        launch.session.onReady = { [weak self, weak session = launch.session] _ in
            runOnMainThread {
                guard let self, let session, self.pendingSourceSwitch?.launch.session === session else { return }
                self.pendingSourceSwitchDidBecomeReady()
            }
        }
        launch.session.onFailure = { [weak self, weak session = launch.session] _ in
            runOnMainThread {
                guard let self, let session, self.pendingSourceSwitch?.launch.session === session else { return }
                self.abortPendingSourceSwitch()
            }
        }
        launch.item.prepareToPlay()
    }

    public func cancelSourceSwitch() {
        abortPendingSourceSwitch()
    }

    public func shutdown() {
        abortPendingSourceSwitch()
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        seekCompletion?(false)
        remuxItem?.delegate = nil
        innerPlayer.shutdown()
        remuxItem?.shutdown()
        session?.requestCleanup()
        remuxItem = nil
        session = nil
        server.stop()
        serverBaseURL = nil
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        restart(at: max(time, 0), completion: completion)
    }

    public func enterBackground() {
        innerPlayer.enterBackground()
    }

    public func enterForeground() {
        innerPlayer.enterForeground()
    }

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        await innerPlayer.thumbnailImageAtCurrentTime()
    }

    public func tracks(mediaType: AVFoundation.AVMediaType) -> [MediaPlayerTrack] {
        if let remuxItem {
            return remuxItem.assetTracks.filter { $0.mediaType == mediaType }
        }
        return innerPlayer.tracks(mediaType: mediaType)
    }

    public func select(track: some MediaPlayerTrack) {
        guard track.mediaType == .audio else { return }
        guard preferredAudioTrackID != track.trackID else { return }
        preferredAudioTrackID = track.trackID
        remuxItem?.assetTracks.filter { $0.mediaType == .audio }.forEach { $0.isEnabled = $0.trackID == track.trackID }
        restart(at: currentPlaybackTime, completion: nil)
    }
}

extension ProAVPlayer: MediaPlayerDelegate {
    public func readyToPlay(player _: some MediaPlayerProtocol) {
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        if reportedReady {
            seekCompletion?(true)
            if options.isSeekedAutoPlay {
                play()
            }
        } else {
            reportedReady = true
            seekCompletion?(true)
            delegate?.readyToPlay(player: self)
        }
    }

    public func changeLoadState(player _: some MediaPlayerProtocol) {
        delegate?.changeLoadState(player: self)
    }

    public func changeBuffering(player _: some MediaPlayerProtocol, progress: Int) {
        delegate?.changeBuffering(player: self, progress: progress)
    }

    public func playBack(player _: some MediaPlayerProtocol, loopCount: Int) {
        delegate?.playBack(player: self, loopCount: loopCount)
    }

    public func finish(player _: some MediaPlayerProtocol, error: Error?) {
        if let error {
            fail(error: NSError(description: "ProAV playback failed: \(error.localizedDescription)"))
        } else {
            delegate?.finish(player: self, error: nil)
        }
    }
}

private final class ProAVLaunchDelegateProxy: MEPlayerDelegate {
    private weak var target: ProAVPlayer?
    private let launch: Int

    init(target: ProAVPlayer, launch: Int) {
        self.target = target
        self.launch = launch
    }

    func sourceDidChange(loadingState _: LoadingState) {}

    func sourceDidOpened() {}

    func sourceDidFailed(error: NSError?) {
        let index = launch
        runOnMainThread { [weak target] in
            target?.launchDidFail(index: index, error: error)
        }
    }

    func sourceDidFinished() {}

    func sourceDidChange(oldBitRate _: Int64, newBitrate _: Int64) {}
}
