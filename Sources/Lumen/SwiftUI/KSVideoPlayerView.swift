//
//  File.swift
//  Lumen
//
//  Created by kintan on 2022/1/29.
//
import AVFoundation
import MediaPlayer
import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
@MainActor
public struct KSVideoPlayerView: View {
    private let subtitleDataSouce: SubtitleDataSouce?
    private let closeAction: (() -> Void)?
    private let usesEmbeddedTitle: Bool
    @State
    private var title: String
    @StateObject
    private var playerCoordinator: KSVideoPlayer.Coordinator
    @Environment(\.dismiss)
    private var dismiss
    @FocusState
    private var focusableField: FocusableField?

    public let options: KSOptions
    @State
    private var showVideoSetting = false
    @State
    private var playbackError: Error?
    #if os(tvOS)
    private var tvMetadata = TVPlayerMetadata()
    @State
    private var tvOverlayMode = TVOverlayMode.transport
    @State
    private var tvSkipHint: TVSkipHint?
    @State
    private var tvIsInitialLoading = true
    @State
    private var tvActivePrompt: TVActivePrompt?
    @State
    private var tvDismissedSkips = Set<Int>()
    @State
    private var tvNeedsNowPlayingRefresh = false
    #endif
    private let requestedURL: URL
    @State
    public var url: URL {
        didSet {
            #if os(macOS)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            #endif
        }
    }

    public init(url: URL, options: KSOptions, title: String? = nil, onClose: (() -> Void)? = nil) {
        self.init(
            coordinator: KSVideoPlayer.Coordinator(),
            url: url,
            options: options,
            title: title,
            subtitleDataSouce: nil,
            onClose: onClose
        )
    }

    public init(
        coordinator: KSVideoPlayer.Coordinator,
        url: URL,
        options: KSOptions,
        title: String? = nil,
        subtitleDataSouce: SubtitleDataSouce? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.init(
            coordinator: coordinator,
            url: .init(wrappedValue: url),
            options: options,
            title: .init(wrappedValue: title ?? url.lastPathComponent),
            subtitleDataSouce: subtitleDataSouce,
            onClose: onClose,
            usesEmbeddedTitle: title == nil
        )
    }

    public init(
        coordinator: KSVideoPlayer.Coordinator,
        url: State<URL>,
        options: KSOptions,
        title: State<String>,
        subtitleDataSouce: SubtitleDataSouce?,
        onClose: (() -> Void)? = nil
    ) {
        self.init(
            coordinator: coordinator,
            url: url,
            options: options,
            title: title,
            subtitleDataSouce: subtitleDataSouce,
            onClose: onClose,
            usesEmbeddedTitle: false
        )
    }

