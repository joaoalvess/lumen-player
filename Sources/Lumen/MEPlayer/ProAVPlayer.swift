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

enum ProAVSeekRoute: Equatable {
    case inner(TimeInterval)
    case restart
}

enum ProAVPendingSwitchSeekAction: Equatable {
    case abort
    case deferUntilCommitted
}

enum ProAVAudioSwitchAction: Equatable {
    case ignore
    case abortPending
    case hotSwitch
    case coldRestart
}

enum ProAVSubtitlePreference: Equatable, Sendable {
    case automatic
    case disabled
    case track(Int32)

    func enablesImageTrack(trackID: Int32, defaultEnabled: Bool) -> Bool {
        switch self {
        case .automatic:
            return defaultEnabled
        case .disabled:
            return false
        case let .track(preferredTrackID):
            return trackID == preferredTrackID
        }
    }
}

enum ProAVSourceSwitchOutcome: Equatable {
    case committed
    case failed
    case cancelled
}

enum ProAVTrackSwitchPurpose: Equatable {
    case audio
    case bitmapSubtitle
}

enum ProAVAudioSelectionResult: Equatable {
    case committed
    case failed
    case cancelled
    case unchanged
}

@MainActor
protocol AsyncAudioTrackSelecting: AnyObject {
    func selectAudioTrack(trackID: Int32, completion: @escaping (ProAVAudioSelectionResult) -> Void)
}

struct ProAVTrackSelection: Equatable {
    var audioTrackID: Int32?
    var subtitlePreference: ProAVSubtitlePreference
}

private enum ProAVSwitchKind: Equatable {
    case source
    case audio(generation: Int, previousTrackID: Int32?, targetTrackID: Int32)
    case bitmapSubtitle

    var diagnosticLabel: String {
        switch self {
        case .source:
            return "source-switch"
        case let .audio(generation, previousTrackID, targetTrackID):
            let previous = previousTrackID.map { String($0) } ?? "none"
            return "audio-switch generation=\(generation) from=\(previous) to=\(targetTrackID)"
        case .bitmapSubtitle:
            return "subtitle-switch"
        }
    }
}

@MainActor
public final class ProAVPlayer: AsyncAudioTrackSelecting {
    public static var segmentDuration = TimeInterval(2)
    public static var minimumSegmentsBeforeReady = 2
    public static var serverFactory: () -> ProAVLocalServer = { ProAVLoopbackHTTPServer() }
    private static var didPurgeStaleWorkspaces = false

