@testable import Lumen
import XCTest

class ProAVAudioSwitchTest: XCTestCase {
    @MainActor
    private func action(target: Int32, active: Int32?, preferred: Int32? = nil, pending: Int32? = nil, canHotSwitch: Bool = true) -> ProAVAudioSwitchAction {
        ProAVPlayer.audioSwitchAction(target: target, activeTrackID: active, preferredTrackID: preferred, pendingTrackID: pending, canHotSwitch: canHotSwitch)
    }

    @MainActor
    func testSelectingTheTrackAlreadyPlayingDoesNothing() {
        XCTAssertEqual(action(target: 1, active: 1), .ignore)
        XCTAssertEqual(action(target: 1, active: nil, preferred: 1), .ignore)
    }

    @MainActor
    func testSelectingAnotherTrackPreparesTheSwitchInParallel() {
        XCTAssertEqual(action(target: 2, active: 1), .hotSwitch)
    }

    @MainActor
    func testSelectingTheCurrentTrackAgainCancelsTheCandidate() {
        XCTAssertEqual(action(target: 1, active: 1, pending: 2), .abortPending)
    }

    @MainActor
    func testSelectingTheCandidateAgainDoesNothing() {
        XCTAssertEqual(action(target: 2, active: 1, pending: 2), .ignore)
    }

    @MainActor
    func testAThirdSelectionSupersedesTheCandidate() {
        XCTAssertEqual(action(target: 3, active: 1, pending: 2), .hotSwitch)
    }

    @MainActor
    func testSwitchBeforeTheSessionIsUsableFallsBackToARestart() {
        XCTAssertEqual(action(target: 2, active: 1, canHotSwitch: false), .coldRestart)
        XCTAssertEqual(action(target: 2, active: nil, canHotSwitch: false), .coldRestart)
    }

    @MainActor
    func testPreferredTrackIsUsedWhileTheNewItemIsStillOpening() {
        XCTAssertEqual(action(target: 2, active: nil, preferred: 2), .ignore)
        XCTAssertEqual(action(target: 3, active: nil, preferred: 2), .hotSwitch)
    }
}
