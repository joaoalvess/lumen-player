//
//  TVPromptLogic.swift
//  Lumen
//
import Foundation

#if os(tvOS)
enum TVActivePrompt: Equatable, Sendable {
    case upNext
    case skip(index: Int, segment: TVSkipSegment)
}

enum TVUpNextTiming: Sendable {
    static func windowStart(duration: TimeInterval, leadTime: TimeInterval, startTime: TimeInterval?) -> TimeInterval {
        let requested = startTime.flatMap { $0.isFinite ? $0 : nil } ?? duration - leadTime
        return max(requested, duration * 0.5)
    }

    static func isVisible(currentTime: TimeInterval,
                          duration: TimeInterval,
                          leadTime: TimeInterval,
                          startTime: TimeInterval?) -> Bool {
        guard duration.isFinite, duration > 0, currentTime.isFinite else {
            return false
        }
        return currentTime >= windowStart(duration: duration, leadTime: leadTime, startTime: startTime)
    }

    static func remainingSeconds(currentTime: TimeInterval, duration: TimeInterval) -> Int {
        let remaining = (duration - currentTime).rounded(.up)
        guard remaining.isFinite, remaining > 0 else {
            return 0
        }
        return remaining < Double(Int.max) ? Int(remaining) : Int.max
    }

    static func progress(currentTime: TimeInterval,
                         duration: TimeInterval,
                         leadTime: TimeInterval,
                         startTime: TimeInterval?) -> Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else {
            return 0
        }
        let start = windowStart(duration: duration, leadTime: leadTime, startTime: startTime)
        let span = duration - start
        guard span > 0 else {
            return currentTime >= start ? 1 : 0
        }
        return min(1, max(0, (currentTime - start) / span))
    }
}

enum TVSkipTiming: Sendable {
    static func active(at time: TimeInterval,
                       segments: [TVSkipSegment],
                       dismissed: Set<Int>,
                       hidingCredits: Bool) -> (index: Int, segment: TVSkipSegment)? {
        guard time.isFinite else {
            return nil
        }
        for (index, segment) in segments.enumerated() where !dismissed.contains(index) {
            if hidingCredits, segment.kind == .credits {
                continue
            }
            if segment.range.contains(time) {
                return (index, segment)
            }
        }
        return nil
    }
}

enum TVPromptResolver: Sendable {
    static func active(currentTime: TimeInterval,
                       duration: TimeInterval,
                       upNext: (leadTime: TimeInterval, startTime: TimeInterval?)?,
                       isUpNextDismissed: Bool,
                       segments: [TVSkipSegment],
                       dismissedSkips: Set<Int>) -> TVActivePrompt? {
        let isInUpNextWindow = upNext.map {
            TVUpNextTiming.isVisible(currentTime: currentTime,
                                     duration: duration,
                                     leadTime: $0.leadTime,
                                     startTime: $0.startTime)
        } ?? false
        if isInUpNextWindow, !isUpNextDismissed {
            return .upNext
        }
        guard let skip = TVSkipTiming.active(at: currentTime,
                                             segments: segments,
                                             dismissed: dismissedSkips,
                                             hidingCredits: isInUpNextWindow)
        else {
            return nil
        }
        return .skip(index: skip.index, segment: skip.segment)
    }
}
#endif
