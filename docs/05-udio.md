# 05 — Subsistema de Áudio (MEPlayer)

Escopo: os 4 backends de saída de áudio do pipeline FFmpeg (`KSMEPlayer`), o contrato `AudioOutput`, o modelo `AudioFrame`, a derivação de formato/multicanal e a view utilitária `AudioPlayerView`. Este documento cobre apenas o caminho MEPlayer; o `KSAVPlayer` (AVFoundation puro) tem áudio gerenciado pelo próprio `AVPlayer` e não passa por aqui.

## Responsabilidade

Receber `AudioFrame` PCM já decodificado e resampleado (produzido por `AudioSwresample` no thread de decode) e entregá-lo ao hardware de saída, aplicando volume, mute e playback rate/pitch. Como efeito colateral do render, o subsistema publica o **relógio de áudio** (`setAudio(time:position:)`), que é o *master clock* da sincronização A/V quando existe trilha de áudio (`MEPlayerItem.mainClock` em `Sources/Lumen/MEPlayer/MEPlayerItem.swift`).

O modelo é **pull**: o backend puxa frames sob demanda via `renderSource?.getAudioOutputRender` a partir do callback de render do Core Audio (exceto `AudioRendererPlayer`, que é push via `enqueue` de `CMSampleBuffer`).

## Tipos principais

| Tipo | Arquivo | Papel |
|---|---|---|
| `AudioOutput` (protocolo) | `Sources/Lumen/MEPlayer/AudioEnginePlayer.swift` | Contrato de backend: `playbackRate`, `volume`, `isMuted`, `init`, `prepare(audioFormat:)`. Herda `FrameOutput` (`Model.swift`): `renderSource`, `play`, `pause`, `flush` |
| `AudioDynamicsProcessor` (protocolo) | `Sources/Lumen/MEPlayer/AudioEnginePlayer.swift` | Expõe o `AudioUnit` do DynamicsProcessor + params computados (`attackTime`, `releaseTime`, `threshold`, `expansionRatio`, `overallGain`) via `AudioUnitGet/SetParameter` |
| `AudioEnginePlayer` | `Sources/Lumen/MEPlayer/AudioEnginePlayer.swift` | **Backend default** (`KSOptions.audioPlayerType`, `Model.swift`). `AVAudioEngine` + `AVAudioSourceNode` + `AVAudioUnitTimePitch` |
| `AudioEngineDynamicsPlayer` | `Sources/Lumen/MEPlayer/AudioEnginePlayer.swift` | Subclasse que insere `AVAudioUnitEffect` (DynamicsProcessor) na cadeia via override de `audioNodes` |
| `AudioGraphPlayer` | `Sources/Lumen/MEPlayer/AudioGraphPlayer.swift` | Backend legado em `AUGraph` (API deprecada pela Apple): timePitch → dynamicsProcessor → mixer → output |
| `AudioUnitPlayer` | `Sources/Lumen/MEPlayer/AudioUnitPlayer.swift` | `AudioUnit` cru (RemoteIO no iOS/tvOS, HALOutput no macOS), sem grafo de efeitos. Rate via filtro FFmpeg `atempo`, mute por `memset` |
| `AudioRendererPlayer` | `Sources/Lumen/MEPlayer/AudioRendererPlayer.swift` | `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`. Único caminho para spatial audio/multicanal "de verdade" no tvOS |
| `AudioFrame` | `Sources/Lumen/MEPlayer/Model.swift` | Frame PCM: `data: [UnsafeMutablePointer<UInt8>?]` (1 ponteiro se interleaved, 1 por canal se planar), `numberOfSamples`, `audioFormat`. Conversores `toFloat`, `toPCMBuffer`, `toCMSampleBuffer` |
| `AudioDescriptor` | `Sources/Lumen/MEPlayer/Resample.swift` | Descreve a trilha fonte (sampleFormat/sampleRate/channel FFmpeg) e calcula o `audioFormat: AVAudioFormat` de saída |
| `AudioSwresample` | `Sources/Lumen/MEPlayer/Resample.swift` | `swr_convert` de `AVFrame` → `AudioFrame` no formato do descriptor; refaz o contexto se a fonte ou o `outChannel` mudarem (`Resample.swift`) |
| `OutputRenderSourceDelegate` (protocolo) | `Sources/Lumen/MEPlayer/Model.swift` | Fonte dos frames e destino do clock (`getAudioOutputRender`, `setAudio(time:position:)`). Implementado por `MEPlayerItem` |
| `AudioPlayerView` | `Sources/Lumen/Audio/AudioPlayerView.swift` | Subclasse de `PlayerView` para player só-áudio (toolbar com play/slider/tempos). Puramente UI; não participa do pipeline de render |

