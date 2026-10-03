//
//  ScrubThumbnailEngine.swift
//  Lumen
//
import AVFoundation
import Foundation
import Libavcodec
import Libavformat
#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)
public struct ScrubThumbnail: Sendable {
    public let image: UIImage
    public let time: TimeInterval
}

final class ScrubThumbnailEngine: @unchecked Sendable {
    private static let maximumVideoPacketsPerThumbnail = 200
    private let queue = DispatchQueue(label: "lumen.scrub.thumbnail", qos: .userInitiated)
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var reScale: VideoSwresample?
    private var videoStreamIndex = Int32(-1)
    private var timeBase = Timebase.defaultValue
    private var streamTimeBase = AVRational(num: 1, den: 1)
    private var startTime = Int64(0)

    deinit {
        closeSync()
    }

    func open(urlString: String, formatOptions: [String: Any], width: Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.openSync(urlString: urlString, formatOptions: formatOptions, width: width))
            }
        }
    }

    func thumbnail(near seconds: TimeInterval) async -> ScrubThumbnail? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.thumbnailSync(near: seconds))
            }
        }
    }

    func close() {
        queue.async {
            self.closeSync()
        }
    }

    private func openSync(urlString: String, formatOptions: [String: Any], width: Int32) -> Bool {
        closeSync()
        var avOptions = formatOptions.avOptions
        av_dict_set(&avOptions, "rw_timeout", "8000000", 0)
        var formatCtx: UnsafeMutablePointer<AVFormatContext>?
        var result = avformat_open_input(&formatCtx, urlString, nil, &avOptions)
        av_dict_free(&avOptions)
        guard result == 0, let formatCtx else {
            return false
        }
        result = avformat_find_stream_info(formatCtx, nil)
        guard result == 0 else {
            var formatCtxOption: UnsafeMutablePointer<AVFormatContext>? = formatCtx
            avformat_close_input(&formatCtxOption)
            return false
        }
        var streamIndex = Int32(-1)
        for i in 0 ..< Int32(formatCtx.pointee.nb_streams) {
            if formatCtx.pointee.streams[Int(i)]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                streamIndex = i
                break
            }
        }
        guard streamIndex >= 0, let videoStream = formatCtx.pointee.streams[Int(streamIndex)] else {
            var formatCtxOption: UnsafeMutablePointer<AVFormatContext>? = formatCtx
            avformat_close_input(&formatCtxOption)
            return false
        }
        let codecCtx: UnsafeMutablePointer<AVCodecContext>
        do {
            codecCtx = try videoStream.pointee.codecpar.pointee.createContext(options: nil)
        } catch {
            var formatCtxOption: UnsafeMutablePointer<AVFormatContext>? = formatCtx
            avformat_close_input(&formatCtxOption)
            return false
        }
        let sourceWidth = codecCtx.pointee.width
        let sourceHeight = codecCtx.pointee.height
        guard sourceWidth > 0, sourceHeight > 0 else {
            var codecCtxOption: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&codecCtxOption)
            var formatCtxOption: UnsafeMutablePointer<AVFormatContext>? = formatCtx
            avformat_close_input(&formatCtxOption)
            return false
        }
        guard let frame = av_frame_alloc() else {
            var codecCtxOption: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&codecCtxOption)
            var formatCtxOption: UnsafeMutablePointer<AVFormatContext>? = formatCtx
            avformat_close_input(&formatCtxOption)
            return false
        }
        let thumbHeight = width * sourceHeight / sourceWidth
        reScale = VideoSwresample(dstWidth: width, dstHeight: thumbHeight, isDovi: false)
        self.formatCtx = formatCtx
        self.codecCtx = codecCtx
        self.frame = frame
        videoStreamIndex = streamIndex
        streamTimeBase = videoStream.pointee.time_base
        timeBase = Timebase(videoStream.pointee.time_base)
        startTime = videoStream.pointee.start_time
        if startTime == Int64.min {
            startTime = 0
        }
        return true
    }

    private func thumbnailSync(near seconds: TimeInterval) -> ScrubThumbnail? {
        guard let formatCtx, let codecCtx, let frame, let reScale else {
            return nil
        }
        let target = av_rescale_q(Int64(seconds * Double(AV_TIME_BASE)),
                                  AVRational(num: 1, den: AV_TIME_BASE), streamTimeBase) + startTime
        avcodec_flush_buffers(codecCtx)
        guard av_seek_frame(formatCtx, videoStreamIndex, target, AVSEEK_FLAG_BACKWARD) >= 0 else {
            return nil
        }
        avcodec_flush_buffers(codecCtx)
        var packet = AVPacket()
        var thumbnail: ScrubThumbnail?
        var videoPacketCount = 0
        while videoPacketCount < Self.maximumVideoPacketsPerThumbnail, av_read_frame(formatCtx, &packet) >= 0 {
            defer {
                av_packet_unref(&packet)
            }
            guard packet.stream_index == videoStreamIndex else {
                continue
            }
            videoPacketCount += 1
            guard avcodec_send_packet(codecCtx, &packet) >= 0 else {
                break
            }
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret < 0 {
                if ret == -EAGAIN {
                    continue
                } else {
                    break
                }
            }
            var timestamp = frame.pointee.best_effort_timestamp
            if timestamp < 0 {
                timestamp = frame.pointee.pts
            }
            if timestamp < 0 {
                timestamp = frame.pointee.pkt_dts
            }
            if timestamp < 0 {
                timestamp = max(target, 0)
            }
            if let cgImage = reScale.transfer(frame: frame.pointee)?.cgImage() {
                thumbnail = ScrubThumbnail(image: UIImage(cgImage: cgImage),
                                           time: timeBase.cmtime(for: timestamp).seconds)
            }
            break
        }
        return thumbnail
    }

    private func closeSync() {
        if frame != nil {
            av_frame_free(&frame)
        }
        frame = nil
        if codecCtx != nil {
            avcodec_free_context(&codecCtx)
        }
        codecCtx = nil
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
        }
        formatCtx = nil
        reScale?.shutdown()
        reScale = nil
        videoStreamIndex = -1
    }
}
#endif
