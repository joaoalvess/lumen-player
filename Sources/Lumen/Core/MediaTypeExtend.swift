//
//  MediaTypeExtend.swift
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

public extension URL {
    var isMovie: Bool {
        if let typeID = try? resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier as CFString? {
            return UTTypeConformsTo(typeID, kUTTypeMovie)
        }
        return false
    }

    var isAudio: Bool {
        if let typeID = try? resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier as CFString? {
            return UTTypeConformsTo(typeID, kUTTypeAudio)
        }
        return false
    }

    var isSubtitle: Bool {
        ["ass", "srt", "ssa", "vtt"].contains(pathExtension.lowercased())
    }

    var isPlaylist: Bool {
        ["cue", "m3u", "pls"].contains(pathExtension.lowercased())
    }
}

#if canImport(UIKit)
extension AVPlayer.HDRMode {
    var dynamicRange: DynamicRange {
        if contains(.dolbyVision) {
            return .dolbyVision
        } else if contains(.hlg) {
            return .hlg
        } else if contains(.hdr10) {
            return .hdr10
        } else {
            return .sdr
        }
    }
}
#endif

public extension FourCharCode {
    var string: String {
        let cString: [CChar] = [
            CChar(self >> 24 & 0xFF),
            CChar(self >> 16 & 0xFF),
            CChar(self >> 8 & 0xFF),
            CChar(self & 0xFF),
            0,
        ]
        return String(cString: cString)
    }
}

extension CMTime {
    init(seconds: TimeInterval) {
        self.init(seconds: seconds, preferredTimescale: Int32(USEC_PER_SEC))
    }
}

extension CMTimeRange {
    init(start: TimeInterval, end: TimeInterval) {
        self.init(start: CMTime(seconds: start), end: CMTime(seconds: end))
    }
}
