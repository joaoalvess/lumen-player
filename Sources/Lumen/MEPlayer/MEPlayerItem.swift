//
//  MEPlayerItem.swift
//  Lumen
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import FFmpegKit
import Libavcodec
import Libavfilter
import Libavformat

public final class MEPlayerItem: Sendable {
    private let url: URL
    private let options: KSOptions
    private let operationQueue = OperationQueue()
    private let condition = NSCondition()
    private let fontOwnerID = UUID()
    var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    var outputFormatCtx: UnsafeMutablePointer<AVFormatContext>?
    var outputPacket: UnsafeMutablePointer<AVPacket>?
    var streamMapping = [Int: Int]()
    private let remuxSession: ProAVRemuxSession?
    private var remuxTranscoder: ProAVAudioTranscoder?
    private var remuxTranscodeStreamIndex: Int?
    private var remuxCompleted = false
    private var remuxHeaderWritten = false
    private var openOperation: BlockOperation?
    private var readOperation: BlockOperation?
    private var closeOperation: BlockOperation?
    private var seekingCompletionHandler: ((Bool) -> Void)?
    // 没有音频数据可以渲染
    private var isAudioStalled = true
    private var audioClock = KSClock()
    private var videoClock = KSClock()
    private var isFirst = true
    private var isSeek = false
    private var memorySeekNeedsNetwork = false
    private var allPlayerItemTracks = [PlayerItemTrackProtocol]()
    private var maxFrameDuration = 10.0
    private var videoAudioTracks = [CapacityProtocol]()
    private var videoTrack: SyncPlayerItemTrack<VideoVTBFrame>?
    private var audioTrack: SyncPlayerItemTrack<AudioFrame>?
    private(set) var assetTracks = [FFmpegAssetTrack]()
    private var videoAdaptation: VideoAdaptationState?
    private var videoDisplayCount = UInt8(0)
    private var seekByBytes = false
    private var lastVideoDisplayTime = CACurrentMediaTime()
    public private(set) var chapters: [Chapter] = []
    public var currentPlaybackTime: TimeInterval {
        state == .seeking ? seekTime : (mainClock().time - startTime).seconds
    }

    private var seekTime = TimeInterval(0)
    private var startTime = CMTime.zero
    public private(set) var duration: TimeInterval = 0
    public private(set) var fileSize: Double = 0
    public private(set) var naturalSize = CGSize.zero
    private var error: NSError? {
        didSet {
            if error != nil {
                state = .failed
            }
        }
    }

    private var state = MESourceState.idle {
        didSet {
            switch state {
            case .opened:
                delegate?.sourceDidOpened()
            case .reading:
                timer.fireDate = Date.distantPast
            case .closed:
                timer.invalidate()
            case .failed:
                delegate?.sourceDidFailed(error: error)
                timer.fireDate = Date.distantFuture
            case .idle, .opening, .seeking, .paused, .finished:
                break
            }
        }
    }

    private lazy var timer: Timer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        self?.codecDidChangeCapacity()
    }

    lazy var dynamicInfo = DynamicInfo { [weak self] in
        // metadata可能会实时变化。所以把它放在DynamicInfo里面
        toDictionary(self?.formatCtx?.pointee.metadata)
    } bytesRead: { [weak self] in
        self?.formatCtx?.pointee.pb?.pointee.bytes_read ?? 0
    } audioBitrate: { [weak self] in
        Int(8 * (self?.audioTrack?.bitrate ?? 0))
    } videoBitrate: { [weak self] in
        Int(8 * (self?.videoTrack?.bitrate ?? 0))
    }

    private static var onceInitial: Void = {
        var result = avformat_network_init()
        av_log_set_callback { ptr, level, format, args in
            guard let format else {
                return
            }
            var log = String(cString: format)
            let arguments: CVaListPointer? = args
            if let arguments {
                log = NSString(format: log, arguments: arguments) as String
            }
            if let ptr {
                let avclass = ptr.assumingMemoryBound(to: UnsafePointer<AVClass>.self).pointee
                if avclass == avfilter_get_class() {
                    let context = ptr.assumingMemoryBound(to: AVFilterContext.self).pointee
                    if let opaque = context.graph?.pointee.opaque {
                        let options = Unmanaged<KSOptions>.fromOpaque(opaque).takeUnretainedValue()
                        options.filter(log: log)
                    }
                }
            }
            // 找不到解码器
            if log.hasPrefix("parser not found for codec") {
                KSLog(level: .error, log)
            }
            KSLog(level: LogLevel(rawValue: level) ?? .warning, log)
        }
    }()

    weak var delegate: MEPlayerDelegate?
    public init(url: URL, options: KSOptions, remuxSession: ProAVRemuxSession? = nil) {
        self.url = url
        self.options = options
        self.remuxSession = remuxSession
        timer.fireDate = Date.distantFuture
        operationQueue.name = "Lumen_" + String(describing: self).components(separatedBy: ".").last!
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInteractive
        _ = MEPlayerItem.onceInitial
    }

    func select(track: some MediaPlayerTrack) -> Bool {
        if track.isEnabled {
            return false
        }
        let sameMediaTypeTracks = assetTracks.filter { $0.mediaType == track.mediaType }
        sameMediaTypeTracks.first { track === $0 }?.isEnabled = true
        sameMediaTypeTracks.filter { track !== $0 }.forEach {
            $0.isEnabled = false
        }
        guard let assetTrack = track as? FFmpegAssetTrack else {
            return false
        }
        if assetTrack.mediaType == .video {
            findBestAudio(videoTrack: assetTrack)
        } else if assetTrack.mediaType == .subtitle {
            if assetTrack.isImageSubtitle {
                if !options.isSeekImageSubtitle {
                    return false
                }
            } else {
                return false
            }
        }
        seek(time: currentPlaybackTime) { _ in
        }
        return true
    }
}

// MARK: private functions

extension MEPlayerItem {
    private func openThread() {
        avformat_close_input(&self.formatCtx)
        formatCtx = avformat_alloc_context()
        guard let formatCtx else {
            error = NSError(errorCode: .formatCreate)
            return
        }
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = Unmanaged.passUnretained(self).toOpaque()
        interruptCB.callback = { ctx -> Int32 in
            guard let ctx else {
                return 0
            }
            let formatContext = Unmanaged<MEPlayerItem>.fromOpaque(ctx).takeUnretainedValue()
            switch formatContext.state {
            case .finished, .closed, .failed:
                return 1
            default:
                return 0
            }
        }
        formatCtx.pointee.interrupt_callback = interruptCB
        // avformat_close_input这个函数会调用io_close2。但是自定义协议是不会调用io_close2这个函数
//        formatCtx.pointee.io_close2 = { _, _ -> Int32 in
//            0
//        }
        setHttpProxy()
        var avOptions = options.formatContextOptions.avOptions
        var customIOContext: UnsafeMutablePointer<AVIOContext>?
        if let pb = options.process(url: url) {
            // 如果要自定义协议的话，那就用avio_alloc_context，对formatCtx.pointee.pb赋值
            customIOContext = pb.getContext()
            formatCtx.pointee.pb = customIOContext
        }
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            urlString = url.absoluteString
        }
        var result = avformat_open_input(&self.formatCtx, urlString, nil, &avOptions)
        av_dict_free(&avOptions)
        if result == AVError.eof.code {
            releaseCustomIOContext(customIOContext)
            state = .finished
            delegate?.sourceDidFinished()
            return
        }
        guard result == 0 else {
            error = .init(errorCode: .formatOpenInput, avErrorCode: result)
            releaseCustomIOContext(customIOContext)
            avformat_close_input(&self.formatCtx)
            return
        }
        options.openTime = CACurrentMediaTime()
        formatCtx.pointee.flags |= AVFMT_FLAG_GENPTS
        if options.nobuffer {
            formatCtx.pointee.flags |= AVFMT_FLAG_NOBUFFER
        }
        if let probesize = options.probesize {
            formatCtx.pointee.probesize = probesize
        }
        if let maxAnalyzeDuration = options.maxAnalyzeDuration {
            formatCtx.pointee.max_analyze_duration = maxAnalyzeDuration
        }
        result = avformat_find_stream_info(formatCtx, nil)
        guard result == 0 else {
            error = .init(errorCode: .formatFindStreamInfo, avErrorCode: result)
            releaseCustomIOContext(customIOContext)
            avformat_close_input(&self.formatCtx)
            return
        }
        // FIXME: hack, ffplay maybe should not use avio_feof() to test for the end
        formatCtx.pointee.pb?.pointee.eof_reached = 0
        let flags = formatCtx.pointee.iformat.pointee.flags
        maxFrameDuration = flags & AVFMT_TS_DISCONT == AVFMT_TS_DISCONT ? 10.0 : 3600.0
        options.findTime = CACurrentMediaTime()
        options.formatName = String(cString: formatCtx.pointee.iformat.pointee.name)
        seekByBytes = (flags & AVFMT_NO_BYTE_SEEK == 0) && (flags & AVFMT_TS_DISCONT != 0) && options.formatName != "ogg"
        if formatCtx.pointee.start_time != Int64.min {
            startTime = CMTime(value: formatCtx.pointee.start_time, timescale: AV_TIME_BASE)
            videoClock.time = startTime
            audioClock.time = startTime
        }
        duration = TimeInterval(max(formatCtx.pointee.duration, 0)) / TimeInterval(AV_TIME_BASE)
        fileSize = Double(formatCtx.pointee.bit_rate) * duration / 8
        createCodec(formatCtx: formatCtx)
        if formatCtx.pointee.nb_chapters > 0 {
            chapters.removeAll()
            for i in 0 ..< formatCtx.pointee.nb_chapters {
                if let chapter = formatCtx.pointee.chapters[Int(i)]?.pointee {
                    let timeBase = Timebase(chapter.time_base)
                    let start = timeBase.cmtime(for: chapter.start).seconds
                    let end = timeBase.cmtime(for: chapter.end).seconds
                    let metadata = toDictionary(chapter.metadata)
                    let title = metadata["title"] ?? ""
                    chapters.append(Chapter(start: start, end: end, title: title))
                }
            }
        }

        if let remuxSession {
            startProAVRemux(session: remuxSession)
            if state == .failed {
                return
            }
        } else if let outputURL = options.outputURL {
            startRecord(url: outputURL)
        }
        if videoTrack == nil, audioTrack == nil {
            state = .failed
        } else {
            state = .opened
            read()
        }
    }

    private func releaseCustomIOContext(_ ioContext: UnsafeMutablePointer<AVIOContext>?) {
        guard let ioContext, let opaque = ioContext.pointee.opaque else {
            return
        }
        ioContext.pointee.opaque = nil
        let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque).takeRetainedValue()
        value.close()
    }

    private func startProAVRemux(session: ProAVRemuxSession) {
        guard let formatCtx else {
            error = NSError(errorCode: .formatOutputCreate)
            return
        }
        guard let videoAssetTrack = assetTracks.first(where: { $0.mediaType == .video && $0.isEnabled }),
              let signaling = ProAVVideoSignaling(track: videoAssetTrack)
        else {
            error = NSError(description: "ProAV video signaling unsupported")
            return
        }
        var ret = avformat_alloc_output_context2(&outputFormatCtx, nil, "mp4", nil)
        guard let outputFormatCtx else {
            error = NSError(errorCode: .formatOutputCreate, avErrorCode: ret)
            return
        }
        outputFormatCtx.pointee.strict_std_compliance = ProAVFFmpegConstant.complianceExperimental
        outputFormatCtx.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        streamMapping.removeAll()
        guard let inputVideoStream = formatCtx.pointee.streams[Int(videoAssetTrack.trackID)],
              let outputVideoStream = avformat_new_stream(outputFormatCtx, nil)
        else {
            error = NSError(errorCode: .formatOutputCreate)
            return
        }
        avcodec_parameters_copy(outputVideoStream.pointee.codecpar, inputVideoStream.pointee.codecpar)
        outputVideoStream.pointee.codecpar.pointee.codec_tag = signaling.codecTagValue.bigEndian
        outputVideoStream.pointee.time_base = inputVideoStream.pointee.time_base
        streamMapping[Int(videoAssetTrack.trackID)] = 0
        var audioCodecsAttribute: String?
        let audios = assetTracks.filter { $0.mediaType == .audio }
        let preferredAudioTrackID = session.preferredAudioTrackID
        let audioAssetTrack = audios.first { preferredAudioTrackID == nil ? $0.isEnabled : $0.trackID == preferredAudioTrackID } ?? audios.first { $0.isEnabled } ?? audios.first
        if let audioAssetTrack, let inputAudioStream = formatCtx.pointee.streams[Int(audioAssetTrack.trackID)] {
            let strategy = ProAVAudioStrategy.make(codecId: audioAssetTrack.codecpar.codec_id)
            if strategy.copiesBitstream {
                if let outputAudioStream = avformat_new_stream(outputFormatCtx, nil) {
                    avcodec_parameters_copy(outputAudioStream.pointee.codecpar, inputAudioStream.pointee.codecpar)
                    outputAudioStream.pointee.codecpar.pointee.codec_tag = 0
                    outputAudioStream.pointee.time_base = inputAudioStream.pointee.time_base
                    streamMapping[Int(audioAssetTrack.trackID)] = 1
                    audioCodecsAttribute = strategy.codecsAttribute
                }
            } else if let transcoder = ProAVAudioTranscoder(codecpar: inputAudioStream.pointee.codecpar, sourceTimebase: Timebase(inputAudioStream.pointee.time_base)),
                      let outputAudioStream = avformat_new_stream(outputFormatCtx, nil),
                      transcoder.fill(codecpar: outputAudioStream.pointee.codecpar)
            {
                outputAudioStream.pointee.codecpar.pointee.codec_tag = 0
                outputAudioStream.pointee.time_base = transcoder.timebase
                remuxTranscoder = transcoder
                remuxTranscodeStreamIndex = Int(audioAssetTrack.trackID)
                streamMapping[Int(audioAssetTrack.trackID)] = 1
                audioCodecsAttribute = strategy.codecsAttribute
            } else {
                KSLog("ProAV audio track skipped: flac transcode unavailable")
            }
        }
        let codecpar = videoAssetTrack.codecpar
        let resolution = CGSize(width: Int(codecpar.width), height: Int(codecpar.height))
        let bandwidth = videoAssetTrack.bitRate > 0 ? videoAssetTrack.bitRate : formatCtx.pointee.bit_rate
        guard session.begin(signaling: signaling, audioCodecsAttribute: audioCodecsAttribute, bandwidth: bandwidth, resolution: resolution, frameRate: videoAssetTrack.nominalFrameRate),
              let ioContext = session.makeIOContext()
        else {
            error = NSError(errorCode: .formatOutputCreate)
            return
        }
        outputFormatCtx.pointee.pb = ioContext
        let movDictionary: [String: Any] = ["movflags": "+empty_moov+default_base_moof+frag_custom+skip_sidx"]
        var avOptions = movDictionary.avOptions
        ret = avformat_write_header(outputFormatCtx, &avOptions)
        av_dict_free(&avOptions)
        guard ret >= 0 else {
            error = NSError(errorCode: .formatWriteHeader, avErrorCode: ret)
            return
        }
        remuxHeaderWritten = true
        if let pb = outputFormatCtx.pointee.pb {
            avio_flush(pb)
        }
        session.finishInitSegment()
        outputPacket = av_packet_alloc()
    }

    private func writeProAVPacket(corePacket: UnsafeMutablePointer<AVPacket>, outputFormatCtx: UnsafeMutablePointer<AVFormatContext>, formatCtx: UnsafeMutablePointer<AVFormatContext>, session: ProAVRemuxSession) {
        let index = Int(corePacket.pointee.stream_index)
        guard let outputIndex = streamMapping[index],
              let inputStream = formatCtx.pointee.streams[index],
              let outputStream = outputFormatCtx.pointee.streams[outputIndex]
        else { return }
        if index == remuxTranscodeStreamIndex {
            guard let remuxTranscoder else { return }
            let succeeded = remuxTranscoder.transcode(packet: corePacket) { encodedPacket in
                encodedPacket.pointee.stream_index = Int32(outputIndex)
                av_packet_rescale_ts(encodedPacket, remuxTranscoder.timebase, outputStream.pointee.time_base)
                _ = av_write_frame(outputFormatCtx, encodedPacket)
            }
            if !succeeded {
                session.fail(NSError(description: "ProAV flac transcode failed"))
            }
            return
        }
        guard let outputPacket else { return }
        if outputStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
            let timestamp = corePacket.pointee.pts == Int64.min ? corePacket.pointee.dts : corePacket.pointee.pts
            if timestamp != Int64.min {
                let seconds = Timebase(inputStream.pointee.time_base).cmtime(for: timestamp).seconds
                session.trackVideoTime(seconds: seconds)
                if corePacket.pointee.flags & AV_PKT_FLAG_KEY != 0, session.shouldCutSegment(at: seconds) {
                    _ = av_write_frame(outputFormatCtx, nil)
                    if let pb = outputFormatCtx.pointee.pb {
                        avio_flush(pb)
                    }
                    session.closeSegment(nextStartTime: seconds)
                }
            }
        }
        av_packet_ref(outputPacket, corePacket)
        outputPacket.pointee.stream_index = Int32(outputIndex)
        av_packet_rescale_ts(outputPacket, inputStream.pointee.time_base, outputStream.pointee.time_base)
        outputPacket.pointee.pos = -1
        let ret = av_write_frame(outputFormatCtx, outputPacket)
        if ret < 0 {
            KSLog("ProAV remux can not av_write_frame")
        }
        av_packet_unref(outputPacket)
    }

    private func finishRemux(reachedEnd: Bool) {
        guard let remuxSession, !remuxCompleted else { return }
        remuxCompleted = true
        if let outputFormatCtx, remuxHeaderWritten {
            if reachedEnd, let remuxTranscoder, let streamIndex = remuxTranscodeStreamIndex,
               let outputIndex = streamMapping[streamIndex],
               let outputStream = outputFormatCtx.pointee.streams[outputIndex]
            {
                _ = remuxTranscoder.finish { encodedPacket in
                    encodedPacket.pointee.stream_index = Int32(outputIndex)
                    av_packet_rescale_ts(encodedPacket, remuxTranscoder.timebase, outputStream.pointee.time_base)
                    _ = av_write_frame(outputFormatCtx, encodedPacket)
                }
            }
            av_write_trailer(outputFormatCtx)
            if let pb = outputFormatCtx.pointee.pb {
                avio_flush(pb)
            }
        }
        remuxTranscoder?.shutdown()
        remuxTranscoder = nil
        av_packet_free(&outputPacket)
        avformat_close_input(&outputFormatCtx)
        remuxSession.releaseIOContext()
        remuxSession.finish(reachedEnd: reachedEnd)
    }

    private func createCodec(formatCtx: UnsafeMutablePointer<AVFormatContext>) {
        allPlayerItemTracks.removeAll()
        assetTracks.removeAll()
        videoAdaptation = nil
        videoTrack = nil
        audioTrack = nil
        videoAudioTracks.removeAll()
        assetTracks = (0 ..< Int(formatCtx.pointee.nb_streams)).compactMap { i in
            if let coreStream = formatCtx.pointee.streams[i] {
                coreStream.pointee.discard = AVDISCARD_ALL
                if let assetTrack = FFmpegAssetTrack(stream: coreStream) {
                    if assetTrack.mediaType == .subtitle {
                        let subtitle = SyncPlayerItemTrack<SubtitleFrame>(mediaType: .subtitle, frameCapacity: 255, options: options)
                        assetTrack.subtitle = subtitle
                        allPlayerItemTracks.append(subtitle)
                    }
                    assetTrack.seekByBytes = seekByBytes
                    return assetTrack
                } else if coreStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT {
                    registerEmbeddedFont(stream: coreStream)
                }
            }
            return nil
        }
        var videoIndex: Int32 = -1
        if !options.videoDisable {
            let videos = assetTracks.filter { $0.mediaType == .video }
            let wantedStreamNb: Int32
            if !videos.isEmpty, let index = options.wantedVideo(tracks: videos) {
                wantedStreamNb = videos[index].trackID
            } else {
                wantedStreamNb = -1
            }
            videoIndex = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, wantedStreamNb, -1, nil, 0)
            if let first = videos.first(where: { $0.trackID == videoIndex }) {
                first.isEnabled = true
                let rotation = first.rotation
                if rotation > 0, options.autoRotate {
                    options.hardwareDecode = false
                    if abs(rotation - 90) <= 1 {
                        options.videoFilters.append("transpose=clock")
                    } else if abs(rotation - 180) <= 1 {
                        options.videoFilters.append("hflip")
                        options.videoFilters.append("vflip")
                    } else if abs(rotation - 270) <= 1 {
                        options.videoFilters.append("transpose=cclock")
                    } else if abs(rotation) > 1 {
                        options.videoFilters.append("rotate=\(rotation)*PI/180")
                    }
                }
                naturalSize = abs(rotation - 90) <= 1 || abs(rotation - 270) <= 1 ? first.naturalSize.reverse : first.naturalSize
                options.process(assetTrack: first)
                let frameCapacity = options.videoFrameMaxCount(fps: first.nominalFrameRate, naturalSize: naturalSize, isLive: duration == 0)
                let track = options.syncDecodeVideo ? SyncPlayerItemTrack<VideoVTBFrame>(mediaType: .video, frameCapacity: frameCapacity, options: options) : AsyncPlayerItemTrack<VideoVTBFrame>(mediaType: .video, frameCapacity: frameCapacity, options: options)
                track.delegate = self
                allPlayerItemTracks.append(track)
                videoTrack = track
                if first.codecpar.codec_id != AV_CODEC_ID_MJPEG {
                    videoAudioTracks.append(track)
                }
                let bitRates = videos.map(\.bitRate).filter {
                    $0 > 0
                }
                if bitRates.count > 1, options.videoAdaptable {
                    let bitRateState = VideoAdaptationState.BitRateState(bitRate: first.bitRate, time: CACurrentMediaTime())
                    videoAdaptation = VideoAdaptationState(bitRates: bitRates.sorted(by: <), duration: duration, fps: first.nominalFrameRate, bitRateStates: [bitRateState])
                }
            }
        }

        let audios = assetTracks.filter { $0.mediaType == .audio }
        let wantedStreamNb: Int32
        if !audios.isEmpty, let index = options.wantedAudio(tracks: audios) {
            wantedStreamNb = audios[index].trackID
        } else {
            wantedStreamNb = -1
        }
        let index = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, wantedStreamNb, videoIndex, nil, 0)
        if let first = audios.first(where: {
            index > 0 ? $0.trackID == index : true
        }), first.codecpar.codec_id != AV_CODEC_ID_NONE {
            first.isEnabled = true
            options.process(assetTrack: first)
            // 音频要比较所有的音轨，因为truehd的fps是1200，跟其他的音轨差距太大了
            let fps = audios.map(\.nominalFrameRate).max() ?? 44
            let frameCapacity = options.audioFrameMaxCount(fps: fps, channelCount: Int(first.audioDescriptor?.audioFormat.channelCount ?? 2))
            let track = options.syncDecodeAudio ? SyncPlayerItemTrack<AudioFrame>(mediaType: .audio, frameCapacity: frameCapacity, options: options) : AsyncPlayerItemTrack<AudioFrame>(mediaType: .audio, frameCapacity: frameCapacity, options: options)
            track.delegate = self
            allPlayerItemTracks.append(track)
            audioTrack = track
            videoAudioTracks.append(track)
            isAudioStalled = false
        }
    }

    private func registerEmbeddedFont(stream: UnsafeMutablePointer<AVStream>) {
        guard KSOptions.registerEmbeddedFonts else {
            return
        }
        let codecpar = stream.pointee.codecpar.pointee
        guard let extradata = codecpar.extradata, codecpar.extradata_size > 0 else {
            return
        }
        let metadata = toDictionary(stream.pointee.metadata)
        guard EmbeddedFontRegistry.isFontAttachment(mimeType: metadata["mimetype"], filename: metadata["filename"]) else {
            return
        }
        let data = Data(bytes: extradata, count: Int(codecpar.extradata_size))
        EmbeddedFontRegistry.shared.register(fontData: data, owner: fontOwnerID)
    }

    private func read() {
        readOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_read"
            Thread.current.stackSize = KSOptions.stackSize
            self.readThread()
        }
        readOperation?.queuePriority = .veryHigh
        readOperation?.qualityOfService = .userInteractive
        if let readOperation {
            operationQueue.addOperation(readOperation)
        }
    }

    private func readThread() {
        if state == .opened {
            if options.startPlayTime > 0 {
                let timestamp = startTime + CMTime(seconds: options.startPlayTime)
                let flags = seekByBytes ? AVSEEK_FLAG_BYTE : 0
                let seekStartTime = CACurrentMediaTime()
                let result = avformat_seek_file(formatCtx, -1, Int64.min, timestamp.value, Int64.max, flags)
                audioClock.time = timestamp
                videoClock.time = timestamp
                KSLog("start PlayTime: \(timestamp.seconds) spend Time: \(CACurrentMediaTime() - seekStartTime)")
            }
            state = .reading
        }
        if remuxSession == nil {
            allPlayerItemTracks.forEach { $0.decode() }
        }
        while [MESourceState.paused, .seeking, .reading].contains(state) {
            condition.lock()
            while state == .paused {
                condition.wait()
            }
            var forceNetworkSeek = false
            if state == .seeking {
                forceNetworkSeek = memorySeekNeedsNetwork
                memorySeekNeedsNetwork = false
            }
            condition.unlock()
            if state == .seeking {
                if !forceNetworkSeek, !seekByBytes, options.isMemorySeekEnabled,
                   allPlayerItemTracks.allSatisfy({ !$0.isLoopModel })
                {
                    let seekToTime = seekTime
                    let time = mainClock().time
                    let increaseSeconds = seekToTime + startTime.seconds - time.seconds
                    if increaseSeconds > 0, serveSeekFromMemory(target: seekToTime + startTime.seconds) {
                        if state == .closed {
                            break
                        }
                        condition.lock()
                        let committed = !memorySeekNeedsNetwork && seekToTime == seekTime
                        if committed {
                            state = .reading
                        }
                        condition.unlock()
                        if committed {
                            KSLog("seek to \(seekToTime) served from memory")
                            isSeek = true
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.seekingCompletionHandler?(true)
                                self.seekingCompletionHandler = nil
                            }
                            audioClock.time = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                            videoClock.time = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                        }
                        continue
                    } else {
                        KSLog("memory seek miss for \(seekToTime)")
                    }
                }
                let seekToTime = seekTime
                let time = mainClock().time
                let increaseSeconds = seekTime + startTime.seconds - time.seconds
                let increase: Int64
                var seekFlags = options.seekFlags
                let timeStamp: Int64
                if seekByBytes {
                    seekFlags |= AVSEEK_FLAG_BYTE
                    if let bitRate = formatCtx?.pointee.bit_rate {
                        increase = Int64(increaseSeconds * Double(bitRate) / 8)
                    } else {
                        increase = Int64(increaseSeconds * 180_000)
                    }
                    var position = Int64(-1)
                    if position < 0 {
                        position = videoClock.position
                    }
                    if position < 0 {
                        position = audioClock.position
                    }
                    if position < 0 {
                        position = avio_tell(formatCtx?.pointee.pb)
                    }
                    timeStamp = position + increase
                } else {
                    increase = Int64(increaseSeconds * Double(AV_TIME_BASE))
                    timeStamp = Int64(time.seconds * Double(AV_TIME_BASE)) + increase
                }
                let seekMin = increase > 0 ? timeStamp - increase + 2 : Int64.min
                let seekMax = increase < 0 ? timeStamp - increase - 2 : Int64.max
                allPlayerItemTracks.forEach { $0.seek(time: seekToTime) }
                // can not seek to key frame
                let seekStartTime = CACurrentMediaTime()
                var result = avformat_seek_file(formatCtx, -1, seekMin, timeStamp, seekMax, seekFlags)
//                var result = av_seek_frame(formatCtx, -1, timeStamp, seekFlags)
                // When seeking before the beginning of the file, and seeking fails,
                // try again without the backwards flag to make it seek to the
                // beginning.
                if result < 0, seekFlags & AVSEEK_FLAG_BACKWARD == AVSEEK_FLAG_BACKWARD {
                    KSLog("seek to \(seekToTime) failed. seekFlags remove BACKWARD")
                    options.seekFlags &= ~AVSEEK_FLAG_BACKWARD
                    seekFlags &= ~AVSEEK_FLAG_BACKWARD
                    result = avformat_seek_file(formatCtx, -1, seekMin, timeStamp, seekMax, seekFlags)
                }
                KSLog("seek to \(seekToTime) spend Time: \(CACurrentMediaTime() - seekStartTime)")
                if state == .closed {
                    break
                }
                if seekToTime != seekTime {
                    continue
                }
                isSeek = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.seekingCompletionHandler?(result >= 0)
                    self.seekingCompletionHandler = nil
                }
                audioClock.time = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                videoClock.time = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                state = .reading
            } else if state == .reading {
                autoreleasepool {
                    _ = reading()
                }
            }
        }
    }

    private func reading() -> Int32 {
        let packet = Packet()
        guard let corePacket = packet.corePacket else {
            return 0
        }
        let readResult = av_read_frame(formatCtx, corePacket)
        if state == .closed {
            return 0
        }
        if readResult == 0 {
            if let remuxSession, let outputFormatCtx, let formatCtx {
                writeProAVPacket(corePacket: corePacket, outputFormatCtx: outputFormatCtx, formatCtx: formatCtx, session: remuxSession)
            } else {
                muxPacket(packet: corePacket)
            }
            if corePacket.pointee.size <= 0 || remuxSession != nil {
                return 0
            }
            let first = assetTracks.first { $0.trackID == corePacket.pointee.stream_index }
            if let first, first.isEnabled {
                packet.assetTrack = first
                if first.mediaType == .video {
                    if options.readVideoTime == 0 {
                        options.readVideoTime = CACurrentMediaTime()
                    }
                    videoTrack?.putPacket(packet: packet)
                } else if first.mediaType == .audio {
                    if options.readAudioTime == 0 {
                        options.readAudioTime = CACurrentMediaTime()
                    }
                    audioTrack?.putPacket(packet: packet)
                } else {
                    first.subtitle?.putPacket(packet: packet)
                }
            }
        } else {
            if readResult == AVError.eof.code || avio_feof(formatCtx?.pointee.pb) > 0 {
                if options.isLoopPlay, remuxSession == nil, allPlayerItemTracks.allSatisfy({ !$0.isLoopModel }) {
                    allPlayerItemTracks.forEach { $0.isLoopModel = true }
                    _ = av_seek_frame(formatCtx, -1, startTime.value, AVSEEK_FLAG_BACKWARD)
                } else {
                    allPlayerItemTracks.forEach { $0.isEndOfFile = true }
                    state = .finished
                    finishRemux(reachedEnd: true)
                }
            } else {
                //                        if IS_AVERROR_INVALIDDATA(readResult)
                error = .init(errorCode: .readFrame, avErrorCode: readResult)
            }
        }
        return readResult
    }

    private func pause() {
        condition.lock()
        if state == .reading {
            state = .paused
        }
        condition.unlock()
    }

    private func resume() {
        condition.lock()
        if state == .paused {
            state = .reading
            condition.signal()
        }
        condition.unlock()
    }

    private func canServeSeekFromMemory(target: TimeInterval) -> Bool {
        let asyncVideoTrack = videoTrack as? AsyncPlayerItemTrack<VideoVTBFrame>
        let asyncAudioTrack = audioTrack as? AsyncPlayerItemTrack<AudioFrame>
        if videoTrack != nil, asyncVideoTrack == nil {
            return false
        }
        if audioTrack != nil, asyncAudioTrack == nil {
            return false
        }
        if asyncVideoTrack == nil, asyncAudioTrack == nil {
            return false
        }
        if let asyncVideoTrack, !asyncVideoTrack.canServeSeekFromBuffer(target: target) {
            return false
        }
        if let asyncAudioTrack, !asyncAudioTrack.canServeSeekFromBuffer(target: target) {
            return false
        }
        return true
    }

    private func isMemorySeekEligible(time: TimeInterval) -> Bool {
        guard !seekByBytes, options.isMemorySeekEnabled, allPlayerItemTracks.allSatisfy({ !$0.isLoopModel }) else {
            return false
        }
        let target = time + startTime.seconds
        guard target - mainClock().time.seconds > 0 else {
            return false
        }
        return canServeSeekFromMemory(target: target)
    }

    private func serveSeekFromMemory(target: TimeInterval) -> Bool {
        guard canServeSeekFromMemory(target: target) else {
            return false
        }
        (videoTrack as? AsyncPlayerItemTrack<VideoVTBFrame>)?.fastSeek(to: target) { [weak self] in
            self?.handleMemorySeekFailure()
        }
        (audioTrack as? AsyncPlayerItemTrack<AudioFrame>)?.fastSeek(to: target) { [weak self] in
            self?.handleMemorySeekFailure()
        }
        return true
    }

    private func handleMemorySeekFailure() {
        condition.lock()
        defer { condition.unlock() }
        guard [MESourceState.reading, .paused, .seeking].contains(state) else {
            return
        }
        memorySeekNeedsNetwork = true
        state = .seeking
        condition.broadcast()
    }
}

// MARK: MediaPlayback

extension MEPlayerItem: MediaPlayback {
    var seekable: Bool {
        guard let formatCtx else {
            return false
        }
        var seekable = true
        if let ioContext = formatCtx.pointee.pb {
            seekable = ioContext.pointee.seekable > 0
        }
        return seekable
    }

    public func prepareToPlay() {
        state = .opening
        openOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_open"
            Thread.current.stackSize = KSOptions.stackSize
            self.openThread()
        }
        openOperation?.queuePriority = .veryHigh
        openOperation?.qualityOfService = .userInteractive
        if let openOperation {
            operationQueue.addOperation(openOperation)
        }
    }

    public func shutdown() {
        condition.lock()
        guard state != .closed else {
            condition.unlock()
            return
        }
        state = .closed
        condition.broadcast()
        condition.unlock()
        if remuxSession == nil {
            av_packet_free(&outputPacket)
            stopRecord()
        }
        // 故意循环引用。等结束了。才释放
        let closeOperation = BlockOperation {
            Thread.current.name = (self.operationQueue.name ?? "") + "_close"
            self.allPlayerItemTracks.forEach { $0.shutdown() }
            self.assetTracks.compactMap { $0.closedCaptionsTrack?.subtitle }.forEach { $0.shutdown() }
            KSLog("清空formatCtx")
            // 自定义的协议才会av_class为空
            if let formatCtx = self.formatCtx, (formatCtx.pointee.flags & AVFMT_FLAG_CUSTOM_IO) != 0, let opaque = formatCtx.pointee.pb.pointee.opaque {
                let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque).takeRetainedValue()
                value.close()
            }
            // 不要自己来释放pb。不然第二次播放同一个url会出问题
//            self.formatCtx?.pointee.pb = nil
            self.formatCtx?.pointee.interrupt_callback.opaque = nil
            self.formatCtx?.pointee.interrupt_callback.callback = nil
            avformat_close_input(&self.formatCtx)
            self.finishRemux(reachedEnd: false)
            avformat_close_input(&self.outputFormatCtx)
            EmbeddedFontRegistry.shared.unregister(owner: self.fontOwnerID)
            self.duration = 0
            self.closeOperation = nil
            self.operationQueue.cancelAllOperations()
        }
        closeOperation.queuePriority = .veryHigh
        closeOperation.qualityOfService = .userInteractive
        if let readOperation {
            readOperation.cancel()
            closeOperation.addDependency(readOperation)
        } else if let openOperation {
            openOperation.cancel()
            closeOperation.addDependency(openOperation)
        }
        operationQueue.addOperation(closeOperation)
        if options.syncDecodeVideo || options.syncDecodeAudio {
            DispatchQueue.global().async { [weak self] in
                self?.allPlayerItemTracks.forEach { $0.shutdown() }
            }
        }
        self.closeOperation = closeOperation
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        if state == .reading || state == .paused {
            let isEligible = isMemorySeekEligible(time: time)
            condition.lock()
            seekTime = time
            state = .seeking
            seekingCompletionHandler = completion
            condition.broadcast()
            condition.unlock()
            if !isEligible {
                allPlayerItemTracks.forEach { $0.seek(time: time) }
            }
        } else if state == .finished {
            seekTime = time
            state = .seeking
            seekingCompletionHandler = completion
            read()
        } else if state == .seeking {
            seekTime = time
            seekingCompletionHandler = completion
        }
        isAudioStalled = audioTrack == nil
    }
}

extension MEPlayerItem: CodecCapacityDelegate {
    func codecDidChangeCapacity() {
        guard remuxSession == nil else {
            return
        }
        let loadingState = options.playable(capacitys: videoAudioTracks, isFirst: isFirst, isSeek: isSeek)
        delegate?.sourceDidChange(loadingState: loadingState)
        if loadingState.isPlayable {
            isFirst = false
            isSeek = false
            if loadingState.loadedTime > options.maxBufferDuration {
                adaptableVideo(loadingState: loadingState)
                pause()
            } else if loadingState.loadedTime < options.maxBufferDuration / 2 {
                resume()
            }
        } else {
            resume()
            adaptableVideo(loadingState: loadingState)
        }
    }

    func codecDidFinished(track: some CapacityProtocol) {
        if track.mediaType == .audio {
            isAudioStalled = true
        }
        let allSatisfy = videoAudioTracks.allSatisfy { $0.isEndOfFile && $0.frameCount == 0 && $0.packetCount == 0 }
        if allSatisfy {
            delegate?.sourceDidFinished()
            timer.fireDate = Date.distantFuture
            if options.isLoopPlay {
                isAudioStalled = audioTrack == nil
                allPlayerItemTracks.forEach { $0.isLoopModel = false }
                if state == .finished {
                    seek(time: 0) { _ in }
                }
            }
        }
    }

