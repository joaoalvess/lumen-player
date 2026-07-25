# 03 — Engine MEPlayer: demux e pipeline

Subsistema: `Sources/Lumen/MEPlayer/` — núcleo FFmpeg do player. Cobre `KSMEPlayer`, `MEPlayerItem`, `MEPlayerItemTrack`, `Model.swift`, `CircularBuffer`, `EmbedDataSouce`, `FFmpegAssetTrack`. Este documento também cobre dois subsistemas que se apoiam no mesmo demuxer: o engine **ProAV** (`ProAV*.swift`) e o **cache de disco** (`Sources/Lumen/Cache/`).

## Responsabilidade

Transformar um `URL` em playback A/V sincronizado usando FFmpeg como demuxer/decoder:

1. **Demux**: abrir o container via `avformat_open_input`, descobrir streams (`avformat_find_stream_info`) e mapeá-los para `FFmpegAssetTrack`.
2. **Pipeline por trilha**: para cada trilha habilitada, manter uma fila de `Packet` (comprimidos) e uma fila de `MEFrame` (decodificados) conectadas por um decoder (`FFmpegDecode`/`VideoToolboxDecode`/`SubtitleDecode`).
3. **Clocks e sincronização A/V**: manter `audioClock`/`videoClock` (`KSClock`), eleger o clock mestre (áudio, com fallback para vídeo) e decidir por frame se o vídeo renderiza, espera, dropa frame/packet/GOP ou flusha.
4. **Backpressure**: pausar/retomar a thread de leitura conforme a ocupação dos buffers (`maxBufferDuration`), e reportar `LoadingState` para a UI (buffering %).
5. **Fachada pública**: `KSMEPlayer` implementa `MediaPlayerProtocol` (mesma interface do `KSAVPlayer`), agregando saídas de áudio (`AudioOutput`) e vídeo (`VideoOutput`), PiP, `AVPlaybackCoordinator` (SharePlay) e gravação (remux para arquivo).

O modelo é **pull-based na saída**: os renderizadores (Metal/AudioEngine) puxam frames do `MEPlayerItem` via `OutputRenderSourceDelegate`; e **push-based na entrada**: a thread de leitura empurra packets para as trilhas.

## Tipos principais

| Tipo | Arquivo | Papel |
|---|---|---|
| `KSMEPlayer` | `Sources/Lumen/MEPlayer/KSMEPlayer.swift` | Fachada `MediaPlayerProtocol`. Compõe `MEPlayerItem` + `AudioOutput` + `VideoOutput`, gerencia `playbackState`/`loadState`, PiP, playback coordinator, notificações de rota de áudio. |
| `MEPlayerItem` | `Sources/Lumen/MEPlayer/MEPlayerItem.swift` | Dono do `AVFormatContext`. Threads de open/read/close via `OperationQueue` serial, seek, clocks, seleção de trilha, adaptação de bitrate, gravação (remux) e fonte de frames para os renderizadores. |
| `MESourceState` | `Sources/Lumen/MEPlayer/Model.swift` | Máquina de estados do item: `idle → opening → opened → reading ⇄ (seeking/paused) → finished/closed/failed`. |
| `PlayerItemTrackProtocol` | `Sources/Lumen/MEPlayer/MEPlayerItemTrack.swift` | Contrato de uma trilha de decodificação: `decode`, `seek(time:)`, `putPacket(packet:)`, `shutdown`, flags `isEndOfFile`/`isLoopModel`. Estende `CapacityProtocol`. |
| `SyncPlayerItemTrack<Frame>` | `Sources/Lumen/MEPlayer/MEPlayerItemTrack.swift` | Trilha síncrona: decodifica no ato do `putPacket` (thread de leitura). Usada para legendas sempre, e para A/V quando `options.syncDecodeAudio/Video`. Mantém `outputRenderQueue: CircularBuffer<Frame>`. |
| `AsyncPlayerItemTrack<Frame>` | `Sources/Lumen/MEPlayer/MEPlayerItemTrack.swift` | Subclasse assíncrona: adiciona `packetQueue: CircularBuffer<Packet>` e uma thread própria de decode (`decodeThread`, `MEPlayerItemTrack.swift`). Default para A/V. |
| `DecodeProtocol` | `Sources/Lumen/MEPlayer/MEPlayerItemTrack.swift` | Contrato do decoder concreto: `decodeFrame(from:completionHandler:)`, `doFlushCodec`, `shutdown`. Implementações: `FFmpegDecode`, `VideoToolboxDecode`, `SubtitleDecode`. |
| `CircularBuffer<Item>` | `Sources/Lumen/MEPlayer/CircularBuffer.swift` | Fila circular bloqueante (NSCondition), opcionalmente ordenada por `timestamp` (insertion sort no push, `CircularBuffer.swift`) e opcionalmente expansível (dobra capacidade, `CircularBuffer.swift`). Backpressure: `push` bloqueia quando cheia e não-expansível (`CircularBuffer.swift`). |
| `Packet` | `Sources/Lumen/MEPlayer/Model.swift` | Wrapper de `AVPacket*`. `assetTrack` didSet copia pts/dts/pos/duration/size (`Model.swift`). Libera o packet no `deinit`. |
| `MEFrame` | `Sources/Lumen/MEPlayer/Model.swift` | Protocolo de frame decodificado (`ObjectQueueItem` + timebase mutável). Implementações: `AudioFrame`, `VideoVTBFrame`, `SubtitleFrame`. |
| `AudioFrame` | `Sources/Lumen/MEPlayer/Model.swift` | PCM decodificado (planar ou interleaved). Conversões: `toPCMBuffer` (`Model.swift`) para AVAudioEngine, `toCMSampleBuffer` (`Model.swift`) para `AVSampleBufferAudioRenderer`. |
| `VideoVTBFrame` | `Sources/Lumen/MEPlayer/Model.swift` | Frame de vídeo com `corePixelBuffer: PixelBufferProtocol?`, `fps`, `isDovi` e `edrMetaData` (HDR10/HLG → `CAEDRMetadata`, `Model.swift`). |
| `SubtitleFrame` | `Sources/Lumen/MEPlayer/Model.swift` | `SubtitlePart` + timebase. |
| `FFmpegAssetTrack` | `Sources/Lumen/MEPlayer/FFmpegAssetTrack.swift` | Metadados de um `AVStream`: codec, timebase, fps nominal, rotação, DOVI, `CMFormatDescription`, `AudioDescriptor`. `isEnabled` mapeia direto para `stream.discard` (`FFmpegAssetTrack.swift`). |
| `Timebase` | `Sources/Lumen/MEPlayer/Model.swift` | num/den ↔ `AVRational`; converte timestamp ↔ `CMTime`. |
| `KSClock` | `Sources/Lumen/AVPlayer/KSOptions.swift` | `time: CMTime` + `lastMediaTime` (host time); `getTime` extrapola o tempo atual (`KSOptions.swift`). |
| `MEPlayerDelegate` | `Sources/Lumen/MEPlayer/Model.swift` | Callbacks do item para o player: `sourceDidOpened/Failed/Finished`, `sourceDidChange(loadingState:)`, mudança de bitrate. |
| `CodecCapacityDelegate` | `Sources/Lumen/MEPlayer/Model.swift` | Trilha → item: `codecDidFinished(track:)` (fim real do playback). |
| `OutputRenderSourceDelegate` | `Sources/Lumen/MEPlayer/Model.swift` | Renderizador → item: `getVideoOutputRender(force:)`, `getAudioOutputRender`, `setVideo/setAudio(time:position:)`. |
| `FrameOutput`/`AudioOutput`/`VideoOutput` | `Model.swift`, `AudioEnginePlayer.swift`, `MetalPlayView.swift` | Saídas plugáveis; instanciadas por `KSOptions.audioPlayerType`/`videoPlayerType` (`Model.swift`). |
| `EmbedDataSouce` (extensões) | `Sources/Lumen/MEPlayer/EmbedDataSouce.swift` | Expõe trilhas de legenda embutidas como `SubtitleInfo`/`KSSubtitleProtocol`; `KSMEPlayer` vira `SubtitleDataSouce`. |

## Fluxo de dados

### 1. Construção e abertura

1. `KSMEPlayer.init(url:options:)` (`KSMEPlayer.swift`): cria `audioOutput = KSOptions.audioPlayerType.init`, `playerItem = MEPlayerItem(url:options:)`, `videoOutput = KSOptions.videoPlayerType.init(options:)` (`nil` se `options.videoDisable`). Liga `playerItem.delegate = self` e injeta `playerItem` como `renderSource` das duas saídas.
2. `prepareToPlay` (`KSMEPlayer.swift` → `MEPlayerItem.prepareToPlay`, `MEPlayerItem.swift`): estado `.opening`, enfileira `openOperation` numa `OperationQueue` serial (`maxConcurrentOperationCount = 1`, `MEPlayerItem.swift`).
3. `openThread` (`MEPlayerItem.swift`):
 - `avformat_alloc_context` + `interrupt_callback` que aborta I/O quando o estado é `finished/closed/failed` (`MEPlayerItem.swift`).
 - I/O custom: se `options.process(url:)` retorna um `AbstractAVIOContext` (`KSOptions.swift`), `formatCtx.pb` recebe o `AVIOContext` criado por `AbstractAVIOContext.getContext` (`MEPlayerItem.swift`) — é assim que protocolos custom (ex.: SMB, cache) entram.
 - `avformat_open_input` com `options.formatContextOptions` como `AVDictionary`; depois flags `AVFMT_FLAG_GENPTS`, `nobuffer`, `probesize`/`maxAnalyzeDuration`, `avformat_find_stream_info`.
 - Deriva: `maxFrameDuration`, `seekByBytes` (formatos `TS_DISCONT` exceto ogg), `startTime` do container (semeia os dois clocks), `duration`, `fileSize`, capítulos.
 - `createCodec(formatCtx:)` monta as trilhas; se nem vídeo nem áudio existirem → `.failed`, senão `state = .opened` (dispara `sourceDidOpened`) e `read`.

### 2. Criação de trilhas — `createCodec` (`MEPlayerItem.swift`)

1. Todos os streams começam com `discard = AVDISCARD_ALL` e viram `FFmpegAssetTrack`. Streams de legenda ganham imediatamente uma `SyncPlayerItemTrack<SubtitleFrame>` com capacidade 255 — legendas decodificam sempre, independentemente de seleção.
2. Vídeo: `options.wantedVideo(tracks:)` (`KSOptions.swift`) pode forçar a escolha; senão `av_find_best_stream`. A trilha escolhida: `isEnabled = true` (361 — isso muda `stream.discard` para `AVDISCARD_DEFAULT`), rotação vira `videoFilters` + desliga `hardwareDecode` se `autoRotate`, `naturalSize` considera rotação. Capacidade da fila de frames vem de `options.videoFrameMaxCount(fps:naturalSize:isLive:)` (`KSOptions.swift`). Track é `SyncPlayerItemTrack` ou `AsyncPlayerItemTrack` conforme `options.syncDecodeVideo`. Se houver múltiplos bitrates e `options.videoAdaptable`, inicializa `videoAdaptation`.
3. Áudio: análogo com `wantedAudio`/`av_find_best_stream` relativo ao vídeo; capacidade via `audioFrameMaxCount(fps:channelCount:)` usando o **maior** fps entre todas as trilhas de áudio (comentário no código: TrueHD tem fps 1200). `isAudioStalled = false` → o clock de áudio vira o mestre.
4. `sourceDidOpened` chega em `KSMEPlayer` (`KSMEPlayer.swift`): remove `videoOutput` se não há vídeo, chama `audioOutput.prepare(audioFormat:)` com o `AudioDescriptor` da trilha ativa e notifica `delegate?.readyToPlay`.

### 3. Leitura (demux loop) — `readThread`/`reading` (`MEPlayerItem.swift`)

1. `readThread` roda numa `BlockOperation` nomeada `..._read` com `stackSize` custom (`MEPlayerItem.swift`). Se `options.startPlayTime > 0`, faz `avformat_seek_file` inicial e realinha os clocks.
2. `allPlayerItemTracks.forEach { $0.decode }` — nas trilhas async isso sobe as threads de decode.
3. Loop `while state ∈ {paused, seeking, reading}`:
 - `.paused` → `condition.wait` — backpressure do demux.
 - `.seeking` → calcula alvo em bytes ou tempo (`seekByBytes`, 459-480), `avformat_seek_file` com min/max, retry sem `AVSEEK_FLAG_BACKWARD` em falha, re-checa se `seekTime` mudou durante o seek (seek coalescing), `allPlayerItemTracks.forEach { $0.seek(time:) }`, completion no main thread, clocks re-semeados, volta a `.reading`.
 - `.reading` → `reading` dentro de `autoreleasepool`.
4. `reading` (`MEPlayerItem.swift`): `av_read_frame`. Com gravação ativa, remuxa o packet para `outputFormatCtx` com rescale de timebase. Roteia o packet pela `trackID == stream_index` para a trilha **habilitada**: vídeo → `videoTrack.putPacket`, áudio → `audioTrack.putPacket`, resto → `assetTrack.subtitle?.putPacket`. EOF: modo loop marca `isLoopModel` e re-seeka para o início; senão `isEndOfFile = true` em todas as trilhas e `state = .finished`. Erro de leitura → `error` → `.failed`.

### 4. Decodificação — `SyncPlayerItemTrack`/`AsyncPlayerItemTrack`

1. **Sync** (`MEPlayerItemTrack.swift`): `putPacket` decodifica inline (na thread de leitura). **Async** (`MEPlayerItemTrack.swift`): `putPacket` só empurra na `packetQueue`; a `decodeThread` faz `packetQueue.pop(wait: true)` e chama `doDecode`.
2. `doDecode` (`MEPlayerItemTrack.swift`): mede bitrate por keyframe, obtém/cria o decoder por `trackID` via `decoderMap` + `makeDecode(assetTrack:)`. `makeDecode` (`MEPlayerItemTrack.swift`): legendas → `SubtitleDecode`; vídeo com `options.asynchronousDecompression && options.hardwareDecode` e `DecompressionSession` válida → `VideoToolboxDecode`; senão → `FFmpegDecode`.
3. O callback de `decodeFrame`: descarta frames se `state == .flush/.closed`; **accurate seek**: descarta frames com `frame.timestamp + duration < seekTime`; empurra o frame na `outputRenderQueue` e propaga o fps nominal da trilha para a fila. Erro em `VideoToolboxDecode` → fallback automático para `FFmpegDecode` re-decodificando o mesmo packet; outros erros → `state = .failed`.
4. As filas de frames têm política por mídia (`MEPlayerItemTrack.swift`): áudio = FIFO não-ordenada, não-expansível; vídeo = ordenada por timestamp (B-frames), não-expansível; legenda = ordenada e expansível. Filas não-expansíveis bloqueiam o produtor (decode) quando cheias — segundo estágio de backpressure.

### 5. Renderização e clocks (pull)

1. **Vídeo**: `MetalPlayView` puxa via `renderSource?.getVideoOutputRender(force:)` (`MetalPlayView.swift`). A implementação (`MEPlayerItem.swift`) consulta `options.videoClockSync(main:nextVideoTime:fps:frameCount:)` (`KSOptions.swift`) dentro do predicate do `pop`, recebendo um `ClockProcessType` (`PlayerDefines.swift`): `.remain` (mantém frame atual), `.next` (renderiza), `.dropNextFrame`, `.flush`, `.seek`, `.dropNextPacket`, `.dropGOPPacket` — os três últimos manipulam diretamente `outputRenderQueue`/`packetQueue` e alimentam contadores em `dynamicInfo`.
2. Depois de exibir, o renderer devolve o tempo: `setVideo(time:position:)` (`MEPlayerItem.swift`, chamado de `MetalPlayView.swift`) atualiza `videoClock` e calcula `displayFPS`. Áudio idem: `setAudio` (`MEPlayerItem.swift`, chamado de `AudioEnginePlayer.swift`) atualiza `audioClock` **no main thread**.
3. **Clock mestre**: `mainClock` = `audioClock`, ou `videoClock` quando `isAudioStalled` (`MEPlayerItem.swift`). `isAudioStalled` vira `true` quando a trilha de áudio termina (`codecDidFinished`, 718-720) e é recalculado em cada seek. `currentPlaybackTime = mainClock.time - startTime`.
4. **Áudio**: `getAudioOutputRender` (`MEPlayerItem.swift`) faz pop simples e alimenta reconhecimento de fala (`SubtitleModel.audioRecognizes`) se habilitado.

### 6. Loading state e backpressure de alto nível

1. Um `Timer` de 50 ms (`MEPlayerItem.swift`) chama `codecDidChangeCapacity`: calcula `LoadingState` via `options.playable(capacitys:isFirst:isSeek:)` (`KSOptions.swift`) sobre `videoAudioTracks` (`CapacityProtocol.loadedTime = (packetCount+frameCount)/fps`, `PlayerDefines.swift`) e publica via `sourceDidChange(loadingState:)`.
2. Se `loadedTime > options.maxBufferDuration` → `pause` do demux; `< maxBufferDuration/2` → `resume`. Também aciona `adaptableVideo` que troca trilha de vídeo por bitrate (`options.adaptable(state:)`) e re-elege áudio via `findBestAudio`.
3. `KSMEPlayer.sourceDidChange(loadingState:)` (`KSMEPlayer.swift`) converte em `loadState` (`.loading`/`.playable`), `bufferingProgress` e `playableTime`; para live (duration == 0) aplica `liveAdaptivePlaybackRate`. `loadState`+`playbackState` decidem play/pause físico das saídas em `playOrPause`.

### 7. Fim, seek e shutdown

- **Fim**: quando todas as trilhas A/V têm `isEndOfFile && frameCount == 0 && packetCount == 0`, `codecDidFinished` → `sourceDidFinished` (`MEPlayerItem.swift`) → `KSMEPlayer` decide loop (replay) ou `playbackState = .finished` (`KSMEPlayer.swift`).
- **Seek público**: `KSMEPlayer.seek` (`KSMEPlayer.swift`) → `MEPlayerItem.seek` (`MEPlayerItem.swift`): grava `seekTime`, `state = .seeking`, acorda a read thread (`condition.broadcast`) e flusha as trilhas na hora — o flush só é pulado quando o fast-path em memória é elegível para aquele alvo (mesmas guardas da read thread, cobertura inclusive); de `.finished` re-dispara `read`. Após sucesso, `audioOutput.flush` e reset do `controlTimebase` da display layer.
- **Fast-path de seek em memória** (`KSOptions.isMemorySeekEnabled`, padrão ligado): para seek **para a frente** cujo alvo ainda está na janela de packets bufferizada, a read thread checa cobertura por trilha (`packetQueue.peekEdges` + conversão por timebase, margem de 1 s porque os timestamps estão em ordem de decode e com B-frames o tail não é o pts máximo; packets sem pts e sem dts invalidam a janela) e a existência de um packet de partida (keyframe ≤ alvo no vídeo). Se todas as trilhas A/V cobrem o alvo, **pula o `avformat_seek_file`**: cada trilha recebe `fastSeek`, que seta `seekTime` (reuso do accurate-seek), flusha a `outputRenderQueue` e registra um marcador de drenagem. Quem drena a `packetQueue` é a **própria decode thread** (consumidora): `scan` não-destrutivo acha o último keyframe ≤ alvo (áudio: último packet ≤ alvo) e `drain(upTo:)` descarta, numa única seção crítica, tudo o que precede **aquele packet por identidade**, deixando-o no head — se ele não estiver mais na fila (flush concorrente, drop de GOP), nada é descartado e a drenagem falha; então `doFlushCodec` reinicia o decoder e o accurate-seek descarta os frames até o alvo. Qualquer falha degrada para o caminho de rede normal: a trilha sinaliza sob o `condition` do item, e o commit do fast-path na read thread (transição para `.reading`, completion, clocks) só acontece se essa flag não tiver sido levantada no meio do caminho. Legendas não participam: os `SubtitlePart` são selecionados por tempo (`search(for:)`), itens pré-alvo simplesmente não são exibidos.
- No caminho de rede, o flush das trilhas acontece **antes** do `avformat_seek_file` (que pode bloquear por segundos em rede/cache de disco), para o áudio e o vídeo antigos pararem no instante do comando.
- **Shutdown** (`MEPlayerItem.swift`): `state = .closed`, cria `closeOperation` com **retain cycle intencional** de `self` (, ver comentário no código) dependente da read/open operation; fecha AVIO custom via `takeRetainedValue.close`, `avformat_close_input`, cancela a queue. Para decode síncrono há um caminho extra de shutdown em `DispatchQueue.global` porque a read thread pode estar bloqueada num `push` cheio.

## O engine ProAV — remux para HLS fMP4

Arquivos: `ProAVPlayer.swift`, `ProAVRemuxSession.swift`, `ProAVHTTPServer.swift`, `ProAVPlaylist.swift`, `ProAVAudioTranscoder.swift` (todos em `Sources/Lumen/MEPlayer/`), mais o caminho de remux dentro de `MEPlayerItem.swift`.

O `ProAVPlayer` é o terceiro engine do fork. Ele **não decodifica nada**: usa o demuxer do FFmpeg para reempacotar o container de entrada em HLS fMP4, serve o resultado por HTTP local e deixa o AVFoundation reproduzir. A razão de existir é obter **Dolby Vision e Dolby Atmos nativos**, que só o pipeline da Apple entrega no tvOS.

### Tipos

| Tipo | Arquivo | Papel |
|---|---|---|
| `ProAVPlayer` | `ProAVPlayer.swift` | `@MainActor public final class`, conforma `MediaPlayerProtocol`; compõe um `KSAVPlayer` interno (`innerPlayer`) e um `MEPlayerItem` em modo remux |
| `ProAVRemuxSession` | `ProAVRemuxSession.swift` | `@unchecked Sendable`; recebe os bytes do muxer, decide onde cada segmento começa/termina e escreve as playlists |
| `ProAVLocalServer` / `ProAVLoopbackHTTPServer` | `ProAVHTTPServer.swift` | Protocolo + implementação `NWListener` (Network.framework) que serve o workspace por HTTP |
| `ProAVVideoSignaling` | `ProAVPlaylist.swift` | Deriva `codecTag`, `CODECS`, `VIDEO-RANGE` e `SUPPLEMENTAL-CODECS` a partir da `FFmpegAssetTrack` de vídeo; init falível — é o **gate de compatibilidade** |
| `ProAVAudioStrategy` / `ProAVAudioSignaling` | `ProAVPlaylist.swift` | Decide por trilha de áudio (stream copy ou transcode) e deriva `CODECS` + `CHANNELS` |
| `ProAVSegment` / `ProAVPlaylist` | `ProAVPlaylist.swift` | Modelo de segmento e geração dos textos `master.m3u8`/`media.m3u8` |
| `ProAVInitBoundaryScanner` | `ProAVInitBoundaryScanner.swift` | Box-walk ISOBMFF sobre o stream do muxer: acha a fronteira entre o init segment e o primeiro `moof` |
| `ProAVAudioTranscoder` | `ProAVAudioTranscoder.swift` | Transcode de áudio não suportado pelo HLS para FLAC |
| `DOVIPacketRewriter` | `DOVIPacketRewriter.swift` | Reescrita de packet HEVC para converter Dolby Vision perfil 7 em 8.1 (libdovi) |

### Fluxo