    private init(
        coordinator: KSVideoPlayer.Coordinator,
        url: State<URL>,
        options: KSOptions,
        title: State<String>,
        subtitleDataSouce: SubtitleDataSouce?,
        onClose: (() -> Void)?,
        usesEmbeddedTitle: Bool
    ) {
        requestedURL = url.wrappedValue
        _url = url
        _playerCoordinator = .init(wrappedValue: coordinator)
        _title = title
        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url.wrappedValue)
        #endif
        self.options = options
        self.subtitleDataSouce = subtitleDataSouce
        closeAction = onClose
        self.usesEmbeddedTitle = usesEmbeddedTitle
    }

    public var body: some View {
        ZStack {
            GeometryReader { proxy in
                playView
                HStack {
                    Spacer()
                    VideoSubtitleView(model: playerCoordinator.subtitleModel)
                        .allowsHitTesting(false) // 禁止字幕视图交互，以免抢占视图的点击事件或其它手势事件
                    Spacer()
                }
                .padding()
                #if os(tvOS)
                .padding(.bottom, playerCoordinator.isMaskShow ? 200 : 0)
                .animation(TVPlayerMotion.transition, value: playerCoordinator.isMaskShow)
                #endif
                controllerView(playerWidth: proxy.size.width)
                #if os(tvOS)
                    .ignoresSafeArea()
                #endif
            }
            #if os(tvOS)
            tvPromptLayer
            if tvIsInitialLoading, playbackError == nil {
                ZStack {
                    Color.black
                    ProgressView()
                }
                .ignoresSafeArea()
            }
            #endif
            if let playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                    Text(playbackError.localizedDescription)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                #if os(tvOS)
                .tvPlayerControlMaterial(in: RoundedRectangle(cornerRadius: 16))
                #else
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                #endif
                .padding()
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .automatic)
        .task(id: requestedURL) {
            if url != requestedURL {
                url = requestedURL
            }
        }
        #if os(tvOS)
            .onPlayPauseCommand {
                togglePlaybackAndShowTransport()
            }
            .onExitCommand {
                if tvIsInitialLoading {
                    close()
                } else if tvActivePrompt != nil {
                    dismissTVPrompt()
                } else if tvOverlayMode != .transport {
                    showTransportAndFocusTimeline()
                } else if playerCoordinator.isMaskShow {
                    playerCoordinator.isMaskShow = false
                    focusableField = .play
                } else {
                    close()
                }
            }
            .onChange(of: tvActivePrompt) { _ in
                refreshTVIdleFocus()
            }
            .onChange(of: url) { _ in
                tvDismissedSkips = []
            }
        #endif
    }

    private func close() {
        if let closeAction {
            closeAction()
        } else {
            dismiss()
        }
    }

    private var playView: some View {
        KSVideoPlayer(coordinator: playerCoordinator, url: url, options: options)
            .onStateChanged { playerLayer, state in
                if state == .preparing {
                    playbackError = nil
                    #if os(tvOS)
                    tvIsInitialLoading = true
                    #endif
                }
                if state == .readyToPlay {
                    #if os(tvOS)
                    tvIsInitialLoading = false
                    #endif
                    if usesEmbeddedTitle,
                       let movieTitle = playerLayer.player.dynamicInfo?.metadata["title"] {
                        title = movieTitle
                    }
                    #if os(tvOS)
                    applyTVNowPlaying(on: playerLayer)
                    tvNeedsNowPlayingRefresh = true
                    #endif
                }
                #if os(tvOS)
                if state == .bufferFinished, tvNeedsNowPlayingRefresh {
                    tvNeedsNowPlayingRefresh = false
                    applyTVNowPlaying(on: playerLayer)
                }
                #endif
            }
            .onFinish { _, error in
                #if os(tvOS)
                tvIsInitialLoading = false
                #endif
                if let error {
                    playbackError = error
                }
            }
            .onBufferChanged { bufferedCount, consumeTime in
                print("bufferedCount \(bufferedCount), consumeTime \(consumeTime)")
            }
        #if canImport(UIKit)
            .onSwipe { direction in
                #if os(tvOS)
                if direction == .down {
                    playerCoordinator.mask(show: true, autoHide: false)
                    focusableField = .pills
                    return
                }
                #endif
                playerCoordinator.isMaskShow = true
            }
        #endif
            .ignoresSafeArea()
            .onAppear {
                focusableField = .play
                if let subtitleDataSouce {
                    playerCoordinator.subtitleModel.addSubtitle(dataSouce: subtitleDataSouce)
                }
                // 不要加这个，不然playerCoordinator无法释放，也可以在onDisappear调用removeMonitor释放
                //                    #if os(macOS)
                //                    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
                //                        isMaskShow = overView
                //                        return $0
                //                    }
                //                    #endif
            }

        #if os(iOS) || os(xrOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(tvOS)
            .focusable((!playerCoordinator.isMaskShow && tvActivePrompt == nil) || tvIsInitialLoading)
        .focused($focusableField, equals: .play)
        #elseif !os(iOS)
            .focusable(!playerCoordinator.isMaskShow)
        .focused($focusableField, equals: .play)
        #endif
        #if !os(xrOS)
            .onKeyPressLeftArrow {
            #if os(tvOS)
            tvSkip(-KSOptions.tvSkipInterval)
            #else
            playerCoordinator.skip(interval: -15)
            #endif
        }
        .onKeyPressRightArrow {
            #if os(tvOS)
            tvSkip(KSOptions.tvSkipInterval)
            #else
            playerCoordinator.skip(interval: 15)
            #endif
        }
        .onKeyPressSapce {
            if playerCoordinator.state.isPlaying {
                playerCoordinator.playerLayer?.pause()
            } else {
                playerCoordinator.playerLayer?.play()
            }
        }
        #endif
        #if os(macOS)
            .onTapGesture(count: 2) {
                guard let view = playerCoordinator.playerLayer?.player.view else {
                    return
                }
                view.window?.toggleFullScreen(nil)
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
        }
        .onExitCommand {
            playerCoordinator.playerLayer?.player.view?.exitFullScreenMode()
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                playerCoordinator.skip(interval: -15)
            case .right:
                playerCoordinator.skip(interval: 15)
            case .up:
                playerCoordinator.playerLayer?.player.playbackVolume += 0.2
            case .down:
                playerCoordinator.playerLayer?.player.playbackVolume -= 0.2
            @unknown default:
                break
            }
        }
        #elseif os(tvOS)
        .onTapGesture {
                togglePlaybackAndShowTransport()
            }
        #else
        .onTapGesture {
                playerCoordinator.isMaskShow.toggle()
            }
        #endif
        #if os(tvOS)
            .onMoveCommand { direction in
            tvMove(direction)
        }
        #else
        .onHover { _ in
                playerCoordinator.isMaskShow = true
            }
            .onDrop(of: ["public.file-url"], isTargeted: nil) { providers -> Bool in
                providers.first?.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    if let data, let path = NSString(data: data, encoding: 4), let url = URL(string: path as String) {
                        openURL(url)
                    }
                }
                return true
            }
        #endif
    }

    @ViewBuilder
    private func controllerView(playerWidth: Double) -> some View {
        #if os(tvOS)
        ZStack(alignment: .bottom) {
            if playerCoordinator.isMaskShow, !tvIsInitialLoading {
                TVControlsOverlayView(config: playerCoordinator,
                                      subtitleModel: playerCoordinator.subtitleModel,
                                      timemodel: playerCoordinator.timemodel,
                                      features: playerCoordinator.tvFeatures,
                                      title: title,
                                      metadata: tvMetadata,
                                      mode: $tvOverlayMode,
                                      skipHint: $tvSkipHint,
                                      focusableField: $focusableField,
                                      onShowTransport: { showTransportAndFocusTimeline() })
                    .transition(.opacity)
                    .onAppear {
                        if focusableField != .pills {
                            focusableField = .timeline
                        }
                    }
                    .onDisappear {
                        tvOverlayMode = .transport
                        focusableField = tvActivePrompt == nil ? .play : .prompt
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(TVPlayerMotion.transition, value: playerCoordinator.isMaskShow)
        #else
        VStack {
            VideoControllerView(config: playerCoordinator, subtitleModel: playerCoordinator.subtitleModel, title: $title, volumeSliderSize: playerWidth / 4)
            #if !os(xrOS)
            // 设置opacity为0，还是会去更新View。所以只能这样了
            if playerCoordinator.isMaskShow {
                VideoTimeShowView(config: playerCoordinator, model: playerCoordinator.timemodel)
                    .onAppear {
                        focusableField = .controller
                    }
                    .onDisappear {
                        focusableField = .play
                    }
            }
            #endif
        }
        #if os(xrOS)
        .ornament(visibility: playerCoordinator.isMaskShow ? .visible : .hidden, attachmentAnchor: .scene(.bottom)) {
            ornamentView(playerWidth: playerWidth)
        }
        .sheet(isPresented: $showVideoSetting) {
            NavigationStack {
                VideoSettingView(config: playerCoordinator, subtitleModel: playerCoordinator.subtitleModel, subtitleTitle: title)
            }
            .buttonStyle(.plain)
        }
        #endif
        .focused($focusableField, equals: .controller)
        .opacity(playerCoordinator.isMaskShow ? 1 : 0)
        .padding()
        #endif
    }

    #if os(tvOS)
    private func togglePlaybackAndShowTransport() {
        let isPausing = playerCoordinator.state.isPlaying
        if isPausing {
            playerCoordinator.playerLayer?.pause()
        } else {
            playerCoordinator.playerLayer?.play()
        }
        showTransportAndFocusTimeline(autoHide: !isPausing)
    }

    private func showTransportAndFocusTimeline(autoHide: Bool = true) {
        withAnimation(TVPlayerMotion.transition) {
            tvOverlayMode = .transport
        }
        playerCoordinator.mask(show: true, autoHide: autoHide)
        focusableField = .timeline
        Task { @MainActor in
            await Task.yield()
            focusableField = .timeline
        }
    }

    private func tvSkip(_ seconds: Int) {
        playerCoordinator.skip(interval: seconds)
        playerCoordinator.mask(show: true)
        tvSkipHint = TVSkipHint(seconds: seconds)
    }

    private func tvMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            tvSkip(-KSOptions.tvSkipInterval)
        case .right:
            tvSkip(KSOptions.tvSkipInterval)
        case .up:
            showTransportAndFocusTimeline(autoHide: false)
        case .down:
            playerCoordinator.mask(show: true, autoHide: false)
            focusableField = .pills
        @unknown default:
            break
        }
    }

    private var tvPromptLayer: some View {
        TVPromptLayer(config: playerCoordinator,
                      features: playerCoordinator.tvFeatures,
                      timemodel: playerCoordinator.timemodel,
                      isPresented: !playerCoordinator.isMaskShow && !tvIsInitialLoading && playbackError == nil,
                      dismissedSkips: $tvDismissedSkips,
                      activePrompt: $tvActivePrompt)
            .focused($focusableField, equals: .prompt)
            .onMoveCommand { direction in
                tvMove(direction)
            }
            .padding(.trailing, TVPlayerMetrics.edgeHorizontal)
            .padding(.bottom, TVPlayerMetrics.edgeBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea()
    }

    private var tvIdleFocusTarget: FocusableField? {
        if tvActivePrompt != nil {
            return .prompt
        }
        if !playerCoordinator.isMaskShow {
            return .play
        }
        return nil
    }

    private func refreshTVIdleFocus() {
        guard let target = tvIdleFocusTarget else { return }
        focusableField = target
        Task { @MainActor in
            await Task.yield()
            if let target = tvIdleFocusTarget {
                focusableField = target
            }
        }
    }

    private func dismissTVPrompt() {
        switch tvActivePrompt {
        case .upNext?:
            playerCoordinator.dismissUpNext()
        case let .skip(index, _)?:
            tvDismissedSkips.insert(index)
        case nil:
            break
        }
    }

    private func applyTVNowPlaying(on playerLayer: KSPlayerLayer) {
        let nowPlayingTitle: String? = usesEmbeddedTitle ? playerLayer.player.dynamicInfo?.metadata["title"] : title
        playerLayer.setNowPlaying(title: nowPlayingTitle,
                                  subtitle: tvMetadata.subtitle,
                                  artworkURL: tvMetadata.artworkURL)
    }

    public func tvPlayerMetadata(_ metadata: TVPlayerMetadata) -> KSVideoPlayerView {
        var view = self
        view.tvMetadata = metadata
        return view
    }
    #endif

    private func ornamentView(playerWidth: Double) -> some View {
        VStack(alignment: .leading) {
            KSVideoPlayerViewBuilder.titleView(title: title, config: playerCoordinator)
            ornamentControlsView(playerWidth: playerWidth)
        }
        .frame(width: playerWidth / 1.5)
        .buttonStyle(.plain)
        .padding(.vertical, 24)
        .padding(.horizontal, 36)
        #if os(xrOS)
            .glassBackgroundEffect()
        #endif
    }

    private func ornamentControlsView(playerWidth _: Double) -> some View {
        HStack {
            KSVideoPlayerViewBuilder.playbackControlView(config: playerCoordinator, spacing: 16)
            Spacer()
            VideoTimeShowView(config: playerCoordinator, model: playerCoordinator.timemodel, timeFont: .title3.monospacedDigit())
            Spacer()
            Group {
                KSVideoPlayerViewBuilder.contentModeButton(config: playerCoordinator)
                KSVideoPlayerViewBuilder.subtitleButton(config: playerCoordinator)
                KSVideoPlayerViewBuilder.playbackRateButton(playbackRate: $playerCoordinator.playbackRate)
                KSVideoPlayerViewBuilder.infoButton(showVideoSetting: $showVideoSetting)
            }
            .font(.largeTitle)
        }
    }

    enum FocusableField {
        case play, controller, timeline, pills, popover, panel, prompt
    }

    public func openURL(_ url: URL) {
        runOnMainThread {
            if url.isSubtitle {
                let info = URLSubtitleInfo(url: url)
                playerCoordinator.subtitleModel.selectedSubtitleInfo = info
            } else if url.isAudio || url.isMovie {
                self.url = url
                title = url.lastPathComponent
            }
        }
    }
}

extension View {
    func onKeyPressLeftArrow(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return onKeyPress(.leftArrow) {
                action()
                return .handled
            }
        } else {
            return self
        }
    }

    func onKeyPressRightArrow(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return onKeyPress(.rightArrow) {
                action()
                return .handled
            }
        } else {
            return self
        }
    }

    func onKeyPressSapce(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return onKeyPress(.space) {
                action()
                return .handled
            }
        } else {
            return self
        }
    }
}

