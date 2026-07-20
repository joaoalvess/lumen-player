# Roadmap

Where Lumen is going. No dates — this is roughly the order things are likely to land.

## Next

### Atmos signaling in the remux

E-AC-3 already rides through the remux untouched — the Atmos data is in the stream. What's missing is the signaling that makes the system treat it as Atmos: the JOC complexity fields in the `dec3` box and the matching `CHANNELS` attribute in the playlist. The muxer half was blocked on an FFmpeg fix that landed in 8.0, and Lumen now ships 8.1 — so this is next in line, and small.

### Dolby Vision dynamic metadata

Dolby Vision already reaches the TV through the remux engine, but the *dynamic* metadata doesn't: the RPU is dropped along the way, so the display falls back to static tone mapping. The plan is to preserve the `dvcC`/`dvvC` box and the RPU through the remux, so VideoToolbox applies Dolby's real per-scene tone mapping — and to convert profile 7 dual-layer into profile 8.1 single-layer while we're in there.

### Instant stream switching

Switching between two URLs of the same title — a different audio track, another quality, a fallback source — currently tears the player down and opens a new one, and you see it happen. Replacing that with prewarm and hot-swap should make the change seamless.

### Memory cache for short seeks

Around 30 seconds of data already sits in RAM and gets thrown away on every seek. Two layers to fix it: reuse the buffered window for forward seeks without touching the network, and keep a keyframe-aligned retention ring per track so short backward seeks are instant.

## Later

### HDR10+ dynamic metadata

The same idea as Dolby Vision, one format over: pass ST 2094-40 through the local HLS remux and let tvOS apply it. There's no public API to hand dynamic metadata to the compositor directly, so the remux path is the only route.

### Background read-ahead

The disk cache fills strictly on demand: a byte is fetched when the reader asks for it, never before. Read-ahead would keep the next stretch of the file warm ahead of the playhead, so short network stalls stay invisible and long forward seeks land on disk more often.

### Full ASS subtitle effects

ASS is parsed natively today, which covers positioning, styling and embedded fonts — but not `\move`, `\fad`, `\t`, `\clip`, karaoke or rotation. libass already ships inside the bundled FFmpeg build without ever being wired into Swift; connecting it would give fansub releases full fidelity.

### System caption appearance

An opt-in toggle that applies the viewer's **Settings → Accessibility → Subtitles and Captioning** preferences — colour, font, size, edge style — to the subtitle overlay, through `MediaAccessibility`.

### Subtitles in Picture in Picture

Subtitles are a SwiftUI overlay, so when video moves to the PiP window they stay behind in the app. Compositing them into the video layer itself would let them travel with the picture.

## Housekeeping

- **A first tagged release** — the only way to depend on Lumen today is the `main` branch. Cutting a version makes the API breakable on purpose instead of by accident.
- **Availability annotations that tell the truth** — `Package.swift` declares tvOS 13, but the SwiftUI interface really needs 16, and the floor is enforced at runtime instead of by the compiler. Annotating the types closes that gap.

## Shipped

The remux engine that switches the TV into real Dolby Vision, with E-AC-3/AC-3/AAC/FLAC/ALAC passthrough and TrueHD/DTS transcoded to FLAC; FFmpeg 8.1; Dolby Vision profile 5 colour on the FFmpeg engine; the byte-range disk cache; embedded subtitle fonts; scrub thumbnail previews; and the tvOS interface. See the [README](./README.md) for what works today.
