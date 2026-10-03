//
//  NowPlayingArtworkLoader.swift
//  Lumen
//
import Foundation
import ImageIO
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class NowPlayingArtworkLoader {
    private let maxPixelSize: Int
    private var task: Task<Void, Never>?
    private var requestedURL: URL?
    private var loadedURL: URL?
    private var loadedArtwork: MPMediaItemArtwork?

    nonisolated init(maxPixelSize: Int = 600) {
        self.maxPixelSize = maxPixelSize
    }

    deinit {
        task?.cancel()
    }

    func artwork(for url: URL) -> MPMediaItemArtwork? {
        loadedURL == url ? loadedArtwork : nil
    }

    func load(_ url: URL, completion: @escaping @MainActor (MPMediaItemArtwork) -> Void) {
        if let artwork = artwork(for: url) {
            completion(artwork)
            return
        }
        guard requestedURL != url || task == nil else {
            return
        }
        cancel()
        requestedURL = url
        let maxPixelSize = maxPixelSize
        task = Task { [weak self] in
            let image = await NowPlayingArtworkLoader.downloadImage(from: url, maxPixelSize: maxPixelSize)
            guard let self, !Task.isCancelled, self.requestedURL == url else {
                return
            }
            self.task = nil
            self.requestedURL = nil
            guard let image else {
                return
            }
            let artwork = NowPlayingArtworkLoader.makeArtwork(UIImage(cgImage: image))
            self.loadedURL = url
            self.loadedArtwork = artwork
            completion(artwork)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestedURL = nil
    }

    private nonisolated static func downloadImage(from url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let data = try? await url.data(),
              !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in
            image
        }
    }
}