1. `prepareToPlay` chama `startRemux(at:)`, que cria um subdiretório de trabalho e instancia um `MEPlayerItem` com uma `ProAVRemuxSession` associada. Nesse modo, o item **não chama `decode` nas trilhas** — ele só demuxa.
2. `MEPlayerItem.startProAVRemux(session:)` monta o output com `avformat_alloc_output_context2(..., "mp4", ...)`, marca `AVFMT_FLAG_CUSTOM_IO` e `strict_std_compliance` experimental, e copia os parâmetros de codec do vídeo com `avcodec_parameters_copy` — **sem reencode e sem bitstream filter do FFmpeg** (a única reescrita de bitstream é a conversão de DV perfil 7, descrita adiante). O `codec_tag` do stream de saída é sobrescrito com a FourCC derivada do signaling. O `avcodec_parameters_copy` também leva junto o side data `AV_PKT_DATA_DOVI_CONF` da entrada; é dele que o movenc monta o box `dvcC`/`dvvC` do `moov`, e é por isso que a compliance experimental importa (o muxer só escreve esse box com compliance ≤ `unofficial`).
3. Fragmentação: `movflags = "+empty_moov+delay_moov+default_base_moof+frag_custom+skip_sidx"`, mais `use_editlist=0`. O `pb` do output aponta para um `AVIOContext` criado por `ProAVRemuxSession.makeIOContext` com buffer de 64 KiB, callback de write e **callback de seek que sempre falha** (`seekable = 0`) — o muxer escreve num pipe, e é o Swift que decide em qual arquivo os bytes caem. `+delay_moov` adia o `moov` para o primeiro flush, quando o muxer já parseou um frame de áudio e consegue preencher `dac3`/`dec3` (é o que habilita a sinalização JOC do Atmos). `use_editlist=0` neutraliza o efeito colateral do `delay_moov`: sem ele o movenc ligaria a edit list e deixaria de rebasear os timestamps para zero, e os fragmentos sairiam com o timestamp da fonte enquanto o `ProAVPlayer` já soma `startOffset` por cima.
4. Segmentação manual: ao encontrar um packet de vídeo com `AV_PKT_FLAG_KEY` numa fronteira de duração alvo (padrão `ProAVPlayer.segmentDuration = 2s`), o código chama `av_write_frame(ctx, nil)` para flushar o fragmento (exigido por `frag_custom`), dá `avio_flush` e fecha o segmento. O **primeiro** corte passa por `canWriteRemuxFragment`: enquanto uma trilha AC-3/E-AC-3 mapeada não tiver escrito um packet começando pelo sync word `0x0B77`, o corte é adiado; se a janela de um segmento passar sem esse packet, a sessão **falha** em vez de emitir um `moov` com `dac3`/`dec3` vazio. E esse primeiro corte faz **dois** flushes: com `+delay_moov` o primeiro emite só `ftyp`+`moov` e retorna, o segundo emite `moof`+`mdat`.
5. Artefatos em disco: `init.mp4` (`ftyp` + `moov` já preenchido), `segment0.m4s`, `segment1.m4s`, …, mais `media.m3u8` e `master.m3u8`, escritos atomicamente. Como o muxer entrega tudo pelo mesmo pipe, quem separa o init segment do primeiro fragmento é o `ProAVInitBoundaryScanner`: um box-walk ISOBMFF que acumula bytes (teto de 8 MiB) até encontrar um `moof` top-level e corta ali — `size==1` (largesize) é tratado, e tamanho de box inválido derruba a sessão em vez de esperar para sempre. As playlists são **HLS v7** com `#EXT-X-MAP:URI="init.mp4"` e `#EXT-X-PLAYLIST-TYPE:EVENT`; `#EXT-X-ENDLIST` só aparece quando o remux termina.
6. Gate de prontidão: quando há `minimumSegmentsBeforeReady` segmentos (padrão 2), a sessão dispara `onReady`. O `ProAVPlayer` então sobe o servidor e faz `innerPlayer.replace(url:options:)` com `http://127.0.0.1:<porta>/<dir>/master.m3u8`.
7. Servidor: `NWListener` ligado a `127.0.0.1` numa **porta efêmera atribuída pelo SO**. Suporta `GET`/`HEAD`, `Range: bytes=` com `206 Partial Content`, `416`, `404` e rejeita paths contendo `..`. Content-Type `application/vnd.apple.mpegurl` para `.m3u8` e `video/mp4` para `mp4`/`m4s`/`m4v`.
8. Workspace: raiz em `Caches/Lumen-ProAV` (fallback `temporaryDirectory`), com subdiretório por sessão. `purgeWorkspaces` limpa a raiz inteira no `init` do player.

### Compatibilidade e signaling

`ProAVVideoSignaling(track:convertDolbyVisionProfile7:)` retorna `nil` — e portanto o engine **recusa a mídia e cai no fallback** — sempre que o vídeo não é HEVC, ou quando é Dolby Vision fora dos perfis suportados. O mapeamento:

| Caso | `codecTag` | `CODECS` | `VIDEO-RANGE` | `SUPPLEMENTAL-CODECS` |
|---|---|---|---|---|
| DV perfil 5, e perfil 8 com compat id 1 | `dvh1` | `dvh1.PP.LL` | `PQ` | — |
| DV perfil 8 com compat id 4 | `hvc1` | `hvc1.…` | `HLG` | `dvh1.PP.LL/db4h` |
| DV perfil 7, com `options.convertDolbyVisionProfile7` (default ligado) | `dvh1` | `dvh1.08.LL` | `PQ` | — |
| Outros perfis DV (e perfil 7 com a opção desligada) | — | recusa (`nil`) | — | — |
| Sem DV | `hvc1` | `hvc1.…`, e `VIDEO-RANGE` por `color_trc`: PQ → HDR10, ARIB B67 → HLG, senão SDR | — | — |

Áudio, por `ProAVAudioStrategy`: EC-3, AC-3, AAC, FLAC e ALAC passam por **stream copy**; qualquer outro codec (DTS, TrueHD, PCM, Opus…) é **transcodificado para FLAC** por `ProAVAudioTranscoder` (S16 ou S32/24 bits, sample rate e layout de canais preservados, PTS regenerado por contagem de amostras). Se o transcoder não puder inicializar, a trilha de áudio é simplesmente descartada.

A trilha de áudio também é anunciada na master playlist, como uma rendition `#EXT-X-MEDIA:TYPE=AUDIO` sem `URI` (o áudio está muxado na própria variante) referenciada por `AUDIO="main"`. O `CHANNELS` vem de `ch_layout.nb_channels`, **exceto** em E-AC-3 cujo `codecpar.profile` é `AV_PROFILE_EAC3_DDP_ATMOS`: aí o valor é `16/JOC`, que é como a HLS Authoring Specification pede para DD+ com Atmos. Quando a sondagem não fecha a contagem de canais (`nb_channels == 0`), o atributo é **omitido** em vez de sair como `CHANNELS="0"`.

### Conversão de Dolby Vision perfil 7

Perfil 7 é dual-layer (base layer + enhancement layer + RPU) e o AVFoundation não o reproduz. Com `KSOptions.convertDolbyVisionProfile7` (default ligado), o remux converte para **perfil 8.1 single-layer** enquanto copia o bitstream:

1. `startProAVRemux` lê o `lengthSizeMinusOne` do `hvcC` (`DOVIPacketRewriter.hevcNALUnitLengthSize`). Se a extradata não for um `hvcC` — Annex-B vindo de MPEG-TS, por exemplo — a sessão falha antes do header e o playback cai no fallback, que é o comportamento que perfil 7 já tinha.
2. O side data `AV_PKT_DATA_DOVI_CONF` do stream de **saída** é sobrescrito (`profile = 8`, `dv_bl_signal_compatibility_id = 1`, `el_present_flag = 0`, `dv_md_compression = 0`; major/minor/level/`rpu_present_flag`/`bl_present_flag` preservados da fonte). Como `dv_profile > 7`, o movenc escreve `dvvC` — não `dvcC`.
3. Cada packet de vídeo passa por `DOVIPacketRewriter.rewrite(packet:nalLengthSize:)`, que percorre as NAL units length-prefixed, **descarta** as de tipo 63 (enhancement layer) e converte as de tipo 62 (RPU) com o libdovi vendorizado (`dovi_parse_unspec62_nalu` → `dovi_convert_rpu_with_mode(_, 2)` → `dovi_write_unspec62_nalu`). O modo 2 é o de perfil 8.1 com as curvas de mapping luma/chroma zeradas (no-op); o buffer devolvido pela lib já vem escapado para HEVC e com o header `0x7C01` na frente, então é escrito verbatim, só com o prefixo de tamanho recalculado. A reescrita acontece sobre a referência de saída — o packet do demuxer nunca é mutado.
4. Qualquer erro do walker ou do libdovi derruba a sessão (`onFailure` → fallback), e se nenhum RPU tiver sido convertido até o primeiro corte de fragmento a sessão também falha — para não anunciar Dolby Vision sobre um stream sem metadata dinâmica.

### Pegadinhas do ProAV

- **Seek é caro**: não existe seek dentro do HLS gerado. `seek(time:completion:)` derruba player e item e **re-remuxa a partir do novo ponto**; `startOffset` é somado ao tempo reportado. O mesmo vale para `select(track:)` de áudio. A exceção é `switchSource` (doc 02), que sobe um segundo remux em paralelo e só derruba o antigo no commit.
- **Sem seleção automática**: nenhum código do `KSPlayerLayer` escolhe `ProAVPlayer`. É opt-in via `KSOptions.firstPlayerType`.
- **Sem legendas embutidas**: o remux carrega apenas vídeo e uma trilha de áudio; legendas do container não entram na playlist.
- **A sinalização de Atmos depende do primeiro packet de áudio**: o `dec3` só sai completo porque o `moov` é adiado (`+delay_moov`) até o muxer ter parseado um frame E-AC-3. Se a trilha mapeada não entregar um packet com sync word dentro da janela do primeiro segmento, a sessão falha de propósito — antes ela emitiria um `dec3` zerado. O `CHANNELS="16/JOC"` da playlist, por outro lado, vem do `codecpar.profile` (decoder), não do muxer: as duas metades da sinalização têm fontes independentes e podem, em tese, discordar.
- **RPU só é manipulada no perfil 7**: em DV perfil 5 e 8 as RPUs seguem embutidas no bitstream HEVC, sem extração nem reinjeção, e quem as interpreta é o decoder da Apple. A única reescrita é a conversão de perfil 7 para 8.1 descrita acima.
- **Consumo de disco**: o workspace cresce enquanto o remux avança, e só é limpo na próxima inicialização do player. `switchSource` marca o diretório do launch descartado para remoção (`requestCleanup`), que acontece quando aquele remux termina de fechar.

## Cache de disco por byte-range

Arquivos: `Sources/Lumen/Cache/DiskByteCache.swift`, `Sources/Lumen/Cache/DiskCacheURLReader.swift`, `Sources/Lumen/MEPlayer/DiskCacheAVIOContext.swift`, `Sources/Lumen/AVPlayer/DiskCacheResourceLoader.swift`.

Camada opcional que persiste em disco os trechos já baixados de **streams HTTP remotos**, evitando redownload em replay e em seeks para trás.

- **`DiskByteCache`** — duas entradas por mídia, nomeadas pelo SHA-256 da chave: um arquivo `.data` **esparso**, onde cada byte é gravado no seu offset absoluto do recurso remoto (`pwrite`/`pread`), e um `.index` JSON com a lista de ranges válidos, `contentLength` e `contentType`. Ranges adjacentes/sobrepostos são fundidos na inserção; uma leitura só é servida se um único range cobrir o offset pedido. O índice é persistido a cada 8 MiB escritos, no `close` e ao definir metadados; na abertura, um índice de versão divergente ou incoerente com o tamanho real do `.data` faz os dois arquivos serem descartados.
- **Evicção** — LRU aproximado por data de modificação, sobre as **outras** entradas do diretório: a entrada corrente nunca é despejada (seu `mtime` é tocado na abertura). Se o orçamento não couber nem após a evicção, a entrada corrente vira somente-leitura: o que já está em disco continua servindo, mas nada mais é gravado.
- **`DiskCacheURLReader`** — faz as requisições `Range: bytes=` com `URLSession` efêmera, cancela a task assim que junta os bytes necessários e serializa uma requisição de rede por vez. Só respostas `206` populam o cache; o `contentLength` vem do header `Content-Range`. Leituras buscam pelo menos um chunk (1 MiB por padrão), servindo de read-ahead.
- **`DiskCacheAVIOContext`** — subclasse de `AbstractAVIOContext` que expõe o reader ao FFmpeg pelos callbacks C de read/seek/fileSize (buffer AVIO de 256 KiB, somente leitura). É plugado pelo hook `KSOptions.process(url:)`. `canCache(url:)` exige `http`/`https` e **exclui `.m3u8`/`.m3u`**; se o servidor não suportar Range, o init falha e o I/O nativo do FFmpeg assume.
- **`DiskCacheResourceLoader`** — caminho equivalente para o `KSAVPlayer`: um `AVAssetResourceLoaderDelegate` que reescreve o scheme da URL para forçar a delegação, responde em blocos e preenche o `contentInformationRequest`. É injetado ao montar o asset, e só se houver diretório de cache configurado.

**Como ligar**: definir `KSOptions.diskCacheDirectory` (estática, para todo o app) ou `options.diskCacheDirectory` (por reprodução). É `nil` por padrão, ou seja, **o cache vem desligado**. O orçamento default é `diskCacheMaxBytes = 2 GiB`; a chave default é a URL absoluta sem query string, sobrescrevível por `diskCacheKey`. Ambos os engines compartilham o mesmo cache e a mesma chave.

## Pontos de extensão

- **Saída de áudio/vídeo custom**: implementar `AudioOutput` (`Sources/Lumen/MEPlayer/AudioEnginePlayer.swift`) ou `VideoOutput & UIView` (`Sources/Lumen/MEPlayer/MetalPlayView.swift`) e registrar em `KSOptions.audioPlayerType`/`KSOptions.videoPlayerType` (`Sources/Lumen/MEPlayer/Model.swift`). O contrato mínimo é `FrameOutput` (`Model.swift`) + puxar frames de `renderSource` (`OutputRenderSourceDelegate`, `Model.swift`). Alternativas já existentes: `AudioUnitPlayer`, `AudioGraphPlayer`, `AudioRendererPlayer`.
- **Protocolo de I/O custom (cache, SMB, DRM leve)**: subclassear `AbstractAVIOContext` (`Sources/Lumen/AVPlayer/PlayerDefines.swift`) e retorná-lo em `KSOptions.process(url:)` (`Sources/Lumen/AVPlayer/KSOptions.swift`); o hook está em `MEPlayerItem.openThread` (`MEPlayerItem.swift`) e a ponte C em `AbstractAVIOContext.getContext` (`MEPlayerItem.swift`).
- **Política de sincronização A/V**: sobrescrever `KSOptions.videoClockSync(main:nextVideoTime:fps:frameCount:)` (`KSOptions.swift`) — é o único ponto que decide drop/flush/render, consumido em `MEPlayerItem.getVideoOutputRender` (`MEPlayerItem.swift`).
- **Política de buffering**: sobrescrever `KSOptions.playable(capacitys:isFirst:isSeek:)` (`KSOptions.swift`) e os tamanhos de fila `videoFrameMaxCount`/`audioFrameMaxCount` (`KSOptions.swift`).
- **Seleção default de trilhas**: sobrescrever `KSOptions.wantedVideo(tracks:)`/`wantedAudio(tracks:)` (`KSOptions.swift`), consumidos em `createCodec` (`MEPlayerItem.swift`).
- **Decoder novo**: implementar `DecodeProtocol` (`MEPlayerItemTrack.swift`) e plugar em `SyncPlayerItemTrack.makeDecode(assetTrack:)` (`MEPlayerItemTrack.swift`) — hoje a escolha VTB vs FFmpeg é hardcoded ali; é o lugar para um decoder Dolby Vision/AV1 dedicado.
- **Pós-processamento por trilha**: `KSOptions.process(assetTrack:)` é chamado para as trilhas eleitas (`MEPlayerItem.swift`) — ponto para ajustar filtros, delay de legenda etc.
- **ABR custom**: `KSOptions.adaptable(state:)` com `VideoAdaptationState` (`PlayerDefines.swift`), consumido em `adaptableVideo` (`MEPlayerItem.swift`).
- **Legendas embutidas**: `FFmpegAssetTrack` já é `SubtitleInfo`/`KSSubtitleProtocol` (`EmbedDataSouce.swift`); `search(for:)` drena a `outputRenderQueue` da trilha de legenda. Fontes externas entram por outro subsistema (`SubtitleDataSouce`), não por aqui.
- **Gravação**: `KSMEPlayer.startRecord(url:)`/`stoptRecord` (`KSMEPlayer.swift`) fazem remux sem re-encode (`MEPlayerItem.startRecord`, `MEPlayerItem.swift`); `options.outputURL` inicia gravação já no open (`MEPlayerItem.swift`).

## Pegadinhas

- **Threading — mapa das threads**: `OperationQueue` serial do item roda open/read/close (`MEPlayerItem.swift`); cada `AsyncPlayerItemTrack` tem sua própria `OperationQueue` serial de decode (`MEPlayerItemTrack.swift`); render de vídeo puxa da thread de display (CADisplayLink/MTKView), render de áudio puxa da realtime audio thread; o `Timer` de capacidade dispara no RunLoop main. `state` de `MEPlayerItem` é lido/escrito de várias dessas threads sem lock — o design tolera leituras stale (checagens redundantes de `.closed` espalhadas, ex. `MEPlayerItem.swift`).
- **`Sendable` de fachada**: `MEPlayerItem` é `public final class ... Sendable` (`MEPlayerItem.swift`) mas contém estado mutável não protegido; é uma promessa não verificada (o projeto usa default MainActor isolation em outros alvos — código novo aqui precisa manter a disciplina manual de threads, não confiar no compilador).
- **Backpressure em dois estágios e deadlock potencial**: a read thread para via `condition.wait` em `.paused` (`MEPlayerItem.swift`) **e** pode bloquear dentro de `push` de fila cheia não-expansível (`CircularBuffer.swift`) quando decode é síncrono. Por isso `shutdown` tem o caminho extra em `DispatchQueue.global` quando `syncDecodeVideo/Audio` (`MEPlayerItem.swift`) — remover isso trava o close.
- **`CircularBuffer.push` insere antes de bloquear**: o item é escrito e `tailIndex` incrementado antes do `condition.wait` de fila cheia (`CircularBuffer.swift`); o "bloqueio" é a posteriori. `count` é lido sem lock (comentado de propósito, `CircularBuffer.swift`). O `pop(where:)` com predicate falso retorna `nil` **sem** consumir — é assim que o vídeo segura o frame até a hora certa.
- **`flush` semeia a fila com lixo estrutural se destruída**: após `shutdown`, `flush` deixa a fila com capacidade 1 (`CircularBuffer.swift`) — qualquer uso pós-shutdown é no-op por `destroyed`, mas não reinicializável.
- **Ordem de inicialização do áudio**: `audioOutput.prepare(audioFormat:)` só acontece em `sourceDidOpened` (`KSMEPlayer.swift`), no main thread, depois que `createCodec` escolheu a trilha. Trocar trilha de áudio com formato diferente **não** repassa por `prepare` — mudanças de rota/spatial chamam apenas `audioDescriptor.updateAudioFormat` (`KSMEPlayer.swift`).
- **Seleção de trilha ≠ troca imediata**: `MEPlayerItem.select(track:)` (`MEPlayerItem.swift`) apenas alterna `isEnabled` (= `stream.discard`) e re-seeka para o tempo atual para forçar re-buffer. Legendas de texto retornam `false` e **não** seekam: elas são decodificadas continuamente porque `isEnabled` de legenda não-imagem sempre força `AVDISCARD_DEFAULT` (`FFmpegAssetTrack.swift`). Legendas de imagem só seekam se `options.isSeekImageSubtitle`.
- **Clock de vídeo no primeiro frame**: `currentPlaybackTime` depende de `mainClock.time - startTime` (`MEPlayerItem.swift`); antes do primeiro `setAudio/setVideo` o valor é o `startTime` semeado no open. Durante seek, retorna `seekTime` — a UI não vê o tempo "pulando de volta".
- **Seek coalescente**: chamadas repetidas de `seek` durante `.seeking` só sobrescrevem `seekTime`/handler (`MEPlayerItem.swift`); a read thread compara `seekToTime != seekTime` e re-loopa. O handler anterior é **silenciosamente descartado** (nunca chamado).
- **`isAudioStalled` muda o clock mestre em runtime**: fim da trilha de áudio (`codecDidFinished`, `MEPlayerItem.swift`) migra a sincronização para o clock de vídeo; arquivos com áudio mais curto que o vídeo mudam de regime no meio do playback.
- **`Packet.assetTrack` é implicitly-unwrapped e o didSet é o construtor real** (`Model.swift`): um `Packet` sem `assetTrack` atribuído tem timestamp/size zerados. A ordem `packet.assetTrack = first` antes de `putPacket` (`MEPlayerItem.swift`) é obrigatória.
- **Hack de NAL size no extradata**: `extradata[4] == 0xFE` é mutado in-place para `0xFF` e marca `isConvertNALSize` (`FFmpegAssetTrack.swift`) — afeta o parsing downstream no decoder VTB; não "limpar" esse código.
- **`avformat_seek_file` por bytes**: para formatos `TS_DISCONT` o seek é em bytes com estimativa por bitrate (`MEPlayerItem.swift`); o fallback `increase *= 180_000` é chute puro. Seeks imprecisos nesses containers são esperados; a precisão real vem do descarte de frames por `seekTime` na trilha (`MEPlayerItemTrack.swift`, dependente de `options.isAccurateSeek`).
- **Retain cycle intencional no close** (`MEPlayerItem.swift`): a `closeOperation` captura `self` forte de propósito para o teardown do FFmpeg terminar antes do dealloc. Não converter para `[weak self]`.
- **`timer` no main RunLoop**: o `Timer` de 50 ms é criado lazy na init (`MEPlayerItem.swift`) e invalidado só em `.closed`; `fireDate` distantFuture/distantPast faz papel de pause/resume. Se `codecDidChangeCapacity` ficar caro, trava o main thread.
- **Loop gapless**: EOF em modo loop cria uma segunda `packetQueue` (`loopPacketQueue`, `MEPlayerItemTrack.swift`) que recebe os packets do arquivo re-lido do zero enquanto a fila antiga drena; a troca acontece quando `isLoopModel` volta a `false` em `codecDidFinished` (`MEPlayerItem.swift`). Mexer em seek/shutdown precisa considerar `loopPacketQueue = nil` (`MEPlayerItemTrack.swift`).
- **`replace(url:)` reusa o `audioOutput` mas recria `MEPlayerItem` e possivelmente o `videoOutput`** (`KSMEPlayer.swift`); o `videoOutput` antigo é invalidado no didSet. `KSOptions.isClearVideoWhereReplace` controla se o último frame fica na tela no shutdown (`KSMEPlayer.swift`).

## Relação com outros subsistemas

- **Camada de player unificada**: `KSMEPlayer` implementa `MediaPlayerProtocol` (`Sources/Lumen/AVPlayer/MediaPlayerProtocol.swift`), a mesma interface do `KSAVPlayer`; `KSPlayerLayer` alterna entre eles por `firstPlayerType/secondPlayerType`. Callbacks sobem via `MediaPlayerDelegate` (`readyToPlay`, `changeLoadState`, `changeBuffering`, `finish`).
- **Configuração**: praticamente toda política (buffering, sync, seleção de trilha, hardware decode, filtros, ABR) vive em `KSOptions` (`Sources/Lumen/AVPlayer/KSOptions.swift`) e é consumida aqui — este subsistema é o "motor", `KSOptions` é o "painel".
- **Decoders**: `FFmpegDecode` (`Sources/Lumen/MEPlayer/FFmpegDecode.swift`), `VideoToolboxDecode`/`DecompressionSession` (`Sources/Lumen/MEPlayer/VideoToolboxDecode.swift`), `SubtitleDecode` (`Sources/Lumen/MEPlayer/SubtitleDecode.swift`) implementam `DecodeProtocol`; filtros FFmpeg em `Filter.swift`, resample/`AudioDescriptor` em `Resample.swift`.
- **Renderização de vídeo**: `MetalPlayView` (`Sources/Lumen/MEPlayer/MetalPlayView.swift`) consome `getVideoOutputRender` e devolve o clock via `setVideo`; usa `AVSampleBufferDisplayLayer`+Metal e expõe `displayLayer` para PiP (contentSource em `KSMEPlayer.swift`).
- **Renderização de áudio**: `AudioEnginePlayer`/`AudioUnitPlayer`/`AudioGraphPlayer`/`AudioRendererPlayer` consomem `getAudioOutputRender` (`AudioEnginePlayer.swift`, `AudioRendererPlayer.swift`) e devolvem o clock via `setAudio` (`AudioEnginePlayer.swift`).
- **Legendas**: as trilhas embutidas entram no pipeline de legendas do app via `SubtitleDataSouce` (`Sources/Lumen/Subtitle/SubtitleDataSouce.swift`) através das extensões de `EmbedDataSouce.swift`; `SubtitlePart`/`SubtitleModel` vivem em `Sources/Lumen/Subtitle/`. O reconhecimento de fala (`SubtitleModel.audioRecognizes`) é alimentado pelo pull de áudio (`MEPlayerItem.swift`).
- **UI/SwiftUI**: `dynamicInfo` (`MEPlayerItem.swift`, tipo em `MediaPlayerProtocol.swift`) alimenta o painel de debug (`DynamicInfoView`, `Sources/Lumen/SwiftUI/KSVideoPlayerView.swift`) com fps de display, drops, bitrate e metadata em tempo real.
- **FFmpegKit**: todo o subsistema depende dos módulos `Libavformat/Libavcodec/Libavfilter` do pacote FFmpegKit; o setup global de rede/log é feito uma única vez em `MEPlayerItem.onceInitial` (`MEPlayerItem.swift`), incluindo o roteamento de logs do avfilter de volta para o `KSOptions.filter(log:)` da instância.
