//
//  FoundationExtend.swift
//  Lumen
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import CryptoKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if canImport(MobileCoreServices)
import MobileCoreServices.UTType
#endif
public extension String {
    static func systemClockTime(second: Bool = false) -> String {
        let date = Date()
        let calendar = Calendar.current
        let component = calendar.dateComponents([.hour, .minute, .second], from: date)
        if second {
            return String(format: "%02i:%02i:%02i", component.hour!, component.minute!, component.second!)
        } else {
            return String(format: "%02i:%02i", component.hour!, component.minute!)
        }
    }

    /// 把字符串时间转为对应的秒
    /// - Parameter fromStr: srt 00:02:52,184 ass 0:30:11.56 vtt 00:00.430
    /// - Returns: 秒
    func parseDuration() -> TimeInterval {
        let scanner = Scanner(string: self)

        var hour: Double = 0
        if split(separator: ":").count > 2 {
            hour = scanner.scanDouble() ?? 0.0
            _ = scanner.scanString(":")
        }

        let min = scanner.scanDouble() ?? 0.0
        _ = scanner.scanString(":")
        let sec = scanner.scanDouble() ?? 0.0
        let seconds = (hour * 3600.0) + (min * 60.0) + sec
        guard (scanner.scanString(",") ?? scanner.scanString(".")) != nil,
              let digits = scanner.scanCharacters(from: .decimalDigits),
              let fraction = Double(digits)
        else {
            return seconds
        }
        return seconds + fraction / pow(10.0, Double(digits.count))
    }

    func md5() -> String {
        Data(utf8).md5()
    }
}

@inline(__always)
@preconcurrency
public func runOnMainThread(block: @MainActor @escaping () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(block)
    } else {
        Task { @MainActor in
            block()
        }
    }
}

public extension Data {
    func md5() -> String {
        let digestData = Insecure.MD5.hash(data: self)
        return String(digestData.map { String(format: "%02hhx", $0) }.joined().prefix(32))
    }
}

public extension Double {
    var kmFormatted: String {
        //        return .formatted(.number.notation(.compactName))
        if self >= 1_000_000 {
            return String(format: "%.1fM", locale: Locale.current, self / 1_000_000)
            //                .replacingOccurrences(of: ".0", with: "")
        } else if self >= 10000, self <= 999_999 {
            return String(format: "%.1fK", locale: Locale.current, self / 1000)
            //                .replacingOccurrences(of: ".0", with: "")
        } else {
            return String(format: "%.0f", locale: Locale.current, self)
        }
    }
}
