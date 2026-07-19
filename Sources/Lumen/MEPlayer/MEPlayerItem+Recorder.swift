//
//  MEPlayerItem+Recorder.swift
//  Lumen
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import Libavcodec
import Libavformat

extension MEPlayerItem {
    func startRecord(url: URL) {
        stopRecord()
        let filename = url.isFileURL ? url.path : url.absoluteString
        var ret = avformat_alloc_output_context2(&outputFormatCtx, nil, nil, filename)
        guard let outputFormatCtx, let formatCtx else {
            KSLog(NSError(errorCode: .formatOutputCreate, avErrorCode: ret))
            return
        }
        var index = 0
        var audioIndex: Int?
        var videoIndex: Int?
        let formatName = outputFormatCtx.pointee.oformat.pointee.name.flatMap { String(cString: $0) }
        for i in 0 ..< Int(formatCtx.pointee.nb_streams) {
            if let inputStream = formatCtx.pointee.streams[i] {
                let codecType = inputStream.pointee.codecpar.pointee.codec_type
                if [AVMEDIA_TYPE_AUDIO, AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_SUBTITLE].contains(codecType) {
                    if codecType == AVMEDIA_TYPE_AUDIO {
                        if let audioIndex {
                            streamMapping[i] = audioIndex
                            continue
                        } else {
                            audioIndex = index
                        }
                    } else if codecType == AVMEDIA_TYPE_VIDEO {
                        if let videoIndex {
                            streamMapping[i] = videoIndex
                            continue
                        } else {
                            videoIndex = index
                        }
                    }
                    if let outStream = avformat_new_stream(outputFormatCtx, nil) {
                        streamMapping[i] = index
                        index += 1
                        avcodec_parameters_copy(outStream.pointee.codecpar, inputStream.pointee.codecpar)
                        if codecType == AVMEDIA_TYPE_SUBTITLE, formatName == "mp4" || formatName == "mov" {
                            outStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_MOV_TEXT
                        }
                        if inputStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
                            outStream.pointee.codecpar.pointee.codec_tag = CMFormatDescription.MediaSubType.hevc.rawValue.bigEndian
                        } else {
                            outStream.pointee.codecpar.pointee.codec_tag = 0
                        }
                    }
                }
            }
        }
        ret = avio_open(&(outputFormatCtx.pointee.pb), filename, AVIO_FLAG_WRITE)
        guard ret >= 0 else {
            KSLog(NSError(errorCode: .formatOutputCreate, avErrorCode: ret))
            avformat_close_input(&self.outputFormatCtx)
            return
        }
        ret = avformat_write_header(outputFormatCtx, nil)
        guard ret >= 0 else {
            KSLog(NSError(errorCode: .formatWriteHeader, avErrorCode: ret))
            avformat_close_input(&self.outputFormatCtx)
            return
        }
        outputPacket = av_packet_alloc()
    }

    func stopRecord() {
        if let outputFormatCtx {
            av_write_trailer(outputFormatCtx)
        }
    }

    func muxPacket(packet corePacket: UnsafeMutablePointer<AVPacket>) {
        guard let outputFormatCtx, let formatCtx else {
            return
        }
        let index = Int(corePacket.pointee.stream_index)
        guard let outputIndex = streamMapping[index],
              let inputTb = formatCtx.pointee.streams[index]?.pointee.time_base,
              let outputTb = outputFormatCtx.pointee.streams[outputIndex]?.pointee.time_base,
              let outputPacket
        else {
            return
        }
        av_packet_ref(outputPacket, corePacket)
        outputPacket.pointee.stream_index = Int32(outputIndex)
        av_packet_rescale_ts(outputPacket, inputTb, outputTb)
        outputPacket.pointee.pos = -1
        let ret = av_interleaved_write_frame(outputFormatCtx, outputPacket)
        if ret < 0 {
            KSLog("can not av_interleaved_write_frame")
        }
    }
}
