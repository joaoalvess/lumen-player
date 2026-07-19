# Documentação do Lumen

Documentação técnica do Lumen, fork GPL do KSPlayer. Cada documento cobre um subsistema com o mesmo formato: Responsabilidade, Tipos principais, Fluxo de dados, Pontos de extensão, Pegadinhas e Relação com outros subsistemas. Comece pelo `00-ARQUITETURA.md`.

## Índice

| Doc | Arquivo | Uma linha |
|---|---|---|
| 00 | [00-ARQUITETURA.md](00-ARQUITETURA.md) | Visão geral: diagrama URL → demux → decode → render/áudio → UI, os três engines (`KSAVPlayer`, `KSMEPlayer`, `ProAVPlayer`) e o mapa mental obrigatório antes de mexer no código |
| 01 | [01-vis-o-geral-e-build.md](01-vis-o-geral-e-build.md) | Build: manifesto SPM do pacote `Lumen`, FFmpeg 8.1 e libass como binários vendorizados em `FFmpegKit/`, target ObjC `DisplayCriteria` (API privada) e CI |
| 02 | [02-camada-avplayer.md](02-camada-avplayer.md) | Contrato público (`MediaPlayerProtocol`), orquestrador `KSPlayerLayer` (estados, fallback de engine, PiP, remote commands), engine nativo `KSAVPlayer`, `KSOptions` e ponte SwiftUI `KSVideoPlayer` |
| 03 | [03-engine-meplayer-demux-e-pipeline.md](03-engine-meplayer-demux-e-pipeline.md) | Engine FFmpeg: `MEPlayerItem` (demux, threads, seek, backpressure), filas `CircularBuffer`, clocks e sincronização A/V, ABR e gravação; também o engine `ProAVPlayer` (remux para HLS fMP4) e o cache de disco por byte-range |
| 04 | [04-decodifica-o.md](04-decodifica-o.md) | Decoders (`FFmpegDecode` com hwaccel VTB, `VideoToolboxDecode`), negociação de pixel/áudio format (`Resample`), filtros libavfilter, side data HDR/DV e os dois motores de thumbnail (`ThumbnailController`, `ScrubThumbnailEngine`) |
| 05 | [05-udio.md](05-udio.md) | Os 4 backends de saída de áudio (`AudioEnginePlayer` default, `AudioRendererPlayer` p/ multicanal/spatial no tvOS…), clock de áudio mestre, formato e route changes |
| 06 | [06-render-de-v-deo-e-hdr.md](06-render-de-v-deo-e-hdr.md) | Render: `AVSampleBufferDisplayLayer` vs pipeline Metal próprio, shaders YUV→RGB, EDR/HDR, projeções 360° e frame rate/HDR matching do tvOS (`AVDisplayCriteria`) |
| 07 | [07-legendas.md](07-legendas.md) | Legendas: parsers SRT/VTT/ASS, `SubtitleModel`, trilhas embutidas (`SubtitleDecode`, texto e bitmap), fontes online (Shooter/Assrt/OpenSubtitles), fontes tipográficas embutidas em MKV (`EmbeddedFontRegistry`) e exibição |
| 08 | [08-ui-e-views.md](08-ui-e-views.md) | As duas UIs paralelas: UIKit/AppKit clássica (`VideoPlayerView`) e SwiftUI (`KSVideoPlayerView`), mais a camada dedicada de tvOS em `SwiftUI/TVOS/` (transport bar, scrubber, painéis, thumbnails) |
| 09 | [09-fronteiras-e-reescrita.md](09-fronteiras-e-reescrita.md) | O que será reescrito, o contrato que sobrevive (`MediaPlayerProtocol`, `KSPlayerLayer`) e as regras para que features novas não gerem retrabalho |

## Panorama de capacidades

Resumo do que existe hoje no fork, por área. "Parcial" significa que há infraestrutura ou ganchos, mas não comportamento completo.

### Presentes

