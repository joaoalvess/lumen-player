# 04 — Decodificação

Subsistema de decodificação do MEPlayer (pipeline FFmpeg). Escopo: `Sources/Lumen/MEPlayer/` — `FFmpegDecode.swift`, `VideoToolboxDecode.swift`, `AVFFmpegExtension.swift`, `AVFoundationExtension.swift`, `Resample.swift`, `Filter.swift`, `ThumbnailController.swift`, `ScrubThumbnailEngine.swift`.

## Responsabilidade

Converter `Packet` (AVPacket demuxado, produzido pelo `MEPlayerItem`) em `MEFrame` prontos para renderização:

- **Vídeo** → `VideoVTBFrame` contendo um `PixelBufferProtocol` (um `CVPixelBuffer` real ou um `PixelBuffer` baseado em `MTLBuffer`), com metadata HDR (`EDRMetaData`) anexada.
- **Áudio** → `AudioFrame` com PCM já convertido para o `AVAudioFormat` que o player de áudio ativo consome.

Inclui: escolha entre decode por software (libavcodec, com hwaccel VideoToolbox interno) e decode por hardware assíncrono puro (`VTDecompressionSession`); negociação de formato de pixel (AVPixelFormat → OSType/CVPixelBuffer ou MTLBuffer) e de áudio (sample format/canais/layout → AVAudioFormat); grafo de filtros libavfilter por frame; extração de side data (HDR estático, SEI, closed captions, Dolby Vision); e um pipeline standalone de thumbnails.

Fora do escopo deste doc (mas fronteiras diretas): demux (`MEPlayerItem.swift`), filas/threads de decode (`MEPlayerItemTrack.swift`), render Metal (`Sources/Lumen/Metal/`), players de áudio (`Audio*Player.swift`), legendas (`SubtitleDecode.swift`).

## Tipos principais

