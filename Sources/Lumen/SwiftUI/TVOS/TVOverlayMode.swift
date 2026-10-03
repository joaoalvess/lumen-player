//
//  TVOverlayMode.swift
//  Lumen
//
import Foundation

#if os(tvOS)
enum TVTrackPopoverKind: Hashable {
    case subtitles
    case audio
}

enum TVPanelTab: Hashable {
    case info
    case cast
    case continueWatching
    case advanced

    var label: String {
        switch self {
        case .info:
            return "Informações"
        case .cast:
            return "Elenco"
        case .continueWatching:
            return "A seguir"
        case .advanced:
            return "Avançado"
        }
    }
}

enum TVOverlayMode: Equatable {
    case transport
    case popover(TVTrackPopoverKind)
    case panel(TVPanelTab)

    var showsTransport: Bool {
        if case .panel = self {
            return false
        }
        return true
    }

    var popoverKind: TVTrackPopoverKind? {
        if case let .popover(kind) = self {
            return kind
        }
        return nil
    }

    var activePanelTab: TVPanelTab? {
        if case let .panel(tab) = self {
            return tab
        }
        return nil
    }
}
#endif