| Capacidade | Onde vive no fork |
|---|---|
| Demux/decode de praticamente qualquer formato | FFmpeg 8.1 completo via `FFmpegKit/` (docs 03/04) |
| Aceleração de hardware (VideoToolbox) | hwaccel dentro do `FFmpegDecode` (default) + `VTDecompressionSession` (doc 04) |
| Decode Annex-B assíncrono por hardware (live) | `VideoToolboxDecode` + `asynchronousDecompression` (doc 04) |
| Reprodução 4K/HDR/HDR10 | displayLayer + `CAEDRMetadata` + colorspaces BT.2020 (doc 06) |
| Dolby Vision e Atmos nativos | `ProAVPlayer`: remux para HLS fMP4 com signaling `dvh1`/`hvc1` e passthrough EC-3 (doc 03) |
| Vídeo 360°/panorama | `SphereDisplayModel`/VR/VRBox + `MotionSensor` (doc 06) |
| Picture in Picture | `KSPictureInPictureController` sobre `AVPictureInPictureController` (doc 02) |
| Loop de reprodução sem emenda | `loopPacketQueue` gapless no MEPlayer; `AVPlayerLooper` no KSAVPlayer (docs 02/03) |
| Detecção automática de entrelaçamento | filtro `idet` + `options.filter(log:)` → injeção de `yadif` (docs 02/04) |
| Áudio multicanal / spatial | `AudioRendererPlayer` + `outputNumberOfChannels` (doc 05) |
| Gravação de vídeo | remux sem re-encode (`startRecord`/`options.outputURL`, doc 03) |
| Legendas de texto / imagem / closed captions | SRT/VTT/ASS + PGS/VobSub/DVB + EIA-608 (doc 07) |
| Fontes embutidas no container para render de legenda | `EmbeddedFontRegistry` sobre CoreText (doc 07) |
| Busca de legendas online | `SearchSubtitleDataSouce` (Shooter/Assrt/OpenSubtitles) — com bugs conhecidos (doc 07) |
| Troca automática de bitrate por rede | `videoAdaptable` + `KSOptions.adaptable(state:)` (doc 03) |
| Cache em disco para seek e replay | `DiskByteCache` + `DiskCacheURLReader`, com hooks para FFmpeg e AVFoundation (doc 03) |
| Preview de thumbnails no scrubbing | `ScrubThumbnailEngine` + `ScrubThumbnailProvider` (docs 04/08) |
| Interface tvOS dedicada | `Sources/Lumen/SwiftUI/TVOS/` (doc 08) |

### Parciais

| Capacidade | O que existe hoje / o que falta |
|---|---|
| Metadados dinâmicos Dolby Vision no caminho MEPlayer | No `ProAVPlayer` o DV é nativo. No `KSMEPlayer`, DV passa como passthrough pelo displayLayer; RPU/metadata são lidos e **descartados** no `FFmpegDecode`; o shader `displayYCCTexture` (P5) existe e não é usado |
| Metadados dinâmicos HDR10+ | HDR10 estático vira `CAEDRMetadata`; side data `DYNAMIC_HDR_PLUS` é lido e jogado fora |
| De-interlace por hardware | `yadif_videotoolbox` só se configurado à mão; o auto-detect injeta `yadif` por software |
| Janela pequena in-app retomável | PiP do sistema existe; janela pequena in-app retomável não |
| PiP com legendas | PiP funciona, mas legendas são overlay de UI fora do layer do PiP |
| Clipes de vídeo a qualquer momento | gravação por remux desde o open ou sob demanda; sem clipe retroativo/trecho arbitrário |
| Download e conversão de formato | só remux para arquivo; sem conversão de formato/download gerenciado |
| 8K ou 120 FPS suaves | pipeline toca, mas o render bloqueia a main thread (`waitUntilCompleted`) e não há otimizações dedicadas |
| Live 4K de baixa latência | `nobuffer`/`codecLowDelay`/opções de formato existem; sem pipeline dedicado de baixa latência |
| Protocolos de URL custom (NFS/SMB/UPnP) | `libsmbclient` linkado + gancho `AbstractAVIOContext`/`process(url:)`; nada de NFS/UPnP pronto |
| Swift Concurrency no núcleo | flag `StrictConcurrency` ligada; núcleo ainda usa threads/`NSCondition` manuais e `Sendable` de fachada |
| Efeitos ASS completos | parser Swift próprio, aproximado; `libass` é linkado mas não importado (ver doc 01) |

### Ausentes

Upscaling de vídeo; cache em memória para seek em janela curta; saída de vídeo para uma segunda tela; troca de vídeo com atraso zero; passthrough de áudio por Wi-Fi; rewind de transmissão ao vivo; Blu-ray/ISO/DVD; reprodução simultânea de URLs separadas de áudio e vídeo; Dolby AC-4; decode de AV1 por hardware; ajuste de saturação/brilho/contraste; legendas de imagem externas (SUP); legendas principal e secundária simultâneas; legendas palavra a palavra; legendas com efeitos HDR; tradução de legendas; geração/tradução de legendas por IA offline; uso da aparência de legendas do sistema.

Notas:

- "Presente" = a funcionalidade existe e funciona no caminho default (podendo ter bugs pontuais documentados nas seções "Pegadinhas" dos docs).
- "Parcial" = existe infraestrutura/ganchos, mas o comportamento não está completo.
- "Ausente" = nenhuma implementação no fork; alguns casos já têm ganchos naturais mapeados (ex.: side data DV/HDR10+ descartada no `FFmpegDecode`, produto `libass` já linkado — ver "Pontos de extensão" dos docs 01, 04 e 07).
