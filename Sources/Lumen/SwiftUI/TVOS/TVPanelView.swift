//
//  TVPanelView.swift
//  Lumen
//
import AVFoundation
import SwiftUI

#if os(tvOS)
@available(tvOS 16.0, *)
struct TVPanelView: View {
    let tab: TVPanelTab
    @ObservedObject
    var config: KSVideoPlayer.Coordinator
    @ObservedObject
    var subtitleModel: SubtitleModel
    let title: String
    let metadata: TVPlayerMetadata
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch tab {
            case .info:
                infoPanel
            case .cast:
                castPanel
            case .continueWatching:
                continueWatchingPanel
            case .advanced:
                advancedPanel
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
        .tvPlayerSurfaceMaterial(in: RoundedRectangle(cornerRadius: TVPlayerMetrics.panelRadius))
    }

    private var infoPanel: some View {
        HStack(alignment: .center, spacing: 36) {
            AsyncImage(url: metadata.artworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "photo")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .frame(width: 392, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle = metadata.subtitle {
                    Text(subtitle)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                if let synopsis = metadata.synopsis {
                    Text(synopsis)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
                metadataLine
            }

            Spacer(minLength: 24)

            Button {
                config.seek(time: 0)
                config.playerLayer?.play()
                onDismiss()
            } label: {
                Label("Do Início", systemImage: "play.fill")
            }
            .buttonStyle(TVProminentButtonStyle())
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 12) {
            if !metaComponents.isEmpty {
                Text(metaComponents.joined(separator: " • "))
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
                    }
            }
        }
    }

    private var metaComponents: [String] {
        var parts = [String]()
        if let genre = metadata.genres.first {
            parts.append(genre)
        }
        if let year = metadata.year {
            parts.append(String(year))
        }
        if let runtime = runtimeLabel {
            parts.append(runtime)
        }
        if let ageRating = metadata.ageRatingLabel {
            parts.append(ageRating)
        }
        if let rating = metadata.ratingLabel {
            parts.append("IMDb \(rating)")
        }
        return parts
    }

    private var runtimeLabel: String? {
        var minutes = metadata.runtimeMinutes ?? 0
        if minutes <= 0, let duration = config.playerLayer?.player.duration, duration > 0 {
            minutes = Int(duration / 60)
        }
        guard minutes > 0 else {
            return nil
        }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0, rest > 0 {
            return "\(hours) h e \(rest) min"
        }
        if hours > 0 {
            return "\(hours) h"
        }
        return "\(rest) min"
    }

    private var badges: [String] {
        var result = [String]()
        if let videoTrack = config.playerLayer?.player.tracks(mediaType: .video).first(where: { $0.isEnabled }) {
            let size = videoTrack.naturalSize
            if max(size.width, size.height) >= 3200 {
                result.append("4K")
            }
            switch videoTrack.dynamicRange {
            case .dolbyVision?:
                result.append("Dolby Vision")
            case .hdr10?, .hlg?:
                result.append("HDR")
            default:
                break
            }
        }
        if !subtitleModel.subtitleInfos.isEmpty {
            result.append("CC")
        }
        return result
    }

    @ViewBuilder
    private var castPanel: some View {
        if metadata.cast.isEmpty, metadata.directors.isEmpty {
            HStack(spacing: 18) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 38, weight: .medium))
                Text("Elenco indisponível")
                    .font(.system(size: 30, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, minHeight: 188, alignment: .center)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    if !metadata.cast.isEmpty {
                        ForEach(Array(metadata.cast.enumerated()), id: \.offset) { _, credit in
                            TVCreditCard(credit: credit)
                        }
                    }
                    if !metadata.directors.isEmpty {
                        if !metadata.cast.isEmpty {
                            Divider()
                                .overlay(.white.opacity(0.18))
                                .frame(height: 128)
                                .padding(.horizontal, 8)
                        }
                        creditSectionLabel("Direção")
                        ForEach(Array(metadata.directors.enumerated()), id: \.offset) { _, credit in
                            TVCreditCard(credit: credit)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func creditSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white.opacity(0.62))
            .frame(width: 96, height: 108, alignment: .topLeading)
            .padding(.top, 6)
    }

    private var continueWatchingPanel: some View {
        TVUpNextPanelContent(features: config.tvFeatures) {
            onDismiss()
            config.playUpNextNow()
        }
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let videoTrack = config.playerLayer?.player.tracks(mediaType: .video).first(where: { $0.isEnabled }) {
                advancedRow("Faixa de vídeo") {
                    Text(videoTrack.description)
                }
                advancedRow("Faixa dinâmica") {
                    Text((videoTrack.dynamicRange ?? .sdr).description)
                }
                advancedRow("Tipo de stream") {
                    Text(videoTrack.fieldOrder.description)
                }
            }
            if let dynamicInfo = config.playerLayer?.player.dynamicInfo {
                TVAdvancedDynamicRows(dynamicInfo: dynamicInfo)
            }
            if let fileSize = config.playerLayer?.player.fileSize, fileSize > 0 {
                advancedRow("Tamanho do arquivo") {
                    Text(fileSize.kmFormatted + "B")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
    }
}

@available(tvOS 16.0, *)
private struct TVUpNextPanelContent: View {
    @ObservedObject
    var features: TVPlayerFeatures
    let onPlay: () -> Void

    var body: some View {
        if let item = features.upNext?.item {
            HStack(alignment: .center, spacing: 36) {
                AsyncImage(url: item.artworkURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 40, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
                .frame(width: 392, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Próximo")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(item.title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 24)

                Button(action: onPlay) {
                    Label("Reproduzir agora", systemImage: "play.fill")
                }
                .buttonStyle(TVProminentButtonStyle())
            }
        } else {
            Text("Nada a seguir")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, minHeight: 188, alignment: .center)
        }
    }
}

@available(tvOS 16.0, *)
private struct TVCreditCard: View {
    let credit: TVPlayerCredit
    @Environment(\.isFocused)
    private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: credit.imageURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "person.crop.rectangle")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .frame(width: 108, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(credit.name)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
            if let role = credit.role, !role.isEmpty {
                Text(role)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 132, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(isFocused ? 0.16 : 0))
        }
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(TVPlayerMotion.focus, value: isFocused)
        .focusable()
    }
}

@available(tvOS 16.0, *)
private func advancedRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
    HStack {
        Text(label)
            .foregroundStyle(.white.opacity(0.6))
        Spacer()
        value()
            .foregroundStyle(.white)
            .multilineTextAlignment(.trailing)
    }
    .font(.system(size: 23, weight: .medium).monospacedDigit())
}

@available(tvOS 16.0, *)
private struct TVAdvancedDynamicRows: View {
    @ObservedObject
    var dynamicInfo: DynamicInfo

    var body: some View {
        advancedRow("FPS") {
            Text(dynamicInfo.displayFPS, format: .number)
        }
        advancedRow("Sincronização A/V") {
            Text(dynamicInfo.audioVideoSyncDiff, format: .number)
        }
        advancedRow("Quadros perdidos") {
            Text(dynamicInfo.droppedVideoFrameCount + dynamicInfo.droppedVideoPacketCount, format: .number)
        }
        advancedRow("Bytes lidos") {
            Text(dynamicInfo.bytesRead.kmFormatted + "B")
        }
        advancedRow("Bitrate de áudio") {
            Text(dynamicInfo.audioBitrate.kmFormatted + "bps")
        }
        advancedRow("Bitrate de vídeo") {
            Text(dynamicInfo.videoBitrate.kmFormatted + "bps")
        }
    }
}
#endif