## Seleção de backend

- `KSOptions.audioPlayerType: AudioOutput.Type` — global estático, default `AudioEnginePlayer.self` (`Sources/Lumen/MEPlayer/Model.swift`). Instanciado em `KSMEPlayer.init` (`Sources/Lumen/MEPlayer/KSMEPlayer.swift`), após `KSOptions.setAudioSession` (`KSMEPlayer.swift`).
- O tipo escolhido **muda o formato do resample** (`Sources/Lumen/MEPlayer/Resample.swift`):
 - `interleaved = (audioPlayerType == AudioRendererPlayer.self)` — só o renderer recebe PCM intercalado; os demais recebem planar.
 - `commonFormat` é forçado para `.pcmFormatFloat32` exceto para `AudioRendererPlayer`/`AudioUnitPlayer` (que preservam Int16/Int32/Float64 da fonte).
- Também muda a política de canais no tvOS: `KSOptions.outputNumberOfChannels` só mantém >2 canais se `AudioRendererPlayer` + spatial ativo (`Sources/Lumen/AVPlayer/KSOptions.swift`).

Resumo prático por backend:

| | AudioEnginePlayer (default) | AudioGraphPlayer | AudioUnitPlayer | AudioRendererPlayer |
|---|---|---|---|---|
| API | AVAudioEngine | AUGraph (deprecada) | AudioUnit puro | AVSampleBufferAudioRenderer |
| Modelo | pull (sourceNode) | pull (render callback) | pull (render callback) | push (`enqueue`) |
| Formato exigido | Float32 planar | Float32 planar | formato nativo planar | formato nativo interleaved |
| Rate/pitch | `AVAudioUnitTimePitch` (clamp 1/32...32, `AudioEnginePlayer.swift`) | `kNewTimePitchParam_Rate` (`AudioGraphPlayer.swift`) | filtro FFmpeg `atempo` injetado em `options.audioFilters` (`KSMEPlayer.swift`) | `synchronizer.rate` + `audioTimePitchAlgorithm` (`AudioRendererPlayer.swift`) |
| Volume | `sourceNode.volume` (`AudioEnginePlayer.swift`) | mixer (`kStereoMixerParam_Volume`/`kMultiChannelMixerParam_Volume`, `AudioGraphPlayer.swift`) | **no-op** — var armazenada e nunca aplicada (`AudioUnitPlayer.swift`) | `renderer.volume` (`AudioRendererPlayer.swift`) |
| Mute | `mainMixerNode.outputVolume = 0` (`AudioEnginePlayer.swift`) | iOS: `kMultiChannelMixerParam_Enable`; macOS: volume 0 + `volumeBeforeMute` (`AudioGraphPlayer.swift`) | `memset` no callback (`AudioUnitPlayer.swift`) | `renderer.isMuted` (`AudioRendererPlayer.swift`) |
| Latência compensada | sim (`outputLatency`, `AudioEnginePlayer.swift`) | sim (`AudioGraphPlayer.swift`) | sim (`AudioUnitPlayer.swift`) | não precisa (comentário em `AudioEnginePlayer.swift`) |
| Spatial/passthrough multicanal | limitado (mixa p/ layout da sessão) | limitado | limitado | sim (`allowedAudioSpatializationFormats = .monoStereoAndMultichannel`, `AudioRendererPlayer.swift`) |

Para paridade com Infuse em tvOS (Atmos/spatial), o caminho relevante é `AudioRendererPlayer`.

## Fluxo de dados

1. **Abertura da trilha**: `MEPlayerItem` escolhe a trilha via `av_find_best_stream`/`options.wantedAudio` e cria o `audioTrack` (`Sync`/`AsyncPlayerItemTrack<AudioFrame>`) com capacidade `options.audioFrameMaxCount(fps:channelCount:)` (`Sources/Lumen/MEPlayer/MEPlayerItem.swift`; default `(fps*channels)>>2`, `KSOptions.swift`). `FFmpegAssetTrack` de áudio carrega um `AudioDescriptor` criado do `codecpar` (`FFmpegAssetTrack.swift`).
2. **Formato de saída**: o `AudioDescriptor` computa `audioFormat` combinando formato da fonte com `KSOptions.outputNumberOfChannels` (canais da rota/spatial; macOS fixa 2 em `Resample.swift`) e com os overrides por tipo de backend (`Resample.swift`). O layout tag CoreAudio é derivado do `AVChannelLayout` FFmpeg (fallback: layout default de N canais, depois estéreo — `Resample.swift`).
3. **Decode/resample**: `FFmpegDecode` (thread de decode) roda `avcodec_receive_frame` → `MEFilter` (`options.audioFilters`, `Filter.swift`) → `AudioSwresample.change` que aloca um `AudioFrame` e faz `swr_convert` (`FFmpegDecode.swift`; `Resample.swift`). O frame vai para a `outputRenderQueue` do track.
4. **Prepare**: em `sourceDidOpened`, `KSMEPlayer` chama `audioOutput.prepare(audioFormat:)` na main thread com o `audioFormat` do descriptor da trilha habilitada (`KSMEPlayer.swift`). Cada `prepare` é idempotente por formato (early return se `sourceNodeAudioFormat == audioFormat`) e chama `AVAudioSession.setPreferredOutputNumberOfChannels` (todos os backends; ex.: `AudioEnginePlayer.swift`).
 - `AudioEnginePlayer.prepare` para/reseta o engine, recria o `AVAudioSourceNode` e conecta a cadeia `sourceNode → [dynamics] → timePitch → mainMixer (→ outputNode se >2 canais)` sempre passando o `format` (`AudioEnginePlayer.swift`).
 - `AudioGraphPlayer.prepare` seta `kAudioUnitProperty_StreamFormat`/`AudioChannelLayout` em todas as units, registra o render callback na unit de timePitch e `AUGraphInitialize` (`AudioGraphPlayer.swift`).
 - `AudioUnitPlayer.prepare` seta formato/layout/callback na unit de output e `AudioUnitInitialize` (`AudioUnitPlayer.swift`).
 - `AudioRendererPlayer.prepare` só ajusta a sessão (`AudioRendererPlayer.swift`); o formato viaja dentro de cada `CMSampleBuffer`.
5. **Play/pause**: derivado de `playbackState`+`loadState` em `KSMEPlayer.playOrPause`, sempre na main thread (`KSMEPlayer.swift`).
6. **Render (pull)**: o Core Audio chama o callback em thread de tempo real → `audioPlayerShouldInputData(ioData:numberOfFrames:)` consome `currentRender` (frame corrente + `currentRenderReadOffset` em samples), pedindo novo frame com `renderSource?.getAudioOutputRender` quando esgota (`AudioEnginePlayer.swift`, `AudioGraphPlayer.swift`, `AudioUnitPlayer.swift`). Offsets em bytes usam `audioFormat.sampleSize` (bytes por frame por buffer, `AVFoundationExtension.swift`). O que faltar é zerado com `memset` (silêncio).
 - `MEPlayerItem.getAudioOutputRender` só faz pop da fila e alimenta `SubtitleModel.audioRecognizes` habilitado (`MEPlayerItem.swift`).
7. **Render (push, AudioRendererPlayer)**: `play` calcula o tempo inicial (usa `synchronizer.currentTime` se `hasSufficientMediaDataForReliablePlaybackStart`, senão o pts do próximo frame), `setRate(_:time:)`, e instala `requestMediaDataWhenReady` numa fila serial própria (`AudioRendererPlayer.swift`). `request` agrupa frames até ~50 ms (`sampleRate/20` samples, `AudioRendererPlayer.swift`, via `AudioFrame(array:)` `Model.swift`), converte com `toCMSampleBuffer` (`Model.swift`) e `enqueue`. `audioTimePitchAlgorithm = .spectral` se >2 canais, senão `.timeDomain` (`AudioRendererPlayer.swift`).
8. **Clock**: pós-render notify (`AudioUnitAddRenderNotify`, flag `.unitRenderAction_PostRender`) → `audioPlayerDidRenderSample` interpola o pts pelo offset lido, subtrai `outputLatency` e chama `renderSource?.setAudio(time:position:)` (`AudioEnginePlayer.swift`). No `AudioRendererPlayer` isso vem de um `addPeriodicTimeObserver` de 10 ms na main (`AudioRendererPlayer.swift`, `position: -1`). `MEPlayerItem.setAudio` grava em `audioClock` na main thread (`MEPlayerItem.swift`); o vídeo sincroniza contra `mainClock` em `getVideoOutputRender` (`MEPlayerItem.swift`).
9. **Mudança de formato mid-stream**: cada callback pull compara `sourceNodeAudioFormat != currentRender.audioFormat`; se diferente, despacha `prepare(audioFormat:)` para a main e retorna (`AudioEnginePlayer.swift`, `AudioGraphPlayer.swift`, `AudioUnitPlayer.swift`). O gatilho upstream é `updateAudioFormat` nos descriptors em route change / spatial change (`KSMEPlayer.swift`), que faz o `AudioSwresample` reconstruir o `SwrContext` no próximo `change` (`Resample.swift`) e os frames novos saírem no novo formato.
10. **Flush**: `seek`, `replace(url:)` e `select(track:)` com seek chamam `audioOutput.flush` (`KSMEPlayer.swift`) — zera `currentRender` (e `currentRenderReadOffset` via `didSet`) e relê `outputLatency`; no renderer, `renderer.flush` (`AudioRendererPlayer.swift`).

## Pontos de extensão

- **Novo backend**: implementar `AudioOutput` (`AudioEnginePlayer.swift` + `FrameOutput` `Model.swift`) e apontar `KSOptions.audioPlayerType` antes de criar o player. Atenção: `Resample.swift` decide interleaved/commonFormat comparando **tipos concretos hardcoded** — um backend novo cai no caso "Float32 planar" a menos que esse trecho seja alterado (candidato óbvio de refactor: mover essa decisão para o protocolo, ex. `static var preferredInterleaved/CommonFormat`).
- **Efeitos DSP no caminho default**: sobrescrever `AudioEnginePlayer.audioNodes` (`AudioEnginePlayer.swift`) numa subclasse, anexando os nodes no `init` — é exatamente o que `AudioEngineDynamicsPlayer` faz (`AudioEnginePlayer.swift`). Há nodes comentados prontos para inspiração (reverb/EQ/distortion/delay, `AudioEnginePlayer.swift`). Expor parâmetros via um protocolo à la `AudioDynamicsProcessor` (`AudioEnginePlayer.swift`).
- **Equalizer/loudness (paridade Infuse)**: no caminho `AVAudioEngine`, inserir `AVAudioUnitEQ` em `audioNodes`; no caminho `AudioRendererPlayer` não há grafo — teria que ser filtro FFmpeg.
- **Filtros FFmpeg de áudio**: `options.audioFilters` (`KSOptions.swift`), aplicados por `MEFilter` no decode (`Filter.swift`). É como o `AudioUnitPlayer` implementa rate (`atempo`, `KSMEPlayer.swift`). Serve para downmix custom, normalização (`loudnorm`), delay de áudio, etc.
- **Seleção de trilha**: override de `KSOptions.wantedAudio(tracks:)` (`KSOptions.swift`).
- **Buffer**: override de `KSOptions.audioFrameMaxCount(fps:channelCount:)` (`KSOptions.swift`).
- **Tap de PCM (reconhecimento/visualização)**: `SubtitleModel.audioRecognizes` recebe todo frame consumido (`MEPlayerItem.swift`); `AudioFrame.toFloat`/`toPCMBuffer` (`Model.swift`) já existem para esse consumo.
- **Política de canais**: `KSOptions.outputNumberOfChannels` (`KSOptions.swift`) é `static` mas não `open`; mudanças de política de downmix/passthrough exigem editar essa função no fork.