    private let innerPlayer: KSAVPlayer
    private let server: ProAVLocalServer
    private let workspaceURL: URL
    private var url: URL
    private var options: KSOptions
    private var remuxItem: MEPlayerItem?
    private var session: ProAVRemuxSession?
    private var serverBaseURL: URL?
    private var serverGeneration = 0
    private var startOffset = TimeInterval(0)
    private var pendingSeekCompletion: ((Bool) -> Void)?
    private var launchIndex = 0
    private var activeLaunchIndex = 0
    private var delegateProxy: ProAVLaunchDelegateProxy?
    private var pendingSourceSwitch: PendingSourceSwitch?
    private var deferredSeek: DeferredSeek?
    private var preferredAudioTrackID: Int32?
    private var audioSelectionGeneration = 0
    private var preferredSubtitlePreference = ProAVSubtitlePreference.automatic
    private var embeddedSubtitles = [ProAVEmbeddedSubtitleInfo]()
    private var reportedReady = false
    private var didFail = false
    private var knownDuration = TimeInterval(0)
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
        let trackSelection: ProAVTrackSelection
        let kind: ProAVSwitchKind
        let startedAt: TimeInterval
        let completion: (ProAVSourceSwitchOutcome) -> Void
        var innerSwitchStarted = false
    }

    private struct DeferredSeek {
        let time: TimeInterval
        let completion: (Bool) -> Void
    }

    public required init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
        server = ProAVPlayer.serverFactory()
        innerPlayer = KSAVPlayer(url: url, options: options)
        ProAVPlayer.purgeStaleWorkspacesOnce()
        workspaceURL = ProAVPlayer.workspaceRoot.appendingPathComponent(UUID().uuidString)
        innerPlayer.delegate = self
    }

    private static var workspaceRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lumen-ProAV")
    }

    private static func purgeStaleWorkspacesOnce() {
        guard !didPurgeStaleWorkspaces else { return }
        didPurgeStaleWorkspaces = true
        guard let items = try? FileManager.default.contentsOfDirectory(at: workspaceRoot, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func makeLaunch(url: URL, options: KSOptions, at time: TimeInterval, trackSelection: ProAVTrackSelection) -> RemuxLaunch {
        launchIndex += 1
        let directoryName = "launch\(launchIndex)"
        let directory = workspaceURL.appendingPathComponent(directoryName)
        let configuration = ProAVRemuxSession.Configuration(directory: directory, targetSegmentDuration: ProAVPlayer.segmentDuration, minimumSegmentsBeforeReady: ProAVPlayer.minimumSegmentsBeforeReady)
        let session = ProAVRemuxSession(configuration: configuration)
        session.preferredAudioTrackID = trackSelection.audioTrackID
        session.subtitlePreference = trackSelection.subtitlePreference
        options.startPlayTime = time
        let item = MEPlayerItem(url: url, options: options, remuxSession: session)
        let proxy = ProAVLaunchDelegateProxy(target: self, launch: launchIndex)
        item.delegate = proxy
        return RemuxLaunch(index: launchIndex, directoryName: directoryName, session: session, item: item, proxy: proxy)
    }

    private func startRemux(at time: TimeInterval) {
        let trackSelection = ProAVTrackSelection(audioTrackID: preferredAudioTrackID, subtitlePreference: preferredSubtitlePreference)
        let launch = makeLaunch(url: url, options: options, at: time, trackSelection: trackSelection)
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
            serverGeneration &+= 1
            let generation = serverGeneration
            server.start(rootDirectory: workspaceURL) { [weak self, weak session = self.session] result in
                runOnMainThread {
                    guard let self, self.serverGeneration == generation else { return }
                    switch result {
                    case let .success(baseURL):
                        self.serverBaseURL = baseURL
                        guard let session, self.session === session else { return }
                        self.attach(baseURL: baseURL, directoryName: directoryName)
                    case let .failure(serverError):
                        guard let session, self.session === session else { return }
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

    private func syncEmbeddedSubtitles(item: MEPlayerItem, preserveSelection: Bool = true) {
        let tracks = item.assetTracks.filter { $0.mediaType == .subtitle }
        embeddedSubtitles = ProAVEmbeddedSubtitleInfo.reconcile(existing: embeddedSubtitles, tracks: tracks, preserveSelection: preserveSelection) { [weak self] trackID, isEnabled in
            runOnMainThread { [weak self] in
                self?.embeddedSubtitleSelectionDidChange(trackID: trackID, isEnabled: isEnabled)
            }
        }
    }

    private func detachEmbeddedSubtitles() {
        embeddedSubtitles.forEach { $0.detach() }
    }

    private func fail(error: NSError) {
        abortPendingSourceSwitch(reissuesDeferredSeek: false)
        guard !didFail else { return }
        didFail = true
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        seekCompletion?(false)
        detachEmbeddedSubtitles()
        remuxItem?.delegate = nil
        innerPlayer.shutdown()
        remuxItem?.shutdown()
        session?.requestCleanup()
        serverGeneration &+= 1
        server.stop()
        serverBaseURL = nil
        delegate?.finish(player: self, error: error)
    }

    private func restart(at time: TimeInterval, completion: ((Bool) -> Void)?) {
        abortPendingSourceSwitch(reissuesDeferredSeek: false)
        let previousCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        previousCompletion?(false)
        pendingSeekCompletion = completion
        didFail = false
        teardownActiveLaunch()
        startRemux(at: time)
    }

    private func noteRemuxConsumption() {
        session?.noteConsumed(seconds: innerPlayer.currentPlaybackTime)
    }

    private func teardownActiveLaunch() {
        detachEmbeddedSubtitles()
        remuxItem?.delegate = nil
        innerPlayer.shutdown()
        remuxItem?.shutdown()
        session?.requestCleanup()
    }

    private var timelineOrigin: TimeInterval {
        session?.playlistStartSeconds ?? startOffset
    }

    private var canSwitchSource: Bool {
        !didFail && reportedReady && session != nil && serverBaseURL != nil
    }

    private var activeAudioTrackID: Int32? {
        remuxItem?.assetTracks.first(where: { $0.mediaType == .audio && $0.isEnabled })?.trackID
    }

    private var activeBitmapSubtitleTrackID: Int32? {
        remuxItem?.assetTracks.first(where: { $0.mediaType == .subtitle && $0.isImageSubtitle && $0.isEnabled })?.trackID
    }

    static func trackSelectionNeedsRestart(_ selection: ProAVTrackSelection, activeAudioTrackID: Int32?, activeBitmapSubtitleTrackID: Int32?) -> Bool {
        if let audioTrackID = selection.audioTrackID, audioTrackID != activeAudioTrackID {
            return true
        }
        if case let .track(subtitleTrackID) = selection.subtitlePreference {
            return subtitleTrackID != activeBitmapSubtitleTrackID
        }
        return false
    }

    static func shouldColdRestartTrackSwitch(
        outcome: ProAVSourceSwitchOutcome,
        selectionNeedsRestart: Bool,
        purpose: ProAVTrackSwitchPurpose
    ) -> Bool {
        purpose == .bitmapSubtitle && outcome == .failed && selectionNeedsRestart
    }

    private var desiredTrackSelection: ProAVTrackSelection {
        ProAVTrackSelection(audioTrackID: preferredAudioTrackID ?? activeAudioTrackID, subtitlePreference: preferredSubtitlePreference)
    }

    private func beginTrackSwitch(kind: ProAVSwitchKind, completion: ((ProAVAudioSelectionResult) -> Void)? = nil) {
        let trackSelection = desiredTrackSelection
        beginSourceSwitch(url: url, options: options, trackSelection: trackSelection, kind: kind) { [weak self] outcome in
            self?.trackSwitchDidComplete(outcome: outcome, selection: trackSelection, kind: kind, completion: completion)
        }
    }

    private func trackSwitchDidComplete(
        outcome: ProAVSourceSwitchOutcome,
        selection: ProAVTrackSelection,
        kind: ProAVSwitchKind,
        completion: ((ProAVAudioSelectionResult) -> Void)?
    ) {
        switch kind {
        case let .audio(generation, previousTrackID, targetTrackID):
            if outcome != .committed,
               audioSelectionGeneration == generation,
               preferredAudioTrackID == targetTrackID
            {
                preferredAudioTrackID = activeAudioTrackID ?? previousTrackID
            }
            let result: ProAVAudioSelectionResult
            switch outcome {
            case .committed:
                result = .committed
            case .failed:
                result = .failed
            case .cancelled:
                result = .cancelled
            }
            let active = activeAudioTrackID.map { String($0) } ?? "none"
            KSLog("[\(kind.diagnosticLabel)] finished result=\(result) active=\(active) position=\(currentPlaybackTime) playing=\(isPlaying)")
            completion?(result)
        case .bitmapSubtitle:
            let needsRestart = Self.trackSelectionNeedsRestart(selection, activeAudioTrackID: activeAudioTrackID, activeBitmapSubtitleTrackID: activeBitmapSubtitleTrackID)
            guard Self.shouldColdRestartTrackSwitch(outcome: outcome, selectionNeedsRestart: needsRestart, purpose: .bitmapSubtitle) else { return }
            restart(at: currentPlaybackTime, completion: nil)
        case .source:
            break
        }
    }

    private func embeddedSubtitleSelectionDidChange(trackID: Int32, isEnabled: Bool) {
        if let pendingSourceSwitch, pendingSourceSwitch.url != url {
            return
        }
        if isEnabled {
            preferredSubtitlePreference = .track(trackID)
            preferredAudioTrackID = pendingSourceSwitch?.trackSelection.audioTrackID ?? preferredAudioTrackID ?? activeAudioTrackID
            guard activeBitmapSubtitleTrackID != trackID else { return }
            if canSwitchSource {
                beginTrackSwitch(kind: .bitmapSubtitle)
            } else {
                restart(at: currentPlaybackTime, completion: nil)
            }
        } else {
            preferredSubtitlePreference = .disabled
            guard let pendingSourceSwitch else { return }
            let pendingAudioTrackID = pendingSourceSwitch.trackSelection.audioTrackID
            if pendingAudioTrackID == nil || pendingAudioTrackID == activeAudioTrackID {
                abortPendingSourceSwitch()
            }
        }
    }

    private func beginSourceSwitch(
        url: URL,
        options: KSOptions,
        trackSelection: ProAVTrackSelection,
        kind: ProAVSwitchKind,
        completion: @escaping ((ProAVSourceSwitchOutcome) -> Void)
    ) {
        abortPendingSourceSwitch()
        guard canSwitchSource else {
            completion(.failed)
            return
        }
        let time = currentPlaybackTime
        let launch = makeLaunch(url: url, options: options, at: time, trackSelection: trackSelection)
        let startedAt = CACurrentMediaTime()
        pendingSourceSwitch = PendingSourceSwitch(
            launch: launch,
            url: url,
            options: options,
            startOffset: time,
            trackSelection: trackSelection,
            kind: kind,
            startedAt: startedAt,
            completion: completion
        )
        KSLog("[\(kind.diagnosticLabel)] remux started position=\(time) playing=\(isPlaying)")
        launch.session.onReady = { [weak self, weak session = launch.session] _ in
            runOnMainThread {
                guard let self, let session, self.pendingSourceSwitch?.launch.session === session else { return }
                if let pending = self.pendingSourceSwitch {
                    KSLog("[\(pending.kind.diagnosticLabel)] remux ready elapsed=\(CACurrentMediaTime() - pending.startedAt)")
                }
                self.pendingSourceSwitchDidBecomeReady()
            }
        }
        launch.session.onFailure = { [weak self, weak session = launch.session] sessionError in
            runOnMainThread {
                guard let self, let session, self.pendingSourceSwitch?.launch.session === session else { return }
                if let pending = self.pendingSourceSwitch {
                    KSLog("[\(pending.kind.diagnosticLabel)] remux failed elapsed=\(CACurrentMediaTime() - pending.startedAt) error=\(sessionError.domain)/\(sessionError.code) \(sessionError.localizedDescription)")
                }
                self.abortPendingSourceSwitch(outcome: .failed)
            }
        }
        launch.item.prepareToPlay()
    }

    static func seekRoute(target: TimeInterval, startOffset: TimeInterval, closedSegmentsDuration: TimeInterval) -> ProAVSeekRoute {
        guard closedSegmentsDuration > 0, target >= startOffset, target <= startOffset + closedSegmentsDuration else {
            return .restart
        }
        return .inner(target - startOffset)
    }

    static func pendingSwitchSeekAction(route: ProAVSeekRoute, innerSwitchCommitting: Bool) -> ProAVPendingSwitchSeekAction {
        guard case .inner = route, innerSwitchCommitting else {
            return .abort
        }
        return .deferUntilCommitted
    }

    static func audioSwitchAction(target: Int32, activeTrackID: Int32?, preferredTrackID: Int32?, pendingTrackID: Int32?, canHotSwitch: Bool) -> ProAVAudioSwitchAction {
        let currentTrackID = activeTrackID ?? preferredTrackID
        if let pendingTrackID {
            if pendingTrackID == target {
                return .ignore
            }
            if currentTrackID == target {
                return .abortPending
            }
        } else if currentTrackID == target {
            return .ignore
        }
        return canHotSwitch ? .hotSwitch : .coldRestart
    }

    private func pendingSourceSwitchDidBecomeReady() {
        guard let pending = pendingSourceSwitch else { return }
        guard let serverBaseURL else {
            abortPendingSourceSwitch(outcome: .failed)
            return
        }
        let masterURL = serverBaseURL.appendingPathComponent(pending.launch.directoryName).appendingPathComponent(ProAVRemuxSession.masterPlaylistName)
        pendingSourceSwitch?.innerSwitchStarted = true
        let candidateOrigin = pending.launch.session.playlistStartSeconds ?? pending.startOffset
        let resumeShift = timelineOrigin - candidateOrigin
        let candidateConsumedSeconds = max(0, innerPlayer.currentPlaybackTime + resumeShift)
        innerPlayer.switchSourceDetailed(
            url: masterURL,
            options: pending.options,
            resumeShift: resumeShift,
            diagnosticLabel: pending.kind.diagnosticLabel
        ) { [weak self] result in
            runOnMainThread {
                guard let self, self.pendingSourceSwitch?.launch.session === pending.launch.session else { return }
                switch result {
                case .committed:
                    pending.launch.session.noteConsumed(seconds: candidateConsumedSeconds)
                    self.commitPendingSourceSwitch()
                case .failed, .timedOut:
                    self.abortPendingSourceSwitch(outcome: .failed)
                case .cancelled:
                    self.abortPendingSourceSwitch(outcome: .cancelled)
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
        let sourceChanged = pending.url != url
        previousItem?.delegate = nil
        detachEmbeddedSubtitles()
        url = pending.url
        options = pending.options
        preferredAudioTrackID = pending.trackSelection.audioTrackID
        preferredSubtitlePreference = pending.trackSelection.subtitlePreference
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
        if sourceChanged {
            embeddedSubtitles.forEach { $0.reset() }
            // Stream identifiers are only stable within the same source. Keeping the
            // old proxy would let SubtitleModel's delayed deselection disable a track
            // that already belongs to the new URL.
            embeddedSubtitles.removeAll()
        }
        syncEmbeddedSubtitles(item: pending.launch.item, preserveSelection: !sourceChanged)
        if session?.videoSignaling?.preferredDynamicRange != previousDynamicRange {
            applyDisplayCriteria()
        }
        KSLog("[\(pending.kind.diagnosticLabel)] remux committed elapsed=\(CACurrentMediaTime() - pending.startedAt) position=\(currentPlaybackTime) playing=\(isPlaying)")
        pending.completion(.committed)
        if let deferred = takeDeferredSeek() {
            seek(time: deferred.time, completion: deferred.completion)
        }
    }

    private func takeDeferredSeek() -> DeferredSeek? {
        let deferred = deferredSeek
        deferredSeek = nil
        return deferred
    }

    private func abortPendingSourceSwitch(outcome: ProAVSourceSwitchOutcome = .cancelled, reissuesDeferredSeek: Bool = true) {
        let deferred = takeDeferredSeek()
        if let pending = pendingSourceSwitch {
            pendingSourceSwitch = nil
            if pending.innerSwitchStarted {
                innerPlayer.abandonPendingSourceSwitch()
            }
            pending.launch.item.delegate = nil
            pending.launch.item.shutdown()
            pending.launch.session.requestCleanup()
            pending.completion(outcome)
        }
        guard let replay = deferred else { return }
        if reissuesDeferredSeek {
            seek(time: replay.time, completion: replay.completion)
        } else {
            replay.completion(false)
        }
    }

    fileprivate func launchDidOpen(index: Int) {
        if let pending = pendingSourceSwitch, pending.launch.index == index {
            KSLog("[\(pending.kind.diagnosticLabel)] input opened elapsed=\(CACurrentMediaTime() - pending.startedAt)")
            return
        }
        guard index == activeLaunchIndex, let remuxItem else { return }
        syncEmbeddedSubtitles(item: remuxItem)
    }

    fileprivate func launchDidFail(index: Int, error: NSError?) {
        if let pending = pendingSourceSwitch, pending.launch.index == index {
            abortPendingSourceSwitch(outcome: .failed)
            return
        }
        guard index == activeLaunchIndex else { return }
        fail(error: error ?? NSError(errorCode: .formatOpenInput))
    }
}

extension ProAVPlayer: @preconcurrency MediaPlayerProtocol {
    public var view: UIView? { innerPlayer.view }
    public var playableTime: TimeInterval { timelineOrigin + innerPlayer.playableTime }
    public var isReadyToPlay: Bool { innerPlayer.isReadyToPlay || (reportedReady && !didFail) }
    public var playbackState: MediaPlaybackState { innerPlayer.playbackState }
    public var loadState: MediaLoadState { innerPlayer.loadState }
    public var isPlaying: Bool { innerPlayer.isPlaying }
    public var seekable: Bool { true }
    public var duration: TimeInterval {
        let current = remuxItem?.duration ?? innerPlayer.duration
        guard current > 0 else { return knownDuration }
        knownDuration = current
        return current
    }

    public var fileSize: Double { remuxItem?.fileSize ?? innerPlayer.fileSize }
    public var naturalSize: CGSize { remuxItem?.naturalSize ?? innerPlayer.naturalSize }
    public var chapters: [Chapter] { remuxItem?.chapters ?? [] }
    public var currentPlaybackTime: TimeInterval {
        noteRemuxConsumption()
        return timelineOrigin + innerPlayer.currentPlaybackTime
    }

    public var dynamicInfo: DynamicInfo? { remuxItem?.dynamicInfo }
    public var subtitleDataSouce: SubtitleDataSouce? { self }

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
        if remuxItem != nil {
            abortPendingSourceSwitch(reissuesDeferredSeek: false)
            teardownActiveLaunch()
        }
        didFail = false
        startRemux(at: options.startPlayTime)
    }

    public func replace(url: URL, options: KSOptions) {
        shutdown()
        didFail = false
        reportedReady = false
        preferredAudioTrackID = nil
        preferredSubtitlePreference = .automatic
        knownDuration = 0
        embeddedSubtitles.removeAll()
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
        let trackSelection = ProAVTrackSelection(audioTrackID: nil, subtitlePreference: .automatic)
        beginSourceSwitch(url: url, options: options, trackSelection: trackSelection, kind: .source) { outcome in
            completion(outcome == .committed)
        }
    }

    public func cancelSourceSwitch() {
        abortPendingSourceSwitch()
    }

    public func shutdown() {
        abortPendingSourceSwitch(reissuesDeferredSeek: false)
        reportedReady = false
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        seekCompletion?(false)
        detachEmbeddedSubtitles()
        remuxItem?.delegate = nil
        innerPlayer.shutdown()
        remuxItem?.shutdown()
        session?.requestCleanup()
        remuxItem = nil
        session = nil
        serverGeneration &+= 1
        server.stop()
        serverBaseURL = nil
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        let target = max(time, 0)
        let route = session.map {
            ProAVPlayer.seekRoute(
                target: target,
                startOffset: timelineOrigin,
                closedSegmentsDuration: $0.closedSegmentsDuration
            )
        }
        if !didFail,
           innerPlayer.isReadyToPlay,
           let session,
           case let .inner(innerTime) = route {
            if let pendingSourceSwitch {
                let innerSwitchCommitting = pendingSourceSwitch.innerSwitchStarted && innerPlayer.isCommittingSourceSwitch
                switch ProAVPlayer.pendingSwitchSeekAction(route: .inner(innerTime), innerSwitchCommitting: innerSwitchCommitting) {
                case .abort:
                    abortPendingSourceSwitch(reissuesDeferredSeek: false)
                case .deferUntilCommitted:
                    takeDeferredSeek()?.completion(false)
                    deferredSeek = DeferredSeek(time: target, completion: completion)
                    return
                }
            }
            session.noteConsumed(seconds: innerTime)
            innerPlayer.seek(time: innerTime, completion: completion)
            return
        }
        restart(at: target, completion: completion)
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
        selectAudioTrack(trackID: track.trackID) { _ in }
    }

    func selectAudioTrack(trackID: Int32, completion: @escaping (ProAVAudioSelectionResult) -> Void) {
        if let pendingSourceSwitch, pendingSourceSwitch.url != url {
            completion(.failed)
            return
        }
        guard tracks(mediaType: .audio).contains(where: { $0.trackID == trackID }) else {
            completion(.failed)
            return
        }
        audioSelectionGeneration &+= 1
        let generation = audioSelectionGeneration
        let previousTrackID = activeAudioTrackID
        let kind = ProAVSwitchKind.audio(generation: generation, previousTrackID: previousTrackID, targetTrackID: trackID)
        let action = ProAVPlayer.audioSwitchAction(target: trackID, activeTrackID: activeAudioTrackID, preferredTrackID: preferredAudioTrackID, pendingTrackID: pendingSourceSwitch?.trackSelection.audioTrackID, canHotSwitch: canSwitchSource)
        KSLog("[\(kind.diagnosticLabel)] selected action=\(action) position=\(currentPlaybackTime) playing=\(isPlaying)")
        switch action {
        case .ignore:
            completion(.unchanged)
        case .abortPending:
            preferredAudioTrackID = trackID
            let trackSelection = desiredTrackSelection
            if Self.trackSelectionNeedsRestart(trackSelection, activeAudioTrackID: activeAudioTrackID, activeBitmapSubtitleTrackID: activeBitmapSubtitleTrackID) {
                beginTrackSwitch(kind: kind, completion: completion)
            } else {
                abortPendingSourceSwitch()
                completion(.unchanged)
            }
        case .hotSwitch:
            preferredAudioTrackID = trackID
            beginTrackSwitch(kind: kind, completion: completion)
        case .coldRestart:
            preferredAudioTrackID = trackID
            let position = currentPlaybackTime
            KSLog("[\(kind.diagnosticLabel)] cold preparation started position=\(position)")
            restart(at: position) { [weak self] success in
                guard let self else { return }
                let result: ProAVAudioSelectionResult = success ? .committed : .failed
                if !success, self.audioSelectionGeneration == generation, self.preferredAudioTrackID == trackID {
                    self.preferredAudioTrackID = self.activeAudioTrackID ?? previousTrackID
                }
                KSLog("[\(kind.diagnosticLabel)] cold preparation finished result=\(result) position=\(self.currentPlaybackTime) playing=\(self.isPlaying)")
                completion(result)
            }
        }
    }
}

extension ProAVPlayer: @preconcurrency SubtitleDataSouce {
    public var infos: [any SubtitleInfo] { embeddedSubtitles }
}

extension ProAVPlayer: MediaPlayerDelegate {
    public func readyToPlay(player _: some MediaPlayerProtocol) {
        let seekCompletion = pendingSeekCompletion
        pendingSeekCompletion = nil
        if reportedReady {
            seekCompletion?(true)
        } else {
            reportedReady = true
            seekCompletion?(true)
            delegate?.readyToPlay(player: self)
        }
    }

    public func changeLoadState(player _: some MediaPlayerProtocol) {
        noteRemuxConsumption()
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
            let nsError = error as NSError
            KSLog("[proav-active] av-player failed error=\(nsError.domain)/\(nsError.code) \(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            fail(error: nsError)
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

    func sourceDidOpened() {
        let index = launch
        runOnMainThread { [weak target] in
            target?.launchDidOpen(index: index)
        }
    }

    func sourceDidFailed(error: NSError?) {
        let index = launch
        runOnMainThread { [weak target] in
            target?.launchDidFail(index: index, error: error)
        }
    }

    func sourceDidFinished() {}

    func sourceDidChange(oldBitRate _: Int64, newBitrate _: Int64) {}
}
