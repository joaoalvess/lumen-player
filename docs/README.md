# Documentação do fork KSPlayer (Player)

Documentação técnica do fork GPL do KSPlayer usado pelo StreamHub. Cada documento cobre um subsistema com o mesmo formato: Responsabilidade, Tipos principais, Fluxo de dados, Pontos de extensão, Pegadinhas e Relação com outros subsistemas. Comece pelo `00-ARQUITETURA.md`.

## Índice

| Doc | Arquivo | Uma linha |
|---|---|---|
| 00 | [00-ARQUITETURA.md](00-ARQUITETURA.md) | Visão geral: diagrama URL → demux → decode → render/áudio → UI, os dois engines (`KSAVPlayer` vs `KSMEPlayer`) e o mapa mental obrigatório antes de mexer no código |
| 01 | [01-vis-o-geral-e-build.md](01-vis-o-geral-e-build.md) | Build: manifesto SPM, binários FFmpeg/libass via FFmpegKit, target ObjC `DisplayCriteria` (API privada), podspecs legados e CI |
| 02 | [02-camada-avplayer.md](02-camada-avplayer.md) | Contrato público (`MediaPlayerProtocol`), orquestrador `KSPlayerLayer` (estados, fallback de engine, PiP, remote commands), engine nativo `KSAVPlayer`, `KSOptions` e ponte SwiftUI `KSVideoPlayer` |
| 03 | [03-engine-meplayer-demux-e-pipeline.md](03-engine-meplayer-demux-e-pipeline.md) | Engine FFmpeg: `MEPlayerItem` (demux, threads, seek, backpressure), filas `CircularBuffer`, clocks e sincronização A/V, ABR e gravação |
| 04 | [04-decodifica-o.md](04-decodifica-o.md) | Decoders (`FFmpegDecode` com hwaccel VTB, `VideoToolboxDecode`), negociação de pixel/áudio format (`Resample`), filtros libavfilter, side data HDR/DV e thumbnails |
| 05 | [05-udio.md](05-udio.md) | Os 4 backends de saída de áudio (`AudioEnginePlayer` default, `AudioRendererPlayer` p/ multicanal/spatial no tvOS…), clock de áudio mestre, formato e route changes |
| 06 | [06-render-de-v-deo-e-hdr.md](06-render-de-v-deo-e-hdr.md) | Render: `AVSampleBufferDisplayLayer` vs pipeline Metal próprio, shaders YUV→RGB, EDR/HDR, projeções 360° e frame rate/HDR matching do tvOS (`AVDisplayCriteria`) |
| 07 | [07-legendas.md](07-legendas.md) | Legendas: parsers SRT/VTT/ASS, `SubtitleModel`, trilhas embutidas (`SubtitleDecode`, texto e bitmap), fontes online (Shooter/Assrt/OpenSubtitles) e exibição |
| 08 | [08-ui-e-views.md](08-ui-e-views.md) | As duas UIs paralelas: UIKit/AppKit clássica (`VideoPlayerView`) e SwiftUI (`KSVideoPlayerView`, a usada pelo StreamHub/tvOS), gestos, foco tvOS e camada de compatibilidade |

Investigação individual de cada feature (evidências, arquivos, o que falta): [`../context/investigation/`](../context/investigation/).

## Status real das features (vs. KSPlayer pago / Infuse)

Resumo da auditoria: **13 presentes, 12 parciais, 23 ausentes** (48 features).

### Presentes (13)

