//
//  CoreGraphicsExtend.swift
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

extension CGPoint {
    var reverse: CGPoint {
        CGPoint(x: y, y: x)
    }
}

extension CGSize {
    var reverse: CGSize {
        CGSize(width: height, height: width)
    }

    var toPoint: CGPoint {
        CGPoint(x: width, y: height)
    }

    var isHorizonal: Bool {
        width > height
    }
}

func * (left: CGSize, right: CGFloat) -> CGSize {
    CGSize(width: left.width * right, height: left.height * right)
}

func * (left: CGPoint, right: CGFloat) -> CGPoint {
    CGPoint(x: left.x * right, y: left.y * right)
}

func * (left: CGRect, right: CGFloat) -> CGRect {
    CGRect(origin: left.origin * right, size: left.size * right)
}

func - (left: CGSize, right: CGSize) -> CGSize {
    CGSize(width: left.width - right.width, height: left.height - right.height)
}

extension CGImage {
    static func combine(images: [(CGRect, CGImage)]) -> CGImage? {
        if images.isEmpty {
            return nil
        }
        if images.count == 1 {
            return images[0].1
        }
        var width = 0
        var height = 0
        for (rect, _) in images {
            width = max(width, Int(rect.maxX))
            height = max(height, Int(rect.maxY))
        }
        let bitsPerComponent = 8
        // RGBA(的bytes) * bitsPerComponent *width
        let bytesPerRow = 4 * 8 * bitsPerComponent * width
        return autoreleasepool {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let context else {
                return nil
            }
            //            context.clear(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
            for (rect, cgImage) in images {
                context.draw(cgImage, in: CGRect(x: rect.origin.x, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
            }
            let cgImage = context.makeImage()
            return cgImage
        }
    }

    func data(type: AVFileType, quality: CGFloat) -> Data? {
        autoreleasepool {
            guard let mutableData = CFDataCreateMutable(nil, 0),
                  let destination = CGImageDestinationCreateWithData(mutableData, type.rawValue as CFString, 1, nil)
            else {
                return nil
            }
            CGImageDestinationAddImage(destination, self, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            return mutableData as Data
        }
    }

    static func make(rgbData: UnsafePointer<UInt8>, linesize: Int, width: Int, height: Int, isAlpha: Bool = false) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = isAlpha ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue) : CGBitmapInfo.byteOrderMask
        guard let data = CFDataCreate(kCFAllocatorDefault, rgbData, linesize * height), let provider = CGDataProvider(data: data) else {
            return nil
        }
        // swiftlint:disable line_length
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: isAlpha ? 32 : 24, bytesPerRow: linesize, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        // swiftlint:enable line_length
    }
}

public extension AVFileType {
    static let png = AVFileType(kUTTypePNG as String)
    static let jpeg2000 = AVFileType(kUTTypeJPEG2000 as String)
}