@available(iOS 16, tvOS 16, macOS 13, *)
struct VideoControllerView: View {
    @ObservedObject
    fileprivate var config: KSVideoPlayer.Coordinator
    @ObservedObject
    fileprivate var subtitleModel: SubtitleModel
    @Binding
    fileprivate var title: String
    fileprivate var volumeSliderSize: Double?
    @State
    private var showVideoSetting = false
    @Environment(\.dismiss)
    private var dismiss
    public var body: some View {
        VStack {
            #if os(tvOS)
            Spacer()
            HStack {
                Text(title)
                    .lineLimit(2)
                    .layoutPriority(3)
                ProgressView()
                    .opacity(config.state == .buffering || config.state == .preparing ? 1 : 0)
                Spacer()
                    .layoutPriority(2)
                HStack {
                    Button {
                        if config.state.isPlaying {
                            config.playerLayer?.pause()
                        } else {
                            config.playerLayer?.play()
                        }
                    } label: {
                        Image(systemName: config.state == .error ? "play.slash.fill" : (config.state.isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                    }
                    .frame(width: 56)
                    if let audioTracks = config.playerLayer?.player.tracks(mediaType: .audio), !audioTracks.isEmpty {
                        audioButton(audioTracks: audioTracks)
                    }
                    muteButton
                        .frame(width: 56)
                    contentModeButton
                        .frame(width: 56)
                    subtitleButton
                    playbackRateButton
                    pipButton
                        .frame(width: 56)
                    infoButton
                        .frame(width: 56)
                }
                .font(.title3)
            }
            #else
            HStack {
                #if !os(xrOS)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "x.circle.fill")
                }
                #if !os(tvOS)
                if config.playerLayer?.player.allowsExternalPlayback == true {
                    AirPlayView().fixedSize()
                }
                #endif
                #endif
                Spacer()
                if let audioTracks = config.playerLayer?.player.tracks(mediaType: .audio), !audioTracks.isEmpty {
                    audioButton(audioTracks: audioTracks)
                    #if os(xrOS)
                        .aspectRatio(1, contentMode: .fit)
                        .glassBackgroundEffect()
                    #endif
                }
                muteButton
                #if !os(xrOS)
                contentModeButton
                subtitleButton
                #endif
            }
            Spacer()
            #if !os(xrOS)
            KSVideoPlayerViewBuilder.playbackControlView(config: config)
            Spacer()
            HStack {
                KSVideoPlayerViewBuilder.titleView(title: title, config: config)
                Spacer()
                playbackRateButton
                pipButton
                infoButton
            }
            #endif
            #endif
        }
        #if !os(tvOS)
        .font(.title)
        .buttonStyle(.borderless)
        #endif
        .sheet(isPresented: $showVideoSetting) {
            VideoSettingView(config: config, subtitleModel: config.subtitleModel, subtitleTitle: title)
        }
    }

    private var muteButton: some View {
        #if os(xrOS)
        HStack {
            Slider(value: $config.playbackVolume, in: 0 ... 1)
                .onChange(of: config.playbackVolume) { _, newValue in
                    config.isMuted = newValue == 0
                }
                .frame(width: volumeSliderSize ?? 100)
                .tint(.white.opacity(0.8))
                .padding(.leading, 16)
            KSVideoPlayerViewBuilder.muteButton(config: config)
        }
        .padding(16)
        .glassBackgroundEffect()
        #else
        KSVideoPlayerViewBuilder.muteButton(config: config)
        #endif
    }

    private var contentModeButton: some View {
        KSVideoPlayerViewBuilder.contentModeButton(config: config)
    }

    private func audioButton(audioTracks: [MediaPlayerTrack]) -> some View {
        MenuView(selection: Binding {
            audioTracks.first { $0.isEnabled }?.trackID
        } set: { value in
            if let track = audioTracks.first(where: { $0.trackID == value }) {
                config.playerLayer?.player.select(track: track)
            }
        }) {
            ForEach(audioTracks, id: \.trackID) { track in
                Text(track.description).tag(track.trackID as Int32?)
            }
        } label: {
            Image(systemName: "waveform.circle.fill")
            #if os(xrOS)
                .padding()
                .clipShape(Circle())
            #endif
        }
    }

    private var subtitleButton: some View {
        KSVideoPlayerViewBuilder.subtitleButton(config: config)
    }

    private var playbackRateButton: some View {
        KSVideoPlayerViewBuilder.playbackRateButton(playbackRate: $config.playbackRate)
    }

    private var pipButton: some View {
        Button {
            config.playerLayer?.isPipActive.toggle()
        } label: {
            Image(systemName: "rectangle.on.rectangle.circle.fill")
        }
    }

    private var infoButton: some View {
        KSVideoPlayerViewBuilder.infoButton(showVideoSetting: $showVideoSetting)
    }
}

@available(iOS 15, tvOS 16, macOS 12, *)
public struct MenuView<Label, SelectionValue, Content>: View where Label: View, SelectionValue: Hashable, Content: View {
    public let selection: Binding<SelectionValue>
    @ViewBuilder
    public let content: () -> Content
    @ViewBuilder
    public let label: () -> Label
    @State
    private var showMenu = false
    public var body: some View {
        if #available(tvOS 17, *) {
            Menu {
                Picker(selection: selection) {
                    content()
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } label: {
                label()
            }
            .menuIndicator(.hidden)
        } else {
            Picker(selection: selection, content: content, label: label)
            #if !os(macOS)
                .pickerStyle(.navigationLink)
            #endif
                .frame(height: 50)
            #if os(tvOS)
                .frame(width: 110)
            #endif
        }
    }
}

@available(iOS 15, tvOS 15, macOS 12, *)
struct VideoTimeShowView: View {
    @ObservedObject
    fileprivate var config: KSVideoPlayer.Coordinator
    @ObservedObject
    fileprivate var model: ControllerTimeModel
    fileprivate var timeFont: Font?
    public var body: some View {
        if config.playerLayer?.player.seekable ?? false {
            HStack {
                Text(model.currentTime.toString(for: .minOrHour)).font(timeFont ?? .caption2.monospacedDigit())
                Slider(value: Binding {
                    Float(model.currentTime)
                } set: { newValue, _ in
                    model.currentTime = Int(newValue)
                }, in: 0 ... Float(model.totalTime)) { onEditingChanged in
                    if onEditingChanged {
                        config.playerLayer?.pause()
                    } else {
                        config.seek(time: TimeInterval(model.currentTime))
                    }
                }
                .frame(maxHeight: 20)
                #if os(xrOS)
                    .tint(.white.opacity(0.8))
                #endif
                Text((model.totalTime).toString(for: .minOrHour)).font(timeFont ?? .caption2.monospacedDigit())
            }
            .font(.system(.title2))
        } else {
            Text("Live Streaming")
        }
    }
}

extension EventModifiers {
    static let none = Self()
}

@available(iOS 16, tvOS 16, macOS 13, *)
struct VideoSubtitleView: View {
    @ObservedObject
    fileprivate var model: SubtitleModel
    var body: some View {
        ZStack {
            ForEach(model.parts) { part in
                part.subtitleView
            }
        }
    }

    fileprivate static func imageView(_ image: UIImage) -> some View {
        #if enableFeatureLiveText && canImport(VisionKit) && !targetEnvironment(simulator)
        if #available(macCatalyst 17.0, *) {
            return LiveTextImage(uiImage: image)
        } else {
            return Image(uiImage: image)
                .resizable()
        }
        #else
        return Image(uiImage: image)
            .resizable()
        #endif
    }
}

private extension SubtitlePart {
    @available(iOS 16, tvOS 16, macOS 13, *)
    @MainActor
    var subtitleView: some View {
        VStack {
            if let image {
                Spacer()
                GeometryReader { geometry in
                    let fitRect = image.fitRect(geometry.size)
                    VideoSubtitleView.imageView(image)
                        .offset(CGSize(width: fitRect.origin.x, height: fitRect.origin.y))
                        .frame(width: fitRect.size.width, height: fitRect.size.height)
                }
                // 不能加scaledToFit。不然的话图片的缩放比率会有问题。
//                .scaledToFit()
                .padding()
            } else if let text {
                let textPosition = textPosition ?? SubtitleModel.textPosition
                if textPosition.verticalAlign == .bottom || textPosition.verticalAlign == .center {
                    Spacer()
                }
                Text(AttributedString(text))
                    .font(Font(SubtitleModel.textFont))
                    .shadow(color: .black.opacity(0.9), radius: 1, x: 1, y: 1)
                    .foregroundColor(SubtitleModel.textColor)
                    .italic(SubtitleModel.textItalic)
                    .background(SubtitleModel.textBackgroundColor)
                    .multilineTextAlignment(.center)
                    .alignmentGuide(textPosition.horizontalAlign) {
                        $0[.leading]
                    }
                    .padding(textPosition.edgeInsets)
                #if !os(tvOS)
                    .textSelection(.enabled)
                #endif
                if textPosition.verticalAlign == .top || textPosition.verticalAlign == .center {
                    Spacer()
                }
            } else {
                // 需要加这个，不然图片无法清空。感觉是 swiftUI的bug。
                Text("")
            }
        }
    }
}