| Feature | Onde vive no fork | Investigação |
|---|---|---|
| KSMEPlayer supports all demuxing and decoding formats | FFmpeg 6.1 completo via FFmpegKit (docs 03/04) | [detalhe](../context/investigation/ksmeplayer-supports-all-demuxing-and-decoding-formats.md) |
| Hardware accelerator (VideoToolbox) | hwaccel dentro do `FFmpegDecode` (default) + `VTDecompressionSession` (doc 04) | [detalhe](../context/investigation/hardware-accelerator-videotoolbox.md) |
| Annex-B async hardware decoding (live stream) | `VideoToolboxDecode` + `asynchronousDecompression` (doc 04) | [detalhe](../context/investigation/annex-b-async-hardware-decoding-live-stream.md) |
| 4K/HDR/HDR10 playback | displayLayer + `CAEDRMetadata` + colorspaces BT.2020 (doc 06) | [detalhe](../context/investigation/4k-hdr-hdr10-playback.md) |
| 360 panorama video | `SphereDisplayModel`/VR/VRBox + `MotionSensor` (doc 06) | [detalhe](../context/investigation/360-panorama-video.md) |
| Picture in Picture | `KSPictureInPictureController` sobre `AVPictureInPictureController` (doc 02) | [detalhe](../context/investigation/picture-in-picture.md) |
| Seamless loop playback | `loopPacketQueue` gapless no MEPlayer; `AVPlayerLooper` no KSAVPlayer (docs 02/03) | [detalhe](../context/investigation/seamless-loop-playback.md) |
| De-interlace auto detect | filtro `idet` + `options.filter(log:)` → injeção de `yadif` (docs 02/04) | [detalhe](../context/investigation/de-interlace-auto-detect.md) |
| Multichannel Audio / Spatial Audio | `AudioRendererPlayer` + `outputNumberOfChannels` (doc 05) | — |
| Record video | remux sem re-encode (`startRecord`/`options.outputURL`, doc 03) | [detalhe](../context/investigation/record-video.md) |
| Text subtitle / Image subtitle / Closed Captions | SRT/VTT/ASS + PGS/VobSub/DVB + EIA-608 (doc 07) | [detalhe](../context/investigation/text-subtitle-image-subtitle-closed-captions.md) |
| Search online subtitles (shooter/assrt/opensubtitles) | `SearchSubtitleDataSouce` — com bugs conhecidos (doc 07) | [detalhe](../context/investigation/search-online-subtitles-shooter-assrt-opensubtitles.md) |
| Auto switch multi-bitrate streams by network | `videoAdaptable` + `KSOptions.adaptable(state:)` (doc 03) | [detalhe](../context/investigation/auto-switch-multi-bitrate-streams-by-network.md) |

### Parciais (12)

| Feature | O que existe hoje / o que falta | Investigação |
|---|---|---|
| Native Dolby Vision dynamic metadata P5/P8/P7 single-layer | DV passa como passthrough pelo displayLayer; RPU/metadata lidos e **descartados** no `FFmpegDecode`; shader `displayYCCTexture` (P5) existe e não é usado | [detalhe](../context/investigation/native-dolby-vision-dynamic-metadata-p5-p8-p7-single-layer.md) |
| HDR10+ dynamic metadata | HDR10 estático vira `CAEDRMetadata`; side data `DYNAMIC_HDR_PLUS` é lido e jogado fora | [detalhe](../context/investigation/hdr10-dynamic-metadata.md) |
| Hardware De-interlace | `yadif_videotoolbox` só se configurado à mão; o auto-detect injeta `yadif` por software | [detalhe](../context/investigation/hardware-de-interlace.md) |
| Play videos in small window in-app (resumable, iOS/tvOS) | PiP do sistema existe; janela pequena in-app retomável não | [detalhe](../context/investigation/play-videos-in-small-window-in-app-resumable-ios-tvos.md) |
| Picture in Picture with subtitle display | PiP funciona, mas legendas são overlay de UI fora do layer do PiP | [detalhe](../context/investigation/picture-in-picture-with-subtitle-display.md) |
| Record video clips at any time | gravação por remux desde o open ou sob demanda; sem clipe retroativo/trecho arbitrário | [detalhe](../context/investigation/record-video-clips-at-any-time.md) |
| Video download and format conversion | só remux para arquivo; sem conversão de formato/download gerenciado | [detalhe](../context/investigation/video-download-and-format-conversion.md) |
| Smoothly play 8K or 120 FPS video | pipeline toca, mas render bloqueia a main thread (`waitUntilCompleted`) e não há otimizações dedicadas | [detalhe](../context/investigation/smoothly-play-8k-or-120-fps-video.md) |
| Low latency 4K live streaming (<200ms na LAN) | `nobuffer`/`codecLowDelay`/opções de formato existem; sem pipeline dedicado de baixa latência | [detalhe](../context/investigation/low-latency-4k-live-streaming-menos-de-200ms-na-lan.md) |
| Custom URL protocols (nfs/smb/UPnP) | `libsmbclient` linkado + gancho `AbstractAVIOContext`/`process(url:)`; nada de NFS/UPnP pronto | [detalhe](../context/investigation/custom-url-protocols-nfs-smb-upnp.md) |
| Swift Concurrency (async/await/actors no core) | flag `StrictConcurrency` ligada; núcleo ainda usa threads/`NSCondition` manuais e `Sendable` de fachada | [detalhe](../context/investigation/swift-concurrency-async-await-actors-no-core.md) |
| FFmpeg version bundled | FFmpeg 6.1 fixo em binários do FFmpegKit; atualizar exige o plugin `BuildFFmpeg` | [detalhe](../context/investigation/ffmpeg-version-bundled.md) |

