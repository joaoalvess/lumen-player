//
//  TVPlaybackAdjustments.swift
//  Lumen
//
import Foundation

enum TVSubtitleDelay {
    static let limit: TimeInterval = 30

    static func adjusted(_ value: TimeInterval, by step: TimeInterval) -> TimeInterval {
        normalized((value.isFinite ? value : 0) + (step.isFinite ? step : 0))
    }

    static func label(_ value: TimeInterval) -> String {
        let rounded = tenths(of: value)
        guard rounded != 0 else {
            return "0,0 s"
        }
        return signedDecimal(rounded) + " s"
    }

    static func stepLabel(_ step: TimeInterval) -> String {
        signedDecimal(tenths(of: step))
    }

    private static func normalized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else {
            return 0
        }
        let rounded = (value * 10).rounded() / 10
        let clamped = min(max(rounded, -limit), limit)
        return clamped == 0 ? 0 : clamped
    }

    private static func tenths(of value: TimeInterval) -> Int {
        Int((normalized(value) * 10).rounded())
    }

    private static func signedDecimal(_ tenths: Int) -> String {
        let sign = tenths < 0 ? "\u{2212}" : "+"
        let magnitude = abs(tenths)
        return "\(sign)\(magnitude / 10),\(magnitude % 10)"
    }
}

enum TVPlaybackRate {
    static let steps: [Float] = [0.75, 1, 1.25, 1.5, 2]

    static func label(_ rate: Float) -> String {
        let hundredths = Int((Double(rate.isFinite ? rate : 1) * 100).rounded())
        let whole = hundredths / 100
        let fraction = abs(hundredths % 100)
        guard fraction != 0 else {
            return "\(whole)\u{00D7}"
        }
        var digits = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        if digits.hasSuffix("0") {
            digits.removeLast()
        }
        return "\(whole),\(digits)\u{00D7}"
    }

    static func isSelected(_ step: Float, current: Float) -> Bool {
        abs(step - current) < 0.01
    }
}