@available(iOS 16, tvOS 16, macOS 13, *)
struct VideoSettingView: View {
    @ObservedObject
    fileprivate var config: KSVideoPlayer.Coordinator
    @ObservedObject
    fileprivate var subtitleModel: SubtitleModel
    @State
    fileprivate var subtitleTitle: String
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        PlatformView {
            let videoTracks = config.playerLayer?.player.tracks(mediaType: .video)
            if let videoTracks, !videoTracks.isEmpty {
                Picker(selection: Binding {
                    videoTracks.first { $0.isEnabled }?.trackID
                } set: { value in
                    if let track = videoTracks.first(where: { $0.trackID == value }) {
                        config.playerLayer?.player.select(track: track)
                    }
                }) {
                    ForEach(videoTracks, id: \.trackID) { track in
                        Text(track.description).tag(track.trackID as Int32?)
                    }
                } label: {
                    Label("Video Track", systemImage: "video.fill")
                }
                LabeledContent("Video Type", value: (videoTracks.first { $0.isEnabled }?.dynamicRange ?? .sdr).description)
            }
            TextField("Sutitle delay", value: $subtitleModel.subtitleDelay, format: .number)
            TextField("Title", text: $subtitleTitle)
            Button("Search Sutitle") {
                subtitleModel.searchSubtitle(query: subtitleTitle, languages: ["zh-cn"])
            }
            LabeledContent("Stream Type", value: (videoTracks?.first { $0.isEnabled }?.fieldOrder ?? .progressive).description)
            if let dynamicInfo = config.playerLayer?.player.dynamicInfo {
                DynamicInfoView(dynamicInfo: dynamicInfo)
            }
            if let fileSize = config.playerLayer?.player.fileSize, fileSize > 0 {
                LabeledContent("File Size", value: fileSize.kmFormatted + "B")
            }
        }
        #if os(macOS) || targetEnvironment(macCatalyst) || os(xrOS)
        .toolbar {
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        #endif
    }
}

