import CoreGraphics
@testable import Lumen
import XCTest

class ProAVRemuxSessionTest: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    private func makeSession() -> ProAVRemuxSession? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LumenProAVRemuxSessionTest-\(UUID().uuidString)")
        directory = root
        let configuration = ProAVRemuxSession.Configuration(directory: root, targetSegmentDuration: 2, minimumSegmentsBeforeReady: 2)
        let session = ProAVRemuxSession(configuration: configuration)
        let signaling = ProAVVideoSignaling(codecTag: "hvc1", codecsAttribute: "hvc1.2.4.L120.B0", videoRange: "SDR", supplementalCodecs: nil, preferredDynamicRange: .sdr)
        guard session.begin(signaling: signaling, audioSignaling: nil, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976) else {
            return nil
        }
        return session
    }

    func testClosedSegmentsDurationIsZeroBeforeTheFirstCut() throws {
        let session = try XCTUnwrap(makeSession())
        XCTAssertEqual(session.closedSegmentsDuration, 0)
        _ = session.shouldCutSegment(at: 0)
        session.trackVideoTime(seconds: 1.5)
        XCTAssertEqual(session.closedSegmentsDuration, 0)
        session.finish(reachedEnd: false)
    }

    func testClosedSegmentsDurationSumsTheClosedSegments() throws {
        let session = try XCTUnwrap(makeSession())
        _ = session.shouldCutSegment(at: 0)
        session.closeSegment(nextStartTime: 2)
        XCTAssertEqual(session.closedSegmentsDuration, 2, accuracy: 0.0001)
        session.closeSegment(nextStartTime: 4.5)
        XCTAssertEqual(session.closedSegmentsDuration, 4.5, accuracy: 0.0001)
        session.finish(reachedEnd: false)
    }

    func testOpenSegmentDoesNotCountTowardsTheWindow() throws {
        let session = try XCTUnwrap(makeSession())
        _ = session.shouldCutSegment(at: 0)
        session.closeSegment(nextStartTime: 2)
        session.trackVideoTime(seconds: 3.9)
        XCTAssertEqual(session.closedSegmentsDuration, 2, accuracy: 0.0001)
        session.finish(reachedEnd: false)
    }
}