| Tipo | Arquivo | Papel |
|---|---|---|
| `DecodeProtocol` | `Sources/Lumen/MEPlayer/MEPlayerItemTrack.swift` | Contrato dos decoders: `decode`, `decodeFrame(from:completionHandler:)`, `doFlushCodec`, `shutdown` |
| `FFmpegDecode` | `Sources/Lumen/MEPlayer/FFmpegDecode.swift` | Decoder por software (áudio e vídeo) via `avcodec_send_packet`/`avcodec_receive_frame`; coleta side data, roda filtros e resample; caminho default |
| `VideoToolboxDecode` | `Sources/Lumen/MEPlayer/VideoToolboxDecode.swift` | Decoder de vídeo 100% hardware, assíncrono, via `VTDecompressionSessionDecodeFrame`; só usado com `asynchronousDecompression` |
| `DecompressionSession` | `Sources/Lumen/MEPlayer/VideoToolboxDecode.swift` | Wrapper de `VTDecompressionSession` + `CMFormatDescription`; configura atributos de pixel buffer, HDR passthrough e pixel transfer |
| `MEFilter` | `Sources/Lumen/MEPlayer/Filter.swift` | Grafo libavfilter (`buffer`/`abuffer` → filtros do usuário → `buffersink`), reconfigurado lazy quando params/filtros mudam |
| `FrameChange` (protocol) | `Sources/Lumen/MEPlayer/Resample.swift` | `AVFrame` → `MEFrame` (etapa final do decode sw) |
| `FrameTransfer` (protocol) | `Sources/Lumen/MEPlayer/Resample.swift` | `AVFrame` → `AVFrame` (conversão intermediária) |
| `VideoSwscale` | `Sources/Lumen/MEPlayer/Resample.swift` | Conversão sws AVFrame→AVFrame. **Código morto** — nunca instanciado no pacote |
| `VideoSwresample` | `Sources/Lumen/MEPlayer/Resample.swift` | AVFrame de vídeo → `VideoVTBFrame`: desembrulha CVPixelBuffer de hwaccel, ou copia/converte para pool de CVPixelBuffer, ou cria `PixelBuffer` MTLBuffer p/ 10-bit planar LE |
| `AudioSwresample` | `Sources/Lumen/MEPlayer/Resample.swift` | swr_convert do formato do frame para o `AVAudioFormat` negociado; reconfigura ao detectar mudança de formato/rota |
| `AudioDescriptor` | `Sources/Lumen/MEPlayer/Resample.swift` | Negociação do formato de áudio de saída (sample format, canais, layout tag) em função do `KSOptions.audioPlayerType` e do hardware |
| `ThumbnailController` | `Sources/Lumen/MEPlayer/ThumbnailController.swift` | Pipeline independente (demux+decode+scale próprios) que gera N thumbnails por seek |
| `FFThumbnail` / `ThumbnailControllerDelegate` | `Sources/Lumen/MEPlayer/ThumbnailController.swift` | Resultado (UIImage + tempo) e callback de progresso |
| `ScrubThumbnailEngine` / `ScrubThumbnail` | `Sources/Lumen/MEPlayer/ScrubThumbnailEngine.swift` | Motor tvOS de thumbnails sob demanda: mantém contexto FFmpeg aberto e responde um frame por seek, em fila serial dedicada |
| `UnsafeMutablePointer<AVCodecContext>.getFormat` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Instala callback `get_format` que negocia `AV_PIX_FMT_VIDEOTOOLBOX` (hwaccel dentro do decode sw) |
| `AVCodecParameters.createContext(options:)` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Criação e abertura do `AVCodecContext` (flags, lowres, decoderOptions, hwaccel) |
| `AVPixelFormat.osType(fullRange:)` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Mapa AVPixelFormat → OSType CoreVideo (formatos representáveis sem conversão) |
| `AVPixelFormat.bestPixelFormat` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Alvo de conversão sws (equivalente ao `videotoolbox_best_pixel_format` do FFmpeg: NV12/P010/NV16/P210/NV24/P410/P416/AYUV64) |
| `AVPixelFormat.leftShift` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Marca YUV420P10LE/422P10LE/444P10LE (shift 6) → caminho `PixelBuffer` sem swscale |
| `AVColorPrimaries/AVColorTransferCharacteristic/AVColorSpace/AVChromaLocation` (extensões) | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Mapas FFmpeg → constantes `kCVImageBuffer*` de cor |
| `AVCodecID.mediaSubType` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Mapa codec FFmpeg → `CMFormatDescription.MediaSubType` |
| `CMVideoCodecType.avc` | `Sources/Lumen/MEPlayer/VideoToolboxDecode.swift` | Nome do atom de extradata (`avcC`/`hvcC`/`vpcC`/`esds`) usado no `CMFormatDescription` |
| `AVBufferSrcParameters` (ext.) | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Igualdade + string de args do buffersrc; base da detecção de reconfiguração do `MEFilter` |
| `Dictionary.avOptions` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | `[String: Any]` → `AVDictionary` para `avcodec_open2` |
| `AVError` + `NSError(errorCode:avErrorCode:)` | `Sources/Lumen/MEPlayer/AVFFmpegExtension.swift` | Tipagem dos códigos de erro FFmpeg |
| `CVPixelBufferPool.create(...)` | `Sources/Lumen/MEPlayer/AVFoundationExtension.swift` | Pool Metal-compatible + IOSurface usado pelo `VideoSwresample` |
| `layoutMapTuple` | `Sources/Lumen/MEPlayer/AVFoundationExtension.swift` | Tabela AudioChannelLayoutTag ↔ máscara de canais FFmpeg |
| `AudioChannelLabel.avChannel` | `Sources/Lumen/MEPlayer/AVFoundationExtension.swift` | Mapa label CoreAudio → `AVChannel` FFmpeg (montagem de máscara custom) |
| `AVAudioFormat.sampleFormat`/`sampleSize` | `Sources/Lumen/MEPlayer/AVFoundationExtension.swift` | Mapa AVAudioCommonFormat ↔ AVSampleFormat, tamanho de sample |
| `AVAudioChannelLayout.channelLayout` | `Sources/Lumen/MEPlayer/AVFoundationExtension.swift` | Layout CoreAudio → `AVChannelLayout` FFmpeg (usado por players de áudio p/ route change) |

