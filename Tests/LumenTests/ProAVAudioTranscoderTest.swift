import FFmpegKit
import Libavcodec
@testable import Lumen
import XCTest

class ProAVAudioTranscoderTest: XCTestCase {
    func testTargetSampleRateKeepsRatesTheReceiverCanCarry() {
        XCTAssertEqual(ProAVAudioTranscoder.targetSampleRate(forSource: 32000), 32000)
        XCTAssertEqual(ProAVAudioTranscoder.targetSampleRate(forSource: 44100), 44100)
        XCTAssertEqual(ProAVAudioTranscoder.targetSampleRate(forSource: 48000), 48000)
    }

    func testTargetSampleRateCapsHighResolutionSources() {
        XCTAssertEqual(ProAVAudioTranscoder.targetSampleRate(forSource: 88200), 48000)
        XCTAssertEqual(ProAVAudioTranscoder.targetSampleRate(forSource: 96000), 48000)
        XCTAssertEqual(ProAVAudioTranscoder.targetSampleRate(forSource: 192_000), 48000)
    }

    private func withPCMCodecpar(sampleRate: Int32, channels: Int32, perform: (UnsafeMutablePointer<AVCodecParameters>) -> Void) {
        var parameters: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        guard let codecpar = parameters else {
            XCTFail("could not allocate the codec parameters")
            return
        }
        defer { avcodec_parameters_free(&parameters) }
        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = AV_CODEC_ID_PCM_S24LE
        codecpar.pointee.format = AV_SAMPLE_FMT_S32.rawValue
        codecpar.pointee.sample_rate = sampleRate
        codecpar.pointee.bits_per_coded_sample = 24
        av_channel_layout_default(&codecpar.pointee.ch_layout, channels)
        perform(codecpar)
    }

    func testHighResolutionSourceTranscodesAtFortyEightKilohertz() {
        withPCMCodecpar(sampleRate: 96000, channels: 2) { codecpar in
            guard let transcoder = ProAVAudioTranscoder(codecpar: codecpar, sourceTimebase: Timebase(num: 1, den: 96000)) else {
                XCTFail("transcoder refused the 96 khz source")
                return
            }
            defer { transcoder.shutdown() }
            XCTAssertEqual(transcoder.sampleRate, 48000)
            XCTAssertEqual(transcoder.timebase.num, 1)
            XCTAssertEqual(transcoder.timebase.den, 48000)
        }
    }

    func testSourceBelowTheCapKeepsItsSampleRate() {
        withPCMCodecpar(sampleRate: 44100, channels: 2) { codecpar in
            guard let transcoder = ProAVAudioTranscoder(codecpar: codecpar, sourceTimebase: Timebase(num: 1, den: 44100)) else {
                XCTFail("transcoder refused the 44.1 khz source")
                return
            }
            defer { transcoder.shutdown() }
            XCTAssertEqual(transcoder.sampleRate, 44100)
            XCTAssertEqual(transcoder.timebase.den, 44100)
        }
    }

    func testCappedTranscodeKeepsTheSourceChannelCount() {
        withPCMCodecpar(sampleRate: 96000, channels: 6) { codecpar in
            guard let transcoder = ProAVAudioTranscoder(codecpar: codecpar, sourceTimebase: Timebase(num: 1, den: 96000)) else {
                XCTFail("transcoder refused the multichannel source")
                return
            }
            defer { transcoder.shutdown() }
            var parameters: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
            guard let output = parameters else {
                XCTFail("could not allocate the output codec parameters")
                return
            }
            defer { avcodec_parameters_free(&parameters) }
            XCTAssertTrue(transcoder.fill(codecpar: output))
            XCTAssertEqual(output.pointee.codec_id, AV_CODEC_ID_FLAC)
            XCTAssertEqual(output.pointee.sample_rate, 48000)
            XCTAssertEqual(output.pointee.ch_layout.nb_channels, 6)
        }
    }
}
