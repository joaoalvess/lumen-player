//
//  ScrubThumbnailProvider.swift
//  Lumen
//
import Foundation

#if os(tvOS)
@MainActor final class ScrubThumbnailProvider: ObservableObject {
    enum Status {
        case idle
        case opening
        case ready
        case unavailable
    }

    @Published
    private(set) var status = Status.idle
    @Published
    private(set) var cacheRevision = 0
    private var cache = [Int: ScrubThumbnail]()
    private var lruKeys = [Int]()
    private let cacheLimit = 48
    private var engine: ScrubThumbnailEngine?
    private var bucketLength = TimeInterval(2)
    private var pendingBucket: Int?
    private var isFetching = false

    func startIfNeeded(url: URL?, options: KSOptions?, duration: TimeInterval) {
        guard KSOptions.enableScrubPreview, status == .idle, let url, duration > 0 else {
            return
        }
        status = .opening
        bucketLength = max(2, duration / 240)
        let engine = ScrubThumbnailEngine()
        self.engine = engine
        let formatOptions = options?.formatContextOptions ?? [:]
        let urlString = url.isFileURL ? url.path : url.absoluteString
        let width = KSOptions.scrubThumbnailWidth
        Task { [weak self] in
            let opened = await engine.open(urlString: urlString, formatOptions: formatOptions, width: width)
            guard let self, self.engine === engine else {
                return
            }
            self.status = opened ? .ready : .unavailable
        }
    }

    func request(_ time: TimeInterval) {
        guard status == .ready else {
            return
        }
        let bucket = bucketIndex(for: time)
        guard cache[bucket] == nil else {
            return
        }
        pendingBucket = bucket
        drainIfIdle()
    }

    func image(near time: TimeInterval) -> ScrubThumbnail? {
        let bucket = bucketIndex(for: time)
        for candidate in [bucket, bucket - 1, bucket + 1, bucket - 2, bucket + 2] {
            if let hit = cache[candidate] {
                return hit
            }
        }
        return nil
    }

    func shutdown() {
        engine?.close()
        engine = nil
        cache.removeAll()
        lruKeys.removeAll()
        pendingBucket = nil
        isFetching = false
        status = .idle
    }

    private func bucketIndex(for time: TimeInterval) -> Int {
        Int(time / bucketLength)
    }

    private func drainIfIdle() {
        guard !isFetching, let bucket = pendingBucket, let engine else {
            return
        }
        pendingBucket = nil
        isFetching = true
        let time = (TimeInterval(bucket) + 0.5) * bucketLength
        Task { [weak self] in
            let thumbnail = await engine.thumbnail(near: time)
            guard let self, self.engine === engine else {
                return
            }
            self.isFetching = false
            if let thumbnail {
                self.store(thumbnail, at: bucket)
            }
            self.drainIfIdle()
        }
    }

    private func store(_ thumbnail: ScrubThumbnail, at bucket: Int) {
        if cache[bucket] == nil {
            lruKeys.append(bucket)
            if lruKeys.count > cacheLimit {
                let evicted = lruKeys.removeFirst()
                cache[evicted] = nil
            }
        }
        cache[bucket] = thumbnail
        cacheRevision += 1
    }
}
#endif