## Fluxo de dados

### Seleção do decoder

1. `MEPlayerItem` cria os tracks (`MEPlayerItem.swift` vídeo, áudio) e antes chama `options.process(assetTrack:)` (`MEPlayerItem.swift`; implementação em `Sources/Lumen/AVPlayer/KSOptions.swift` — ex.: conteúdo entrelaçado desliga `hardwareDecode` e injeta `yadif` nos `videoFilters`).
2. No primeiro `Packet` de cada `trackID`, `SyncPlayerItemTrack.doDecode` cria o decoder via `makeDecode(assetTrack:)` (`MEPlayerItemTrack.swift`):
 - subtitle → `SubtitleDecode`;
 - vídeo com `options.asynchronousDecompression && options.hardwareDecode` e `DecompressionSession` criável → `VideoToolboxDecode`;
 - qualquer outro caso → `FFmpegDecode`.
3. Defaults: `KSOptions.hardwareDecode = true` (`KSOptions.swift`), `KSOptions.asynchronousDecompression = false` (`KSOptions.swift`). **Portanto o caminho default é `FFmpegDecode` com hwaccel VideoToolbox interno** (frames `AV_PIX_FMT_VIDEOTOOLBOX`), não o `VideoToolboxDecode`.
4. Fallback hw→sw: se `VideoToolboxDecode` reporta erro, o track faz `shutdown`, substitui por `FFmpegDecode` e redecodifica o mesmo packet (`MEPlayerItemTrack.swift`).

### Caminho software — `FFmpegDecode`

1. **Init** (`FFmpegDecode.swift`): `assetTrack.createContext(options:)` (`FFmpegAssetTrack.swift` → `AVCodecParameters.createContext`, `AVFFmpegExtension.swift`). Nesta criação: `avcodec_parameters_to_context`; se vídeo e `options.hardwareDecode`, instala `getFormat` (`AVFFmpegExtension.swift`) — o callback percorre a lista de formatos e, achando `AV_PIX_FMT_VIDEOTOOLBOX`, aloca `hw_device_ctx` (`av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX)`, `AVFFmpegExtension.swift`; `hw_frames_ctx` intencionalmente não é criado, ver comentário no código); seta `AV_CODEC_FLAG2_FAST`, `AV_CODEC_FLAG_LOW_DELAY` se `options.codecLowDelay`, `lowres` com clamp em `max_lowres`, e abre com `options.decoderOptions.avOptions`. Depois cria `MEFilter` (`FFmpegDecode.swift`) e o `FrameChange`: `VideoSwresample(fps:isDovi:)` para vídeo, `AudioSwresample(audioDescriptor:)` para áudio (`FFmpegDecode.swift`).
2. **`decodeFrame`** (`FFmpegDecode.swift`), chamado pela thread de decode do track:
 - `avcodec_send_packet`; retorno != 0 é ignorado silenciosamente (packet descartado).
 - Se o codec expõe `FF_CODEC_PROPERTY_CLOSED_CAPTIONS`, cria lazy um track de legendas EIA-608 pendurado em `packet.assetTrack.closedCaptionsTrack`.
 - Loop `avcodec_receive_frame`. Para cada frame, varre `side_data` **antes** dos filtros (filtro descarta side data, comentário):
 - `AV_FRAME_DATA_A53_CC` → re-empacota como `Packet` e injeta no track de CC;
 - `AV_FRAME_DATA_SEI_UNREGISTERED` → `options.sei(string:)`;
 - `AV_FRAME_DATA_DOVI_RPU_BUFFER` / `DOVI_METADATA` / `DYNAMIC_HDR_PLUS` / `DYNAMIC_HDR_VIVID` → **lidos e descartados** (variáveis locais sem uso);
 - `MASTERING_DISPLAY_METADATA`, `CONTENT_LIGHT_LEVEL`, `AMBIENT_VIEWING_ENVIRONMENT` → structs big-endian para `EDRMetaData`.
 - `filter.filter(options:inputFrame:completionHandler:)` — sem filtros configurados é passthrough síncrono.
 - `frameChange.change(avframe:)` produz o `MEFrame`; se o resultado é `VideoVTBFrame` com `PixelBuffer` (sw), anexa o `formatDescription` do track e a `edrMetaData`.
 - Timestamps: `frame.timebase = filter.timebase`; duration de áudio derivada de `nb_samples` quando 0; timestamp em cascata `best_effort_timestamp` → `pts` → `pkt_dts` → acumulador `bestEffortTimestamp`.
 - Fim do loop: `AVERROR_EOF` → `avcodec_flush_buffers` + break; `EAGAIN` → break; erro → `NSError` com `.codecAudioReceiveFrame`/`.codecVideoReceiveFrame`.
3. **Flush/shutdown**: `doFlushCodec` zera `bestEffortTimestamp` e `avcodec_flush_buffers`; `shutdown` libera frame, contexto e `frameChange`.

### Caminho hardware — `VideoToolboxDecode`

1. **`DecompressionSession.init`** (`VideoToolboxDecode.swift`): exige `assetTrack.pixelFormatType` (`FFmpegAssetTrack.swift`) e `assetTrack.formatDescription` (construído em `FFmpegAssetTrack.swift` com atoms `avcC`/`hvcC`/`vpcC` e a chave `RequireHardwareAcceleratedVideoDecoder`/`EnableHardwareAcceleratedVideoDecoder`). Atributos do pixel buffer: Metal-compatible + IOSurface (`VideoToolboxDecode.swift`). `VTDecompressionSessionCreate` com `decoderSpecification = CMFormatDescriptionGetExtensions(formatDescription)`. Extras: `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` e pixel transfer para o dynamic range de destino de `options.availableDynamicRange(nil)` (método em `KSOptions.swift`).
2. **`decodeFrame`** (`VideoToolboxDecode.swift`):
 - `needReconfig` (setado após falha em non-keyframe, tipicamente volta de background) recria a sessão e flusha.
 - `getSampleBuffer(isConvertNALSize:data:size:)`: se `assetTrack.isConvertNALSize` (detectado por `extradata[4] == 0xFE` em `FFmpegAssetTrack.swift`), reescreve NALs com length de 3 bytes para 4 via `avio_open_dyn_buf`; senão embrulha o data do packet direto em `CMBlockBuffer`/`CMSampleBuffer`.
 - `VTDecompressionSessionDecodeFrame` com `._EnableAsynchronousDecompression`; o callback roda em thread interna do VT:
 - frames com `.frameDropped` são ignorados;
 - erros `kVTInvalidSessionErr`/`MalfunctionErr`/`BadDataErr`: keyframe → `completionHandler(.failure)` (dispara o fallback sw do track); non-keyframe → `needReconfig = true` e descarte silencioso (mesmo tratamento no retorno síncrono);
 - sucesso → `VideoVTBFrame` com `imageBuffer`, `timebase` do track; ajuste de relógio para packets `AV_PKT_FLAG_DISCARD` pós-seek via `startTime`/`lastPosition`.

### Conversão de vídeo — `VideoSwresample.change` (`Resample.swift`)

- Frame `AV_PIX_FMT_VIDEOTOOLBOX` (hwaccel): `unsafeBitCast(avframe.pointee.data.3, to: CVPixelBuffer.self)` — convenção FFmpeg de que `data[3]` é o `CVPixelBufferRef`.
- Frame de sw com `format.leftShift > 0` (YUV 10-bit planar LE): `PixelBuffer(frame:)` (`Resample.swift` → `Sources/Lumen/Metal/PixelBufferProtocol.swift`), que copia os planos direto para `MTLBuffer`s — o shift de 6 bits é compensado nos shaders.
- Demais: `setup` (`Resample.swift`) decide — se `format.osType` existe, sem conversão (só memcpy pro pool); senão `sws_getCachedContext` para `format.bestPixelFormat`. O destino sai de `CVPixelBufferPool.create` (`AVFoundationExtension.swift`, alinhamento 64, 24 buffers). `transfer(format:width:height:data:linesize:)` (`Resample.swift`) faz `sws_scale` ou cópia plano a plano (com merge U+V → semi-planar quando o pool tem menos planos que a origem). Atributos de cor no buffer: `yCbCrMatrix`/`colorPrimaries`/`transferFunction`/gamma/chroma/colorspace (usando os mapas de `AVFFmpegExtension.swift` e `KSOptions.colorSpace` em `Model.swift`).