## Pegadinhas

- **Threads de tempo real**: `audioPlayerShouldInputData` e os render notifies rodam na thread de render do Core Audio. `getAudioOutputRender` não pode bloquear (a fila retorna `nil` e o backend preenche silêncio). Não coloque locks/alocações pesadas nesse caminho.
- **Early return sem zerar buffer**: no caminho de mudança de formato, o `return` dentro do loop (`AudioEnginePlayer.swift`, `AudioGraphPlayer.swift`, `AudioUnitPlayer.swift`) sai da função **antes** do `memset` final — o restante do `ioData` fica com o conteúdo anterior, podendo gerar um estalo momentâneo.
- **`Unmanaged.passUnretained` nos callbacks**: os render callbacks capturam `self` sem retain (`AudioEnginePlayer.swift`, `AudioGraphPlayer.swift`, `AudioUnitPlayer.swift`). O objeto precisa sobreviver enquanto a unit/engine estiver rodando. `AudioGraphPlayer` para o graph no `deinit` (`AudioGraphPlayer.swift`); `AudioUnitPlayer.deinit` só chama `AudioUnitUninitialize` sem `AudioOutputUnitStop` (`AudioUnitPlayer.swift`); `AudioEnginePlayer` não tem `deinit` (confia no dealloc do `AVAudioEngine`).
- **Troca multicanal→estéreo no AVAudioEngine**: chamar `engine.start` imediatamente após reconectar não funciona; precisa reagendar `play` async na main (comentário e workaround em `AudioEnginePlayer.swift`).
- **`mSampleTime == 0`**: o sourceNode ignora renders com timestamp zero para não puxar frames antes do clock do engine iniciar (`AudioEnginePlayer.swift`).
- **`outputLatency`**: lido de `AVAudioSession` no init e **relido no `flush` na main thread** — ler na thread de áudio causa ruído (comentário `AudioEnginePlayer.swift`). Sem bluetooth ≈0.015 s, com ≈0.176 s (`AudioEnginePlayer.swift`). `AVSampleBufferAudioRenderer` não precisa da compensação.
- **`prepare` re-entrante via callback**: quando o formato muda, quem chama `prepare` é um `runOnMainThread` disparado da thread de áudio enquanto o engine continua rodando; `prepare` faz `engine.stop` no meio do render. Funciona, mas qualquer refactor aqui deve preservar essa ordem (stop → reset → attach novo sourceNode → connect → start).
- **`KSOptions.audioPlayerType` é global e lido no meio do pipeline**: `Resample.swift` e `KSOptions.swift` consultam o global na hora — trocar o backend com player vivo produz formato inconsistente. Trocar apenas entre sessões de reprodução.
- **`AudioUnitPlayer.volume` é inerte** (`AudioUnitPlayer.swift`): setar `playbackVolume` no `KSMEPlayer` (`KSMEPlayer.swift`) com esse backend não tem efeito.
- **`AudioFrame(array:)` assume mesmo `dataSize` lógico**: o merge copia `frame.dataSize` bytes por buffer (`Model.swift`); como só é usado no caminho interleaved do renderer (1 buffer), não há problema hoje — cuidado ao reutilizar com frames planar.
- **`toCMSampleBuffer` usa `duration = .invalid`** de propósito: alinhar duration com timescale gerava chiado (comentário `Model.swift`).
- **Efeito colateral em "getter"**: `KSOptions.isSpatialAudioEnabled` chama `setSupportsMultichannelContent` na sessão (`KSOptions.swift`) — é invocada dentro de `outputNumberOfChannels`, que por sua vez roda a cada `AudioDescriptor.updateAudioFormat`.
- **Ordem de inicialização**: `KSOptions.setAudioSession` (categoria `.playback`, mode `.moviePlayback`, policy `.longFormAudio` no tvOS — `KSOptions.swift`) roda no `KSMEPlayer.init` **antes** de instanciar o backend; `AudioUnitPlayer`/`AudioEnginePlayer` leem `outputLatency` no `init`. `prepare(audioFormat:)` só acontece em `sourceDidOpened`, na main.
- **`deinit` do `KSMEPlayer` restaura a sessão para 2 canais** (`KSMEPlayer.swift`) — relevante se outro player coexistir.
- **`setAudio` salta para a main thread** (`MEPlayerItem.swift`): o clock de áudio é atualizado com um pequeno atraso (Task → MainActor via `runOnMainThread`, `Core/Utility.swift`); o comentário do autor diz que isso deixa a reprodução mais suave.
- **`AudioRendererPlayer.pause` desmonta o observer e o request** (`AudioRendererPlayer.swift`); `play` sempre reinstala ambos — chamar `play` duas vezes sem `pause` empilharia observers (hoje o fluxo `playOrPause` evita isso, mas é acoplamento implícito).
- **tvOS + multicanal**: com qualquer backend que não seja `AudioRendererPlayer`, `outputNumberOfChannels` reduz para `min(maximumOutputNumberOfChannels, channelCount)` e o comentário alerta que `maxRouteChannelsCount` não é confiável (`KSOptions.swift`) — TrueHD/Atmos 7.1 vira downmix.

