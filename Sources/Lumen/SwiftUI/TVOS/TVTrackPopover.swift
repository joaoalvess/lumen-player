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
        }
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
    }

    @ViewBuilder
    private var audioContent: some View {
        sectionHeader("Ajustes de áudio")
        Divider()
            .overlay(.white.opacity(0.14))
            .padding(.horizontal, 28)
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
#endif