### Conversão de áudio — `AudioDescriptor` + `AudioSwresample`

1. `AudioDescriptor` nasce no `FFmpegAssetTrack` (`FFmpegAssetTrack.swift`) a partir do `codecpar`. `init` (`Resample.swift`): sample rate default 48000 se inválido; canais de saída = 2 no macOS, senão `KSOptions.outputNumberOfChannels(channelCount:)` (`KSOptions.swift`, consulta `AVAudioSession`).
2. `AudioDescriptor.audioFormat(...)` (`Resample.swift`): resolve `AudioChannelLayoutTag` via `layoutMapTuple` (`AVFoundationExtension.swift`) com fallbacks progressivos para layout default e por fim estéreo; `interleaved = (KSOptions.audioPlayerType == AudioRendererPlayer.self)`; `commonFormat` forçado para Float32 exceto para `AudioRendererPlayer`/`AudioUnitPlayer`.
3. `AudioSwresample.change` (`Resample.swift`): se o `AVFrame` divergiu do descriptor ou `outChannel` mudou (route change via `updateAudioFormat`), recria o `SwrContext` (`swr_alloc_set_opts2` + `swr_init`); `swr_convert` preenche um `AudioFrame` dimensionado por `av_samples_get_buffer_size`.

### Pós-decode

O `completionHandler` de `decodeFrame` empurra o frame para `outputRenderQueue` do track (`MEPlayerItemTrack.swift`; fila de vídeo é `sorted` — — para reordenar B-frames/callbacks fora de ordem). Dali os renders puxam via `getOutputRender`.

### Thumbnails — `ThumbnailController`

Pipeline totalmente independente do player: abre o próprio `AVFormatContext` (`ThumbnailController.swift`), acha o primeiro stream de vídeo, cria contexto **sem options** (sem hwaccel), instancia `VideoSwresample(dstWidth:dstHeight:)`, rescala a duração global para o timebase do stream e, para cada um dos `thumbnailCount` pontos: `av_seek_frame(AVSEEK_FLAG_BACKWARD)` + flush + decode de 1 frame + `cgImage`. Reporta progresso via `ThumbnailControllerDelegate.didUpdate` e retorna `[FFThumbnail]`; `generateThumbnail(for:thumbWidth:)` roda tudo dentro de um `Task`.

Gera o **filmstrip inteiro de uma vez**, não tem cache nem estado persistente (abre e fecha o contexto a cada chamada) e não é usado pela interface tvOS.

### Thumbnails de scrubbing — `ScrubThumbnailEngine`

Motor separado, em `Sources/Lumen/MEPlayer/ScrubThumbnailEngine.swift` (todo sob `#if os(tvOS)`), feito para responder **sob demanda** enquanto o usuário arrasta a barra de progresso — o oposto do `ThumbnailController`, que é batch.

- `public struct ScrubThumbnail: Sendable` — `image` + `time`.
- `final class ScrubThumbnailEngine: @unchecked Sendable` — mantém um `AVFormatContext` **aberto** entre requisições.

Fluxo: `openSync` abre o input com `rw_timeout` injetado nas opções, roda `avformat_find_stream_info`, pega o primeiro stream de vídeo, cria o `AVCodecContext` sem options e instancia um `VideoSwresample` já dimensionado (largura de `KSOptions.scrubThumbnailWidth`, altura derivada do aspecto da fonte). Cada requisição converte o tempo alvo para o timebase do stream, faz `avcodec_flush_buffers` → `av_seek_frame(AVSEEK_FLAG_BACKWARD)` → `avcodec_flush_buffers` e itera `av_read_frame`/`avcodec_send_packet`/`avcodec_receive_frame` até o primeiro frame decodificado, com fallback em cascata para o timestamp (`best_effort_timestamp` → `pts` → `pkt_dts` → alvo). A conversão final é `transfer(frame:)?.cgImage()`.

Threading: uma `DispatchQueue` serial dedicada (`qos: .userInitiated`) confina toda a manipulação de ponteiros FFmpeg; `open`/`thumbnail` são `async` via `withCheckedContinuation` e `close` é fire-and-forget na mesma fila.

A camada de cache, bucketização e coordenação com a UI é o `ScrubThumbnailProvider` — ver doc 08.

## Pontos de extensão

- **Novo decoder**: implementar `DecodeProtocol` (`MEPlayerItemTrack.swift`) e plugar a seleção em `SyncPlayerItemTrack.makeDecode(assetTrack:)` (`MEPlayerItemTrack.swift`). É o único ponto de decisão sw/hw/subtitle.
- **Dolby Vision / HDR dinâmico (paridade Infuse)**: os hooks já existem e estão vazios — `FFmpegDecode.swift` lê `AV_FRAME_DATA_DOVI_RPU_BUFFER`, `AV_FRAME_DATA_DOVI_METADATA` (com `av_dovi_get_header/mapping/color` já chamados), `DYNAMIC_HDR_PLUS` e `DYNAMIC_HDR_VIVID` e joga fora. Processamento por frame entra aí; o transporte até o render é `VideoVTBFrame.edrMetaData` (`Model.swift`, consumido por `edrMetadata` → `CAEDRMetadata` em `Model.swift`). O flag `isDovi` já viaja no frame (`Model.swift`, setado em `FFmpegDecode.swift` e `VideoToolboxDecode.swift` a partir de `assetTrack.dovi`, que vem de `AV_PKT_DATA_DOVI_CONF` em `FFmpegAssetTrack.swift`).
- **Filtros FFmpeg em runtime**: `options.videoFilters`/`options.audioFilters` (`KSOptions.swift`) são lidos a cada frame (`Filter.swift`) e o grafo é reconstruído quando a string ou os parâmetros do frame mudam (`Filter.swift`) — dá para adicionar/remover filtros com o vídeo rodando. `options.autoDeInterlace` injeta `idet` automaticamente (`Filter.swift`) e o feedback do idet volta por `options.filter(log:)` (`KSOptions.swift`).
- **Hook pré-decoder**: `KSOptions.process(assetTrack:)` (`KSOptions.swift`) — chamado por track antes de criar o decoder (`MEPlayerItem.swift`); lugar certo para ajustar `hardwareDecode`, filtros, `nominalFrameRate` por características do stream.
- **SEI custom**: sobrescrever `KSOptions.sei(string:)` (`KSOptions.swift`), alimentado por `FFmpegDecode.swift`.
- **Opções do codec**: `options.decoderOptions` (`KSOptions.swift`; defaults `threads=auto`, `refcounted_frames=1` em) vira `AVDictionary` no `avcodec_open2` (`AVFFmpegExtension.swift`). `options.lowres` (`KSOptions.swift`) e `options.codecLowDelay` também entram por aí.
- **Dynamic range de saída da sessão VT**: sobrescrever `KSOptions.availableDynamicRange(_:)` (`KSOptions.swift`) muda o pixel transfer configurado em `VideoToolboxDecode.swift`.
- **Novo formato de pixel suportado**: adicionar o mapeamento em `AVPixelFormat.osType(fullRange:)` (`AVFFmpegExtension.swift`) evita swscale; se o Metal precisar de layout de plano novo, ajustar `KSOptions.pixelFormat(planeCount:bitDepth:)` (`Model.swift`) e os shaders.
- **Nova conversão de frame**: implementar `FrameChange` (`Resample.swift`) e trocar a atribuição em `FFmpegDecode.init` (`FFmpegDecode.swift`).
- **Thumbnails**: `ThumbnailControllerDelegate` (`ThumbnailController.swift`) para progresso incremental; `thumbnailCount` e `thumbWidth` são os únicos knobs.

## Pegadinhas

