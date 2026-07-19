# 04 — Decodificação

Subsistema de decodificação do MEPlayer (pipeline FFmpeg). Escopo: `Sources/KSPlayer/MEPlayer/` — `FFmpegDecode.swift`, `VideoToolboxDecode.swift`, `AVFFmpegExtension.swift`, `AVFoundationExtension.swift`, `Resample.swift`, `Filter.swift`, `ThumbnailController.swift`.

## Responsabilidade

Converter `Packet` (AVPacket demuxado, produzido pelo `MEPlayerItem`) em `MEFrame` prontos para renderização:

- **Vídeo** → `VideoVTBFrame` contendo um `PixelBufferProtocol` (um `CVPixelBuffer` real ou um `PixelBuffer` baseado em `MTLBuffer`), com metadata HDR (`EDRMetaData`) anexada.
- **Áudio** → `AudioFrame` com PCM já convertido para o `AVAudioFormat` que o player de áudio ativo consome.

Inclui: escolha entre decode por software (libavcodec, com hwaccel VideoToolbox interno) e decode por hardware assíncrono puro (`VTDecompressionSession`); negociação de formato de pixel (AVPixelFormat → OSType/CVPixelBuffer ou MTLBuffer) e de áudio (sample format/canais/layout → AVAudioFormat); grafo de filtros libavfilter por frame; extração de side data (HDR estático, SEI, closed captions, Dolby Vision); e um pipeline standalone de thumbnails.

Fora do escopo deste doc (mas fronteiras diretas): demux (`MEPlayerItem.swift`), filas/threads de decode (`MEPlayerItemTrack.swift`), render Metal (`Sources/KSPlayer/Metal/`), players de áudio (`Audio*Player.swift`), legendas (`SubtitleDecode.swift`).

## Tipos principais

