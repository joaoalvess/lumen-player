//
//  TVPromptLayer.swift
//  Lumen
//
import SwiftUI

#if os(tvOS)
@available(tvOS 16.0, *)
struct TVPromptLayer: View {
    @ObservedObject
    var config: KSVideoPlayer.Coordinator
    @ObservedObject
    var features: TVPlayerFeatures
    @ObservedObject
    var timemodel: ControllerTimeModel
    let isPresented: Bool
    @Binding
    var dismissedSkips: Set<Int>
    @Binding
    var activePrompt: TVActivePrompt?

    var body: some View {
        let prompt = resolvedPrompt
        ZStack(alignment: .bottomTrailing) {
            switch prompt {
            case .upNext?:
                if let upNext = features.upNext {
                    TVUpNextCard(item: upNext.item,
                                 remainingSeconds: remainingSeconds,
                                 progress: countdownProgress(upNext)) {
                        config.playUpNextNow()
                    }
                    .transition(promptTransition)
                }
            case let .skip(index, segment)?:
                TVSkipButton(segment: segment) {
                    dismissedSkips.insert(index)
                    config.seek(time: segment.range.upperBound)
                }
                .transition(promptTransition)
            case nil:
                EmptyView()
            }
        }
        .animation(TVPlayerMotion.transition, value: prompt)
        .onAppear {
            activePrompt = prompt
        }
        .onChange(of: prompt) { newPrompt in
            activePrompt = newPrompt
        }
        .onChange(of: features.skipSegments) { _ in
            dismissedSkips = []
        }
    }

    private var currentTime: TimeInterval {
        TimeInterval(timemodel.currentTime)
    }

    private var duration: TimeInterval {
        TimeInterval(timemodel.totalTime)
    }

    private var remainingSeconds: Int {
        TVUpNextTiming.remainingSeconds(currentTime: currentTime, duration: duration)
    }

    private var isPlaybackActive: Bool {
        switch config.state {
        case .buffering, .bufferFinished, .paused, .playedToTheEnd:
            return true
        default:
            return false
        }
    }

    private var resolvedPrompt: TVActivePrompt? {
        guard isPresented, isPlaybackActive else {
            return nil
        }
        return TVPromptResolver.active(currentTime: currentTime,
                                       duration: duration,
                                       upNext: features.upNext.map { (leadTime: $0.leadTime, startTime: $0.startTime) },
                                       isUpNextDismissed: config.isUpNextDismissed,
                                       segments: features.skipSegments,
                                       dismissedSkips: dismissedSkips)
    }

    private var promptTransition: AnyTransition {
        .move(edge: .trailing).combined(with: .opacity)
    }

    private func countdownProgress(_ upNext: TVUpNext) -> Double {
        TVUpNextTiming.progress(currentTime: currentTime,
                                duration: duration,
                                leadTime: upNext.leadTime,
                                startTime: upNext.startTime)
    }
}

@available(tvOS 16.0, *)
private struct TVUpNextCard: View {
    let item: TVUpNextItem
    let remainingSeconds: Int
    let progress: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 24) {
                artwork
                VStack(alignment: .leading, spacing: 6) {
                    Text("Próximo")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(2)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        TVCountdownRing(progress: progress)
                        Text(countdownLabel)
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVPromptCardButtonStyle())
        .accessibilityLabel("Próximo: \(item.title)")
        .accessibilityValue(countdownLabel)
    }

    private var artwork: some View {
        AsyncImage(url: item.artworkURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 224, height: 126)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var countdownLabel: String {
        guard remainingSeconds > 0 else {
            return "Agora"
        }
        if remainingSeconds < 60 {
            return "Em \(remainingSeconds) s"
        }
        let minutes = remainingSeconds / 60 + (remainingSeconds % 60 == 0 ? 0 : 1)
        return "Em \(minutes) min"
    }
}

@available(tvOS 16.0, *)
private struct TVCountdownRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 3)
                .opacity(0.25)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22)
        .animation(.linear(duration: 1), value: progress)
    }
}

@available(tvOS 16.0, *)
private struct TVSkipButton: View {
    let segment: TVSkipSegment
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "forward.end.fill")
        }
        .buttonStyle(TVPillButtonStyle())
    }

    private var title: String {
        if let label = segment.label, !label.isEmpty {
            return label
        }
        switch segment.kind {
        case .intro:
            return "Pular abertura"
        case .credits:
            return "Pular créditos"
        case .recap:
            return "Pular recapitulação"
        case .preview:
            return "Pular prévia"
        case .other:
            return "Pular"
        }
    }
}

@available(tvOS 16.0, *)
private struct TVPromptCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    private struct Card: View {
        @Environment(\.isFocused)
        private var isFocused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
                .padding(20)
                .frame(width: 640, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: TVPlayerMetrics.popoverRadius)
                        .fill(.white)
                        .opacity(isFocused ? 1 : 0)
                }
                .tvPlayerSurfaceMaterial(in: RoundedRectangle(cornerRadius: TVPlayerMetrics.popoverRadius))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0.25), radius: isFocused ? 24 : 12, y: 8)
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.03 : 1))
                .animation(TVPlayerMotion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif
