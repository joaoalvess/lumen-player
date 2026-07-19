# 03 — Engine MEPlayer: demux e pipeline

Subsistema: `Sources/KSPlayer/MEPlayer/` — núcleo FFmpeg do KSPlayer. Cobre `KSMEPlayer`, `MEPlayerItem`, `MEPlayerItemTrack`, `Model.swift`, `CircularBuffer`, `EmbedDataSouce`, `FFmpegAssetTrack`.

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
| `KSMEPlayer` | `Sources/KSPlayer/MEPlayer/KSMEPlayer.swift:16` | Fachada `MediaPlayerProtocol`. Compõe `MEPlayerItem` + `AudioOutput` + `VideoOutput`, gerencia `playbackState`/`loadState`, PiP, playback coordinator, notificações de rota de áudio. |
| `MEPlayerItem` | `Sources/KSPlayer/MEPlayer/MEPlayerItem.swift:14` | Dono do `AVFormatContext`. Threads de open/read/close via `OperationQueue` serial, seek, clocks, seleção de trilha, adaptação de bitrate, gravação (remux) e fonte de frames para os renderizadores. |
| `MESourceState` | `Sources/KSPlayer/MEPlayer/Model.swift:17` | Máquina de estados do item: `idle → opening → opened → reading ⇄ (seeking/paused) → finished/closed/failed`. |
| `PlayerItemTrackProtocol` | `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift:11` | Contrato de uma trilha de decodificação: `decode()`, `seek(time:)`, `putPacket(packet:)`, `shutdown()`, flags `isEndOfFile`/`isLoopModel`. Estende `CapacityProtocol`. |
| `SyncPlayerItemTrack<Frame>` | `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift:24` | Trilha síncrona: decodifica no ato do `putPacket` (thread de leitura). Usada para legendas sempre, e para A/V quando `options.syncDecodeAudio/Video`. Mantém `outputRenderQueue: CircularBuffer<Frame>`. |
| `AsyncPlayerItemTrack<Frame>` | `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift:179` | Subclasse assíncrona: adiciona `packetQueue: CircularBuffer<Packet>` e uma thread própria de decode (`decodeThread`, `MEPlayerItemTrack.swift:233`). Default para A/V. |
| `DecodeProtocol` | `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift:293` | Contrato do decoder concreto: `decodeFrame(from:completionHandler:)`, `doFlushCodec()`, `shutdown()`. Implementações: `FFmpegDecode`, `VideoToolboxDecode`, `SubtitleDecode`. |
| `CircularBuffer<Item>` | `Sources/KSPlayer/MEPlayer/CircularBuffer.swift:12` | Fila circular bloqueante (NSCondition), opcionalmente ordenada por `timestamp` (insertion sort no push, `CircularBuffer.swift:53`) e opcionalmente expansível (dobra capacidade, `CircularBuffer.swift:153`). Backpressure: `push` bloqueia quando cheia e não-expansível (`CircularBuffer.swift:69-75`). |
| `Packet` | `Sources/KSPlayer/MEPlayer/Model.swift:195` | Wrapper de `AVPacket*`. `assetTrack` didSet copia pts/dts/pos/duration/size (`Model.swift:213-223`). Libera o packet no `deinit`. |
| `MEFrame` | `Sources/KSPlayer/MEPlayer/Model.swift:73` | Protocolo de frame decodificado (`ObjectQueueItem` + timebase mutável). Implementações: `AudioFrame`, `VideoVTBFrame`, `SubtitleFrame`. |
| `AudioFrame` | `Sources/KSPlayer/MEPlayer/Model.swift:244` | PCM decodificado (planar ou interleaved). Conversões: `toPCMBuffer()` (`Model.swift:333`) para AVAudioEngine, `toCMSampleBuffer()` (`Model.swift:360`) para `AVSampleBufferAudioRenderer`. |
| `VideoVTBFrame` | `Sources/KSPlayer/MEPlayer/Model.swift:420` | Frame de vídeo com `corePixelBuffer: PixelBufferProtocol?`, `fps`, `isDovi` e `edrMetaData` (HDR10/HLG → `CAEDRMetadata`, `Model.swift:437-462`). |
| `SubtitleFrame` | `Sources/KSPlayer/MEPlayer/Model.swift:231` | `SubtitlePart` + timebase. |
| `FFmpegAssetTrack` | `Sources/KSPlayer/MEPlayer/FFmpegAssetTrack.swift:12` | Metadados de um `AVStream`: codec, timebase, fps nominal, rotação, DOVI, `CMFormatDescription`, `AudioDescriptor`. `isEnabled` mapeia direto para `stream.discard` (`FFmpegAssetTrack.swift:265-276`). |
| `Timebase` | `Sources/KSPlayer/MEPlayer/Model.swift:177` | num/den ↔ `AVRational`; converte timestamp ↔ `CMTime`. |
| `KSClock` | `Sources/KSPlayer/AVPlayer/KSOptions.swift:670` | `time: CMTime` + `lastMediaTime` (host time); `getTime()` extrapola o tempo atual (`KSOptions.swift:679-681`). |
| `MEPlayerDelegate` | `Sources/KSPlayer/MEPlayer/Model.swift:42` | Callbacks do item para o player: `sourceDidOpened/Failed/Finished`, `sourceDidChange(loadingState:)`, mudança de bitrate. |
| `CodecCapacityDelegate` | `Sources/KSPlayer/MEPlayer/Model.swift:38` | Trilha → item: `codecDidFinished(track:)` (fim real do playback). |
| `OutputRenderSourceDelegate` | `Sources/KSPlayer/MEPlayer/Model.swift:31` | Renderizador → item: `getVideoOutputRender(force:)`, `getAudioOutputRender()`, `setVideo/setAudio(time:position:)`. |
| `FrameOutput`/`AudioOutput`/`VideoOutput` | `Model.swift:66`, `AudioEnginePlayer.swift:11`, `MetalPlayView.swift:18` | Saídas plugáveis; instanciadas por `KSOptions.audioPlayerType`/`videoPlayerType` (`Model.swift:85-86`). |
| `EmbedDataSouce` (extensões) | `Sources/KSPlayer/MEPlayer/EmbedDataSouce.swift:11-29` | Expõe trilhas de legenda embutidas como `SubtitleInfo`/`KSSubtitleProtocol`; `KSMEPlayer` vira `SubtitleDataSouce`. |

## Fluxo de dados

### 1. Construção e abertura

1. `KSMEPlayer.init(url:options:)` (`KSMEPlayer.swift:117`): cria `audioOutput = KSOptions.audioPlayerType.init()` (119), `playerItem = MEPlayerItem(url:options:)` (120), `videoOutput = KSOptions.videoPlayerType.init(options:)` (124, `nil` se `options.videoDisable`). Liga `playerItem.delegate = self` (128) e injeta `playerItem` como `renderSource` das duas saídas (129-130).
2. `prepareToPlay()` (`KSMEPlayer.swift:382` → `MEPlayerItem.prepareToPlay()`, `MEPlayerItem.swift:613`): estado `.opening`, enfileira `openOperation` numa `OperationQueue` serial (`maxConcurrentOperationCount = 1`, `MEPlayerItem.swift:129`).
3. `openThread()` (`MEPlayerItem.swift:164`):
   - `avformat_alloc_context` + `interrupt_callback` que aborta I/O quando o estado é `finished/closed/failed` (`MEPlayerItem.swift:171-185`).
   - I/O custom: se `options.process(url:)` retorna um `AbstractAVIOContext` (`KSOptions.swift:448`), `formatCtx.pb` recebe o `AVIOContext` criado por `AbstractAVIOContext.getContext()` (`MEPlayerItem.swift:862-881`) — é assim que protocolos custom (ex.: SMB, cache) entram.
   - `avformat_open_input` (202) com `options.formatContextOptions` como `AVDictionary`; depois flags `AVFMT_FLAG_GENPTS` (215), `nobuffer` (216-218), `probesize`/`maxAnalyzeDuration` (219-224), `avformat_find_stream_info` (225).
   - Deriva: `maxFrameDuration` (234), `seekByBytes` (237, formatos `TS_DISCONT` exceto ogg), `startTime` do container (238-242, semeia os dois clocks), `duration` (243), `fileSize` (244), capítulos (246-258).
   - `createCodec(formatCtx:)` (245) monta as trilhas; se nem vídeo nem áudio existirem → `.failed`, senão `state = .opened` (dispara `sourceDidOpened`) e `read()` (263-268).

### 2. Criação de trilhas — `createCodec` (`MEPlayerItem.swift:328`)

1. Todos os streams começam com `discard = AVDISCARD_ALL` (337) e viram `FFmpegAssetTrack` (338). Streams de legenda ganham imediatamente uma `SyncPlayerItemTrack<SubtitleFrame>` com capacidade 255 (340-342) — legendas decodificam sempre, independentemente de seleção.
2. Vídeo: `options.wantedVideo(tracks:)` (`KSOptions.swift:222`) pode forçar a escolha; senão `av_find_best_stream` (359). A trilha escolhida: `isEnabled = true` (361 — isso muda `stream.discard` para `AVDISCARD_DEFAULT`), rotação vira `videoFilters` + desliga `hardwareDecode` se `autoRotate` (362-375), `naturalSize` considera rotação (376). Capacidade da fila de frames vem de `options.videoFrameMaxCount(fps:naturalSize:isLive:)` (378, `KSOptions.swift:233`). Track é `SyncPlayerItemTrack` ou `AsyncPlayerItemTrack` conforme `options.syncDecodeVideo` (379). Se houver múltiplos bitrates e `options.videoAdaptable`, inicializa `videoAdaptation` (386-392).
3. Áudio: análogo com `wantedAudio`/`av_find_best_stream` relativo ao vídeo (396-403); capacidade via `audioFrameMaxCount(fps:channelCount:)` (411) usando o **maior** fps entre todas as trilhas de áudio (comentário na linha 409: TrueHD tem fps 1200). `isAudioStalled = false` (417) → o clock de áudio vira o mestre.
4. `sourceDidOpened` chega em `KSMEPlayer` (`KSMEPlayer.swift:194`): remove `videoOutput` se não há vídeo (197-200), chama `audioOutput.prepare(audioFormat:)` com o `AudioDescriptor` da trilha ativa (206-209) e notifica `delegate?.readyToPlay` (213).

### 3. Leitura (demux loop) — `readThread`/`reading` (`MEPlayerItem.swift:435/521`)

1. `readThread` roda numa `BlockOperation` nomeada `..._read` com `stackSize` custom (`MEPlayerItem.swift:422-426`). Se `options.startPlayTime > 0`, faz `avformat_seek_file` inicial e realinha os clocks (437-445).
2. `allPlayerItemTracks.forEach { $0.decode() }` (448) — nas trilhas async isso sobe as threads de decode.
3. Loop `while state ∈ {paused, seeking, reading}` (449):
   - `.paused` → `condition.wait()` (450-452) — backpressure do demux.
   - `.seeking` → calcula alvo em bytes ou tempo (`seekByBytes`, 459-480), `avformat_seek_file` com min/max (485), retry sem `AVSEEK_FLAG_BACKWARD` em falha (490-495), re-checa se `seekTime` mudou durante o seek (500-502, seek coalescing), `allPlayerItemTracks.forEach { $0.seek(time:) }` (504), completion no main thread (505-509), clocks re-semeados (510-511), volta a `.reading`.
   - `.reading` → `reading()` dentro de `autoreleasepool` (513-517).
4. `reading()` (`MEPlayerItem.swift:521`): `av_read_frame` (526). Com gravação ativa, remuxa o packet para `outputFormatCtx` com rescale de timebase (531-547). Roteia o packet pela `trackID == stream_index` para a trilha **habilitada** (551-566): vídeo → `videoTrack.putPacket`, áudio → `audioTrack.putPacket`, resto → `assetTrack.subtitle?.putPacket`. EOF: modo loop marca `isLoopModel` e re-seeka para o início (570-572); senão `isEndOfFile = true` em todas as trilhas e `state = .finished` (574-575). Erro de leitura → `error` → `.failed` (579).

### 4. Decodificação — `SyncPlayerItemTrack`/`AsyncPlayerItemTrack`

1. **Sync** (`MEPlayerItemTrack.swift:84-92`): `putPacket` decodifica inline (na thread de leitura). **Async** (`MEPlayerItemTrack.swift:211-217`): `putPacket` só empurra na `packetQueue`; a `decodeThread` (233-261) faz `packetQueue.pop(wait: true)` (252) e chama `doDecode`.
2. `doDecode` (`MEPlayerItemTrack.swift:115`): mede bitrate por keyframe (116-129), obtém/cria o decoder por `trackID` via `decoderMap` + `makeDecode(assetTrack:)` (130). `makeDecode` (`MEPlayerItemTrack.swift:301-315`): legendas → `SubtitleDecode`; vídeo com `options.asynchronousDecompression && options.hardwareDecode` e `DecompressionSession` válida → `VideoToolboxDecode`; senão → `FFmpegDecode`.
3. O callback de `decodeFrame` (132-168): descarta frames se `state == .flush/.closed`; **accurate seek**: descarta frames com `frame.timestamp + duration < seekTime` (145-153); empurra o frame na `outputRenderQueue` (155) e propaga o fps nominal da trilha para a fila (156). Erro em `VideoToolboxDecode` → fallback automático para `FFmpegDecode` re-decodificando o mesmo packet (160-165); outros erros → `state = .failed`.
4. As filas de frames têm política por mídia (`MEPlayerItemTrack.swift:56-64`): áudio = FIFO não-ordenada, não-expansível; vídeo = ordenada por timestamp (B-frames), não-expansível; legenda = ordenada e expansível. Filas não-expansíveis bloqueiam o produtor (decode) quando cheias — segundo estágio de backpressure.

### 5. Renderização e clocks (pull)

1. **Vídeo**: `MetalPlayView` puxa via `renderSource?.getVideoOutputRender(force:)` (`MetalPlayView.swift:173`). A implementação (`MEPlayerItem.swift:798-848`) consulta `options.videoClockSync(main:nextVideoTime:fps:frameCount:)` (`KSOptions.swift:359`) dentro do predicate do `pop`, recebendo um `ClockProcessType` (`PlayerDefines.swift:163`): `.remain` (mantém frame atual), `.next` (renderiza), `.dropNextFrame`, `.flush`, `.seek`, `.dropNextPacket`, `.dropGOPPacket` — os três últimos manipulam diretamente `outputRenderQueue`/`packetQueue` e alimentam contadores em `dynamicInfo` (814-846).
2. Depois de exibir, o renderer devolve o tempo: `setVideo(time:position:)` (`MEPlayerItem.swift:776`, chamado de `MetalPlayView.swift:220`) atualiza `videoClock` e calcula `displayFPS`. Áudio idem: `setAudio` (`MEPlayerItem.swift:789`, chamado de `AudioEnginePlayer.swift:323`) atualiza `audioClock` **no main thread**.
3. **Clock mestre**: `mainClock()` = `audioClock`, ou `videoClock` quando `isAudioStalled` (`MEPlayerItem.swift:772-774`). `isAudioStalled` vira `true` quando a trilha de áudio termina (`codecDidFinished`, 718-720) e é recalculado em cada seek (694). `currentPlaybackTime = mainClock().time - startTime` (44-46).
4. **Áudio**: `getAudioOutputRender()` (`MEPlayerItem.swift:850-859`) faz pop simples e alimenta reconhecimento de fala (`SubtitleModel.audioRecognizes`) se habilitado.

### 6. Loading state e backpressure de alto nível

1. Um `Timer` de 50 ms (`MEPlayerItem.swift:79-81`) chama `codecDidChangeCapacity` (699): calcula `LoadingState` via `options.playable(capacitys:isFirst:isSeek:)` (`KSOptions.swift:163`) sobre `videoAudioTracks` (`CapacityProtocol.loadedTime = (packetCount+frameCount)/fps`, `PlayerDefines.swift:184-186`) e publica via `sourceDidChange(loadingState:)`.
2. Se `loadedTime > options.maxBufferDuration` → `pause()` do demux; `< maxBufferDuration/2` → `resume()` (705-709). Também aciona `adaptableVideo` (736-757) que troca trilha de vídeo por bitrate (`options.adaptable(state:)`) e re-elege áudio via `findBestAudio` (759-768).
3. `KSMEPlayer.sourceDidChange(loadingState:)` (`KSMEPlayer.swift:238`) converte em `loadState` (`.loading`/`.playable`), `bufferingProgress` e `playableTime`; para live (duration == 0) aplica `liveAdaptivePlaybackRate` (279-283). `loadState`+`playbackState` decidem play/pause físico das saídas em `playOrPause()` (153-166).

### 7. Fim, seek e shutdown

- **Fim**: quando todas as trilhas A/V têm `isEndOfFile && frameCount == 0 && packetCount == 0`, `codecDidFinished` → `sourceDidFinished` (`MEPlayerItem.swift:717-734`) → `KSMEPlayer` decide loop (replay) ou `playbackState = .finished` (`KSMEPlayer.swift:224-236`).
- **Seek público**: `KSMEPlayer.seek` (`KSMEPlayer.swift:355-380`) → `MEPlayerItem.seek` (`MEPlayerItem.swift:678-695`): grava `seekTime`, `state = .seeking`, acorda a read thread (`condition.broadcast()`) e flusha as trilhas; de `.finished` re-dispara `read()`. Após sucesso, `audioOutput.flush()` e reset do `controlTimebase` da display layer.
- **Shutdown** (`MEPlayerItem.swift:628-670`): `state = .closed`, cria `closeOperation` com **retain cycle intencional** de `self` (comentário na linha 633) dependente da read/open operation; fecha AVIO custom via `takeRetainedValue().close()` (639-642), `avformat_close_input`, cancela a queue. Para decode síncrono há um caminho extra de shutdown em `DispatchQueue.global()` (664-668) porque a read thread pode estar bloqueada num `push` cheio.

## Pontos de extensão

- **Saída de áudio/vídeo custom**: implementar `AudioOutput` (`Sources/KSPlayer/MEPlayer/AudioEnginePlayer.swift:11`) ou `VideoOutput & UIView` (`Sources/KSPlayer/MEPlayer/MetalPlayView.swift:18`) e registrar em `KSOptions.audioPlayerType`/`KSOptions.videoPlayerType` (`Sources/KSPlayer/MEPlayer/Model.swift:85-86`). O contrato mínimo é `FrameOutput` (`Model.swift:66`) + puxar frames de `renderSource` (`OutputRenderSourceDelegate`, `Model.swift:31`). Alternativas já existentes: `AudioUnitPlayer`, `AudioGraphPlayer`, `AudioRendererPlayer`.
- **Protocolo de I/O custom (cache, SMB, DRM leve)**: subclassear `AbstractAVIOContext` (`Sources/KSPlayer/AVPlayer/PlayerDefines.swift:347`) e retorná-lo em `KSOptions.process(url:)` (`Sources/KSPlayer/AVPlayer/KSOptions.swift:448`); o hook está em `MEPlayerItem.openThread` (`MEPlayerItem.swift:192-195`) e a ponte C em `AbstractAVIOContext.getContext()` (`MEPlayerItem.swift:862-881`).
- **Política de sincronização A/V**: sobrescrever `KSOptions.videoClockSync(main:nextVideoTime:fps:frameCount:)` (`KSOptions.swift:359`) — é o único ponto que decide drop/flush/render, consumido em `MEPlayerItem.getVideoOutputRender` (`MEPlayerItem.swift:805`).
- **Política de buffering**: sobrescrever `KSOptions.playable(capacitys:isFirst:isSeek:)` (`KSOptions.swift:163`) e os tamanhos de fila `videoFrameMaxCount`/`audioFrameMaxCount` (`KSOptions.swift:233/237`).
- **Seleção default de trilhas**: sobrescrever `KSOptions.wantedVideo(tracks:)`/`wantedAudio(tracks:)` (`KSOptions.swift:222/229`), consumidos em `createCodec` (`MEPlayerItem.swift:354/398`).
- **Decoder novo**: implementar `DecodeProtocol` (`MEPlayerItemTrack.swift:293`) e plugar em `SyncPlayerItemTrack.makeDecode(assetTrack:)` (`MEPlayerItemTrack.swift:301`) — hoje a escolha VTB vs FFmpeg é hardcoded ali; é o lugar para um decoder Dolby Vision/AV1 dedicado.
- **Pós-processamento por trilha**: `KSOptions.process(assetTrack:)` é chamado para as trilhas eleitas (`MEPlayerItem.swift:377/408`) — ponto para ajustar filtros, delay de legenda etc.
- **ABR custom**: `KSOptions.adaptable(state:)` com `VideoAdaptationState` (`PlayerDefines.swift:148`), consumido em `adaptableVideo` (`MEPlayerItem.swift:746`).
- **Legendas embutidas**: `FFmpegAssetTrack` já é `SubtitleInfo`/`KSSubtitleProtocol` (`EmbedDataSouce.swift:11-23`); `search(for:)` drena a `outputRenderQueue` da trilha de legenda. Fontes externas entram por outro subsistema (`SubtitleDataSouce`), não por aqui.
- **Gravação**: `KSMEPlayer.startRecord(url:)`/`stoptRecord()` (`KSMEPlayer.swift:580-587`) fazem remux sem re-encode (`MEPlayerItem.startRecord`, `MEPlayerItem.swift:271`); `options.outputURL` inicia gravação já no open (`MEPlayerItem.swift:260-262`).

## Pegadinhas

- **Threading — mapa das threads**: (1) `OperationQueue` serial do item roda open/read/close (`MEPlayerItem.swift:17,129`); (2) cada `AsyncPlayerItemTrack` tem sua própria `OperationQueue` serial de decode (`MEPlayerItemTrack.swift:180,204-209`); (3) render de vídeo puxa da thread de display (CADisplayLink/MTKView), render de áudio puxa da realtime audio thread; (4) o `Timer` de capacidade dispara no RunLoop main. `state` de `MEPlayerItem` é lido/escrito de várias dessas threads sem lock — o design tolera leituras stale (checagens redundantes de `.closed` espalhadas, ex. `MEPlayerItem.swift:497,527`).
- **`Sendable` de fachada**: `MEPlayerItem` é `public final class ... Sendable` (`MEPlayerItem.swift:14`) mas contém estado mutável não protegido; é uma promessa não verificada (o projeto usa default MainActor isolation em outros alvos — código novo aqui precisa manter a disciplina manual de threads, não confiar no compilador).
- **Backpressure em dois estágios e deadlock potencial**: a read thread para via `condition.wait()` em `.paused` (`MEPlayerItem.swift:450-452`) **e** pode bloquear dentro de `push` de fila cheia não-expansível (`CircularBuffer.swift:74`) quando decode é síncrono. Por isso `shutdown` tem o caminho extra em `DispatchQueue.global()` quando `syncDecodeVideo/Audio` (`MEPlayerItem.swift:664-668`) — remover isso trava o close.
- **`CircularBuffer.push` insere antes de bloquear**: o item é escrito e `tailIndex` incrementado antes do `condition.wait()` de fila cheia (`CircularBuffer.swift:43-82`); o "bloqueio" é a posteriori. `count` é lido sem lock (comentado de propósito, `CircularBuffer.swift:24-28`). O `pop(where:)` com predicate falso retorna `nil` **sem** consumir — é assim que o vídeo segura o frame até a hora certa.
- **`flush()` semeia a fila com lixo estrutural se destruída**: após `shutdown`, `flush` deixa a fila com capacidade 1 (`CircularBuffer.swift:143-144`) — qualquer uso pós-shutdown é no-op por `destroyed`, mas não reinicializável.
- **Ordem de inicialização do áudio**: `audioOutput.prepare(audioFormat:)` só acontece em `sourceDidOpened` (`KSMEPlayer.swift:206-209`), no main thread, depois que `createCodec` escolheu a trilha. Trocar trilha de áudio com formato diferente **não** repassa por `prepare` — mudanças de rota/spatial chamam apenas `audioDescriptor.updateAudioFormat()` (`KSMEPlayer.swift:168-189`).
- **Seleção de trilha ≠ troca imediata**: `MEPlayerItem.select(track:)` (`MEPlayerItem.swift:134-158`) apenas alterna `isEnabled` (= `stream.discard`) e re-seeka para o tempo atual para forçar re-buffer. Legendas de texto retornam `false` (150-153) e **não** seekam: elas são decodificadas continuamente porque `isEnabled` de legenda não-imagem sempre força `AVDISCARD_DEFAULT` (`FFmpegAssetTrack.swift:270-273`). Legendas de imagem só seekam se `options.isSeekImageSubtitle`.
- **Clock de vídeo no primeiro frame**: `currentPlaybackTime` depende de `mainClock().time - startTime` (`MEPlayerItem.swift:44-46`); antes do primeiro `setAudio/setVideo` o valor é o `startTime` semeado no open (238-242). Durante seek, retorna `seekTime` — a UI não vê o tempo "pulando de volta".
- **Seek coalescente**: chamadas repetidas de `seek` durante `.seeking` só sobrescrevem `seekTime`/handler (`MEPlayerItem.swift:690-692`); a read thread compara `seekToTime != seekTime` e re-loopa (500-502). O handler anterior é **silenciosamente descartado** (nunca chamado).
- **`isAudioStalled` muda o clock mestre em runtime**: fim da trilha de áudio (`codecDidFinished`, `MEPlayerItem.swift:718-720`) migra a sincronização para o clock de vídeo; arquivos com áudio mais curto que o vídeo mudam de regime no meio do playback.
- **`Packet.assetTrack` é implicitly-unwrapped e o didSet é o construtor real** (`Model.swift:213-223`): um `Packet` sem `assetTrack` atribuído tem timestamp/size zerados. A ordem `packet.assetTrack = first` antes de `putPacket` (`MEPlayerItem.swift:553`) é obrigatória.
- **Hack de NAL size no extradata**: `extradata[4] == 0xFE` é mutado in-place para `0xFF` e marca `isConvertNALSize` (`FFmpegAssetTrack.swift:188-193`) — afeta o parsing downstream no decoder VTB; não "limpar" esse código.
- **`avformat_seek_file` por bytes**: para formatos `TS_DISCONT` o seek é em bytes com estimativa por bitrate (`MEPlayerItem.swift:459-476`); o fallback `increase *= 180_000` é chute puro. Seeks imprecisos nesses containers são esperados; a precisão real vem do descarte de frames por `seekTime` na trilha (`MEPlayerItemTrack.swift:145-153`, dependente de `options.isAccurateSeek`).
- **Retain cycle intencional no close** (`MEPlayerItem.swift:633-634`): a `closeOperation` captura `self` forte de propósito para o teardown do FFmpeg terminar antes do dealloc. Não converter para `[weak self]`.
- **`timer` no main RunLoop**: o `Timer` de 50 ms é criado lazy na init (`MEPlayerItem.swift:79`) e invalidado só em `.closed` (69); `fireDate` distantFuture/distantPast faz papel de pause/resume. Se `codecDidChangeCapacity` ficar caro, trava o main thread.
- **Loop gapless**: EOF em modo loop cria uma segunda `packetQueue` (`loopPacketQueue`, `MEPlayerItemTrack.swift:183-202`) que recebe os packets do arquivo re-lido do zero enquanto a fila antiga drena; a troca acontece quando `isLoopModel` volta a `false` em `codecDidFinished` (`MEPlayerItem.swift:727-728`). Mexer em seek/shutdown precisa considerar `loopPacketQueue = nil` (`MEPlayerItemTrack.swift:269`).
- **`replace(url:)` reusa o `audioOutput` mas recria `MEPlayerItem` e possivelmente o `videoOutput`** (`KSMEPlayer.swift:317-334`); o `videoOutput` antigo é invalidado no didSet (22-29). `KSOptions.isClearVideoWhereReplace` controla se o último frame fica na tela no shutdown (`KSMEPlayer.swift:423-425`).

## Relação com outros subsistemas

- **Camada de player unificada**: `KSMEPlayer` implementa `MediaPlayerProtocol` (`Sources/KSPlayer/AVPlayer/MediaPlayerProtocol.swift:67`), a mesma interface do `KSAVPlayer`; `KSPlayerLayer` alterna entre eles por `firstPlayerType/secondPlayerType`. Callbacks sobem via `MediaPlayerDelegate` (`readyToPlay`, `changeLoadState`, `changeBuffering`, `finish`).
- **Configuração**: praticamente toda política (buffering, sync, seleção de trilha, hardware decode, filtros, ABR) vive em `KSOptions` (`Sources/KSPlayer/AVPlayer/KSOptions.swift`) e é consumida aqui — este subsistema é o "motor", `KSOptions` é o "painel".
- **Decoders**: `FFmpegDecode` (`Sources/KSPlayer/MEPlayer/FFmpegDecode.swift`), `VideoToolboxDecode`/`DecompressionSession` (`Sources/KSPlayer/MEPlayer/VideoToolboxDecode.swift:111`), `SubtitleDecode` (`Sources/KSPlayer/MEPlayer/SubtitleDecode.swift`) implementam `DecodeProtocol`; filtros FFmpeg em `Filter.swift`, resample/`AudioDescriptor` em `Resample.swift:271`.
- **Renderização de vídeo**: `MetalPlayView` (`Sources/KSPlayer/MEPlayer/MetalPlayView.swift`) consome `getVideoOutputRender` (173) e devolve o clock via `setVideo` (220); usa `AVSampleBufferDisplayLayer`+Metal e expõe `displayLayer` para PiP (contentSource em `KSMEPlayer.swift:40-48`).
- **Renderização de áudio**: `AudioEnginePlayer`/`AudioUnitPlayer`/`AudioGraphPlayer`/`AudioRendererPlayer` consomem `getAudioOutputRender` (`AudioEnginePlayer.swift:273`, `AudioRendererPlayer.swift:71-123`) e devolvem o clock via `setAudio` (`AudioEnginePlayer.swift:323`).
- **Legendas**: as trilhas embutidas entram no pipeline de legendas do app via `SubtitleDataSouce` (`Sources/KSPlayer/Subtitle/SubtitleDataSouce.swift:63`) através das extensões de `EmbedDataSouce.swift`; `SubtitlePart`/`SubtitleModel` vivem em `Sources/KSPlayer/Subtitle/`. O reconhecimento de fala (`SubtitleModel.audioRecognizes`) é alimentado pelo pull de áudio (`MEPlayerItem.swift:852-854`).
- **UI/SwiftUI**: `dynamicInfo` (`MEPlayerItem.swift:83-92`, tipo em `MediaPlayerProtocol.swift:27`) alimenta o painel de debug (`DynamicInfoView`, `Sources/KSPlayer/SwiftUI/KSVideoPlayerView.swift:721`) com fps de display, drops, bitrate e metadata em tempo real.
- **FFmpegKit**: todo o subsistema depende dos módulos `Libavformat/Libavcodec/Libavfilter` do pacote FFmpegKit; o setup global de rede/log é feito uma única vez em `MEPlayerItem.onceInitial` (`MEPlayerItem.swift:94-121`), incluindo o roteamento de logs do avfilter de volta para o `KSOptions.filter(log:)` da instância.
