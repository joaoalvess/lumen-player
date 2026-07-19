# 05 — Subsistema de Áudio (MEPlayer)

Escopo: os 4 backends de saída de áudio do pipeline FFmpeg (`KSMEPlayer`), o contrato `AudioOutput`, o modelo `AudioFrame`, a derivação de formato/multicanal e a view utilitária `AudioPlayerView`. Este documento cobre apenas o caminho MEPlayer; o `KSAVPlayer` (AVFoundation puro) tem áudio gerenciado pelo próprio `AVPlayer` e não passa por aqui.

## Responsabilidade

Receber `AudioFrame` PCM já decodificado e resampleado (produzido por `AudioSwresample` no thread de decode) e entregá-lo ao hardware de saída, aplicando volume, mute e playback rate/pitch. Como efeito colateral do render, o subsistema publica o **relógio de áudio** (`setAudio(time:position:)`), que é o *master clock* da sincronização A/V quando existe trilha de áudio (`MEPlayerItem.mainClock()` em `Sources/KSPlayer/MEPlayer/MEPlayerItem.swift:772-774`).

O modelo é **pull**: o backend puxa frames sob demanda via `renderSource?.getAudioOutputRender()` a partir do callback de render do Core Audio (exceto `AudioRendererPlayer`, que é push via `enqueue` de `CMSampleBuffer`).

## Tipos principais

| Tipo | Arquivo | Papel |
|---|---|---|
| `AudioOutput` (protocolo) | `Sources/KSPlayer/MEPlayer/AudioEnginePlayer.swift:11-17` | Contrato de backend: `playbackRate`, `volume`, `isMuted`, `init()`, `prepare(audioFormat:)`. Herda `FrameOutput` (`Model.swift:66-71`): `renderSource`, `play()`, `pause()`, `flush()` |
| `AudioDynamicsProcessor` (protocolo) | `Sources/KSPlayer/MEPlayer/AudioEnginePlayer.swift:19-78` | Expõe o `AudioUnit` do DynamicsProcessor + params computados (`attackTime`, `releaseTime`, `threshold`, `expansionRatio`, `overallGain`) via `AudioUnitGet/SetParameter` |
| `AudioEnginePlayer` | `Sources/KSPlayer/MEPlayer/AudioEnginePlayer.swift:103-327` | **Backend default** (`KSOptions.audioPlayerType`, `Model.swift:85`). `AVAudioEngine` + `AVAudioSourceNode` + `AVAudioUnitTimePitch` |
| `AudioEngineDynamicsPlayer` | `Sources/KSPlayer/MEPlayer/AudioEnginePlayer.swift:80-101` | Subclasse que insere `AVAudioUnitEffect` (DynamicsProcessor) na cadeia via override de `audioNodes()` |
| `AudioGraphPlayer` | `Sources/KSPlayer/MEPlayer/AudioGraphPlayer.swift:12-303` | Backend legado em `AUGraph` (API deprecada pela Apple): timePitch → dynamicsProcessor → mixer → output |
| `AudioUnitPlayer` | `Sources/KSPlayer/MEPlayer/AudioUnitPlayer.swift:12-197` | `AudioUnit` cru (RemoteIO no iOS/tvOS, HALOutput no macOS), sem grafo de efeitos. Rate via filtro FFmpeg `atempo`, mute por `memset` |
| `AudioRendererPlayer` | `Sources/KSPlayer/MEPlayer/AudioRendererPlayer.swift:11-143` | `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`. Único caminho para spatial audio/multicanal "de verdade" no tvOS |
| `AudioFrame` | `Sources/KSPlayer/MEPlayer/Model.swift:244-418` | Frame PCM: `data: [UnsafeMutablePointer<UInt8>?]` (1 ponteiro se interleaved, 1 por canal se planar), `numberOfSamples`, `audioFormat`. Conversores `toFloat()`, `toPCMBuffer()`, `toCMSampleBuffer()` |
| `AudioDescriptor` | `Sources/KSPlayer/MEPlayer/Resample.swift:271-384` | Descreve a trilha fonte (sampleFormat/sampleRate/channel FFmpeg) e calcula o `audioFormat: AVAudioFormat` de saída |
| `AudioSwresample` | `Sources/KSPlayer/MEPlayer/Resample.swift:223-269` | `swr_convert` de `AVFrame` → `AudioFrame` no formato do descriptor; refaz o contexto se a fonte ou o `outChannel` mudarem (`Resample.swift:246`) |
| `OutputRenderSourceDelegate` (protocolo) | `Sources/KSPlayer/MEPlayer/Model.swift:31-36` | Fonte dos frames e destino do clock (`getAudioOutputRender()`, `setAudio(time:position:)`). Implementado por `MEPlayerItem` |
| `AudioPlayerView` | `Sources/KSPlayer/Audio/AudioPlayerView.swift:13-36` | Subclasse de `PlayerView` para player só-áudio (toolbar com play/slider/tempos). Puramente UI; não participa do pipeline de render |

## Seleção de backend

- `KSOptions.audioPlayerType: AudioOutput.Type` — global estático, default `AudioEnginePlayer.self` (`Sources/KSPlayer/MEPlayer/Model.swift:85`). Instanciado em `KSMEPlayer.init` (`Sources/KSPlayer/MEPlayer/KSMEPlayer.swift:119`), após `KSOptions.setAudioSession()` (`KSMEPlayer.swift:118`).
- O tipo escolhido **muda o formato do resample** (`Sources/KSPlayer/MEPlayer/Resample.swift:368-371`):
  - `interleaved = (audioPlayerType == AudioRendererPlayer.self)` — só o renderer recebe PCM intercalado; os demais recebem planar.
  - `commonFormat` é forçado para `.pcmFormatFloat32` exceto para `AudioRendererPlayer`/`AudioUnitPlayer` (que preservam Int16/Int32/Float64 da fonte).
- Também muda a política de canais no tvOS: `KSOptions.outputNumberOfChannels` só mantém >2 canais se `AudioRendererPlayer` + spatial ativo (`Sources/KSPlayer/AVPlayer/KSOptions.swift:526,535-540`).

Resumo prático por backend:

| | AudioEnginePlayer (default) | AudioGraphPlayer | AudioUnitPlayer | AudioRendererPlayer |
|---|---|---|---|---|
| API | AVAudioEngine | AUGraph (deprecada) | AudioUnit puro | AVSampleBufferAudioRenderer |
| Modelo | pull (sourceNode) | pull (render callback) | pull (render callback) | push (`enqueue`) |
| Formato exigido | Float32 planar | Float32 planar | formato nativo planar | formato nativo interleaved |
| Rate/pitch | `AVAudioUnitTimePitch` (clamp 1/32...32, `AudioEnginePlayer.swift:130`) | `kNewTimePitchParam_Rate` (`AudioGraphPlayer.swift:42-51`) | filtro FFmpeg `atempo` injetado em `options.audioFilters` (`KSMEPlayer.swift:82-90`) | `synchronizer.rate` + `audioTimePitchAlgorithm` (`AudioRendererPlayer.swift:14-16,133`) |
| Volume | `sourceNode.volume` (`AudioEnginePlayer.swift:134-141`) | mixer (`kStereoMixerParam_Volume`/`kMultiChannelMixerParam_Volume`, `AudioGraphPlayer.swift:53-72`) | **no-op** — var armazenada e nunca aplicada (`AudioUnitPlayer.swift:42`) | `renderer.volume` (`AudioRendererPlayer.swift:20-27`) |
| Mute | `mainMixerNode.outputVolume = 0` (`AudioEnginePlayer.swift:143-150`) | iOS: `kMultiChannelMixerParam_Enable`; macOS: volume 0 + `volumeBeforeMute` (`AudioGraphPlayer.swift:74-95`) | `memset` no callback (`AudioUnitPlayer.swift:165-169`) | `renderer.isMuted` (`AudioRendererPlayer.swift:29-36`) |
| Latência compensada | sim (`outputLatency`, `AudioEnginePlayer.swift:318-322`) | sim (`AudioGraphPlayer.swift:296-298`) | sim (`AudioUnitPlayer.swift:190-192`) | não precisa (comentário em `AudioEnginePlayer.swift:319`) |
| Spatial/passthrough multicanal | limitado (mixa p/ layout da sessão) | limitado | limitado | sim (`allowedAudioSpatializationFormats = .monoStereoAndMultichannel`, `AudioRendererPlayer.swift:52-54`) |