### Ausentes (23)

| Feature | Investigação |
|---|---|
| Video upscaling | [detalhe](../context/investigation/video-upscaling.md) |
| ProgressBar Preview (thumbnails no scrubbing) | [detalhe](../context/investigation/progressbar-preview.md) |
| Precache data to Hard Drive | [detalhe](../context/investigation/precache-data-to-hard-drive.md) |
| Memory cache for fast seek in short time range | — |
| Video output to another screen | [detalhe](../context/investigation/video-output-to-another-screen.md) |
| Video switching with zero delay | — |
| Audio Passthrough Output by Wi-Fi | [detalhe](../context/investigation/audio-passthrough-output-by-wi-fi.md) |
| Live streaming rewind viewing | [detalhe](../context/investigation/live-streaming-rewind-viewing.md) |
| Blu-ray disc (ISO/DVD) playback | [detalhe](../context/investigation/blu-ray-disc-iso-dvd-playback.md) |
| Simultaneous playback of separate audio and video URLs | [detalhe](../context/investigation/simultaneous-playback-of-separate-audio-and-video-urls.md) |
| ProAVPlayer: MKV com Dolby Vision e Atmos nativos via AVPlayer | [detalhe](../context/investigation/proavplayer-mkv-com-dolby-vision-e-atmos-nativos-via-avplaye.md) |
| Dolby AC-4 | [detalhe](../context/investigation/dolby-ac-4.md) |
| AV1 hardware decoding | [detalhe](../context/investigation/av1-hardware-decoding.md) |
| Adjust saturation, brightness and contrast | [detalhe](../context/investigation/adjust-saturation-brightness-and-contrast.md) |
| Full ASS subtitle effects (render via libass) | — |
| Use fonts embedded in the video to render subtitles | [detalhe](../context/investigation/use-fonts-embedded-in-the-video-to-render-subtitles.md) |
| External image subtitles (SUP) | [detalhe](../context/investigation/external-image-subtitles-sup.md) |
| Main subtitles and secondary subtitles | [detalhe](../context/investigation/main-subtitles-and-secondary-subtitles.md) |
| Word-by-word subtitles | [detalhe](../context/investigation/word-by-word-subtitles.md) |
| Display subtitles with HDR effects | [detalhe](../context/investigation/display-subtitles-with-hdr-effects.md) |
| Text subtitle translation | [detalhe](../context/investigation/text-subtitle-translation.md) |
| Offline AI real-time subtitle generation and translation | [detalhe](../context/investigation/offline-ai-real-time-subtitle-generation-and-translation.md) |
| Use System Caption Appearance | [detalhe](../context/investigation/use-system-caption-appearance.md) |

Notas:
- "Presente" = funcionalidade existe e funciona no caminho default (podendo ter bugs pontuais documentados nas seções "Pegadinhas" dos docs).
- "Parcial" = existe infraestrutura/ganchos, mas o comportamento de paridade com o KSPlayer pago/Infuse não está completo.
- "Ausente" = nenhuma implementação no fork; alguns casos já têm ganchos naturais mapeados (ex.: side data DV/HDR10+ descartada no `FFmpegDecode`, produto `libass` já linkado — ver "Pontos de extensão" dos docs 01, 04 e 07).
- Features sem link de investigação (—) foram avaliadas na auditoria mas não ganharam arquivo próprio em `context/investigation/`.
