//
//  TVTransportBar.swift
//  Lumen
//
import SwiftUI

#if os(tvOS)
@available(tvOS 16.0, *)
struct TVTransportBar: View {
    @ObservedObject
    var config: KSVideoPlayer.Coordinator
    @ObservedObject
    var model: ControllerTimeModel
    @ObservedObject
    var thumbs: ScrubThumbnailProvider
    var skipHint: TVSkipHint?
    @Binding
    var isScrubbing: Bool
    var isFocusable = true
    var onDownArrow: (() -> Void)?

    @State
    private var scrubAnchorTime = 0
    @State
    private var wasPlayingBeforeScrub = false
    @State
    private var indicatorSize = CGSize.zero
    @State
    private var currentTimeSize = CGSize.zero
    @State
    private var remainingTimeSize = CGSize.zero
    @State
    private var isTimelineFocused = false

    var body: some View {
        if config.playerLayer?.player.seekable ?? false {
            timelineView
        } else {
            Text("Ao vivo")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var progressFraction: CGFloat {
        guard model.totalTime > 0 else { return 0 }
        return min(1, max(0, CGFloat(model.currentTime) / CGFloat(model.totalTime)))
    }

    private var bufferFraction: CGFloat {
        guard model.totalTime > 0 else { return 0 }
        return min(1, max(progressFraction, CGFloat(model.bufferTime) / CGFloat(model.totalTime)))
    }

    private var scrubRequestID: Int {
        isScrubbing ? model.currentTime : -1
    }

    private var trackHeight: CGFloat {
        if isScrubbing {
            return 20
        }
        return isTimelineFocused ? 13 : 11
    }

    private var timelineView: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let playheadX = width * progressFraction

            VStack(spacing: 4) {
                track(width: width, playheadX: playheadX)
                    .frame(height: 24)
                timeLabels(width: width, playheadX: playheadX)
            }
        }
        .frame(height: 56)
        .task(id: scrubRequestID) {
            guard isScrubbing else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !Task.isCancelled {
                thumbs.request(TimeInterval(model.currentTime))
            }
        }
    }

    private func track(width: CGFloat, playheadX: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(height: trackHeight)
                .tvPlayerControlMaterial(in: Capsule())
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: max(0, width * bufferFraction), height: trackHeight)
            Capsule()
                .fill(.white.opacity(0.92))
                .frame(width: max(trackHeight, playheadX) + (isScrubbing ? trackHeight : 0), height: trackHeight)
                .frame(width: max(trackHeight, playheadX), alignment: .leading)
                .clipped()
            if isScrubbing {
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: trackHeight)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .position(x: min(max(1.5, playheadX), max(1.5, width - 1.5)),
                              y: 12)
            }
            TVScrubberInput(
                value: Binding {
                    Float(model.currentTime)
                } set: { newValue in
                    model.currentTime = Int(newValue.rounded())
                },
                bounds: 0 ... Float(max(1, model.totalTime)),
                isFocusable: isFocusable,
                onEditingChanged: { editing in
                    editing ? beginScrubIfNeeded() : commitScrub()
                },
                onCancel: cancelScrub,
                onDownArrow: onDownArrow,
                onFocusChanged: { focused in
                    isTimelineFocused = focused
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .topLeading) {
            if isScrubbing {
                scrubIndicator
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { geometry in
                        geometry.size
                    } action: { size in
                        indicatorSize = size
                    }
                    .offset(x: indicatorX(playheadX: playheadX, width: width),
                            y: -indicatorSize.height - 18)
            }
        }
        .animation(TVPlayerMotion.focus, value: isScrubbing)
        .animation(TVPlayerMotion.focus, value: isTimelineFocused)
    }

    private func timeLabels(width: CGFloat, playheadX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                if let skipHint, skipHint.seconds < 0 {
                    Image(systemName: skipHint.symbolName)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                Text(model.currentTime.toString(for: .minOrHour))
                if let skipHint, skipHint.seconds >= 0 {
                    Image(systemName: skipHint.symbolName)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else if config.state == .buffering {
                    TVTimeSpinner()
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else if config.state == .paused, !isScrubbing {
                    Image(systemName: "pause.circle")
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { size in
                currentTimeSize = size
            }
            .offset(x: currentTimeX(playheadX: playheadX, width: width))
            .animation(TVPlayerMotion.transition, value: skipHint)
            .animation(TVPlayerMotion.transition, value: config.state)
            Text("-" + max(0, model.totalTime - model.currentTime).toString(for: .minOrHour))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { size in
                    remainingTimeSize = size
                }
                .frame(width: width, alignment: .trailing)
        }
        .font(.system(size: 24, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: width, height: 28, alignment: .topLeading)
    }

    private func currentTimeX(playheadX: CGFloat, width: CGFloat) -> CGFloat {
        TVScrubberTuning.elapsedLabelLeadingX(
            playheadX: playheadX,
            trackWidth: width,
            elapsedWidth: currentTimeSize.width,
            remainingWidth: remainingTimeSize.width
        )
    }

    private var scrubIndicator: some View {
        scrubPreviewSlot
    }

    @ViewBuilder
    private var scrubPreviewSlot: some View {
        if let thumbnail = thumbs.image(near: TimeInterval(model.currentTime)) {
            Image(uiImage: thumbnail.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 360, height: 360 / previewAspect)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        }
    }

    private var previewAspect: CGFloat {
        if let size = config.playerLayer?.player.naturalSize, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return 16.0 / 9.0
    }

    private func indicatorX(playheadX: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, playheadX - indicatorSize.width / 2), max(0, width - indicatorSize.width))
    }

    private func beginScrubIfNeeded() {
        guard !isScrubbing else { return }
        isScrubbing = true
        scrubAnchorTime = model.currentTime
        wasPlayingBeforeScrub = config.state.isPlaying
        if wasPlayingBeforeScrub {
            config.playerLayer?.pause()
        }
        config.mask(show: true, autoHide: false)
        thumbs.startIfNeeded(url: config.playerLayer?.url,
                             options: config.playerLayer?.options,
                             duration: TimeInterval(model.totalTime))
    }

    private func commitScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        config.seek(time: TimeInterval(model.currentTime), autoPlay: wasPlayingBeforeScrub)
        config.mask(show: true)
    }

    private func cancelScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        model.currentTime = scrubAnchorTime
        if wasPlayingBeforeScrub {
            config.playerLayer?.play()
        }
        config.mask(show: true)
    }
}

@available(tvOS 16.0, *)
private struct TVTimeSpinner: View {
    @State
    private var nativeSize = CGSize.zero

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { size in
                nativeSize = size
            }
            .scaleEffect(fittingScale)
            .frame(width: 24, height: 24)
    }

    private var fittingScale: CGFloat {
        let largest = max(nativeSize.width, nativeSize.height)
        guard largest > 0 else { return 1 }
        return min(1, 24 / largest)
    }
}
#endif