Para paridade com Infuse em tvOS (Atmos/spatial), o caminho relevante é `AudioRendererPlayer`.

## Fluxo de dados

1. **Abertura da trilha**: `MEPlayerItem` escolhe a trilha via `av_find_best_stream`/`options.wantedAudio` e cria o `audioTrack` (`Sync`/`AsyncPlayerItemTrack<AudioFrame>`) com capacidade `options.audioFrameMaxCount(fps:channelCount:)` (`Sources/KSPlayer/MEPlayer/MEPlayerItem.swift:396-418`; default `(fps*channels)>>2`, `KSOptions.swift:237-244`). `FFmpegAssetTrack` de áudio carrega um `AudioDescriptor` criado do `codecpar` (`FFmpegAssetTrack.swift:146`).
2. **Formato de saída**: o `AudioDescriptor` computa `audioFormat` combinando formato da fonte com `KSOptions.outputNumberOfChannels` (canais da rota/spatial; macOS fixa 2 em `Resample.swift:300-305`) e com os overrides por tipo de backend (`Resample.swift:320-374`). O layout tag CoreAudio é derivado do `AVChannelLayout` FFmpeg (fallback: layout default de N canais, depois estéreo — `Resample.swift:324-335`).
3. **Decode/resample**: `FFmpegDecode` (thread de decode) roda `avcodec_receive_frame` → `MEFilter` (`options.audioFilters`, `Filter.swift:108`) → `AudioSwresample.change` que aloca um `AudioFrame` e faz `swr_convert` (`FFmpegDecode.swift:33,137-139`; `Resample.swift:245-264`). O frame vai para a `outputRenderQueue` do track.
4. **Prepare**: em `sourceDidOpened`, `KSMEPlayer` chama `audioOutput.prepare(audioFormat:)` na main thread com o `audioFormat` do descriptor da trilha habilitada (`KSMEPlayer.swift:201-209`). Cada `prepare` é idempotente por formato (early return se `sourceNodeAudioFormat == audioFormat`) e chama `AVAudioSession.setPreferredOutputNumberOfChannels` (todos os backends; ex.: `AudioEnginePlayer.swift:162-170`).
   - `AudioEnginePlayer.prepare` para/reseta o engine, recria o `AVAudioSourceNode` e conecta a cadeia `sourceNode → [dynamics] → timePitch → mainMixer (→ outputNode se >2 canais)` sempre passando o `format` (`AudioEnginePlayer.swift:178-198`).
   - `AudioGraphPlayer.prepare` seta `kAudioUnitProperty_StreamFormat`/`AudioChannelLayout` em todas as units, registra o render callback na unit de timePitch e `AUGraphInitialize` (`AudioGraphPlayer.swift:155-202`).
   - `AudioUnitPlayer.prepare` seta formato/layout/callback na unit de output e `AudioUnitInitialize` (`AudioUnitPlayer.swift:65-95`).
   - `AudioRendererPlayer.prepare` só ajusta a sessão (`AudioRendererPlayer.swift:57-62`); o formato viaja dentro de cada `CMSampleBuffer`.
5. **Play/pause**: derivado de `playbackState`+`loadState` em `KSMEPlayer.playOrPause()`, sempre na main thread (`KSMEPlayer.swift:153-166`).
6. **Render (pull)**: o Core Audio chama o callback em thread de tempo real → `audioPlayerShouldInputData(ioData:numberOfFrames:)` consome `currentRender` (frame corrente + `currentRenderReadOffset` em samples), pedindo novo frame com `renderSource?.getAudioOutputRender()` quando esgota (`AudioEnginePlayer.swift:268-311`, `AudioGraphPlayer.swift:246-289`, `AudioUnitPlayer.swift:136-183`). Offsets em bytes usam `audioFormat.sampleSize` (bytes por frame por buffer, `AVFoundationExtension.swift:169-184`). O que faltar é zerado com `memset` (silêncio).
   - `MEPlayerItem.getAudioOutputRender()` só faz pop da fila e alimenta `SubtitleModel.audioRecognizes` habilitado (`MEPlayerItem.swift:850-859`).
7. **Render (push, AudioRendererPlayer)**: `play()` calcula o tempo inicial (usa `synchronizer.currentTime()` se `hasSufficientMediaDataForReliablePlaybackStart`, senão o pts do próximo frame), `setRate(_:time:)`, e instala `requestMediaDataWhenReady` numa fila serial própria (`AudioRendererPlayer.swift:64-99`). `request()` agrupa frames até ~50 ms (`sampleRate/20` samples, `AudioRendererPlayer.swift:120-127`, via `AudioFrame(array:)` `Model.swift:263-287`), converte com `toCMSampleBuffer()` (`Model.swift:360-417`) e `enqueue`. `audioTimePitchAlgorithm = .spectral` se >2 canais, senão `.timeDomain` (`AudioRendererPlayer.swift:133`).
8. **Clock**: pós-render notify (`AudioUnitAddRenderNotify`, flag `.unitRenderAction_PostRender`) → `audioPlayerDidRenderSample` interpola o pts pelo offset lido, subtrai `outputLatency` e chama `renderSource?.setAudio(time:position:)` (`AudioEnginePlayer.swift:313-326`). No `AudioRendererPlayer` isso vem de um `addPeriodicTimeObserver` de 10 ms na main (`AudioRendererPlayer.swift:93-98`, `position: -1`). `MEPlayerItem.setAudio` grava em `audioClock` na main thread (`MEPlayerItem.swift:789-796`); o vídeo sincroniza contra `mainClock()` em `getVideoOutputRender` (`MEPlayerItem.swift:798-808`).
9. **Mudança de formato mid-stream**: cada callback pull compara `sourceNodeAudioFormat != currentRender.audioFormat`; se diferente, despacha `prepare(audioFormat:)` para a main e retorna (`AudioEnginePlayer.swift:283-291`, `AudioGraphPlayer.swift:261-269`, `AudioUnitPlayer.swift:151-159`). O gatilho upstream é `updateAudioFormat()` nos descriptors em route change / spatial change (`KSMEPlayer.swift:168-190`), que faz o `AudioSwresample` reconstruir o `SwrContext` no próximo `change` (`Resample.swift:246-252`) e os frames novos saírem no novo formato.
10. **Flush**: `seek`, `replace(url:)` e `select(track:)` com seek chamam `audioOutput.flush()` (`KSMEPlayer.swift:330,370,469`) — zera `currentRender` (e `currentRenderReadOffset` via `didSet`) e relê `outputLatency`; no renderer, `renderer.flush()` (`AudioRendererPlayer.swift:110-112`).

## Pontos de extensão

- **Novo backend**: implementar `AudioOutput` (`AudioEnginePlayer.swift:11-17` + `FrameOutput` `Model.swift:66-71`) e apontar `KSOptions.audioPlayerType` antes de criar o player. Atenção: `Resample.swift:368-371` decide interleaved/commonFormat comparando **tipos concretos hardcoded** — um backend novo cai no caso "Float32 planar" a menos que esse trecho seja alterado (candidato óbvio de refactor: mover essa decisão para o protocolo, ex. `static var preferredInterleaved/CommonFormat`).
- **Efeitos DSP no caminho default**: sobrescrever `AudioEnginePlayer.audioNodes()` (`AudioEnginePlayer.swift:208-210`) numa subclasse, anexando os nodes no `init` — é exatamente o que `AudioEngineDynamicsPlayer` faz (`AudioEnginePlayer.swift:91-100`). Há nodes comentados prontos para inspiração (reverb/EQ/distortion/delay, `AudioEnginePlayer.swift:108-111`). Expor parâmetros via um protocolo à la `AudioDynamicsProcessor` (`AudioEnginePlayer.swift:19-78`).
- **Equalizer/loudness (paridade Infuse)**: no caminho `AVAudioEngine`, inserir `AVAudioUnitEQ` em `audioNodes()`; no caminho `AudioRendererPlayer` não há grafo — teria que ser filtro FFmpeg.
- **Filtros FFmpeg de áudio**: `options.audioFilters` (`KSOptions.swift:71`), aplicados por `MEFilter` no decode (`Filter.swift:108`). É como o `AudioUnitPlayer` implementa rate (`atempo`, `KSMEPlayer.swift:82-90`). Serve para downmix custom, normalização (`loudnorm`), delay de áudio, etc.
- **Seleção de trilha**: override de `KSOptions.wantedAudio(tracks:)` (`KSOptions.swift:229-231`).
- **Buffer**: override de `KSOptions.audioFrameMaxCount(fps:channelCount:)` (`KSOptions.swift:237-244`).
- **Tap de PCM (reconhecimento/visualização)**: `SubtitleModel.audioRecognizes` recebe todo frame consumido (`MEPlayerItem.swift:850-859`); `AudioFrame.toFloat()`/`toPCMBuffer()` (`Model.swift:297-358`) já existem para esse consumo.
- **Política de canais**: `KSOptions.outputNumberOfChannels` (`KSOptions.swift:522-553`) é `static` mas não `open`; mudanças de política de downmix/passthrough exigem editar essa função no fork.

