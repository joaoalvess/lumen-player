//
//  TVSourcesContent.swift
//  Lumen
//
import SwiftUI

#if os(tvOS)
@available(tvOS 16.0, *)
struct TVSourcesContent: View {
    static let loadingRowID = "sources.loading"
    private static let retryRowID = "sources.retry"
    private static let emptyRowID = "sources.empty"
    private static let scrollThreshold = 5

    private enum Phase {
        case loading
        case failed
        case loaded([TVSourceOption])
    }

    let provider: TVSourcesProvider?
    let focusedRow: FocusState<String?>.Binding
    let onClose: () -> Void
    @State
    private var phase = Phase.loading
    @State
    private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch phase {
            case .loading:
                statusRow(id: Self.loadingRowID, label: "Carregando fontes…", showsProgress: true) {}
            case .failed:
                Text("Não foi possível carregar as fontes")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
                statusRow(id: Self.retryRowID, label: "Tentar novamente") {
                    attempt += 1
                }
            case let .loaded(options):
                if options.isEmpty {
                    statusRow(id: Self.emptyRowID, label: "Nenhuma fonte disponível") {
                        onClose()
                    }
                } else {
                    optionList(options)
                }
            }
        }
        .task(id: attempt) {
            await load()
        }
    }

    @ViewBuilder
    private func optionList(_ options: [TVSourceOption]) -> some View {
        if options.count > Self.scrollThreshold {
            ScrollView {
                VStack(spacing: 4) {
                    optionRows(options)
                }
            }
            .frame(height: 560)
        } else {
            optionRows(options)
        }
    }

    private func optionRows(_ options: [TVSourceOption]) -> some View {
        ForEach(options) { option in
            optionRow(option)
        }
    }

    private func optionRow(_ option: TVSourceOption) -> some View {
        Button {
            select(option)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(option.isSelected ? 1 : 0)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .lineLimit(1)
                    if let subtitle = option.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 22, weight: .regular))
                            .opacity(0.7)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.vertical, 10)
                Spacer(minLength: 0)
            }
        }
        .focused(focusedRow, equals: rowID(for: option))
    }

    private func statusRow(
        id: String,
        label: String,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if showsProgress {
                        TVSourcesProgress()
                    }
                }
                .frame(width: 24, height: 24)
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .focused(focusedRow, equals: id)
    }

    private func rowID(for option: TVSourceOption) -> String {
        "source.\(option.id)"
    }

    private func select(_ option: TVSourceOption) {
        if !option.isSelected {
            provider?.onSelect(option)
        }
        onClose()
    }

    private func load() async {
        guard let provider else {
            phase = .loaded([])
            await focus(Self.emptyRowID)
            return
        }
        phase = .loading
        await focus(Self.loadingRowID)
        do {
            let options = try await provider.load()
            guard !Task.isCancelled else {
                return
            }
            phase = .loaded(options)
            let initial = options.first { $0.isSelected } ?? options.first
            await focus(initial.map { rowID(for: $0) } ?? Self.emptyRowID)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            phase = .failed
            await focus(Self.retryRowID)
        }
    }

    private func focus(_ id: String) async {
        await Task.yield()
        guard !Task.isCancelled else {
            return
        }
        focusedRow.wrappedValue = id
    }
}

@available(tvOS 16.0, *)
private struct TVSourcesProgress: View {
    @Environment(\.isFocused)
    private var isFocused

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(isFocused ? .black : .white)
    }
}
#endif
