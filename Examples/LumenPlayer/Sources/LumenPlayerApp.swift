import Lumen
import SwiftUI

/// Plays the URL in the launch environment through the remux engine, with the FFmpeg engine behind it.
@main
struct LumenPlayerApp: App {
    init() {
        KSOptions.firstPlayerType = ProAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        if ProcessInfo.processInfo.environment["LUMEN_LOG"] == "info" {
            KSOptions.logLevel = .info
        }
    }

    var body: some Scene {
        WindowGroup {
            PlayerScreen()
        }
    }
}

struct PlayerScreen: View {
    private let environment = ProcessInfo.processInfo.environment

    var body: some View {
        if let url = environment["LUMEN_URL"].flatMap(URL.init(string:)) {
            KSVideoPlayerView(url: url, options: makeOptions(), title: environment["LUMEN_TITLE"])
                .ignoresSafeArea()
        } else {
            Color.black
                .ignoresSafeArea()
                .onAppear { print("Launch with LUMEN_URL set to the media to play.") }
        }
    }

    private func makeOptions() -> KSOptions {
        let options = KSOptions()
        options.startPlayTime = environment["LUMEN_START"].flatMap(TimeInterval.init) ?? 0
        return options
    }
}