## Pegadinhas

- **Threads de tempo real**: `audioPlayerShouldInputData` e os render notifies rodam na thread de render do Core Audio. `getAudioOutputRender()` não pode bloquear (a fila retorna `nil` e o backend preenche silêncio). Não coloque locks/alocações pesadas nesse caminho.
- **Early return sem zerar buffer**: no caminho de mudança de formato, o `return` dentro do loop (`AudioEnginePlayer.swift:290`, `AudioGraphPlayer.swift:268`, `AudioUnitPlayer.swift:158`) sai da função **antes** do `memset` final — o restante do `ioData` fica com o conteúdo anterior, podendo gerar um estalo momentâneo.
- **`Unmanaged.passUnretained` nos callbacks**: os render callbacks capturam `self` sem retain (`AudioEnginePlayer.swift:245`, `AudioGraphPlayer.swift:222,243`, `AudioUnitPlayer.swift:112,133`). O objeto precisa sobreviver enquanto a unit/engine estiver rodando. `AudioGraphPlayer` para o graph no `deinit` (`AudioGraphPlayer.swift:211-216`); `AudioUnitPlayer.deinit` só chama `AudioUnitUninitialize` sem `AudioOutputUnitStop` (`AudioUnitPlayer.swift:104-106`); `AudioEnginePlayer` não tem `deinit` (confia no dealloc do `AVAudioEngine`).
- **Troca multicanal→estéreo no AVAudioEngine**: chamar `engine.start()` imediatamente após reconectar não funciona; precisa reagendar `play()` async na main (comentário e workaround em `AudioEnginePlayer.swift:199-205`).
- **`mSampleTime == 0`**: o sourceNode ignora renders com timestamp zero para não puxar frames antes do clock do engine iniciar (`AudioEnginePlayer.swift:179-181`).
- **`outputLatency`**: lido de `AVAudioSession` no init e **relido no `flush()` na main thread** — ler na thread de áudio causa ruído (comentário `AudioEnginePlayer.swift:230-233`). Sem bluetooth ≈0.015 s, com ≈0.176 s (`AudioEnginePlayer.swift:319-321`). `AVSampleBufferAudioRenderer` não precisa da compensação.
- **`prepare` re-entrante via callback**: quando o formato muda, quem chama `prepare` é um `runOnMainThread` disparado da thread de áudio enquanto o engine continua rodando; `prepare` faz `engine.stop()` no meio do render. Funciona, mas qualquer refactor aqui deve preservar essa ordem (stop → reset → attach novo sourceNode → connect → start).
- **`KSOptions.audioPlayerType` é global e lido no meio do pipeline**: `Resample.swift:368-371` e `KSOptions.swift:526` consultam o global na hora — trocar o backend com player vivo produz formato inconsistente. Trocar apenas entre sessões de reprodução.
- **`AudioUnitPlayer.volume` é inerte** (`AudioUnitPlayer.swift:42`): setar `playbackVolume` no `KSMEPlayer` (`KSMEPlayer.swift:297-304`) com esse backend não tem efeito.
- **`AudioFrame(array:)` assume mesmo `dataSize` lógico**: o merge copia `frame.dataSize` bytes por buffer (`Model.swift:280-286`); como só é usado no caminho interleaved do renderer (1 buffer), não há problema hoje — cuidado ao reutilizar com frames planar.
- **`toCMSampleBuffer` usa `duration = .invalid`** de propósito: alinhar duration com timescale gerava chiado (comentário `Model.swift:402-404`).
- **Efeito colateral em "getter"**: `KSOptions.isSpatialAudioEnabled` chama `setSupportsMultichannelContent` na sessão (`KSOptions.swift:512-520`) — é invocada dentro de `outputNumberOfChannels`, que por sua vez roda a cada `AudioDescriptor.updateAudioFormat()`.
- **Ordem de inicialização**: `KSOptions.setAudioSession()` (categoria `.playback`, mode `.moviePlayback`, policy `.longFormAudio` no tvOS — `KSOptions.swift:494-509`) roda no `KSMEPlayer.init` **antes** de instanciar o backend; `AudioUnitPlayer`/`AudioEnginePlayer` leem `outputLatency` no `init`. `prepare(audioFormat:)` só acontece em `sourceDidOpened`, na main.
- **`deinit` do `KSMEPlayer` restaura a sessão para 2 canais** (`KSMEPlayer.swift:140-143`) — relevante se outro player coexistir.
- **`setAudio` salta para a main thread** (`MEPlayerItem.swift:789-796`): o clock de áudio é atualizado com um pequeno atraso (Task → MainActor via `runOnMainThread`, `Core/Utility.swift:355-363`); o comentário do autor diz que isso deixa a reprodução mais suave.
- **`AudioRendererPlayer.pause()` desmonta o observer e o request** (`AudioRendererPlayer.swift:101-108`); `play()` sempre reinstala ambos — chamar `play()` duas vezes sem `pause()` empilharia observers (hoje o fluxo `playOrPause` evita isso, mas é acoplamento implícito).
- **tvOS + multicanal**: com qualquer backend que não seja `AudioRendererPlayer`, `outputNumberOfChannels` reduz para `min(maximumOutputNumberOfChannels, channelCount)` e o comentário alerta que `maxRouteChannelsCount` não é confiável (`KSOptions.swift:535-540`) — TrueHD/Atmos 7.1 vira downmix.