@available(iOS 16, tvOS 16, macOS 13, *)
public struct DynamicInfoView: View {
    @ObservedObject
    var dynamicInfo: DynamicInfo
    public var body: some View {
        LabeledContent("Display FPS", value: dynamicInfo.displayFPS, format: .number)
        LabeledContent("Audio Video sync", value: dynamicInfo.audioVideoSyncDiff, format: .number)
        LabeledContent("Dropped Frames", value: dynamicInfo.droppedVideoFrameCount + dynamicInfo.droppedVideoPacketCount, format: .number)
        LabeledContent("Bytes Read", value: dynamicInfo.bytesRead.kmFormatted + "B")
        LabeledContent("Audio bitrate", value: dynamicInfo.audioBitrate.kmFormatted + "bps")
        LabeledContent("Video bitrate", value: dynamicInfo.videoBitrate.kmFormatted + "bps")
    }
}

@available(iOS 15, tvOS 16, macOS 12, *)
public struct PlatformView<Content: View>: View {
    private let content: () -> Content
    public var body: some View {
        #if os(tvOS)
        ScrollView {
            content()
                .padding()
        }
        .pickerStyle(.navigationLink)
        #else
        Form {
            content()
        }
        #if os(macOS)
        .padding()
        #endif
        #endif
    }

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct KSVideoPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        let url = URL(string: "http://clips.vorwaerts-gmbh.de/big_buck_bunny.mp4")!
        KSVideoPlayerView(coordinator: KSVideoPlayer.Coordinator(), url: url, options: KSOptions())
    }
}
