//
//  TVScrubberTuning.swift
//  Lumen
//
import CoreGraphics
import Foundation

enum TVScrubberTuning {
    static let arrowStep: TimeInterval = 10
    static let repeatDelay: TimeInterval = 0.45
    static let repeatInterval: TimeInterval = 0.22
    static let autoCommitDelay: TimeInterval = 1

    static func showsLiveLabel(isReadyToPlay: Bool, isSeekable: Bool, duration: TimeInterval) -> Bool {
        isReadyToPlay && !isSeekable && (!duration.isFinite || duration <= 0)
    }

    static func panDelta(
        points: CGFloat,
        trackWidth: CGFloat,
        duration: TimeInterval,
        velocity: CGFloat
    ) -> TimeInterval {
        guard trackWidth > 0, duration > 0, points.isFinite, velocity.isFinite else {
            return 0
        }
        let maximumDelta = trackWidth * 0.35
        let limitedPoints = min(max(points, -maximumDelta), maximumDelta)
        return TimeInterval(limitedPoints / trackWidth) * secondsPerTrack(
            duration: duration,
            velocity: velocity
        )
    }

    static func secondsPerTrack(
        duration: TimeInterval,
        velocity: CGFloat
    ) -> TimeInterval {
        guard duration > 0 else { return 0 }

        let preciseSpan = min(duration * 0.1, min(30, max(5, duration * 0.005)))
        let fastSpan = min(duration * 0.2, min(360, max(45, duration * 0.05)))
        let normalizedVelocity = min(1, max(0, (abs(velocity) - 180) / 1_220))
        let easedVelocity = normalizedVelocity * normalizedVelocity * (3 - 2 * normalizedVelocity)
        return preciseSpan + (fastSpan - preciseSpan) * TimeInterval(easedVelocity)
    }

    static func repeatedArrowStep(heldFor duration: TimeInterval) -> TimeInterval {
        if duration < 1.5 {
            return arrowStep
        }
        if duration < 3.5 {
            return 30
        }
        return 60
    }

    static func elapsedLabelLeadingX(
        playheadX: CGFloat,
        trackWidth: CGFloat,
        elapsedWidth: CGFloat,
        remainingWidth: CGFloat,
        spacing: CGFloat = 24
    ) -> CGFloat {
        guard playheadX.isFinite,
              trackWidth.isFinite,
              elapsedWidth.isFinite,
              remainingWidth.isFinite,
              spacing.isFinite,
              trackWidth > 0
        else {
            return 0
        }

        let centeredX = playheadX - elapsedWidth / 2
        let maximumX = trackWidth - remainingWidth - elapsedWidth - spacing
        return min(max(0, centeredX), max(0, maximumX))
    }
}