## Relação com outros subsistemas

- **MEPlayerItem (demux/decode/clock)**: é o `renderSource` de todos os backends (`KSMEPlayer.swift:129`). Fornece frames (`getAudioOutputRender`, `MEPlayerItem.swift:850`) e recebe o clock (`setAudio`, `MEPlayerItem.swift:789`). `isAudioStalled` decide se o master clock é áudio ou vídeo (`MEPlayerItem.swift:28,694,772-774`).
- **Vídeo (MetalPlayView)**: consome o `mainClock()` alimentado por este subsistema para decidir render/drop de frames (`MEPlayerItem.swift:798-847`, `options.videoClockSync`).
- **Decode/Resample**: `FFmpegDecode` + `AudioSwresample` produzem os `AudioFrame` já no `audioFormat` esperado pelo backend (`FFmpegDecode.swift:33`, `Resample.swift:223-269`); o contrato de formato entre resample e backend passa pelo global `KSOptions.audioPlayerType`.
- **KSOptions**: sessão de áudio (`setAudioSession`), política de canais/spatial (`outputNumberOfChannels`/`isSpatialAudioEnabled`), filtros (`audioFilters`), seleção de trilha (`wantedAudio`), profundidade de buffer (`audioFrameMaxCount`).
- **KSMEPlayer**: ciclo de vida (init/prepare/play/pause/flush/deinit), propagação de `playbackVolume`/`isMuted`/`playbackRate`, e reação a `AVAudioSession.routeChangeNotification`/`spatialPlaybackCapabilitiesChangedNotification` (`KSMEPlayer.swift:132-137,168-190`).
- **Legendas/ASR**: frames de áudio consumidos são espelhados para `SubtitleModel.audioRecognizes` (`MEPlayerItem.swift:851-854`).
- **UI**: `AudioPlayerView` (`Sources/KSPlayer/Audio/AudioPlayerView.swift`) é apenas uma casca de controles sobre `PlayerView` para mídia sem vídeo; não toca nos backends.
