<div align="center">

# 🌗 Lumen

**A media player framework for Apple platforms — built for the living room.**

![Platform](https://img.shields.io/badge/platform-tvOS%20·%20iOS%20·%20iPadOS%20·%20macOS-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![FFmpeg](https://img.shields.io/badge/FFmpeg-8.1-007808?logo=ffmpeg&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0-4C9AFF)

</div>

---

Lumen plays high-bitrate video on Apple TV without giving anything up.

Most players on tvOS force a choice: use `AVPlayer` and get native Dolby Vision and Atmos but no MKV, or use a software engine and get every format but lose the system's HDR and spatial-audio pipeline. Lumen refuses the trade — it stream-copies MKV into local HLS on the fly and hands it to `AVPlayer`, so the TV lights up in real Dolby Vision while FFmpeg still handles everything else.

It ships with a complete SwiftUI interface designed for the Siri Remote, a network cache built for streaming over HTTP, and subtitle rendering that survives fansub ASS.

## ✨ Features

**Picture & sound**
- 🎞️ Native **Dolby Vision** and **Dolby Atmos** — passed through to the system, not tone-mapped away
- 📼 MKV, HLS, MP4 and anything else FFmpeg 8.1 demuxes
- 🎚️ Hardware decoding with software fallback, 4K/8K, high frame rate
- 🔊 Multichannel and spatial audio, with TrueHD/DTS transcoded losslessly when passthrough isn't available

**Interface**
- 📺 A full tvOS player UI — transport bar, info panels, track popover, content tabs
- 🖼️ **Scrub previews** — live thumbnails while you seek, decoded on a dedicated engine
- 🎯 Focus model built for the remote from the start, not adapted from touch
- 🪟 Picture in Picture, with subtitles

**Streaming**
- 💾 Byte-range **disk cache** backed by `URLSession` — feeds FFmpeg through a custom AVIO context and `AVPlayer` through a resource loader
- ⚡ Fast seeking inside cached ranges, with precaching ahead of playback
- 🌐 Network I/O stays in Swift, so TLS and connection handling use the system stack

**Subtitles**
- 🔤 ASS/SSA, SRT and WebVTT parsed and rendered natively, with positioning and styling
- 📦 Embedded-font extraction — fansub releases render with their own fonts
- 📐 Font scaling derived from the script's `PlayResY` instead of guessed
- 🈯 Text, image (SUP/PGS) and closed captions

## 🎛️ Three engines, one API

You set the order, and Lumen falls back to the next engine when one fails to open a stream:

| Engine | Backed by | Best at |
| --- | --- | --- |
| **`ProAVPlayer`** | Remux → `AVPlayer` | MKV with native Dolby Vision and Atmos |
| **`KSAVPlayer`** | `AVFoundation` | HLS and MP4, lowest overhead |
| **`KSMEPlayer`** | FFmpeg | Everything else — the universal fallback |

```swift
KSOptions.firstPlayerType = ProAVPlayer.self
KSOptions.secondPlayerType = KSMEPlayer.self
```

## 📦 Requirements

- tvOS 13+ · iOS/iPadOS 13+ · macOS 10.15+ · Mac Catalyst 14+
- Swift 5.9+ / Xcode 15+

## 🚀 Installation

Add Lumen as a local Swift package:

```swift
dependencies: [
    .package(path: "Player")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Lumen", package: "Lumen")
    ])
]
```

In Xcode: **File → Add Package Dependencies → Add Local**, then point at the checkout.

## 🎬 Usage

```swift
import SwiftUI
import Lumen

@main
struct MyApp: App {
    init() {
        KSOptions.firstPlayerType = ProAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
    }

    var body: some Scene { WindowGroup { PlayerScreen() } }
}

struct PlayerScreen: View {
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()

    var body: some View {
        KSVideoPlayerView(
            coordinator: coordinator,
            url: URL(string: "https://example.com/movie.mkv")!,
            options: makeOptions(),
            title: "Blade Runner 2049",
            onClose: { /* dismiss */ }
        )
        .ignoresSafeArea()
    }

    private func makeOptions() -> KSOptions {
        let options = KSOptions()
        options.startPlayTime = 0   // resume position, in seconds
        return options
    }
}
```

On tvOS, feed the info panel with the metadata you already have:

```swift
KSVideoPlayerView(coordinator: coordinator, url: url, options: options)
    .tvPlayerMetadata(
        TVPlayerMetadata(
            subtitle: "S02E04 · The Bicameral Mind",
            synopsis: "…",
            year: 2016,
            genres: ["Sci-Fi", "Drama"],
            runtimeMinutes: 90
        )
    )
```

## 🏗️ Module map

| Path | Responsibility |
| --- | --- |
| `Sources/Lumen/MEPlayer/` | Demux, decode, A/V sync — the FFmpeg engine, `ProAVPlayer` and the remux session |
| `Sources/Lumen/AVPlayer/` | `KSPlayerLayer`, options, player protocols, PiP |
| `Sources/Lumen/Cache/` | Byte cache, `URLSession` reader, AVIO bridge |
| `Sources/Lumen/SwiftUI/TVOS/` | The tvOS interface — transport bar, panels, scrubber, glass styles |
| `Sources/Lumen/Subtitle/` | Parsing, rendering, embedded fonts |
| `Sources/Lumen/Metal/` | Shaders and pixel-buffer rendering |

## 🗺️ Roadmap

What's planned next — native Dolby Vision dynamic metadata, instant stream switching, full ASS effects — lives in [`ROADMAP.md`](./ROADMAP.md).

## 🙏 Credits

Lumen grew out of [**KSPlayer**](https://github.com/kingslay/KSPlayer) by [kingslay](https://github.com/kingslay), and owes it the foundation it stands on. It also builds on [FFmpeg](https://ffmpeg.org) and the build scripts from [MPVKit](https://github.com/mpvkit/MPVKit).

## ⚖️ License

GPL-3.0 — see [`LICENSE`](./LICENSE).