    private func adaptableVideo(loadingState: LoadingState) {
        if options.videoDisable || videoAdaptation == nil || loadingState.isEndOfFile || loadingState.isSeek || state == .seeking {
            return
        }
        guard let track = videoTrack else {
            return
        }
        videoAdaptation?.loadedCount = track.packetCount + track.frameCount
        videoAdaptation?.currentPlaybackTime = currentPlaybackTime
        videoAdaptation?.isPlayable = loadingState.isPlayable
        guard let (oldBitRate, newBitrate) = options.adaptable(state: videoAdaptation), oldBitRate != newBitrate,
              let newFFmpegAssetTrack = assetTracks.first(where: { $0.mediaType == .video && $0.bitRate == newBitrate })
        else {
            return
        }
        assetTracks.first { $0.mediaType == .video && $0.bitRate == oldBitRate }?.isEnabled = false
        newFFmpegAssetTrack.isEnabled = true
        findBestAudio(videoTrack: newFFmpegAssetTrack)
        let bitRateState = VideoAdaptationState.BitRateState(bitRate: newBitrate, time: CACurrentMediaTime())
        videoAdaptation?.bitRateStates.append(bitRateState)
        delegate?.sourceDidChange(oldBitRate: oldBitRate, newBitrate: newBitrate)
    }

    private func findBestAudio(videoTrack: FFmpegAssetTrack) {
        guard videoAdaptation != nil, let first = assetTracks.first(where: { $0.mediaType == .audio && $0.isEnabled }) else {
            return
        }
        let index = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1, videoTrack.trackID, nil, 0)
        if index != first.trackID {
            first.isEnabled = false
            assetTracks.first { $0.mediaType == .audio && $0.trackID == index }?.isEnabled = true
        }
    }
}

extension MEPlayerItem: OutputRenderSourceDelegate {
    func mainClock() -> KSClock {
        isAudioStalled ? videoClock : audioClock
    }

    public func setVideo(time: CMTime, position: Int64) {
//        print("[video] video interval \(CACurrentMediaTime() - videoClock.lastMediaTime) video diff \(time.seconds - videoClock.time.seconds)")
        videoClock.time = time
        videoClock.position = position
        videoDisplayCount += 1
        let diff = videoClock.lastMediaTime - lastVideoDisplayTime
        if diff > 1 {
            dynamicInfo.displayFPS = Double(videoDisplayCount) / diff
            videoDisplayCount = 0
            lastVideoDisplayTime = videoClock.lastMediaTime
        }
    }

    public func setAudio(time: CMTime, position: Int64) {
//        print("[audio] setAudio: \(time.seconds)")
        // 切换到主线程的话，那播放起来会更顺滑
        runOnMainThread {
            self.audioClock.time = time
            self.audioClock.position = position
        }
    }

