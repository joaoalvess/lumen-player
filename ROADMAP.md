# Roadmap

Where Lumen is going. No dates — this is roughly the order things are likely to land.

## Next

### Instant backward seeks

Forward seeks that land inside the buffered window are already served straight from RAM, without a demuxer seek or a network round trip. The other half is a keyframe-aligned retention ring per track, so a short seek *backwards* is just as instant instead of a full reposition.

### Switching without the rewind

Switching between two URLs of the same title no longer tears the player down: the next source is prepared in parallel and only swapped in when it is ready. Two things are still missing. On the remux engine the swap rewinds by however long the new remux took to warm up, because the target position is captured when the switch is requested rather than when it commits. And nothing prepares a candidate before the viewer asks for one — speculative prewarm from the source list is what would make the change feel instantaneous.

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

The remux engine that switches the TV into real Dolby Vision, with E-AC-3/AC-3/AAC/FLAC/ALAC passthrough and TrueHD/DTS transcoded to FLAC; the Atmos `dec3`/`CHANNELS` signaling and profile 7 converted to single-layer 8.1 on the way through the remux (both still waiting on a check against real hardware); opt-in hot source switching; forward seeks served from memory; FFmpeg 8.1; Dolby Vision profile 5 colour on the FFmpeg engine; the byte-range disk cache; embedded subtitle fonts; scrub thumbnail previews; and the tvOS interface. See the [README](./README.md) for what works today.