- **`VideoToolboxDecode` quase nunca roda**: com os defaults (`asynchronousDecompression = false`), todo o decode "hardware" acontece dentro do `FFmpegDecode` via hwaccel (`get_format` → `AV_PIX_FMT_VIDEOTOOLBOX`). Mudanças em `VideoToolboxDecode.swift` não afetam o caminho default; o equivalente hwaccel está em `AVFFmpegExtension.swift` + `Resample.swift`.
- **Threading do completionHandler**: `FFmpegDecode.decodeFrame` é síncrono na thread de decode do track (OperationQueue serial nomeada `Lumen_<mediaType>`, `MEPlayerItemTrack.swift`, com `stackSize` custom), e pode chamar o handler N vezes por packet. `VideoToolboxDecode` chama o handler em **thread interna do VideoToolbox** (flag `._EnableAsynchronousDecompression`, `VideoToolboxDecode.swift`), fora de ordem — por isso a fila de vídeo é `sorted` (`MEPlayerItemTrack.swift`). Estado mutável do decoder (`lastPosition`, `startTime`, `needReconfig`) é tocado dessa thread sem lock.
- **Falha silenciosa de `avcodec_send_packet`**: retorno != 0 simplesmente descarta o packet (`FFmpegDecode.swift`) — sem log, sem erro. Em debugging de "frames faltando", começar aqui.
- **Timebase após filtros**: `frame.timebase = filter.timebase` (`FFmpegDecode.swift`) é o timebase **do track na criação**; a leitura do timebase real do buffersink está comentada (`Filter.swift`, `FFmpegDecode.swift`). Filtros que alteram timing (yadif mode 1 dobra o fps) dependem do ajuste manual de `nominalFrameRate` em `KSOptions.process` (`KSOptions.swift`).
- **Ordem no packet de closed captions**: `Packet.assetTrack` tem `didSet` que copia pts/pos/duration/size do `corePacket` (`Model.swift`). Em `FFmpegDecode.swift` os campos do `corePacket` são preenchidos **antes** de setar `assetTrack` — inverter a ordem quebra os timestamps do CC.
- **Bug real em mastering display**: `display_primaries_b_x` usa `data.display_primaries.2.1.num` (deveria ser `2.0`) — x e y do primário azul saem iguais (`FFmpegDecode.swift`). Herdado do upstream; corrigir ao trabalhar HDR10.
- **Big-endian e denominadores assumidos**: os structs de `EDRMetaData` são convertidos com `.bigEndian` porque `CAEDRMetadata.hdr10(displayInfo:contentInfo:)` espera payload SEI big-endian (`FFmpegDecode.swift`, consumo em `Model.swift`). Só o `.num` dos `AVRational` é usado — assume os denominadores canônicos do FFmpeg (50000 para primaries, 10000 para luminância).
- **`AudioDescriptor` depende de estado global estático**: `interleaved`/`commonFormat` derivam de `KSOptions.audioPlayerType` (`Resample.swift`, default `AudioEnginePlayer` em `Model.swift`). Trocar o player de áudio depois que tracks foram criados gera formato incompatível — definir antes de abrir a mídia.
- **`outChannel` é mutado por `inout`**: `AudioDescriptor.audioFormat(...)` reescreve `outChannel` via `av_channel_layout_default` nos fallbacks (`Resample.swift`); `AudioSwresample.change` usa exatamente essa mutação (`outChannel != descriptor.outChannel`) para detectar route change (`Resample.swift`). Não "simplificar" removendo o `inout`.
- **Erro não fatal vira descarte no VT**: falha de decode em non-keyframe só seta `needReconfig` e retorna (`VideoToolboxDecode.swift`) — todos os frames até o próximo keyframe somem sem nenhum sinal externo. O fallback para software só dispara se a falha ocorre num keyframe.
- **Invalidação da sessão VT**: `session.didSet` invalida a sessão antiga (`VideoToolboxDecode.swift`) e `shutdown` invalida a atual. Substituir a sessão por outro caminho sem passar pelo `didSet` vaza uma `VTDecompressionSession`.
- **`VideoSwscale` é código morto** (`Resample.swift`): nunca instanciado; a classe viva é `VideoSwresample`. `seekByBytes` em `FFmpegDecode` (`FFmpegDecode.swift`) também é armazenado e nunca lido.
- **`swr_alloc_set_opts2` com resultado sobrescrito**: `Resample.swift` ignora o retorno da alocação (a variável `result` é reatribuída pelo `swr_init`); falha de alocação só é percebida indiretamente.
- **Force-unwraps latentes**: `assetTrack.audioDescriptor!` (`FFmpegDecode.swift`), `dstFormat.osType!` (`Resample.swift` — pressupõe que todo `bestPixelFormat` tem OSType), `DecompressionSession(...)!` no reconfig (`VideoToolboxDecode.swift`). Este último crasha se a recriação da sessão falhar (ex. formato que perdeu suporte após background).
- **`ThumbnailController`**: usa `avcodec_close` deprecado (`ThumbnailController.swift`); o `Task` não checa cancelamento entre os até 100 seeks; o delegate é chamado na thread do `Task`; streams sem `avg_frame_rate` ou duração inválida lançam erro cedo.
- **Ordem de inicialização do CC track**: o track de closed captions só passa a existir depois do primeiro packet com a propriedade `FF_CODEC_PROPERTY_CLOSED_CAPTIONS` (`FFmpegDecode.swift`) — listagens de tracks feitas na abertura não o veem.

