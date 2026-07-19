import Foundation
import Libavcodec
import Libavformat
import Libswresample

enum ProAVFFmpegConstant {
    static let complianceExperimental = Int32(-2)
}

final class ProAVAudioTranscoder {
    private var decoderContext: UnsafeMutablePointer<AVCodecContext>?
    private var encoderContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: SwrContext?
    private var decodedFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var encodedPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
    private var pendingSamples = Data()
    private var samplesSent = Int64(0)
    private var timestampPrimed = false
    private let sourceTimebase: Timebase
    private let targetFormat: AVSampleFormat
    private let bytesPerSampleFrame: Int
    let sampleRate: Int32
    let timebase: AVRational

    init?(codecpar: UnsafeMutablePointer<AVCodecParameters>, sourceTimebase: Timebase) {
        self.sourceTimebase = sourceTimebase
        let sourceFormat = AVSampleFormat(rawValue: codecpar.pointee.format)
        targetFormat = sourceFormat == AV_SAMPLE_FMT_S16 || sourceFormat == AV_SAMPLE_FMT_S16P ? AV_SAMPLE_FMT_S16 : AV_SAMPLE_FMT_S32
        sampleRate = codecpar.pointee.sample_rate
        let channelCount = Int(codecpar.pointee.ch_layout.nb_channels)
        timebase = AVRational(num: 1, den: max(sampleRate, 1))
        bytesPerSampleFrame = Int(av_get_bytes_per_sample(targetFormat)) * channelCount
        guard sampleRate > 0, channelCount > 0, bytesPerSampleFrame > 0,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let encoder = avcodec_find_encoder(AV_CODEC_ID_FLAC)
        else { return nil }
        var decoderContextOption = avcodec_alloc_context3(decoder)
        guard let decoderRef = decoderContextOption else { return nil }
        guard avcodec_parameters_to_context(decoderRef, codecpar) >= 0,
              avcodec_open2(decoderRef, decoder, nil) >= 0
        else {
            avcodec_free_context(&decoderContextOption)
            return nil
        }
        decoderContext = decoderRef
        var encoderContextOption = avcodec_alloc_context3(encoder)
        guard let encoderRef = encoderContextOption else {
            avcodec_free_context(&decoderContext)
            return nil
        }
        encoderRef.pointee.sample_rate = sampleRate
        encoderRef.pointee.sample_fmt = targetFormat
        encoderRef.pointee.time_base = timebase
        encoderRef.pointee.bits_per_raw_sample = targetFormat == AV_SAMPLE_FMT_S16 ? 16 : 24
        encoderRef.pointee.strict_std_compliance = ProAVFFmpegConstant.complianceExperimental
        encoderRef.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        guard av_channel_layout_copy(&encoderRef.pointee.ch_layout, &codecpar.pointee.ch_layout) >= 0,
              avcodec_open2(encoderRef, encoder, nil) >= 0
        else {
            avcodec_free_context(&decoderContext)
            avcodec_free_context(&encoderContextOption)
            return nil
        }
        encoderContext = encoderRef
    }

    deinit {
        shutdown()
    }

    func fill(codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        guard let encoderContext else { return false }
        return avcodec_parameters_from_context(codecpar, encoderContext) >= 0
    }

    func transcode(packet: UnsafeMutablePointer<AVPacket>, write: (UnsafeMutablePointer<AVPacket>) -> Void) -> Bool {
        guard let decoderContext, let decodedFrame else { return false }
        guard avcodec_send_packet(decoderContext, packet) >= 0 else { return true }
        while avcodec_receive_frame(decoderContext, decodedFrame) >= 0 {
            let buffered = buffer(frame: decodedFrame)
            av_frame_unref(decodedFrame)
            guard buffered else { return false }
        }
        return encodeBufferedSamples(drainPartial: false, write: write)
    }

    func finish(write: (UnsafeMutablePointer<AVPacket>) -> Void) -> Bool {
        if let decoderContext, let decodedFrame {
            _ = avcodec_send_packet(decoderContext, nil)
            while avcodec_receive_frame(decoderContext, decodedFrame) >= 0 {
                let buffered = buffer(frame: decodedFrame)
                av_frame_unref(decodedFrame)
                guard buffered else { return false }
            }
        }
        return encodeBufferedSamples(drainPartial: true, write: write)
    }

    func shutdown() {
        avcodec_free_context(&decoderContext)
        avcodec_free_context(&encoderContext)
        swr_free(&swrContext)
        av_frame_free(&decodedFrame)
        av_packet_free(&encodedPacket)
        pendingSamples.removeAll()
    }

    private func prepareResampler(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        guard let encoderContext else { return false }
        swr_free(&swrContext)
        var inLayout = frame.pointee.ch_layout
        var outLayout = AVChannelLayout()
        guard av_channel_layout_copy(&outLayout, &encoderContext.pointee.ch_layout) >= 0 else { return false }
        let result = swr_alloc_set_opts2(&swrContext, &outLayout, targetFormat, sampleRate, &inLayout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate, 0, nil)
        av_channel_layout_uninit(&outLayout)
        guard result >= 0 else { return false }
        return swr_init(swrContext) >= 0
    }

    private func buffer(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if swrContext == nil {
            guard prepareResampler(frame: frame) else { return false }
        }
        if !timestampPrimed {
            timestampPrimed = true
            let timestamp = frame.pointee.best_effort_timestamp == Int64.min ? frame.pointee.pts : frame.pointee.best_effort_timestamp
            if timestamp != Int64.min {
                let seconds = sourceTimebase.cmtime(for: timestamp).seconds
                if seconds.isFinite, seconds > 0 {
                    samplesSent = Int64((seconds * Double(sampleRate)).rounded())
                }
            }
        }
        let inSamples = frame.pointee.nb_samples
        let outCapacity = swr_get_out_samples(swrContext, inSamples)
        guard outCapacity > 0 else { return true }
        var chunk = Data(count: Int(outCapacity) * bytesPerSampleFrame)
        var inputPlanes = Array(tuple: frame.pointee.data).map { UnsafePointer<UInt8>($0) }
        let converted = chunk.withUnsafeMutableBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            var outputPlanes: [UnsafeMutablePointer<UInt8>?] = [base]
            return swr_convert(swrContext, &outputPlanes, outCapacity, &inputPlanes, inSamples)
        }
        guard converted >= 0 else { return false }
        pendingSamples.append(chunk.prefix(Int(converted) * bytesPerSampleFrame))
        return true
    }

    private func encodeBufferedSamples(drainPartial: Bool, write: (UnsafeMutablePointer<AVPacket>) -> Void) -> Bool {
        guard let encoderContext else { return false }
        let frameSize = Int(encoderContext.pointee.frame_size)
        let frameBytes = frameSize * bytesPerSampleFrame
        guard frameBytes > 0 else { return false }
        while pendingSamples.count >= frameBytes {
            guard send(samples: pendingSamples.prefix(frameBytes), count: frameSize) else { return false }
            pendingSamples.removeFirst(frameBytes)
            guard receivePackets(write: write) else { return false }
        }
        if drainPartial {
            let remainder = pendingSamples.count / bytesPerSampleFrame
            if remainder > 0 {
                guard send(samples: pendingSamples.prefix(remainder * bytesPerSampleFrame), count: remainder) else { return false }
            }
            pendingSamples.removeAll()
            _ = avcodec_send_frame(encoderContext, nil)
            guard receivePackets(write: write) else { return false }
        }
        return true
    }

    private func send(samples: Data, count: Int) -> Bool {
        guard let encoderContext, count > 0 else { return false }
        var frameOption = av_frame_alloc()
        guard let frame = frameOption else { return false }
        defer { av_frame_free(&frameOption) }
        frame.pointee.nb_samples = Int32(count)
        frame.pointee.format = targetFormat.rawValue
        frame.pointee.sample_rate = sampleRate
        guard av_channel_layout_copy(&frame.pointee.ch_layout, &encoderContext.pointee.ch_layout) >= 0,
              av_frame_get_buffer(frame, 0) >= 0
        else { return false }
        let byteCount = count * bytesPerSampleFrame
        let copied = samples.withUnsafeBytes { rawBuffer -> Bool in
            guard let source = rawBuffer.baseAddress, let destination = frame.pointee.data.0, rawBuffer.count >= byteCount else { return false }
            memcpy(destination, source, byteCount)
            return true
        }
        guard copied else { return false }
        frame.pointee.pts = samplesSent
        samplesSent += Int64(count)
        return avcodec_send_frame(encoderContext, frame) >= 0
    }

    private func receivePackets(write: (UnsafeMutablePointer<AVPacket>) -> Void) -> Bool {
        guard let encoderContext, let encodedPacket else { return false }
        while true {
            let result = avcodec_receive_packet(encoderContext, encodedPacket)
            if result == 0 {
                write(encodedPacket)
                av_packet_unref(encodedPacket)
            } else {
                return result == AVError.tryAgain.code || result == AVError.eof.code
            }
        }
    }
}
