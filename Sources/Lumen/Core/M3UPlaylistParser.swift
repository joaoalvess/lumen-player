//
//  M3UPlaylistParser.swift
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
    func parsePlaylist() async throws -> [(String, URL, [String: String])] {
        let data = try await data()
        var entrys = data.parsePlaylist()
        for i in 0 ..< entrys.count {
            var entry = entrys[i]
            if entry.1.path.hasPrefix("./") {
                entry.1 = deletingLastPathComponent().appendingPathComponent(entry.1.path).standardized
                entrys[i] = entry
            }
        }
        return entrys
    }
}

public extension Data {
    func parsePlaylist() -> [(String, URL, [String: String])] {
        guard let string = String(data: self, encoding: .utf8) else {
            return []
        }
        let scanner = Scanner(string: string)
        var entrys = [(String, URL, [String: String])]()
        guard let symbol = scanner.scanUpToCharacters(from: .newlines), symbol.contains("#EXTM3U") else {
            return []
        }
        while !scanner.isAtEnd {
            if let entry = scanner.parseM3U() {
                entrys.append(entry)
            }
        }
        return entrys
    }
}

extension Scanner {
    /*
     #EXTINF:-1 tvg-id="ExampleTV.ua" tvg-logo="https://image.com" group-title="test test", Example TV (720p) [Not 24/7]
     #EXTVLCOPT:http-referrer=http://example.com/
     #EXTVLCOPT:http-user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)
     http://example.com/stream.m3u8
     */
    func parseM3U() -> (String, URL, [String: String])? {
        if scanString("#EXTINF:") == nil {
            _ = scanUpToCharacters(from: .newlines)
            return nil
        }
        var extinf = [String: String]()
        if let duration = scanDouble() {
            extinf["duration"] = String(duration)
        }
        while scanString(",") == nil {
            let key = scanUpToString("=")
            _ = scanString("=\"")
            let value = scanUpToString("\"")
            _ = scanString("\"")
            if let key, let value {
                extinf[key] = value
            }
        }
        let title = scanUpToCharacters(from: .newlines)
        while scanString("#EXT") != nil {
            if scanString("VLCOPT:") != nil {
                let key = scanUpToString("=")
                _ = scanString("=")
                let value = scanUpToCharacters(from: .newlines)
                if let key, let value {
                    extinf[key] = value
                }
            } else {
                let key = scanUpToString(":")
                _ = scanString(":")
                let value = scanUpToCharacters(from: .newlines)
                if let key, let value {
                    extinf[key] = value
                }
            }
        }
        let urlString = scanUpToCharacters(from: .newlines)
        if let urlString, let url = URL(string: urlString) {
            return (title ?? url.lastPathComponent, url, extinf)
        }
        return nil
    }
}