## Relação com outros subsistemas

- **Demux (`MEPlayerItem`)**: produz os `Packet` e roteia por tipo (`MEPlayerItem.swift` → `putPacket`); cria os tracks e chama `options.process` antes. O `FFmpegAssetTrack` (construído no demux, `FFmpegAssetTrack.swift`) é o contrato de entrada do decoder: `codecpar`, `timebase`, `formatDescription`, `pixelFormatType`, `audioDescriptor`, `dovi`, `isConvertNALSize`, `nominalFrameRate`.
- **Filas/threads (`MEPlayerItemTrack`)**: dono do ciclo de vida dos decoders (`makeDecode`, `doFlushCodec` em flush de seek `MEPlayerItemTrack.swift`, `shutdown`), do fallback hw→sw e do descarte pós-seek com `isAccurateSeek`.
- **Render de vídeo (Metal)**: `VideoVTBFrame.corePixelBuffer` é um `PixelBufferProtocol` (`Sources/Lumen/Metal/PixelBufferProtocol.swift`); o caminho 10-bit LE entrega `PixelBuffer` com `MTLBuffer`s prontos. `MetalPlayView` (default `KSOptions.videoPlayerType`, `Model.swift`) consome via `getVideoOutputRender`. Metadata HDR flui por `VideoVTBFrame.edrMetaData` → `CAEDRMetadata` (`Model.swift`).
- **Render de áudio**: `AudioFrame.audioFormat` foi negociado pelo `AudioDescriptor` especificamente para o `KSOptions.audioPlayerType` ativo (`Resample.swift`); `AudioFrame.toPCMBuffer`/`toCMSampleBuffer` (`Model.swift`) fazem a ponte para `AVAudioEngine`/`AVSampleBufferAudioRenderer`. Route changes chegam via `AudioDescriptor.updateAudioFormat` (`Resample.swift`) e são absorvidos pelo `AudioSwresample.change`.
- **Legendas**: `SubtitleDecode` (terceira implementação de `DecodeProtocol`, `SubtitleDecode.swift`) reutiliza `VideoSwresample` para bitmap subs; o decode de vídeo injeta EIA-608 no track de CC dele (`FFmpegDecode.swift`).
- **KSOptions (config global)**: todos os toggles de decode vivem em `Sources/Lumen/AVPlayer/KSOptions.swift` — `hardwareDecode:85`, `asynchronousDecompression:86`, `syncDecodeAudio:72`/`syncDecodeVideo:84` (decidem Sync vs Async track em `MEPlayerItem.swift`), `videoFilters:83`, `audioFilters:71`, `autoDeInterlace:79`, `decoderOptions:45`, `lowres:48`, `codecLowDelay:50`.
