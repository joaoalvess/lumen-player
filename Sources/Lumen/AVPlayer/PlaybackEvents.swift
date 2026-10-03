//
//  PlaybackEvents.swift
//  Lumen
//
import Foundation

public enum PlaybackEndReason: Sendable {
    case completed
    case failed(Error)
}

public struct TrackSelectionEvent: Equatable, Sendable {
    public enum Kind: Sendable {
        case audio
        case subtitle
    }

    public var kind: Kind
    public var languageCode: String?
    public var isOff: Bool

    public init(kind: Kind, languageCode: String?, isOff: Bool = false) {
        self.kind = kind
        self.languageCode = languageCode
        self.isOff = isOff
    }
}