| Tipo | Arquivo | Papel |
|---|---|---|
| `DecodeProtocol` | `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift:293-298` | Contrato dos decoders: `decode()`, `decodeFrame(from:completionHandler:)`, `doFlushCodec()`, `shutdown()` |
| `FFmpegDecode` | `Sources/KSPlayer/MEPlayer/FFmpegDecode.swift:12` | Decoder por software (áudio e vídeo) via `avcodec_send_packet`/`avcodec_receive_frame`; coleta side data, roda filtros e resample; caminho default |
| `VideoToolboxDecode` | `Sources/KSPlayer/MEPlayer/VideoToolboxDecode.swift:13` | Decoder de vídeo 100% hardware, assíncrono, via `VTDecompressionSessionDecodeFrame`; só usado com `asynchronousDecompression` |
| `DecompressionSession` | `Sources/KSPlayer/MEPlayer/VideoToolboxDecode.swift:111-156` | Wrapper de `VTDecompressionSession` + `CMFormatDescription`; configura atributos de pixel buffer, HDR passthrough e pixel transfer |
| `MEFilter` | `Sources/KSPlayer/MEPlayer/Filter.swift:12` | Grafo libavfilter (`buffer`/`abuffer` → filtros do usuário → `buffersink`), reconfigurado lazy quando params/filtros mudam |
| `FrameChange` (protocol) | `Sources/KSPlayer/MEPlayer/Resample.swift:20-23` | `AVFrame` → `MEFrame` (etapa final do decode sw) |
| `FrameTransfer` (protocol) | `Sources/KSPlayer/MEPlayer/Resample.swift:15-18` | `AVFrame` → `AVFrame` (conversão intermediária) |
| `VideoSwscale` | `Sources/KSPlayer/MEPlayer/Resample.swift:25-65` | Conversão sws AVFrame→AVFrame. **Código morto** — nunca instanciado no pacote |
| `VideoSwresample` | `Sources/KSPlayer/MEPlayer/Resample.swift:67-212` | AVFrame de vídeo → `VideoVTBFrame`: desembrulha CVPixelBuffer de hwaccel, ou copia/converte para pool de CVPixelBuffer, ou cria `PixelBuffer` MTLBuffer p/ 10-bit planar LE |
| `AudioSwresample` | `Sources/KSPlayer/MEPlayer/Resample.swift:223-269` | swr_convert do formato do frame para o `AVAudioFormat` negociado; reconfigura ao detectar mudança de formato/rota |
| `AudioDescriptor` | `Sources/KSPlayer/MEPlayer/Resample.swift:271-384` | Negociação do formato de áudio de saída (sample format, canais, layout tag) em função do `KSOptions.audioPlayerType` e do hardware |
| `ThumbnailController` | `Sources/KSPlayer/MEPlayer/ThumbnailController.swift:24` | Pipeline independente (demux+decode+scale próprios) que gera N thumbnails por seek |
| `FFThumbnail` / `ThumbnailControllerDelegate` | `Sources/KSPlayer/MEPlayer/ThumbnailController.swift:15-22` | Resultado (UIImage + tempo) e callback de progresso |
| `UnsafeMutablePointer<AVCodecContext>.getFormat()` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:19-55` | Instala callback `get_format` que negocia `AV_PIX_FMT_VIDEOTOOLBOX` (hwaccel dentro do decode sw) |
| `AVCodecParameters.createContext(options:)` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:79-121` | Criação e abertura do `AVCodecContext` (flags, lowres, decoderOptions, hwaccel) |
| `AVPixelFormat.osType(fullRange:)` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:282-323` | Mapa AVPixelFormat → OSType CoreVideo (formatos representáveis sem conversão) |
| `AVPixelFormat.bestPixelFormat` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:259-278` | Alvo de conversão sws (equivalente ao `videotoolbox_best_pixel_format` do FFmpeg: NV12/P010/NV16/P210/NV24/P410/P416/AYUV64) |
| `AVPixelFormat.leftShift` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:250-256` | Marca YUV420P10LE/422P10LE/444P10LE (shift 6) → caminho `PixelBuffer` sem swscale |
| `AVColorPrimaries/AVColorTransferCharacteristic/AVColorSpace/AVChromaLocation` (extensões) | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:149-227` | Mapas FFmpeg → constantes `kCVImageBuffer*` de cor |
| `AVCodecID.mediaSubType` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:326-377` | Mapa codec FFmpeg → `CMFormatDescription.MediaSubType` |
| `CMVideoCodecType.avc` | `Sources/KSPlayer/MEPlayer/VideoToolboxDecode.swift:202-216` | Nome do atom de extradata (`avcC`/`hvcC`/`vpcC`/`esds`) usado no `CMFormatDescription` |
| `AVBufferSrcParameters` (ext.) | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:385-398` | Igualdade + string de args do buffersrc; base da detecção de reconfiguração do `MEFilter` |
| `Dictionary.avOptions` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:447-467` | `[String: Any]` → `AVDictionary` para `avcodec_open2` |
| `AVError` + `NSError(errorCode:avErrorCode:)` | `Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift:437-550` | Tipagem dos códigos de erro FFmpeg |
| `CVPixelBufferPool.create(...)` | `Sources/KSPlayer/MEPlayer/AVFoundationExtension.swift:24-39` | Pool Metal-compatible + IOSurface usado pelo `VideoSwresample` |
| `layoutMapTuple` | `Sources/KSPlayer/MEPlayer/AVFoundationExtension.swift:191-217` | Tabela AudioChannelLayoutTag ↔ máscara de canais FFmpeg |
| `AudioChannelLabel.avChannel` | `Sources/KSPlayer/MEPlayer/AVFoundationExtension.swift:229-333` | Mapa label CoreAudio → `AVChannel` FFmpeg (montagem de máscara custom) |
| `AVAudioFormat.sampleFormat`/`sampleSize` | `Sources/KSPlayer/MEPlayer/AVFoundationExtension.swift:151-189` | Mapa AVAudioCommonFormat ↔ AVSampleFormat, tamanho de sample |
| `AVAudioChannelLayout.channelLayout()` | `Sources/KSPlayer/MEPlayer/AVFoundationExtension.swift:114-144` | Layout CoreAudio → `AVChannelLayout` FFmpeg (usado por players de áudio p/ route change) |

## Fluxo de dados

### Seleção do decoder

1. `MEPlayerItem` cria os tracks (`MEPlayerItem.swift:379` vídeo, `:412` áudio) e antes chama `options.process(assetTrack:)` (`MEPlayerItem.swift:377,408`; implementação em `Sources/KSPlayer/AVPlayer/KSOptions.swift:310-336` — ex.: conteúdo entrelaçado desliga `hardwareDecode` e injeta `yadif` nos `videoFilters`).
2. No primeiro `Packet` de cada `trackID`, `SyncPlayerItemTrack.doDecode` cria o decoder via `makeDecode(assetTrack:)` (`MEPlayerItemTrack.swift:130`, `:300-316`):
   - subtitle → `SubtitleDecode`;
   - vídeo com `options.asynchronousDecompression && options.hardwareDecode` e `DecompressionSession` criável → `VideoToolboxDecode`;
   - qualquer outro caso → `FFmpegDecode`.
3. Defaults: `KSOptions.hardwareDecode = true` (`KSOptions.swift:477`), `KSOptions.asynchronousDecompression = false` (`KSOptions.swift:479`). **Portanto o caminho default é `FFmpegDecode` com hwaccel VideoToolbox interno** (frames `AV_PIX_FMT_VIDEOTOOLBOX`), não o `VideoToolboxDecode`.
4. Fallback hw→sw: se `VideoToolboxDecode` reporta erro, o track faz `shutdown()`, substitui por `FFmpegDecode` e redecodifica o mesmo packet (`MEPlayerItemTrack.swift:158-167`).

### Caminho software — `FFmpegDecode`

1. **Init** (`FFmpegDecode.swift:20-35`): `assetTrack.createContext(options:)` (`FFmpegAssetTrack.swift:261-263` → `AVCodecParameters.createContext`, `AVFFmpegExtension.swift:79-121`). Nesta criação: `avcodec_parameters_to_context`; se vídeo e `options.hardwareDecode`, instala `getFormat()` (`AVFFmpegExtension.swift:90-92`) — o callback percorre a lista de formatos e, achando `AV_PIX_FMT_VIDEOTOOLBOX`, aloca `hw_device_ctx` (`av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX)`, `AVFFmpegExtension.swift:27-48`; `hw_frames_ctx` intencionalmente não é criado, comentário na linha 32); seta `AV_CODEC_FLAG2_FAST` (`:98`), `AV_CODEC_FLAG_LOW_DELAY` se `options.codecLowDelay` (`:99-101`), `lowres` com clamp em `max_lowres` (`:104-111`), e abre com `options.decoderOptions.avOptions` (`:102,113`). Depois cria `MEFilter` (`FFmpegDecode.swift:29`) e o `FrameChange`: `VideoSwresample(fps:isDovi:)` para vídeo, `AudioSwresample(audioDescriptor:)` para áudio (`FFmpegDecode.swift:30-34`).
2. **`decodeFrame`** (`FFmpegDecode.swift:37-186`), chamado pela thread de decode do track:
   - `avcodec_send_packet` (`:38`); retorno != 0 é ignorado silenciosamente (packet descartado).
   - Se o codec expõe `FF_CODEC_PROPERTY_CLOSED_CAPTIONS`, cria lazy um track de legendas EIA-608 pendurado em `packet.assetTrack.closedCaptionsTrack` (`:42-57`).
   - Loop `avcodec_receive_frame` (`:58-185`). Para cada frame, varre `side_data` **antes** dos filtros (filtro descarta side data, comentário `:64`):
     - `AV_FRAME_DATA_A53_CC` → re-empacota como `Packet` e injeta no track de CC (`:68-87`);
     - `AV_FRAME_DATA_SEI_UNREGISTERED` → `options.sei(string:)` (`:88-93`);
     - `AV_FRAME_DATA_DOVI_RPU_BUFFER` / `DOVI_METADATA` / `DYNAMIC_HDR_PLUS` / `DYNAMIC_HDR_VIVID` → **lidos e descartados** (`:94-105`, variáveis locais sem uso);
     - `MASTERING_DISPLAY_METADATA`, `CONTENT_LIGHT_LEVEL`, `AMBIENT_VIEWING_ENVIRONMENT` → structs big-endian para `EDRMetaData` (`:106-133`).
   - `filter.filter(options:inputFrame:completionHandler:)` (`:137`) — sem filtros configurados é passthrough síncrono.
   - `frameChange.change(avframe:)` (`:139`) produz o `MEFrame`; se o resultado é `VideoVTBFrame` com `PixelBuffer` (sw), anexa o `formatDescription` do track (`:140-143`) e a `edrMetaData` (`:144-146`).
   - Timestamps: `frame.timebase = filter.timebase` (`:148`); duration de áudio derivada de `nb_samples` quando 0 (`:153-155`); timestamp em cascata `best_effort_timestamp` → `pts` → `pkt_dts` → acumulador `bestEffortTimestamp` (`:156-167`).
   - Fim do loop: `AVERROR_EOF` → `avcodec_flush_buffers` + break (`:174-176`); `EAGAIN` → break (`:177-178`); erro → `NSError` com `.codecAudioReceiveFrame`/`.codecVideoReceiveFrame` (`:179-183`).
3. **Flush/shutdown**: `doFlushCodec` zera `bestEffortTimestamp` e `avcodec_flush_buffers` (`:188-192`); `shutdown` libera frame, contexto e `frameChange` (`:194-198`).

### Caminho hardware — `VideoToolboxDecode`

1. **`DecompressionSession.init`** (`VideoToolboxDecode.swift:115-155`): exige `assetTrack.pixelFormatType` (`FFmpegAssetTrack.swift:280-284`) e `assetTrack.formatDescription` (construído em `FFmpegAssetTrack.swift:143-255` com atoms `avcC`/`hvcC`/`vpcC` e a chave `RequireHardwareAcceleratedVideoDecoder`/`EnableHardwareAcceleratedVideoDecoder`, `:225`). Atributos do pixel buffer: Metal-compatible + IOSurface (`VideoToolboxDecode.swift:128-134`). `VTDecompressionSessionCreate` com `decoderSpecification = CMFormatDescriptionGetExtensions(formatDescription)` (`:137`). Extras: `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` (`:142-145`) e pixel transfer para o dynamic range de destino de `options.availableDynamicRange(nil)` (`:146-153`; método em `KSOptions.swift:403`).
2. **`decodeFrame`** (`VideoToolboxDecode.swift:30-94`):
   - `needReconfig` (setado após falha em non-keyframe, tipicamente volta de background) recria a sessão e flusha (`:31-36`).
   - `getSampleBuffer(isConvertNALSize:data:size:)` (`:160-184`): se `assetTrack.isConvertNALSize` (detectado por `extradata[4] == 0xFE` em `FFmpegAssetTrack.swift:188-193`), reescreve NALs com length de 3 bytes para 4 via `avio_open_dyn_buf`; senão embrulha o data do packet direto em `CMBlockBuffer`/`CMSampleBuffer` (`:186-199`).
   - `VTDecompressionSessionDecodeFrame` com `._EnableAsynchronousDecompression` (`:42-50`); o callback roda em thread interna do VT:
     - frames com `.frameDropped` são ignorados (`:51-53`);
     - erros `kVTInvalidSessionErr`/`MalfunctionErr`/`BadDataErr`: keyframe → `completionHandler(.failure)` (dispara o fallback sw do track); non-keyframe → `needReconfig = true` e descarte silencioso (`:54-63`, mesmo tratamento no retorno síncrono `:83-90`);
     - sucesso → `VideoVTBFrame` com `imageBuffer`, `timebase` do track (`:65-67`); ajuste de relógio para packets `AV_PKT_FLAG_DISCARD` pós-seek via `startTime`/`lastPosition` (`:68-76`).

### Conversão de vídeo — `VideoSwresample.change` (`Resample.swift:86-94`)

- Frame `AV_PIX_FMT_VIDEOTOOLBOX` (hwaccel): `unsafeBitCast(avframe.pointee.data.3, to: CVPixelBuffer.self)` — convenção FFmpeg de que `data[3]` é o `CVPixelBufferRef` (`:88-90`).
- Frame de sw com `format.leftShift > 0` (YUV 10-bit planar LE): `PixelBuffer(frame:)` (`Resample.swift:124-126` → `Sources/KSPlayer/Metal/PixelBufferProtocol.swift:187`), que copia os planos direto para `MTLBuffer`s — o shift de 6 bits é compensado nos shaders.
- Demais: `setup` (`Resample.swift:96-118`) decide — se `format.osType()` existe, sem conversão (só memcpy pro pool); senão `sws_getCachedContext` para `format.bestPixelFormat`. O destino sai de `CVPixelBufferPool.create` (`AVFoundationExtension.swift:24-39`, alinhamento 64, 24 buffers). `transfer(format:width:height:data:linesize:)` (`Resample.swift:146-206`) faz `sws_scale` ou cópia plano a plano (com merge U+V → semi-planar quando o pool tem menos planos que a origem, `:176-191`). Atributos de cor no buffer: `yCbCrMatrix`/`colorPrimaries`/`transferFunction`/gamma/chroma/colorspace (`:128-142`, usando os mapas de `AVFFmpegExtension.swift:149-227` e `KSOptions.colorSpace` em `Model.swift:89-116`).

### Conversão de áudio — `AudioDescriptor` + `AudioSwresample`

1. `AudioDescriptor` nasce no `FFmpegAssetTrack` (`FFmpegAssetTrack.swift:146`) a partir do `codecpar`. `init` (`Resample.swift:291-306`): sample rate default 48000 se inválido; canais de saída = 2 no macOS, senão `KSOptions.outputNumberOfChannels(channelCount:)` (`KSOptions.swift:522`, consulta `AVAudioSession`).
2. `AudioDescriptor.audioFormat(...)` (`Resample.swift:320-374`): resolve `AudioChannelLayoutTag` via `layoutMapTuple` (`AVFoundationExtension.swift:191-217`) com fallbacks progressivos para layout default e por fim estéreo; `interleaved = (KSOptions.audioPlayerType == AudioRendererPlayer.self)` (`:368`); `commonFormat` forçado para Float32 exceto para `AudioRendererPlayer`/`AudioUnitPlayer` (`:369-371`).
3. `AudioSwresample.change` (`Resample.swift:245-264`): se o `AVFrame` divergiu do descriptor ou `outChannel` mudou (route change via `updateAudioFormat`, `:376-383`), recria o `SwrContext` (`swr_alloc_set_opts2` + `swr_init`, `:233-243`); `swr_convert` preenche um `AudioFrame` dimensionado por `av_samples_get_buffer_size` (`:254-263`).

### Pós-decode

O `completionHandler` de `decodeFrame` empurra o frame para `outputRenderQueue` do track (`MEPlayerItemTrack.swift:154-157`; fila de vídeo é `sorted` — `:59-61` — para reordenar B-frames/callbacks fora de ordem). Dali os renders puxam via `getOutputRender` (`:94-102`).

### Thumbnails — `ThumbnailController`

Pipeline totalmente independente do player: abre o próprio `AVFormatContext` (`ThumbnailController.swift:45-56`), acha o primeiro stream de vídeo (`:57-66`), cria contexto **sem options** (sem hwaccel, `:72`), instancia `VideoSwresample(dstWidth:dstHeight:)` (`:78-79`), rescala a duração global para o timebase do stream (`:82-84`) e, para cada um dos `thumbnailCount` pontos: `av_seek_frame(AVSEEK_FLAG_BACKWARD)` + flush + decode de 1 frame + `cgImage()` (`:94-127`). Reporta progresso via `ThumbnailControllerDelegate.didUpdate` (`:122`) e retorna `[FFThumbnail]`; `generateThumbnail(for:thumbWidth:)` roda tudo dentro de um `Task` (`:31-35`).

## Pontos de extensão

- **Novo decoder**: implementar `DecodeProtocol` (`MEPlayerItemTrack.swift:293-298`) e plugar a seleção em `SyncPlayerItemTrack.makeDecode(assetTrack:)` (`MEPlayerItemTrack.swift:300-316`). É o único ponto de decisão sw/hw/subtitle.
- **Dolby Vision / HDR dinâmico (paridade Infuse)**: os hooks já existem e estão vazios — `FFmpegDecode.swift:94-105` lê `AV_FRAME_DATA_DOVI_RPU_BUFFER`, `AV_FRAME_DATA_DOVI_METADATA` (com `av_dovi_get_header/mapping/color` já chamados), `DYNAMIC_HDR_PLUS` e `DYNAMIC_HDR_VIVID` e joga fora. Processamento por frame entra aí; o transporte até o render é `VideoVTBFrame.edrMetaData` (`Model.swift:429`, consumido por `edrMetadata` → `CAEDRMetadata` em `Model.swift:437-462`). O flag `isDovi` já viaja no frame (`Model.swift:428`, setado em `FFmpegDecode.swift:31` e `VideoToolboxDecode.swift:65` a partir de `assetTrack.dovi`, que vem de `AV_PKT_DATA_DOVI_CONF` em `FFmpegAssetTrack.swift:164-180`).
- **Filtros FFmpeg em runtime**: `options.videoFilters`/`options.audioFilters` (`KSOptions.swift:83,71`) são lidos a cada frame (`Filter.swift:105-117`) e o grafo é reconstruído quando a string ou os parâmetros do frame mudam (`Filter.swift:131-137`) — dá para adicionar/remover filtros com o vídeo rodando. `options.autoDeInterlace` injeta `idet` automaticamente (`Filter.swift:110-112`) e o feedback do idet volta por `options.filter(log:)` (`KSOptions.swift:271-301`).
- **Hook pré-decoder**: `KSOptions.process(assetTrack:)` (`KSOptions.swift:310-336`) — chamado por track antes de criar o decoder (`MEPlayerItem.swift:377,408`); lugar certo para ajustar `hardwareDecode`, filtros, `nominalFrameRate` por características do stream.
- **SEI custom**: sobrescrever `KSOptions.sei(string:)` (`KSOptions.swift:303-305`), alimentado por `FFmpegDecode.swift:88-93`.
- **Opções do codec**: `options.decoderOptions` (`KSOptions.swift:45`; defaults `threads=auto`, `refcounted_frames=1` em `:131-132`) vira `AVDictionary` no `avcodec_open2` (`AVFFmpegExtension.swift:102,113`). `options.lowres` (`KSOptions.swift:48`) e `options.codecLowDelay` (`:50`) também entram por aí.
- **Dynamic range de saída da sessão VT**: sobrescrever `KSOptions.availableDynamicRange(_:)` (`KSOptions.swift:403`) muda o pixel transfer configurado em `VideoToolboxDecode.swift:146-153`.
- **Novo formato de pixel suportado**: adicionar o mapeamento em `AVPixelFormat.osType(fullRange:)` (`AVFFmpegExtension.swift:282-323`) evita swscale; se o Metal precisar de layout de plano novo, ajustar `KSOptions.pixelFormat(planeCount:bitDepth:)` (`Model.swift:141-157`) e os shaders.
- **Nova conversão de frame**: implementar `FrameChange` (`Resample.swift:20-23`) e trocar a atribuição em `FFmpegDecode.init` (`FFmpegDecode.swift:30-34`).
- **Thumbnails**: `ThumbnailControllerDelegate` (`ThumbnailController.swift:20-22`) para progresso incremental; `thumbnailCount` e `thumbWidth` são os únicos knobs (`:27,31`).

## Pegadinhas

- **`VideoToolboxDecode` quase nunca roda**: com os defaults (`asynchronousDecompression = false`), todo o decode "hardware" acontece dentro do `FFmpegDecode` via hwaccel (`get_format` → `AV_PIX_FMT_VIDEOTOOLBOX`). Mudanças em `VideoToolboxDecode.swift` não afetam o caminho default; o equivalente hwaccel está em `AVFFmpegExtension.swift:19-55` + `Resample.swift:88-90`.
- **Threading do completionHandler**: `FFmpegDecode.decodeFrame` é síncrono na thread de decode do track (OperationQueue serial `KSPlayer_video`/`KSPlayer_audio`, `MEPlayerItemTrack.swift:204-231`, com `stackSize` custom `:225`), e pode chamar o handler N vezes por packet. `VideoToolboxDecode` chama o handler em **thread interna do VideoToolbox** (flag `._EnableAsynchronousDecompression`, `VideoToolboxDecode.swift:42-44`), fora de ordem — por isso a fila de vídeo é `sorted` (`MEPlayerItemTrack.swift:59-61`). Estado mutável do decoder (`lastPosition`, `startTime`, `needReconfig`) é tocado dessa thread sem lock.
- **Falha silenciosa de `avcodec_send_packet`**: retorno != 0 simplesmente descarta o packet (`FFmpegDecode.swift:38-40`) — sem log, sem erro. Em debugging de "frames faltando", começar aqui.
- **Timebase após filtros**: `frame.timebase = filter.timebase` (`FFmpegDecode.swift:148`) é o timebase **do track na criação**; a leitura do timebase real do buffersink está comentada (`Filter.swift:144`, `FFmpegDecode.swift:149`). Filtros que alteram timing (yadif mode 1 dobra o fps) dependem do ajuste manual de `nominalFrameRate` em `KSOptions.process` (`KSOptions.swift:331-333`).
- **Ordem no packet de closed captions**: `Packet.assetTrack` tem `didSet` que copia pts/pos/duration/size do `corePacket` (`Model.swift:213-223`). Em `FFmpegDecode.swift:72-85` os campos do `corePacket` são preenchidos **antes** de setar `assetTrack` — inverter a ordem quebra os timestamps do CC.
- **Bug real em mastering display**: `display_primaries_b_x` usa `data.display_primaries.2.1.num` (deveria ser `2.0`) — x e y do primário azul saem iguais (`FFmpegDecode.swift:113-114`). Herdado do upstream; corrigir ao trabalhar HDR10.
- **Big-endian e denominadores assumidos**: os structs de `EDRMetaData` são convertidos com `.bigEndian` porque `CAEDRMetadata.hdr10(displayInfo:contentInfo:)` espera payload SEI big-endian (`FFmpegDecode.swift:108-125`, consumo em `Model.swift:441-445`). Só o `.num` dos `AVRational` é usado — assume os denominadores canônicos do FFmpeg (50000 para primaries, 10000 para luminância).
- **`AudioDescriptor` depende de estado global estático**: `interleaved`/`commonFormat` derivam de `KSOptions.audioPlayerType` (`Resample.swift:368-371`, default `AudioEnginePlayer` em `Model.swift:85`). Trocar o player de áudio depois que tracks foram criados gera formato incompatível — definir antes de abrir a mídia.
- **`outChannel` é mutado por `inout`**: `AudioDescriptor.audioFormat(...)` reescreve `outChannel` via `av_channel_layout_default` nos fallbacks (`Resample.swift:320-335`); `AudioSwresample.change` usa exatamente essa mutação (`outChannel != descriptor.outChannel`) para detectar route change (`Resample.swift:246`). Não "simplificar" removendo o `inout`.
- **Erro não fatal vira descarte no VT**: falha de decode em non-keyframe só seta `needReconfig` e retorna (`VideoToolboxDecode.swift:58-61,86-89`) — todos os frames até o próximo keyframe somem sem nenhum sinal externo. O fallback para software só dispara se a falha ocorre num keyframe.
- **Invalidação da sessão VT**: `session.didSet` invalida a sessão antiga (`VideoToolboxDecode.swift:14-18`) e `shutdown` invalida a atual (`:101-103`). Substituir a sessão por outro caminho sem passar pelo `didSet` vaza uma `VTDecompressionSession`.
- **`VideoSwscale` é código morto** (`Resample.swift:25-65`): nunca instanciado; a classe viva é `VideoSwresample`. `seekByBytes` em `FFmpegDecode` (`FFmpegDecode.swift:19,22`) também é armazenado e nunca lido.
- **`swr_alloc_set_opts2` com resultado sobrescrito**: `Resample.swift:234-235` ignora o retorno da alocação (a variável `result` é reatribuída pelo `swr_init`); falha de alocação só é percebida indiretamente.
- **Force-unwraps latentes**: `assetTrack.audioDescriptor!` (`FFmpegDecode.swift:33`), `dstFormat.osType()!` (`Resample.swift:112` — pressupõe que todo `bestPixelFormat` tem OSType), `DecompressionSession(...)!` no reconfig (`VideoToolboxDecode.swift:33`). Este último crasha se a recriação da sessão falhar (ex. formato que perdeu suporte após background).
- **`ThumbnailController`**: usa `avcodec_close` deprecado (`ThumbnailController.swift:74`); o `Task` não checa cancelamento entre os até 100 seeks (`:94`); o delegate é chamado na thread do `Task`; streams sem `avg_frame_rate` ou duração inválida lançam erro cedo (`:69-71`).
- **Ordem de inicialização do CC track**: o track de closed captions só passa a existir depois do primeiro packet com a propriedade `FF_CODEC_PROPERTY_CLOSED_CAPTIONS` (`FFmpegDecode.swift:41-57`) — listagens de tracks feitas na abertura não o veem.

## Relação com outros subsistemas

- **Demux (`MEPlayerItem`)**: produz os `Packet` e roteia por tipo (`MEPlayerItem.swift:558-565` → `putPacket`); cria os tracks e chama `options.process` antes (`:377-412`). O `FFmpegAssetTrack` (construído no demux, `FFmpegAssetTrack.swift:71-259`) é o contrato de entrada do decoder: `codecpar`, `timebase`, `formatDescription`, `pixelFormatType`, `audioDescriptor`, `dovi`, `isConvertNALSize`, `nominalFrameRate`.
- **Filas/threads (`MEPlayerItemTrack`)**: dono do ciclo de vida dos decoders (`makeDecode`, `doFlushCodec` em flush de seek `MEPlayerItemTrack.swift:85-87,245-247`, `shutdown` `:241-243`), do fallback hw→sw (`:158-167`) e do descarte pós-seek com `isAccurateSeek` (`:145-153`).
- **Render de vídeo (Metal)**: `VideoVTBFrame.corePixelBuffer` é um `PixelBufferProtocol` (`Sources/KSPlayer/Metal/PixelBufferProtocol.swift:18`); o caminho 10-bit LE entrega `PixelBuffer` com `MTLBuffer`s prontos (`:166-229`). `MetalPlayView` (default `KSOptions.videoPlayerType`, `Model.swift:86`) consome via `getVideoOutputRender`. Metadata HDR flui por `VideoVTBFrame.edrMetaData` → `CAEDRMetadata` (`Model.swift:437-462`).
- **Render de áudio**: `AudioFrame.audioFormat` foi negociado pelo `AudioDescriptor` especificamente para o `KSOptions.audioPlayerType` ativo (`Resample.swift:368-371`); `AudioFrame.toPCMBuffer`/`toCMSampleBuffer` (`Model.swift:333-417`) fazem a ponte para `AVAudioEngine`/`AVSampleBufferAudioRenderer`. Route changes chegam via `AudioDescriptor.updateAudioFormat` (`Resample.swift:376-383`) e são absorvidos pelo `AudioSwresample.change`.
- **Legendas**: `SubtitleDecode` (terceira implementação de `DecodeProtocol`, `SubtitleDecode.swift:16`) reutiliza `VideoSwresample` para bitmap subs (`:18,112`); o decode de vídeo injeta EIA-608 no track de CC dele (`FFmpegDecode.swift:68-87`).
- **KSOptions (config global)**: todos os toggles de decode vivem em `Sources/KSPlayer/AVPlayer/KSOptions.swift` — `hardwareDecode:85`, `asynchronousDecompression:86`, `syncDecodeAudio:72`/`syncDecodeVideo:84` (decidem Sync vs Async track em `MEPlayerItem.swift:379,412`), `videoFilters:83`, `audioFilters:71`, `autoDeInterlace:79`, `decoderOptions:45`, `lowres:48`, `codecLowDelay:50`.
