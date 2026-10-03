# Roadmap

Where Lumen is going. No dates — this is roughly the order things are likely to land.

## Next

### Instant backward seeks

Forward seeks that land inside the buffered window are already served straight from RAM, without a demuxer seek or a network round trip. The other half is a keyframe-aligned retention ring per track, so a short seek *backwards* is just as instant instead of a full reposition.

### Switching before the viewer asks

Switching between two URLs of the same title no longer tears the player down, and the swap no longer rewinds: the candidate is prepared in parallel and the resume point is computed against its own timeline at commit time. What is still missing is anticipation — nothing prepares a candidate before the viewer picks one, and speculative prewarm from the source list is what would make the change feel instantaneous.

## Later

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

The remux engine that switches the TV into real Dolby Vision, with E-AC-3/AC-3/AAC/FLAC/ALAC passthrough and TrueHD/DTS transcoded to FLAC; the Atmos `dec3`/`CHANNELS` signaling, profile 7 converted to single-layer 8.1, profile 8.2 signalled instead of refused, and HDR10+ announced with the `cdm4` brand when ST 2094-40 is found in the bitstream (all four still waiting on a check against real hardware); embedded subtitles on the remux engine; seeks inside the already-remuxed window served by the AVPlayer itself; audio track changes swapped in hot instead of restarting; opt-in hot source switching; forward seeks served from memory; FFmpeg 8.1; Dolby Vision profile 5 colour on the FFmpeg engine; the byte-range disk cache; embedded subtitle fonts; scrub thumbnail previews; the tvOS interface; Up Next and skip prompts; a sources chip; playback speed and subtitle delay; initial tracks picked by preferred language; host title and artwork in Now Playing; and playback-end and track-selection events for the host. See the [README](./README.md) for what works today.
