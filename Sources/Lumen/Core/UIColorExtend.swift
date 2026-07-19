//
//  UIColorExtend.swift
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
public extension UIColor {
    convenience init?(assColor: String) {
        var colorString = assColor
        // 移除颜色字符串中的前缀 &H 和后缀 &
        if colorString.hasPrefix("&H") {
            colorString = String(colorString.dropFirst(2))
        }
        if colorString.hasSuffix("&") {
            colorString = String(colorString.dropLast())
        }
        if let hex = Scanner(string: colorString).scanInt(representation: .hexadecimal) {
            self.init(abgr: hex)
        } else {
            return nil
        }
    }

    convenience init(abgr hex: Int) {
        let alpha = 1 - (CGFloat(hex >> 24 & 0xFF) / 255)
        let blue = CGFloat((hex >> 16) & 0xFF)
        let green = CGFloat((hex >> 8) & 0xFF)
        let red = CGFloat(hex & 0xFF)
        self.init(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
    }

    convenience init(rgb hex: Int, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF)
        let green = CGFloat((hex >> 8) & 0xFF)
        let blue = CGFloat(hex & 0xFF)
        self.init(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
    }

    func createImage(size: CGSize = CGSize(width: 1, height: 1)) -> UIImage {
        #if canImport(UIKit)
        let rect = CGRect(origin: .zero, size: size)
        UIGraphicsBeginImageContext(rect.size)
        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(cgColor)
        context?.fill(rect)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image!
        #else
        let image = NSImage(size: size)
        image.lockFocus()
        drawSwatch(in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
        #endif
    }
}
