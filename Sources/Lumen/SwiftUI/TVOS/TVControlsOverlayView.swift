//
//  TVControlsOverlayView.swift
//  Lumen
//
import AVFoundation
import SwiftUI

#if os(tvOS)
struct TVSkipHint: Equatable {
    let seconds: Int
    private let id = UUID()

    init(seconds: Int) {
        self.seconds = seconds
    }

    var symbolName: String {
        let base = seconds < 0 ? "gobackward" : "goforward"
        let magnitude = abs(seconds)
        if [5, 10, 15, 30, 45, 60, 75, 90].contains(magnitude) {
            return "\(base).\(magnitude)"
        }
        return base
    }
}

@available(tvOS 16.0, *)
struct TVChipAnchorKey: PreferenceKey {
    static let defaultValue: [TVTrackPopoverKind: Anchor<CGRect>] = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

@available(tvOS 16.0, *)
struct TVControlsOverlayView: View {
    @ObservedObject
    var config: KSVideoPlayer.Coordinator
    @ObservedObject
    var subtitleModel: SubtitleModel
    @ObservedObject
    var timemodel: ControllerTimeModel
    let title: String
    let metadata: TVPlayerMetadata
    @Binding
    var mode: TVOverlayMode
    @Binding
    var skipHint: TVSkipHint?
    let focusableField: FocusState<KSVideoPlayerView.FocusableField?>.Binding
    let onShowTransport: () -> Void
    @FocusState
    private var focusedTab: TVPanelTab?
    @State
    private var isScrubbing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode.showsTransport {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .bottom, spacing: 24) {
                        titleBlock
                        Spacer(minLength: 24)
                        chipsRow
                    }
                    .opacity(isScrubbing ? 0 : 1)
                    .animation(TVPlayerMotion.transition, value: isScrubbing)
                    TVTransportBar(config: config,
                                   model: timemodel,
                                   thumbs: config.scrubThumbnails,
                                   skipHint: skipHint,
                                   isScrubbing: $isScrubbing,
                                   isFocusable: mode == .transport) {
                        focusableField.wrappedValue = .pills
                    }
                    .focused(focusableField, equals: .timeline)
                }
            }
            pillsRow
                .focused(focusableField, equals: .pills)
                .padding(.top, mode.showsTransport ? 12 : 0)
                .opacity(isScrubbing ? 0 : 1)
                .animation(TVPlayerMotion.transition, value: isScrubbing)
            if let tab = mode.activePanelTab {
                TVPanelView(tab: tab,
                            config: config,
                            subtitleModel: subtitleModel,
                            title: title,
                            metadata: metadata) {
                    closePanel()
                }
                .focused(focusableField, equals: .panel)
                .padding(.top, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TVPlayerMetrics.edgeHorizontal)
        .padding(.bottom,
                 mode.showsTransport ? TVPlayerMetrics.transportEdgeBottom : TVPlayerMetrics.edgeBottom)
        .padding(.top, 120)
        .background {
            scrim
        }
        .overlayPreferenceValue(TVChipAnchorKey.self) { anchors in
            popoverLayer(anchors: anchors)
        }
        .task(id: skipHint) {
            guard skipHint != nil else {
                return
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled {
                skipHint = nil
            }
        }
        .onAppear {
            focusInitialTabIfNeeded()
        }
        .onChange(of: focusableField.wrappedValue) { field in
            guard field == .pills else { return }
            focusInitialTabIfNeeded()
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let contextLabel = metadata.contextLabel {
                Text(contextLabel)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            Text(title)
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: 1000, alignment: .leading)
    }

    private var chipsRow: some View {
        TVGlassGroup {
            HStack(spacing: 20) {
                chipButton(kind: .subtitles, systemName: "captions.bubble")
                if let audioTracks = config.playerLayer?.player.tracks(mediaType: .audio), !audioTracks.isEmpty {
                    chipButton(kind: .audio, systemName: "waveform")
                }
                if config.playerLayer?.player.pipController != nil {
                    pipChip
                }
            }
        }
    }

    private func chipButton(kind: TVTrackPopoverKind, systemName: String) -> some View {
        Button {
            openPopover(kind)
        } label: {
            Image(systemName: systemName)
        }
        .accessibilityLabel(kind == .subtitles ? "Legendas" : "Áudio")
        .buttonStyle(TVChipButtonStyle(isOpen: mode.popoverKind == kind))
        .disabled(mode != .transport)
        .anchorPreference(key: TVChipAnchorKey.self, value: .bounds) { [kind: $0] }
    }

    private var pipChip: some View {
        Button {
            config.playerLayer?.isPipActive.toggle()
        } label: {
            Image(systemName: "pip.enter")
        }
        .accessibilityLabel("Picture in Picture")
        .buttonStyle(TVChipButtonStyle())
        .disabled(mode != .transport)
    }

    private var pillsRow: some View {
        HStack(spacing: 16) {
            ForEach(availableTabs, id: \.self) { tab in
                Button {
                    selectPanel(tab)
                } label: {
                    Text(tab.label)
                }
                .buttonStyle(TVPillButtonStyle(isActive: mode.activePanelTab == tab))
                .focused($focusedTab, equals: tab)
            }
        }
        .focusSection()
        .defaultFocus($focusedTab, mode.activePanelTab ?? .info)
        .onChange(of: focusedTab) { tab in
            guard let tab else { return }
            selectPanel(tab)
        }
        .disabled(mode.popoverKind != nil)
    }

    private var availableTabs: [TVPanelTab] {
        [.info, .cast, .continueWatching, .advanced]
    }

    private var scrim: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(color: .black.opacity(0), location: 0),
                Gradient.Stop(color: .black.opacity(0), location: 0.55),
                Gradient.Stop(color: .black.opacity(0.2), location: 0.72),
                Gradient.Stop(color: .black.opacity(0.38), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func popoverLayer(anchors: [TVTrackPopoverKind: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let kind = mode.popoverKind, let anchor = anchors[kind] {
                let chip = proxy[anchor]
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    TVTrackPopover(kind: kind, config: config, subtitleModel: subtitleModel)
                        .focusSection()
                        .focused(focusableField, equals: .popover)
                        .padding(.trailing, max(0, proxy.size.width - chip.maxX))
                        .padding(.bottom, max(0, proxy.size.height - chip.minY + 16))
                }
                .transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
    }

    private func openPopover(_ kind: TVTrackPopoverKind) {
        withAnimation(TVPlayerMotion.transition) {
            mode = .popover(kind)
        }
        config.mask(show: true, autoHide: false)
        focusableField.wrappedValue = .popover
    }

    private func selectPanel(_ tab: TVPanelTab) {
        withAnimation(TVPlayerMotion.transition) {
            mode = .panel(tab)
        }
        config.mask(show: true, autoHide: false)
        focusableField.wrappedValue = .pills
    }

    private func closePanel() {
        focusedTab = nil
        onShowTransport()
    }

    private func focusInitialTabIfNeeded() {
        guard focusableField.wrappedValue == .pills else { return }
        focusedTab = mode.activePanelTab ?? .info
    }

}
#endif
