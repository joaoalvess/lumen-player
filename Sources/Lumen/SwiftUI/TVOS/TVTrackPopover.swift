//
//  TVTrackPopover.swift
//  Lumen
//
import AVFoundation
import SwiftUI

#if os(tvOS)
@available(tvOS 16.0, *)
struct TVTrackPopover: View {
    let kind: TVTrackPopoverKind
    @ObservedObject
    var config: KSVideoPlayer.Coordinator
    @ObservedObject
    var subtitleModel: SubtitleModel
    @FocusState
    private var focusedRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch kind {
            case .subtitles:
                subtitleContent
            case .audio:
                audioContent
            case .sources:
                sectionHeader("Fontes")
                TVSourcesContent(provider: config.tvFeatures.sources, focusedRow: $focusedRow) {
                    closePopover()
                }
            }
        }
        .padding(20)
        .frame(width: TVPlayerMetrics.popoverWidth)
        .tvPlayerSurfaceMaterial(in: RoundedRectangle(cornerRadius: TVPlayerMetrics.popoverRadius))
        .buttonStyle(TVPopoverRowButtonStyle())
        .defaultFocus($focusedRow, defaultRowID)
    }

    private var audioTracks: [MediaPlayerTrack] {
        config.playerLayer?.player.tracks(mediaType: .audio) ?? []
    }

    private var defaultRowID: String {
        switch kind {
        case .subtitles:
            return subtitleModel.selectedSubtitleInfo?.subtitleID ?? "off"
        case .audio:
            let enabled = audioTracks.first { $0.isEnabled } ?? audioTracks.first
            if let enabled {
                return String(enabled.trackID)
            }
            return "off"
        case .sources:
            return TVSourcesContent.loadingRowID
        }
    }

    private var supportsPlaybackRate: Bool {
        config.playerLayer?.player.supportsPlaybackRate ?? false
    }

    @ViewBuilder
    private var subtitleContent: some View {
        sectionHeader("Legendas")
        popoverRow(id: "off", label: "Desativadas", isSelected: subtitleModel.selectedSubtitleInfo == nil) {
            config.selectSubtitle(nil)
        }
        if !subtitleModel.subtitleInfos.isEmpty {
            sectionHeader("Idioma")
                .padding(.top, 4)
        }
        rowList(count: subtitleModel.subtitleInfos.count) {
            ForEach(subtitleModel.subtitleInfos, id: \.subtitleID) { info in
                popoverRow(id: info.subtitleID,
                           label: info.name,
                           isSelected: subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID) {
                    config.selectSubtitle(info)
                }
            }
        }
        if subtitleModel.selectedSubtitleInfo != nil {
            Divider()
                .overlay(.white.opacity(0.14))
                .padding(.horizontal, 28)
            sectionHeader("Atraso")
                .padding(.top, 4)
            subtitleDelayRow
        }
    }

    @ViewBuilder
    private var audioContent: some View {
        if supportsPlaybackRate {
            sectionHeader("Velocidade")
            playbackRateRow
            Divider()
                .overlay(.white.opacity(0.14))
                .padding(.horizontal, 28)
        }
        sectionHeader("Faixa de áudio")
            .padding(.top, 4)
        let pendingTrackID = config.audioTrackSelectionState.pendingTrackID
        rowList(count: audioTracks.count) {
            ForEach(audioTracks, id: \.trackID) { track in
                popoverRow(id: String(track.trackID),
                           label: track.language ?? track.name,
                           isSelected: track.isEnabled,
                           isPending: pendingTrackID == track.trackID,
                           isDisabled: pendingTrackID != nil) {
                    config.selectAudioTrack(track)
                }
            }
        }
    }

    private var playbackRateRow: some View {
        HStack(spacing: 8) {
            ForEach(TVPlaybackRate.steps, id: \.self) { rate in
                Button {
                    config.playbackRate = rate
                } label: {
                    Text(TVPlaybackRate.label(rate))
                }
                .buttonStyle(TVStepButtonStyle(isActive: TVPlaybackRate.isSelected(rate, current: config.playbackRate)))
                .focused($focusedRow, equals: "rate.\(rate)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private var subtitleDelayRow: some View {
        HStack(spacing: 8) {
            delayStepButton(-0.5)
            delayStepButton(-0.1)
            Text(TVSubtitleDelay.label(subtitleModel.subtitleDelay))
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            delayStepButton(0.1)
            delayStepButton(0.5)
        }
        .padding(.horizontal, 20)
    }

    private func delayStepButton(_ step: TimeInterval) -> some View {
        Button {
            subtitleModel.subtitleDelay = TVSubtitleDelay.adjusted(subtitleModel.subtitleDelay, by: step)
        } label: {
            Text(TVSubtitleDelay.stepLabel(step))
        }
        .buttonStyle(TVStepButtonStyle())
        .focused($focusedRow, equals: "delay.\(step)")
    }

    private func closePopover() {
        config.mask(show: false)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func rowList(count: Int, @ViewBuilder rows: () -> some View) -> some View {
        if count > 7 {
            ScrollView {
                VStack(spacing: 4) {
                    rows()
                }
            }
            .frame(height: 560)
        } else {
            VStack(spacing: 4) {
                rows()
            }
        }
    }

    private func popoverRow(
        id: String,
        label: String,
        isSelected: Bool,
        isPending: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if isPending {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 22, weight: .semibold))
                            .opacity(isSelected ? 1 : 0)
                    }
                }
                .frame(width: 24, height: 24)
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .disabled(isDisabled)
        .focused($focusedRow, equals: id)
    }
}

@available(tvOS 16.0, *)
private struct TVStepButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        Step(configuration: configuration, isActive: isActive)
    }

    private struct Step: View {
        @Environment(\.isFocused)
        private var isFocused
        let configuration: Configuration
        let isActive: Bool

        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background {
                    Capsule()
                        .fill(.white)
                        .opacity(isFocused ? 1 : (isActive ? 0.3 : 0.1))
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1))
                .animation(TVPlayerMotion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif
