@testable import Lumen
import XCTest

class KSMEPlayerTest: XCTestCase {
    @MainActor
    func testPlaying() {
        if let path = Bundle(for: type(of: self)).path(forResource: "h264", ofType: "mp4") {
            let options = KSOptions()
            let player = KSMEPlayer(url: URL(fileURLWithPath: path), options: options)
            player.delegate = self
            XCTAssertEqual(player.isPlaying, false)
            player.play()
            XCTAssertEqual(player.isPlaying, true)
            player.pause()
            XCTAssertEqual(player.isPlaying, false)
        }
    }

    @MainActor
    func testAutoPlay() {
        if let path = Bundle(for: type(of: self)).path(forResource: "h264", ofType: "mp4") {
            let options = KSOptions()
            let player = KSMEPlayer(url: URL(fileURLWithPath: path), options: options)
            player.delegate = self
            XCTAssertEqual(player.isPlaying, false)
            player.play()
            XCTAssertEqual(player.isPlaying, true)
            player.pause()
            XCTAssertEqual(player.isPlaying, false)
        }
    }
}

extension KSMEPlayerTest: MediaPlayerDelegate {
    func readyToPlay(player _: some MediaPlayerProtocol) {}

    func changeLoadState(player _: some MediaPlayerProtocol) {}

    func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}

    func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

    func finish(player _: some MediaPlayerProtocol, error _: Error?) {}
}
