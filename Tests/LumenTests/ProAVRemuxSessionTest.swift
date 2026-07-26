import CoreGraphics
import Libavformat
@testable import Lumen
import XCTest

class ProAVRemuxSessionTest: XCTestCase {
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumen-remux-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func box(_ type: String, payload: [UInt8]) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Array($0) })
        data.append(contentsOf: Array(type.utf8))
        data.append(contentsOf: payload)
        return data
    }

    private var initSegment: Data {
        let brands = Array("iso5".utf8) + [UInt8](repeating: 0, count: 4) + Array("iso5".utf8) + Array("iso6".utf8) + Array("mp41".utf8)
        return box("ftyp", payload: brands) + box("moov", payload: [UInt8](repeating: 0xAB, count: 96))
    }

    private var fragment: Data {
        box("moof", payload: [UInt8](repeating: 0xCD, count: 48)) + box("mdat", payload: [UInt8](repeating: 0xEF, count: 128))
    }

    private func hevcPQSignaling() -> ProAVVideoSignaling {
        ProAVVideoSignaling(codecTag: "hvc1", codecsAttribute: "hvc1.2.4.L153.B0", videoRange: "PQ", supplementalCodecs: nil, preferredDynamicRange: .hdr10)
    }

    private func dolbyVision84Signaling() -> ProAVVideoSignaling {
        ProAVVideoSignaling(codecTag: "hvc1", codecsAttribute: "hvc1.2.4.L153.B0", videoRange: "HLG", supplementalCodecs: "dvh1.08.06/db4h", preferredDynamicRange: .dolbyVision)
    }

    private func makeSession(signaling: ProAVVideoSignaling, dynamicHDR10Plus: Bool) -> ProAVRemuxSession? {
        let session = ProAVRemuxSession(configuration: ProAVRemuxSession.Configuration(directory: directory))
        guard session.begin(signaling: signaling, audioSignaling: ProAVAudioSignaling(codecsAttribute: "ec-3", channels: "16/JOC"), bandwidth: 24_000_000, resolution: CGSize(width: 3840, height: 2160), frameRate: 23.976) else {
            XCTFail("the session refused to begin")
            return nil
        }
        if dynamicHDR10Plus {
            session.noteDynamicHDR10Plus()
        }
        guard let context = session.makeIOContext() else {
            XCTFail("the session produced no io context")
            return nil
        }
        let payload = initSegment + fragment
        payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            avio_write(context, base, Int32(rawBuffer.count))
        }
        avio_flush(context)
        session.releaseIOContext()
        XCTAssertFalse(session.isFailed)
        return session
    }

    private func makeWindowSession() -> ProAVRemuxSession? {
        let configuration = ProAVRemuxSession.Configuration(directory: directory, targetSegmentDuration: 2, minimumSegmentsBeforeReady: 2)
        let session = ProAVRemuxSession(configuration: configuration)
        let signaling = ProAVVideoSignaling(codecTag: "hvc1", codecsAttribute: "hvc1.2.4.L120.B0", videoRange: "SDR", supplementalCodecs: nil, preferredDynamicRange: .sdr)
        guard session.begin(signaling: signaling, audioSignaling: nil, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976) else {
            return nil
        }
        return session
    }

    private func writtenMaster() -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("master.m3u8")) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func writtenInitSegment() -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent("init.mp4"))
    }

    func testDynamicHDR10PlusIsSignalledInTheMasterPlaylist() {
        guard makeSession(signaling: hevcPQSignaling(), dynamicHDR10Plus: true) != nil, let master = writtenMaster() else {
            XCTFail("the master playlist was not written")
            return
        }
        XCTAssertTrue(master.contains("SUPPLEMENTAL-CODECS=\"hvc1.2.4.L153.B0/cdm4\""))
        XCTAssertTrue(master.contains("VIDEO-RANGE=PQ"))
        XCTAssertTrue(master.contains("CODECS=\"hvc1.2.4.L153.B0,ec-3\""))
    }

    func testDynamicHDR10PlusAddsTheCompatibleBrandToTheInitSegment() {
        guard makeSession(signaling: hevcPQSignaling(), dynamicHDR10Plus: true) != nil, let written = writtenInitSegment() else {
            XCTFail("the init segment was not written")
            return
        }
        guard let branded = ProAVHDR10PlusScanner.appendingCompatibleBrand("cdm4", toInitSegment: initSegment) else {
            XCTFail("the fixture file type box was refused")
            return
        }
        XCTAssertEqual(written, branded)
        XCTAssertEqual(written.count, initSegment.count + 4)
        XCTAssertEqual(written.subdata(in: 28 ..< 32), Data("cdm4".utf8))
    }

    func testPlainHDR10KeepsTheCurrentPlaylistAndInitSegment() {
        guard makeSession(signaling: hevcPQSignaling(), dynamicHDR10Plus: false) != nil,
              let master = writtenMaster(), let written = writtenInitSegment()
        else {
            XCTFail("the session wrote nothing")
            return
        }
        XCTAssertFalse(master.contains("SUPPLEMENTAL-CODECS"))
        XCTAssertTrue(master.contains("VIDEO-RANGE=PQ"))
        XCTAssertEqual(written, initSegment)
    }

    func testDolbyVisionWinsOverDynamicHDR10Plus() {
        guard makeSession(signaling: dolbyVision84Signaling(), dynamicHDR10Plus: true) != nil,
              let master = writtenMaster(), let written = writtenInitSegment()
        else {
            XCTFail("the session wrote nothing")
            return
        }
        XCTAssertTrue(master.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db4h\""))
        XCTAssertFalse(master.contains("cdm4"))
        XCTAssertEqual(written, initSegment)
    }

    func testDetectionAfterTheInitSegmentIsIgnored() {
        guard let session = makeSession(signaling: hevcPQSignaling(), dynamicHDR10Plus: false) else { return }
        session.noteDynamicHDR10Plus()
        guard let master = writtenMaster() else {
            XCTFail("the master playlist was not written")
            return
        }
        XCTAssertFalse(master.contains("cdm4"))
    }

    func testClosedSegmentsDurationIsZeroBeforeTheFirstCut() throws {
        let session = try XCTUnwrap(makeWindowSession())
        XCTAssertEqual(session.closedSegmentsDuration, 0)
        _ = session.shouldCutSegment(at: 0)
        session.trackVideoTime(seconds: 1.5)
        XCTAssertEqual(session.closedSegmentsDuration, 0)
        session.finish(reachedEnd: false)
    }

    func testClosedSegmentsDurationSumsTheClosedSegments() throws {
        let session = try XCTUnwrap(makeWindowSession())
        _ = session.shouldCutSegment(at: 0)
        session.closeSegment(nextStartTime: 2)
        XCTAssertEqual(session.closedSegmentsDuration, 2, accuracy: 0.0001)
        session.closeSegment(nextStartTime: 4.5)
        XCTAssertEqual(session.closedSegmentsDuration, 4.5, accuracy: 0.0001)
        session.finish(reachedEnd: false)
    }

    func testPlaylistStartIsUnknownBeforeTheFirstVideoKeyframe() throws {
        let session = try XCTUnwrap(makeWindowSession())
        XCTAssertNil(session.playlistStartSeconds)
        session.finish(reachedEnd: false)
    }

    func testPlaylistStartIsTheKeyframeTheRemuxLandedOn() throws {
        let session = try XCTUnwrap(makeWindowSession())
        _ = session.shouldCutSegment(at: 1792)
        let start = try XCTUnwrap(session.playlistStartSeconds)
        XCTAssertEqual(start, 1792, accuracy: 0.0001)
        session.finish(reachedEnd: false)
    }

    func testPlaylistStartDoesNotFollowTheOpenSegment() throws {
        let session = try XCTUnwrap(makeWindowSession())
        _ = session.shouldCutSegment(at: 1792)
        session.closeSegment(nextStartTime: 1794)
        session.closeSegment(nextStartTime: 1796)
        let start = try XCTUnwrap(session.playlistStartSeconds)
        XCTAssertEqual(start, 1792, accuracy: 0.0001)
        session.finish(reachedEnd: false)
    }

    func testOpenSegmentDoesNotCountTowardsTheWindow() throws {
        let session = try XCTUnwrap(makeWindowSession())
        _ = session.shouldCutSegment(at: 0)
        session.closeSegment(nextStartTime: 2)
        session.trackVideoTime(seconds: 3.9)
        XCTAssertEqual(session.closedSegmentsDuration, 2, accuracy: 0.0001)
        session.finish(reachedEnd: false)
    }
}