    public func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        guard let videoTrack else {
            return nil
        }
        var type: ClockProcessType = force ? .next : .remain
        let predicate: ((VideoVTBFrame, Int) -> Bool)? = force ? nil : { [weak self] frame, count -> Bool in
            guard let self else { return true }
            (self.dynamicInfo.audioVideoSyncDiff, type) = self.options.videoClockSync(main: self.mainClock(), nextVideoTime: frame.seconds, fps: Double(frame.fps), frameCount: count)
            return type != .remain
        }
        let frame = videoTrack.getOutputRender(where: predicate)
        switch type {
        case .remain:
            break
        case .next:
            break
        case .dropNextFrame:
            if videoTrack.getOutputRender(where: nil) != nil {
                dynamicInfo.droppedVideoFrameCount += 1
            }
        case .flush:
            let count = videoTrack.outputRenderQueue.count
            videoTrack.outputRenderQueue.flush()
            dynamicInfo.droppedVideoFrameCount += UInt32(count)
        case .seek:
            videoTrack.outputRenderQueue.flush()
            videoTrack.seekTime = mainClock().time.seconds
        case .dropNextPacket:
            if let videoTrack = videoTrack as? AsyncPlayerItemTrack {
                let packet = videoTrack.packetQueue.pop { item, _ -> Bool in
                    !item.isKeyFrame
                }
                if packet != nil {
                    dynamicInfo.droppedVideoPacketCount += 1
                }
            }
        case .dropGOPPacket:
            if let videoTrack = videoTrack as? AsyncPlayerItemTrack {
                var packet: Packet? = nil
                repeat {
                    packet = videoTrack.packetQueue.pop { item, _ -> Bool in
                        !item.isKeyFrame
                    }
                    if packet != nil {
                        dynamicInfo.droppedVideoPacketCount += 1
                    }
                } while packet != nil
            }
        }
        return frame
    }

    public func getAudioOutputRender() -> AudioFrame? {
        if let frame = audioTrack?.getOutputRender(where: nil) {
            SubtitleModel.audioRecognizes.first {
                $0.isEnabled
            }?.append(frame: frame)
            return frame
        } else {
            return nil
        }
    }
}

extension AbstractAVIOContext {
    func getContext() -> UnsafeMutablePointer<AVIOContext> {
        // 需要持有ioContext，不然会被释放掉,等到shutdown在清空
        avio_alloc_context(av_malloc(Int(bufferSize)), bufferSize, writable ? 1 : 0, Unmanaged.passRetained(self).toOpaque()) { opaque, buffer, size -> Int32 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            let ret = value.read(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, buffer, size -> Int32 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            let ret = value.write(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, offset, whence -> Int64 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            if whence == AVSEEK_SIZE {
                return value.fileSize()
            }
            return value.seek(offset: offset, whence: whence)
        }
    }
}
