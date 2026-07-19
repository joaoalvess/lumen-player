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
    func readyToPlay(player _: some Lumen.MediaPlayerProtocol) {}

    func changeLoadState(player _: some Lumen.MediaPlayerProtocol) {}

    func changeBuffering(player _: some Lumen.MediaPlayerProtocol, progress _: Int) {}

    func playBack(player _: some Lumen.MediaPlayerProtocol, loopCount _: Int) {}

    func finish(player _: some Lumen.MediaPlayerProtocol, error _: Error?) {}
}