## Relação com outros subsistemas

- **MEPlayerItem (demux/decode/clock)**: é o `renderSource` de todos os backends (`KSMEPlayer.swift`). Fornece frames (`getAudioOutputRender`, `MEPlayerItem.swift`) e recebe o clock (`setAudio`, `MEPlayerItem.swift`). `isAudioStalled` decide se o master clock é áudio ou vídeo (`MEPlayerItem.swift`).
- **Vídeo (MetalPlayView)**: consome o `mainClock` alimentado por este subsistema para decidir render/drop de frames (`MEPlayerItem.swift`, `options.videoClockSync`).
- **Decode/Resample**: `FFmpegDecode` + `AudioSwresample` produzem os `AudioFrame` já no `audioFormat` esperado pelo backend (`FFmpegDecode.swift`, `Resample.swift`); o contrato de formato entre resample e backend passa pelo global `KSOptions.audioPlayerType`.
- **KSOptions**: sessão de áudio (`setAudioSession`), política de canais/spatial (`outputNumberOfChannels`/`isSpatialAudioEnabled`), filtros (`audioFilters`), seleção de trilha (`wantedAudio`), profundidade de buffer (`audioFrameMaxCount`).
- **KSMEPlayer**: ciclo de vida (init/prepare/play/pause/flush/deinit), propagação de `playbackVolume`/`isMuted`/`playbackRate`, e reação a `AVAudioSession.routeChangeNotification`/`spatialPlaybackCapabilitiesChangedNotification` (`KSMEPlayer.swift`).
- **Legendas/ASR**: frames de áudio consumidos são espelhados para `SubtitleModel.audioRecognizes` (`MEPlayerItem.swift`).
- **UI**: `AudioPlayerView` (`Sources/Lumen/Audio/AudioPlayerView.swift`) é apenas uma casca de controles sobre `PlayerView` para mídia sem vídeo; não toca nos backends.
