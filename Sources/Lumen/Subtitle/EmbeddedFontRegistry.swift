import CoreGraphics
import CoreText
import Foundation
#if !canImport(UIKit)
import AppKit
#else
import UIKit
#endif

public final class EmbeddedFontRegistry: @unchecked Sendable {
    private struct Entry {
        let owner: UUID
        let font: CGFont
        let postScriptName: String
        let keys: Set<String>
        let didRegister: Bool
    }

    public static let shared = EmbeddedFontRegistry()
    private let lock = NSLock()
    private var entries = [Entry]()

    private init() {}

    public static func isFontAttachment(mimeType: String?, filename: String?) -> Bool {
        let fontMimeTypes: Set<String> = [
            "application/x-truetype-font",
            "application/vnd.ms-opentype",
            "application/x-font-ttf",
            "application/x-font-otf",
            "application/font-sfnt",
            "font/ttf",
            "font/otf",
            "font/sfnt",
            "font/collection",
        ]
        if let mimeType, fontMimeTypes.contains(mimeType.lowercased()) {
            return true
        }
        if let filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            return ["ttf", "otf", "ttc"].contains(ext)
        }
        return false
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func register(fontData: Data, owner: UUID) {
        guard let provider = CGDataProvider(data: fontData as CFData),
              let font = CGFont(provider),
              let cfPostScriptName = font.postScriptName
        else {
            return
        }
        let postScriptName = cfPostScriptName as String
        let ctFont = CTFontCreateWithGraphicsFont(font, 0, nil, nil)
        var keys = Set<String>()
        keys.insert(Self.normalize(postScriptName))
        if let familyName = CTFontCopyName(ctFont, kCTFontFamilyNameKey) {
            keys.insert(Self.normalize(familyName as String))
        }
        if let fullName = CTFontCopyName(ctFont, kCTFontFullNameKey) {
            keys.insert(Self.normalize(fullName as String))
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        var didRegister = false
        if !entries.contains(where: { $0.didRegister && $0.postScriptName == postScriptName }) {
            var errorRef: Unmanaged<CFError>?
            didRegister = CTFontManagerRegisterGraphicsFont(font, &errorRef)
            if !didRegister {
                _ = errorRef?.takeRetainedValue()
            }
        }
        entries.append(Entry(owner: owner, font: font, postScriptName: postScriptName, keys: keys, didRegister: didRegister))
    }

    public func unregister(owner: UUID) {
        var fontsToUnregister = [CGFont]()
        lock.lock()
        var kept = [Entry]()
        var removed = [Entry]()
        for entry in entries {
            if entry.owner == owner {
                removed.append(entry)
            } else {
                kept.append(entry)
            }
        }
        for entry in removed where entry.didRegister {
            if let survivorIndex = kept.firstIndex(where: { $0.postScriptName == entry.postScriptName }) {
                let survivor = kept[survivorIndex]
                kept[survivorIndex] = Entry(owner: survivor.owner, font: entry.font, postScriptName: survivor.postScriptName, keys: survivor.keys, didRegister: true)
            } else {
                fontsToUnregister.append(entry.font)
            }
        }
        entries = kept
        lock.unlock()
        for font in fontsToUnregister {
            var errorRef: Unmanaged<CFError>?
            if !CTFontManagerUnregisterGraphicsFont(font, &errorRef) {
                _ = errorRef?.takeRetainedValue()
            }
        }
    }

    public func fontName(for name: String) -> String? {
        let key = Self.normalize(name)
        guard !key.isEmpty else {
            return nil
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        return entries.last { $0.keys.contains(key) }?.postScriptName
    }

    public func font(named name: String, size: CGFloat) -> UIFont? {
        guard let postScriptName = fontName(for: name) else {
            return nil
        }
        return UIFont(name: postScriptName, size: size)
    }
}
