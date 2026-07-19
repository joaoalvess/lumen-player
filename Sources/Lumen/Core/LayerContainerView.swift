//
//  LayerContainerView.swift
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
open class LayerContainerView: UIView {
    #if canImport(UIKit)
    override open class var layerClass: AnyClass {
        CAGradientLayer.self
    }
    #else
    override public init(frame: CGRect) {
        super.init(frame: frame)
        layer = CAGradientLayer()
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    #endif
    public var gradientLayer: CAGradientLayer {
        // swiftlint:disable force_cast
        layer as! CAGradientLayer
        // swiftlint:enable force_cast
    }
}
