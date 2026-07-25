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
- 🎞️ Native **Dolby Vision** on the `ProAVPlayer` path — the remux signals `dvh1`/`hvc1` and carries the `dvcC`/`dvvC` configuration box through, so the TV switches into real DV. The FFmpeg engine reports Dolby Vision to the system as HDR10
- 🧬 **Profile 7 is converted to 8.1** on the way through the remux: the enhancement-layer NAL units are dropped and the RPU is rewritten single-layer with libdovi, turning a format `AVPlayer` refuses outright into one it plays. Implemented and unit-tested; not yet checked against a real Dolby Vision display
- 🔉 E-AC-3, AC-3, AAC, FLAC and ALAC are **bitstream-copied** into the remux, untouched. For Atmos the `moov` is held back until the muxer has parsed an audio frame, so the `dec3` box comes out filled instead of empty, and the playlist declares `CHANNELS="16/JOC"` when the decoder reports the DD+ Atmos profile. Same caveat: the code path is there, the receiver check isn't done
- 🎛️ TrueHD and DTS are re-encoded to FLAC at up to 24-bit: lossless for the channel bed at that depth, but the Atmos objects are gone
- 📼 MKV, HLS, MP4 and anything else FFmpeg 8.1 demuxes
- 🎚️ The `AVPlayer`-backed engines decode in hardware. In the FFmpeg engine, VideoToolbox is opt-in (`asynchronousDecompression`) and falls back to software automatically when a frame fails to decode
- 📶 On tvOS, frame rate and dynamic range are handed to the display through `AVDisplayCriteria` — so the TV can switch mode to match the content, when the viewer has Match Content enabled
- 🔊 Multichannel output on five interchangeable audio backends, swappable via `KSOptions.audioPlayerType`; `AudioRendererPlayer` is the one that enables system spatialization

**Interface**
- 📺 A full tvOS player UI — transport bar, info panels, track popover, content tabs
- 🖼️ **Scrub previews** — live thumbnails while you seek, decoded on a dedicated engine
- 🎯 Focus model built for the remote from the start, not adapted from touch
- 🪟 Picture in Picture — subtitles are a SwiftUI overlay, so they stay in the app window and don't follow the PiP layer

**Streaming**
- 💾 Byte-range **disk cache** backed by `URLSession` — feeds FFmpeg through a custom AVIO context and `AVPlayer` through a resource loader
- ⚡ Fast seeking inside cached ranges — a seek that lands on cached bytes costs no round trip. The cache fills on demand and never fetches less than 1 MB at a time; there is no background precaching ahead of the playhead
- 🧠 Short forward seeks are served **straight from the packets already in RAM** — no demuxer seek, no round trip. Anything outside the buffered window falls back to the normal seek path
- 🔀 **Hot source switching** — opt-in via `isSourceSwitchEnabled`: swapping to another URL of the same title prepares the new source in parallel and only commits when it is ready, so the current frame stays on screen instead of a teardown. On the remux engine playback rewinds by the remux latency at the swap
- 🌐 Opt-in: set `diskCacheDirectory` and HTTP(S) reads go through `URLSession` instead of FFmpeg's network layer. URLs ending in `.m3u8`/`.m3u` are excluded, and scrub thumbnails always open through FFmpeg's own stack

**Subtitles**
- 🔤 ASS/SSA, SRT and WebVTT parsed and rendered natively, with positioning and styling
- 📦 Embedded-font extraction — fansub releases render with their own fonts
- 📐 Font scaling derived from the script's `PlayResY` instead of guessed
- 🈯 Text, image (SUP/PGS) and closed captions

## 🎛️ Three engines, one API

You pick a first and a second engine. When the first one reports an error — opening the stream or during playback — Lumen shuts it down and restarts on the second. There are two slots, not a three-deep chain: once the second engine fails, playback goes to `.error`.

| Engine | Backed by | Best at |
| --- | --- | --- |
| **`ProAVPlayer`** | Remux → `AVPlayer` | MKV with native Dolby Vision and Atmos |
| **`KSAVPlayer`** | `AVFoundation` | HLS and MP4, lowest overhead |
| **`KSMEPlayer`** | FFmpeg | Everything else — the universal fallback |

```swift
KSOptions.firstPlayerType = ProAVPlayer.self
KSOptions.secondPlayerType = KSMEPlayer.self
```

Two cases override your first choice: AirPlay forces `KSAVPlayer`, and any non-plane display mode forces `KSMEPlayer`.

## 📦 Requirements

There are two floors, and they are not the same one:

| | Minimum |
| --- | --- |
| Package manifest — the headless core, `ProAVPlayer`, the disk cache | tvOS 13 · iOS 13 · macOS 10.15 · Mac Catalyst 14 |
| `KSVideoPlayerView` and the whole tvOS interface | tvOS 16 · iOS 16 · macOS 13 |

`Package.swift` declares the lower floor because the engines and the cache carry no type-level availability annotations. The SwiftUI entry point does: if you use `KSVideoPlayerView` — and on tvOS that is the point — the real minimum is 16.

Scrub thumbnails are tvOS-only, at any version.

- Swift 5.9+ / Xcode 15+

## 🚀 Installation

Add Lumen as a remote Swift package. There are no tagged releases yet, so depend on the branch:

```swift
dependencies: [
    .package(url: "https://github.com/joaoalvess/lumen-player.git", branch: "main")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Lumen", package: "lumen-player")
    ])
]
```

In Xcode: **File → Add Package Dependencies**, paste the URL, and choose the `main` branch.

To work against a local checkout instead, note that a path dependency takes its identity from the **directory name**, so `package:` must match the folder — not the package's `name`:

```swift
dependencies: [
    .package(path: "../lumen-player")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Lumen", package: "lumen-player")
    ])
]
```

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
| `Sources/Lumen/MEPlayer/` | Demux, decode, A/V sync — the FFmpeg engine, `ProAVPlayer` and the remux session, the audio output backends, the AVIO bridge and the scrub-thumbnail engine |
| `Sources/Lumen/AVPlayer/` | `KSPlayerLayer`, options, player protocols, PiP, the `AVPlayer` resource loader |
| `Sources/Lumen/Cache/` | The byte cache itself — range bookkeeping on disk and the `URLSession` reader |
| `Sources/Lumen/SwiftUI/TVOS/` | The tvOS interface — transport bar, panels, scrubber, glass styles |
| `Sources/Lumen/Subtitle/` | Parsing, rendering, embedded fonts |
| `Sources/Lumen/Metal/` | Shaders and pixel-buffer rendering |
| `Sources/Lumen/Core/` | Cross-platform shims (UIKit/AppKit/Foundation extensions), the base UIKit `PlayerView` and toolbar, M3U parsing, media export |
| `Sources/Lumen/Video/` | The legacy UIKit/AppKit player interface — `VideoPlayerView`, fullscreen transitions, gestures, `KSPlayerResource` |
| `Sources/Lumen/Audio/` | `AudioPlayerView`, the audio-only UIKit view. The audio *pipeline* lives in `MEPlayer/` |

## 🗺️ Roadmap

What's planned next — HDR10+ dynamic metadata, background read-ahead, full ASS effects — lives in [`ROADMAP.md`](./ROADMAP.md).

## 🙏 Credits

Lumen grew out of [**KSPlayer**](https://github.com/kingslay/KSPlayer) by [kingslay](https://github.com/kingslay), and owes it the foundation it stands on. It also builds on [FFmpeg](https://ffmpeg.org) and the build scripts from [MPVKit](https://github.com/mpvkit/MPVKit).

## ⚖️ License

GPL-3.0 — see [`LICENSE`](./LICENSE).
