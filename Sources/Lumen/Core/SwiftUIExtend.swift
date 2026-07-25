//
//  SwiftUIExtend.swift
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

extension TextAlignment: @retroactive RawRepresentable {
    public typealias RawValue = String
    public init?(rawValue: RawValue) {
        if rawValue == "Leading" {
            self = .leading
        } else if rawValue == "Center" {
            self = .center
        } else if rawValue == "Trailing" {
            self = .trailing
        } else {
            return nil
        }
    }

    public var rawValue: RawValue {
        switch self {
        case .leading:
            return "Leading"
        case .center:
            return "Center"
        case .trailing:
            return "Trailing"
        }
    }
}

extension TextAlignment: @retroactive Identifiable {
    public var id: Self { self }
}

extension HorizontalAlignment: @retroactive Hashable, @retroactive RawRepresentable {
    public typealias RawValue = String
    public init?(rawValue: RawValue) {
        if rawValue == "Leading" {
            self = .leading
        } else if rawValue == "Center" {
            self = .center
        } else if rawValue == "Trailing" {
            self = .trailing
        } else {
            return nil
        }
    }

    public var rawValue: RawValue {
        switch self {
        case .leading:
            return "Leading"
        case .center:
            return "Center"
        case .trailing:
            return "Trailing"
        default:
            return ""
        }
    }
}

extension HorizontalAlignment: @retroactive Identifiable {
    public var id: Self { self }
}

extension VerticalAlignment: @retroactive Hashable, @retroactive RawRepresentable {
    public typealias RawValue = String
    public init?(rawValue: RawValue) {
        if rawValue == "Top" {
            self = .top
        } else if rawValue == "Center" {
            self = .center
        } else if rawValue == "Bottom" {
            self = .bottom
        } else {
            return nil
        }
    }

    public var rawValue: RawValue {
        switch self {
        case .top:
            return "Top"
        case .center:
            return "Center"
        case .bottom:
            return "Bottom"
        default:
            return ""
        }
    }
}

extension VerticalAlignment: @retroactive Identifiable {
    public var id: Self { self }
}

extension Color: @retroactive RawRepresentable {
    public typealias RawValue = String
    public init?(rawValue: RawValue) {
        guard let data = Data(base64Encoded: rawValue) else {
            self = .black
            return
        }

        do {
            let color = try NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) ?? .black
            self = Color(color)
        } catch {
            self = .black
        }
    }

    public var rawValue: RawValue {
        do {
            if #available(macOS 11.0, iOS 14, tvOS 14, *) {
                let data = try NSKeyedArchiver.archivedData(withRootObject: UIColor(self), requiringSecureCoding: false) as Data
                return data.base64EncodedString()
            } else {
                return ""
            }
        } catch {
            return ""
        }
    }
}

extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else { return nil }
        self = result
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

extension Date: @retroactive RawRepresentable {
    public typealias RawValue = String
    public init?(rawValue: RawValue) {
        guard let data = rawValue.data(using: .utf8),
              let date = try? JSONDecoder().decode(Date.self, from: data)
        else {
            return nil
        }
        self = date
    }

    public var rawValue: RawValue {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return result
    }
}

extension URL: @retroactive Identifiable {
    public var id: Self { self }
}

extension String: @retroactive Identifiable {
    public var id: Self { self }
}

extension Float: @retroactive Identifiable {
    public var id: Self { self }
}
