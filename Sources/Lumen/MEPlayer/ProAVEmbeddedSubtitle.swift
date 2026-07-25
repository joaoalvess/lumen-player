import Foundation

final class ProAVSubtitlePartStore {
    private let lock = NSLock()
    private var parts = [SubtitlePart]()
    private var hasOpenEndedParts = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return parts.count
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        parts.removeAll()
        hasOpenEndedParts = false
    }

    func insert(parts newParts: [SubtitlePart]) {
        guard !newParts.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for part in newParts {
            insertLocked(part)
        }
        if hasOpenEndedParts {
            capOpenEndedPartsLocked()
        }
    }

    func search(for time: TimeInterval) -> [SubtitlePart] {
        lock.lock()
        defer { lock.unlock() }
        var result = [SubtitlePart]()
        for part in parts {
            if part == time {
                result.append(part)
            } else if part.start > time {
                break
            }
        }
        return result
    }

    private func insertLocked(_ part: SubtitlePart) {
        let index = insertionIndexLocked(start: part.start)
        var probe = index
        while probe < parts.count, parts[probe].start == part.start {
            let existing = parts[probe]
            if ProAVSubtitlePartStore.isSameCue(existing, part) {
                if existing.end == .infinity, part.end < .infinity {
                    existing.end = part.end
                }
                return
            }
            probe += 1
        }
        parts.insert(part, at: index)
        if part.end == .infinity {
            hasOpenEndedParts = true
        }
    }

    private func insertionIndexLocked(start: TimeInterval) -> Int {
        var lowerBound = 0
        var upperBound = parts.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if parts[middle].start < start {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func capOpenEndedPartsLocked() {
        var remaining = false
        var greaterStart: TimeInterval?
        var index = parts.count - 1
        while index >= 0 {
            let part = parts[index]
            if part.end == .infinity {
                if let greaterStart {
                    part.end = greaterStart
                } else {
                    remaining = true
                }
            }
            if index > 0, part.start > parts[index - 1].start {
                greaterStart = part.start
            }
            index -= 1
        }
        hasOpenEndedParts = remaining
    }

    private static func isSameCue(_ lhs: SubtitlePart, _ rhs: SubtitlePart) -> Bool {
        lhs.text?.string == rhs.text?.string && (lhs.image == nil) == (rhs.image == nil)
    }
}

final class ProAVEmbeddedSubtitleInfo: SubtitleInfo {
    let subtitleID: String
    private(set) var name: String
    var delay: TimeInterval = 0
    private let store = ProAVSubtitlePartStore()
    private weak var track: FFmpegAssetTrack?
    private weak var queue: SyncPlayerItemTrack<SubtitleFrame>?
    private var storedIsEnabled: Bool

    var isEnabled: Bool {
        get { storedIsEnabled }
        set {
            storedIsEnabled = newValue
            track?.isEnabled = newValue
        }
    }

    init(track: FFmpegAssetTrack) {
        subtitleID = String(track.trackID)
        name = track.name
        storedIsEnabled = track.isEnabled
        self.track = track
        queue = track.subtitle
    }

    func bind(track: FFmpegAssetTrack) {
        name = track.name
        self.track = track
        queue = track.subtitle
        track.isEnabled = storedIsEnabled
    }

    func detach() {
        drainPending()
        track = nil
        queue = nil
    }

    func reset() {
        store.removeAll()
    }

    func drainPending() {
        guard let queue else { return }
        let frames = queue.outputRenderQueue.search { _ in true }
        store.insert(parts: frames.map(\.part))
    }

    func search(for time: TimeInterval) -> [SubtitlePart] {
        drainPending()
        return store.search(for: time)
    }
}
