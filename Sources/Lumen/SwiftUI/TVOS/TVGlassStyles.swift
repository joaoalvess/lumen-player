//
//  TVGlassStyles.swift
//  Lumen
//
import SwiftUI

#if os(tvOS)
@available(tvOS 16.0, *)
extension View {
    @ViewBuilder
    func tvPlayerControlMaterial(in shape: some Shape) -> some View {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) {
            glassEffect(.clear, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
        #else
        background(.ultraThinMaterial, in: shape)
        #endif
    }

    func tvPlayerSurfaceMaterial(in shape: some Shape) -> some View {
        background(.regularMaterial, in: shape)
    }

    @ViewBuilder
    func tvGlassCircle() -> some View {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) {
            glassEffect(.regular, in: Circle())
        } else {
            self
        }
        #else
        self
        #endif
    }

}

@available(tvOS 16.0, *)
struct TVGlassGroup<Content: View>: View {
    @ViewBuilder
    let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(tvOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

@available(tvOS 16.0, *)
enum TVPlayerMetrics {
    static let edgeHorizontal: CGFloat = 80
    static let edgeBottom: CGFloat = 60
    static let transportEdgeBottom: CGFloat = 32
    static let chipSize: CGFloat = 68
    static let pillHeight: CGFloat = 62
    static let popoverWidth: CGFloat = 560
    static let popoverRadius: CGFloat = 26
    static let panelRadius: CGFloat = 28
}

@available(tvOS 16.0, *)
enum TVPlayerMotion {
    static let transition = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)
    static let focus = Animation.easeOut(duration: 0.18)
}

@available(tvOS 16.0, *)
struct TVChipButtonStyle: ButtonStyle {
    var isOpen = false

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, isOpen: isOpen)
    }

    private struct Chip: View {
        @Environment(\.isFocused)
        private var isFocused
        let configuration: Configuration
        let isOpen: Bool

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
                .frame(width: TVPlayerMetrics.chipSize, height: TVPlayerMetrics.chipSize)
                .background {
                    Circle()
                        .fill(.white)
                        .opacity(isFocused ? 1 : (isOpen ? 0.3 : 0))
                }
                .tvPlayerControlMaterial(in: Circle())
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.04 : 1))
                .animation(TVPlayerMotion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

@available(tvOS 16.0, *)
struct TVPillButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, isActive: isActive)
    }

    private struct Pill: View {
        @Environment(\.isFocused)
        private var isFocused
        let configuration: Configuration
        let isActive: Bool

        private var isHighlighted: Bool {
            isFocused || isActive
        }

        var body: some View {
            configuration.label
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
                .padding(.horizontal, 28)
                .frame(height: TVPlayerMetrics.pillHeight)
                .background {
                    Capsule()
                        .fill(.white)
                        .opacity(isHighlighted ? 1 : 0)
                }
                .tvPlayerControlMaterial(in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.015 : 1))
                .animation(TVPlayerMotion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

@available(tvOS 16.0, *)
struct TVPopoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        @Environment(\.isFocused)
        private var isFocused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .background {
                    Capsule()
                        .fill(.white)
                        .opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(TVPlayerMotion.focus, value: isFocused)
        }
    }
}

@available(tvOS 16.0, *)
struct TVProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Prominent(configuration: configuration)
    }

    private struct Prominent: View {
        @Environment(\.isFocused)
        private var isFocused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
                .padding(.horizontal, 36)
                .frame(height: 64)
                .background {
                    Capsule()
                        .fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.15)))
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1))
                .animation(TVPlayerMotion.focus, value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif
