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

    init(codecTag: String, codecsAttribute: String, videoRange: String, supplementalCodecs: String?, preferredDynamicRange: DynamicRange) {
        self.codecTag = codecTag
        self.codecsAttribute = codecsAttribute
        self.videoRange = videoRange
        self.supplementalCodecs = supplementalCodecs
        self.preferredDynamicRange = preferredDynamicRange
    }

    init?(track: FFmpegAssetTrack) {
        guard track.codecpar.codec_id == AV_CODEC_ID_HEVC else { return nil }
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
            case (8, 4):
                codecTag = "hvc1"
                codecsAttribute = hevcCodecs
                videoRange = "HLG"
                supplementalCodecs = "\(doviCodecs)/db4h"
                preferredDynamicRange = .dolbyVision
            default:
                return nil
            }
        } else {
            codecTag = "hvc1"
            codecsAttribute = hevcCodecs
            supplementalCodecs = nil
            switch track.codecpar.color_trc {
            case AVCOL_TRC_SMPTE2084:
                videoRange = "PQ"
                preferredDynamicRange = .hdr10
            case AVCOL_TRC_ARIB_STD_B67:
                videoRange = "HLG"
                preferredDynamicRange = .hlg
            default:
                videoRange = "SDR"
                preferredDynamicRange = .sdr
            }
        }
    }

    var codecTagValue: UInt32 {
        codecTag.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

struct ProAVAudioSignaling: Equatable {
    let codecsAttribute: String
    let channels: String
}

enum ProAVAudioStrategy {
    case copy(signaling: ProAVAudioSignaling)
    case transcodeToFLAC(channels: String)

    static func make(codecpar: AVCodecParameters) -> ProAVAudioStrategy {
        let channels = "\(codecpar.ch_layout.nb_channels)"
        switch codecpar.codec_id {
        case AV_CODEC_ID_EAC3:
            let isAtmos = codecpar.profile == AV_PROFILE_EAC3_DDP_ATMOS
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "ec-3", channels: isAtmos ? "16/JOC" : channels))
        case AV_CODEC_ID_AC3:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "ac-3", channels: channels))
        case AV_CODEC_ID_AAC:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "mp4a.40.2", channels: channels))
        case AV_CODEC_ID_FLAC:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "fLaC", channels: channels))
        case AV_CODEC_ID_ALAC:
            return .copy(signaling: ProAVAudioSignaling(codecsAttribute: "alac", channels: channels))
        default:
            return .transcodeToFLAC(channels: channels)
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
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"\(audio.channels)\"")
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
