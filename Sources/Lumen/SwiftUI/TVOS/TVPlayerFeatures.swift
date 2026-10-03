//
//  TVPlayerFeatures.swift
//  Lumen
//
import Foundation
import Combine

#if os(tvOS)
public struct TVUpNextItem: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var artworkURL: URL?

    public init(title: String, subtitle: String? = nil, artworkURL: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }
}

public struct TVUpNext {
    public var item: TVUpNextItem
    public var leadTime: TimeInterval
    public var startTime: TimeInterval?
    public var onPlayNext: @MainActor () -> Void
    public var onDismiss: (@MainActor () -> Void)?

    public init(item: TVUpNextItem,
                leadTime: TimeInterval = 30,
                startTime: TimeInterval? = nil,
                onPlayNext: @escaping @MainActor () -> Void,
                onDismiss: (@MainActor () -> Void)? = nil) {
        self.item = item
        self.leadTime = leadTime
        self.startTime = startTime
        self.onPlayNext = onPlayNext
        self.onDismiss = onDismiss
    }
}

public struct TVSkipSegment: Equatable, Sendable {
    public enum Kind: Sendable {
        case intro
        case credits
        case recap
        case preview
        case other
    }

    public var range: ClosedRange<TimeInterval>
    public var kind: Kind
    public var label: String?

    public init(range: ClosedRange<TimeInterval>, kind: Kind, label: String? = nil) {
        self.range = range
        self.kind = kind
        self.label = label
    }
}

@MainActor
public final class TVPlayerFeatures {
    @Published
    public var upNext: TVUpNext?
    @Published
    public var skipSegments: [TVSkipSegment] = []

    public init() {}
}

extension TVPlayerFeatures: ObservableObject {}
#endif
