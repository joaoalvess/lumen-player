import CoreGraphics
import Foundation
import Libavcodec
import Libavformat

struct ProAVVideoSignaling {
    let codecTag: String
    let codecsAttribute: String
    let videoRange: String
    let supplementalCodecs: String?
    let preferredDynamicRange: DynamicRange
    let convertsDolbyVisionProfile7: Bool

    init(codecTag: String, codecsAttribute: String, videoRange: String, supplementalCodecs: String?, preferredDynamicRange: DynamicRange, convertsDolbyVisionProfile7: Bool = false) {
        self.codecTag = codecTag
        self.codecsAttribute = codecsAttribute
        self.videoRange = videoRange
        self.supplementalCodecs = supplementalCodecs
        self.preferredDynamicRange = preferredDynamicRange
        self.convertsDolbyVisionProfile7 = convertsDolbyVisionProfile7
    }

    init?(track: FFmpegAssetTrack, convertDolbyVisionProfile7: Bool) {
        switch track.codecpar.codec_id {
        case AV_CODEC_ID_HEVC:
            let level = track.codecpar.level > 0 ? Int(track.codecpar.level) : 153
            let hevcProfileSignal = track.codecpar.profile == 1 ? "1.6" : "2.4"
            let hevcCodecs = "hvc1.\(hevcProfileSignal).L\(level).B0"
            if let dovi = track.dovi {
                let doviCodecs = String(format: "dvh1.%02d.%02d", Int(dovi.dv_profile), Int(dovi.dv_level))
                switch (dovi.dv_profile, dovi.dv_bl_signal_compatibility_id) {
                case (5, _), (8, 1):
                    codecTag = "dvh1"
                    codecsAttribute = doviCodecs
                    videoRange = "PQ"
                    supplementalCodecs = nil
                    preferredDynamicRange = .dolbyVision
                    convertsDolbyVisionProfile7 = false
                case (8, 2):
                    codecTag = "hvc1"
                    codecsAttribute = hevcCodecs
                    videoRange = "SDR"
                    supplementalCodecs = "\(doviCodecs)/db2g"
                    preferredDynamicRange = .dolbyVision
                    convertsDolbyVisionProfile7 = false
                case (8, 4):
                    codecTag = "hvc1"
                    codecsAttribute = hevcCodecs
                    videoRange = "HLG"
                    supplementalCodecs = "\(doviCodecs)/db4h"
                    preferredDynamicRange = .dolbyVision
                    convertsDolbyVisionProfile7 = false
                case (7, _) where convertDolbyVisionProfile7:
                    codecTag = "dvh1"
                    codecsAttribute = String(format: "dvh1.08.%02d", Int(dovi.dv_level))
                    videoRange = "PQ"
                    supplementalCodecs = nil
                    preferredDynamicRange = .dolbyVision
                    convertsDolbyVisionProfile7 = true
                default:
                    return nil
                }
            } else {
                codecTag = "hvc1"
                codecsAttribute = hevcCodecs
                supplementalCodecs = nil
                convertsDolbyVisionProfile7 = false
                let range = Self.rangeSignaling(colorTrc: track.codecpar.color_trc)
                videoRange = range.videoRange
                preferredDynamicRange = range.dynamicRange
            }
        case AV_CODEC_ID_H264:
            guard let h264Codecs = Self.h264CodecsAttribute(avcC: track.codecpar.extradata, size: track.codecpar.extradata_size),
                  Self.isRemuxableH264PixelFormat(track.codecpar.format)
            else {
                return nil
            }
            codecTag = "avc1"
            codecsAttribute = h264Codecs
            supplementalCodecs = nil
            convertsDolbyVisionProfile7 = false
            let range = Self.rangeSignaling(colorTrc: track.codecpar.color_trc)
            videoRange = range.videoRange
            preferredDynamicRange = range.dynamicRange
        default:
            return nil
        }
    }

    var codecTagValue: UInt32 {
        codecTag.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func h264CodecsAttribute(avcC: UnsafePointer<UInt8>?, size: Int32) -> String? {
        guard let avcC, size >= 4, avcC[0] == 1 else {
            return nil
        }
        let profileIndication = avcC[1]
        let levelIndication = avcC[3]
        guard profileIndication > 0, levelIndication > 0, isRemuxableH264Profile(profileIndication) else {
            return nil
        }
        return String(format: "avc1.%02x%02x%02x", Int(profileIndication), Int(avcC[2]), Int(levelIndication))
    }

    private static func isRemuxableH264Profile(_ profileIndication: UInt8) -> Bool {
        switch Int32(profileIndication) {
        case AV_PROFILE_H264_HIGH_10, AV_PROFILE_H264_HIGH_422, AV_PROFILE_H264_HIGH_444_PREDICTIVE, AV_PROFILE_H264_CAVLC_444:
            return false
        default:
            return true
        }
    }

    private static func isRemuxableH264PixelFormat(_ format: Int32) -> Bool {
        guard format >= 0 else {
            return true
        }
        return [AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_NV12, AV_PIX_FMT_NV21].contains(AVPixelFormat(rawValue: format))
    }

    private static func rangeSignaling(colorTrc: AVColorTransferCharacteristic) -> (videoRange: String, dynamicRange: DynamicRange) {
        switch colorTrc {
        case AVCOL_TRC_SMPTE2084:
            return (videoRange: "PQ", dynamicRange: .hdr10)
        case AVCOL_TRC_ARIB_STD_B67:
            return (videoRange: "HLG", dynamicRange: .hlg)
        default:
            return (videoRange: "SDR", dynamicRange: .sdr)
        }
    }
}

struct ProAVAudioSignaling: Equatable {
    let codecsAttribute: String
    let channels: String?
}

enum ProAVAudioStrategy {
    case copy(signaling: ProAVAudioSignaling)
    case transcodeToFLAC(channels: String?)

    static func make(codecpar: AVCodecParameters) -> ProAVAudioStrategy {
        let channels: String? = codecpar.ch_layout.nb_channels > 0 ? "\(codecpar.ch_layout.nb_channels)" : nil
        switch codecpar.codec_id {
        case AV_CODEC_ID_EAC3:
            let isAtmos = codecpar.profile == AV_PROFILE_EAC3_DDP_ATMOS
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "ec-3", channels: isAtmos ? "16/JOC" : channels))
        case AV_CODEC_ID_AC3:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "ac-3", channels: channels))
        case AV_CODEC_ID_AAC:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: aacCodecsAttribute(profile: codecpar.profile), channels: channels))
        case AV_CODEC_ID_FLAC:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "fLaC", channels: channels))
        case AV_CODEC_ID_ALAC:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "alac", channels: channels))
        default:
            return .transcodeToFLAC(channels: channels)
        }
    }

    static func aacCodecsAttribute(profile: Int32) -> String {
        switch profile {
        case AV_PROFILE_AAC_HE:
            return "mp4a.40.5"
        case AV_PROFILE_AAC_HE_V2:
            return "mp4a.40.29"
        default:
            return "mp4a.40.2"
        }
    }

    var signaling: ProAVAudioSignaling {
        switch self {
        case let .copy(signaling):
            return signaling
        case let .transcodeToFLAC(channels):
            return ProAVAudioSignaling(codecsAttribute: "fLaC", channels: channels)
        }
    }

    var copiesBitstream: Bool {
        switch self {
        case .copy:
            return true
        case .transcodeToFLAC:
            return false
        }
    }
}

struct ProAVSegment {
    let fileName: String
    let duration: Double
}

enum ProAVPlaylist {
    static func master(mediaPlaylistName: String, video: ProAVVideoSignaling, audio: ProAVAudioSignaling?, bandwidth: Int64, resolution: CGSize, frameRate: Float) -> String {
        var codecs = video.codecsAttribute
        if let audio {
            codecs += ",\(audio.codecsAttribute)"
        }
        var attributes = ["BANDWIDTH=\(max(bandwidth, 1_000_000))"]
        attributes.append("CODECS=\"\(codecs)\"")
        if resolution.width > 0, resolution.height > 0 {
            attributes.append("RESOLUTION=\(Int(resolution.width))x\(Int(resolution.height))")
        }
        if frameRate > 0 {
            attributes.append(String(format: "FRAME-RATE=%.3f", frameRate))
        }
        attributes.append("VIDEO-RANGE=\(video.videoRange)")
        if let supplementalCodecs = video.supplementalCodecs {
            attributes.append("SUPPLEMENTAL-CODECS=\"\(supplementalCodecs)\"")
        }
        if audio != nil {
            attributes.append("AUDIO=\"main\"")
        }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if let audio {
            var mediaAttributes = ["TYPE=AUDIO", "GROUP-ID=\"main\"", "NAME=\"Original\"", "DEFAULT=YES", "AUTOSELECT=YES"]
            if let channels = audio.channels {
                mediaAttributes.append("CHANNELS=\"\(channels)\"")
            }
            lines.append("#EXT-X-MEDIA:" + mediaAttributes.joined(separator: ","))
        }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append(mediaPlaylistName)
        return lines.joined(separator: "\n") + "\n"
    }

    static func media(targetDuration: TimeInterval, initSegmentName: String, segments: [ProAVSegment], ended: Bool) -> String {
        let maxSegmentDuration = segments.map(\.duration).max() ?? targetDuration
        let target = Int(ceil(max(maxSegmentDuration, targetDuration)))
        var lines = ["#EXTM3U",
                     "#EXT-X-VERSION:7",
                     "#EXT-X-TARGETDURATION:\(target)",
                     "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:EVENT",
                     "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"\(initSegmentName)\""]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append(segment.fileName)
        }
        if ended {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
