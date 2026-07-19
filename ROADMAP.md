# Roadmap

Where Lumen is going. No dates — this is roughly the order things are likely to land.

## Next

### Dolby Vision dynamic metadata

Dolby Vision already reaches the TV through the remux engine, but the *dynamic* metadata doesn't: the RPU is dropped along the way, so the display falls back to static tone mapping. The plan is to preserve the `dvcC`/`dvvC` box and the RPU through the remux, so VideoToolbox applies Dolby's real per-scene tone mapping — and to convert profile 7 dual-layer into profile 8.1 single-layer while we're in there.

### Instant stream switching

Switching between two URLs of the same title — a different audio track, another quality, a fallback source — currently tears the player down and opens a new one, and you see it happen. Replacing that with prewarm and hot-swap should make the change seamless.

### Memory cache for short seeks

Around 30 seconds of data already sits in RAM and gets thrown away on every seek. Two layers to fix it: reuse the buffered window for forward seeks without touching the network, and keep a keyframe-aligned retention ring per track so short backward seeks are instant.

## Later

### Full ASS subtitle effects

ASS is parsed natively today, which covers positioning, styling and embedded fonts — but not `\move`, `\fad`, `\t`, `\clip`, karaoke or rotation. libass already ships inside the bundled FFmpeg build without ever being wired into Swift; connecting it would give fansub releases full fidelity.

### HDR10+ dynamic metadata

The same idea as Dolby Vision, one format over: pass ST 2094-40 through the local HLS remux and let tvOS apply it. There's no public API to hand dynamic metadata to the compositor directly, so the remux path is the only route.

### System caption appearance

An opt-in toggle that applies the viewer's **Settings → Accessibility → Subtitles and Captioning** preferences — colour, font, size, edge style — to the subtitle overlay, through `MediaAccessibility`.

## Shipped

Dolby Vision and Atmos through the remux engine, FFmpeg 8.1, the byte-range disk cache, embedded subtitle fonts, scrub thumbnail previews, and the tvOS interface. See the [README](./README.md) for what works today.
