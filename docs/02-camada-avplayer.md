# 02 — Camada AVPlayer (`Sources/Lumen/AVPlayer/`)

Documento técnico do subsistema que define o **contrato público do player** (protocolos, opções, estados) e a **máquina de estados** que orquestra os dois motores de reprodução (`KSAVPlayer` sobre AVFoundation e `KSMEPlayer` sobre FFmpeg). Todos os paths são relativos à raiz do repo.

## Responsabilidade

- Definir o contrato que qualquer motor de player precisa cumprir: `MediaPlayback` + `MediaPlayerProtocol` + `MediaPlayerDelegate` (`Sources/Lumen/AVPlayer/MediaPlayerProtocol.swift`).
- Implementar o motor nativo `KSAVPlayer` (wrapper de `AVQueuePlayer`) que cumpre esse contrato (`Sources/Lumen/AVPlayer/KSAVPlayer.swift`).
- Orquestrar ciclo de vida, troca/fallback de motor, playlist, PiP, remote commands (Control Center), interrupções de áudio e background via `KSPlayerLayer` — a máquina de estados `KSPlayerState` (`Sources/Lumen/AVPlayer/KSPlayerLayer.swift`).
- Centralizar **toda** a configuração e os pontos de customização por herança em `KSOptions` (`Sources/Lumen/AVPlayer/KSOptions.swift`), incluindo defaults globais estáticos (`KSOptions.swift`).
- Expor a ponte SwiftUI `KSVideoPlayer` + `Coordinator` (`Sources/Lumen/AVPlayer/KSVideoPlayer.swift`).
- Tipos compartilhados de domínio: estados, erros, HDR, buffering, clock, I/O customizado (`Sources/Lumen/AVPlayer/PlayerDefines.swift`).
- PiP com manipulação da pilha de navegação (`Sources/Lumen/AVPlayer/KSPictureInPictureController.swift`).

O que **não** está aqui: decodificação FFmpeg (subsistema MEPlayer), parsing/renderização de legendas (subsistema Subtitle), UI de controles (subsistemas Video e SwiftUI).

## Tipos principais

| Tipo | Arquivo | Papel |
|---|---|---|
| `MediaPlayback` (protocol) | `MediaPlayerProtocol.swift` | Contrato mínimo: `duration`, `currentPlaybackTime`, `prepareToPlay`, `shutdown`, `seek(time:completion:)` |
| `MediaPlayerProtocol` (protocol) | `MediaPlayerProtocol.swift` | Contrato completo do motor: `view`, `playbackState`, `loadState`, `tracks(mediaType:)`, `select(track:)`, `pipController`, `init(url:options:)`, `replace(url:options:)` |
| `MediaPlayerDelegate` (protocol, `@MainActor`) | `MediaPlayerProtocol.swift` | Callbacks do motor para o orquestrador: `readyToPlay`, `changeLoadState`, `changeBuffering(progress:)`, `playBack(loopCount:)`, `finish(error:)` |
| `MediaPlayerTrack` (protocol) | `MediaPlayerProtocol.swift` | Abstração de trilha (vídeo/áudio/legenda): `trackID`, `languageCode`, `formatDescription`, `dovi`, `fieldOrder`; helpers derivados em `MediaPlayerProtocol.swift` (`dynamicRange`, `colorSpace`, `naturalSize`) |
| `MediaPlaybackState` (enum) | `MediaPlayerProtocol.swift` | Estado de transporte do motor: `idle/playing/paused/seeking/finished/stopped` |
| `MediaLoadState` (enum) | `MediaPlayerProtocol.swift` | Estado de buffer do motor: `idle/loading/playable` |
| `DynamicInfo` (class, `ObservableObject`) | `MediaPlayerProtocol.swift` | Métricas em tempo real via closures (bitrate, bytesRead, `displayFPS`, frames dropados); `KSAVPlayer` retorna `nil` (`KSAVPlayer.swift`) |
| `Chapter` (struct) | `MediaPlayerProtocol.swift` | Capítulo (`start/end/title`); `KSAVPlayer` retorna `[]` (`KSAVPlayer.swift`) |
| `DOVIDecoderConfigurationRecord` (struct) | `MediaPlayerProtocol.swift` | Config Dolby Vision exposta pela trilha |
| `FFmpegFieldOrder` (enum) | `MediaPlayerProtocol.swift` | Ordem de campos (entrelaçamento) — usado por `KSOptions.process(assetTrack:)` |
| `KSPlayerState` (enum) | `KSPlayerLayer.swift` | Máquina de estados pública: `initialized/preparing/readyToPlay/buffering/bufferFinished/paused/playedToTheEnd/error`; `isPlaying == buffering || bufferFinished` |
| `KSPlayerLayerDelegate` (protocol, `@MainActor`) | `KSPlayerLayer.swift` | Callbacks do orquestrador para a UI: estado, tempo (100 ms), fim/erro, contagem de rebuffer |
| `KSPlayerLayer` (class, `open`) | `KSPlayerLayer.swift` | Orquestrador: seleção/fallback de motor, timer de progresso, Now Playing, remote commands, playlist (`urls`), background/foreground, interrupção de áudio, PiP |
| `KSAVPlayer` (class, `@MainActor`) | `KSAVPlayer.swift` | Motor AVFoundation: `AVQueuePlayer` + KVO de `AVPlayerItem`; loop via `AVPlayerLooper` |
| `KSAVPlayerView` (class) | `KSAVPlayer.swift` | `UIView`/`NSView` com `layerClass = AVPlayerLayer`; mapeia `contentMode` ↔ `videoGravity` |
| `AVMediaPlayerTrack` (class) | `KSAVPlayer.swift` | Adapter `AVPlayerItemTrack` → `MediaPlayerTrack` |
| `KSOptions` (class, `open`) | `KSOptions.swift` | Configuração por reprodução + hooks `open` para customização; defaults estáticos em `KSOptions.swift` |
| `KSClock` (struct) | `KSOptions.swift` | Clock mestre para A/V sync: `getTime = time.seconds + (CACurrentMediaTime - lastMediaTime)` |
| `LogHandler` / `OSLog` / `FileLog` / `LogLevel` / `KSLog` | `KSOptions.swift` | Infra de log plugável (`KSOptions.logger`, `KSOptions.logLevel`) |
| `KSVideoPlayer` (struct, `UIViewRepresentable`) | `KSVideoPlayer.swift` | Ponte SwiftUI; `Equatable` **só por url** |
| `KSVideoPlayer.Coordinator` (class, `@MainActor`, `ObservableObject`) | `KSVideoPlayer.swift` | Dono do `KSPlayerLayer` na camada SwiftUI; expõe callbacks `onPlay/onFinish/onStateChanged/onBufferChanged/onSwipe` e `subtitleModel`/`timemodel` |
| `ControllerTimeModel` (class) | `KSVideoPlayer.swift` | Tempo em `Int` para reduzir invalidações SwiftUI |
| `KSPictureInPictureController` (class) | `KSPictureInPictureController.swift` | Subclasse de `AVPictureInPictureController` com singleton estático e manipulação de navigation stack (gated por `KSOptions.isPipPopViewController`) |
| `DynamicRange` (enum) | `PlayerDefines.swift` | SDR/HDR10/HLG/DV; `availableHDRModes` por plataforma; primaries/transfer/matrix |
| `DisplayEnum` (enum, `@MainActor`) | `PlayerDefines.swift` | `plane/vr/vrBox` — `!= .plane` força KSMEPlayer (`KSPlayerLayer.swift`) |
| `VideoAdaptationState` / `ClockProcessType` | `PlayerDefines.swift` | Estado de ABR e decisão de sync (`remain/next/dropNextFrame/dropNextPacket/dropGOPPacket/flush/seek`) |
| `CapacityProtocol` / `LoadingState` | `PlayerDefines.swift` | Entrada/saída do algoritmo de buffering `KSOptions.playable` |
| `KSPlayerErrorCode` / `KSPlayerErrorDomain` | `PlayerDefines.swift` | Códigos de erro (majoritariamente FFmpeg) |
| `AbstractAVIOContext` (class, `open`) | `PlayerDefines.swift` | I/O customizado (read/write/seek/fileSize) plugado via `KSOptions.process(url:)` |
| `TimeType` + `toString(for:)` | `PlayerDefines.swift` | Formatação de tempo para UI |
| `setHttpProxy` (função) | `MediaPlayerProtocol.swift` | Copia proxy do sistema para env `http_proxy` (usada pelo lado FFmpeg; gated por `KSOptions.useSystemHTTPProxy`) |

## Fluxo de dados

Cadeia completa (caminho SwiftUI): `KSVideoPlayer` → `Coordinator` → `KSPlayerLayer` → `MediaPlayerProtocol` (motor) → callbacks `MediaPlayerDelegate` → `KSPlayerLayer` (máquina de estados) → callbacks `KSPlayerLayerDelegate` → `Coordinator` → UI.

1. **Criação.** `KSVideoPlayer.makeUIView` chama `Coordinator.makeView(url:options:)` (`KSVideoPlayer.swift`). Se já existe `playerLayer` com a mesma URL, reutiliza a view; se a URL mudou, chama `playerLayer.set(url:options:)`; senão cria `KSPlayerLayer(url:options:delegate:)`.
2. **Seleção do motor.** No `KSPlayerLayer.init` (`KSPlayerLayer.swift`): `options.display != .plane` força `KSMEPlayer` (referência direta ao tipo), senão usa `KSOptions.firstPlayerType` (default `KSAVPlayer.self`, `KSOptions.swift`). O motor é instanciado com `firstPlayerType.init(url:options:)`, recebe `playbackRate = options.startPlayRate`, `delegate = self` e `contentMode = .scaleAspectFit`. Se `isAutoPlay` (default `KSOptions.isAutoPlay`, `KSOptions.swift`), chama `prepareToPlay` ainda no init. Registra observers de background/foreground, rota AirPlay e interrupção de áudio, e remote commands se `options.registerRemoteControll`.
3. **Preparação.** `KSPlayerLayer.prepareToPlay` seta `state = .preparing`, grava `startTime` e delega `player.prepareToPlay` (`KSPlayerLayer.swift`). No `KSAVPlayer`: cria `AVPlayerItem(asset: urlAsset)` no main thread e chama `replaceCurrentItem` (`KSAVPlayer.swift`); se `options.isLoopPlay`, usa `AVPlayerLooper`. O `AVURLAsset` foi criado no init com `options.avOptions` (headers/cookies).
4. **Observação KVO.** A troca de `currentItem` dispara `observer(playerItem:)` (`KSAVPlayer.swift`), que registra: notificações `AVPlayerItemDidPlayToEndTime`/`FailedToPlayToEndTime`, e KVO de `status`, `loadedTimeRanges`, `isPlaybackBufferEmpty`, `isPlaybackLikelyToKeepUp`, `isPlaybackBufferFull`.
5. **Ready.** `item.status == .readyToPlay` → `updateStatus` (`KSAVPlayer.swift`): materializa `mediaPlayerTracks`, valida existência de vídeo playable (senão `error = NSError(errorCode: .videoTracksUnplayable)`), desabilita trilhas de áudio extras, calcula `duration`/`fileSize` e seta `isReadyToPlay = true`, cujo `didSet` chama `delegate?.readyToPlay(player:)`.
6. **Reação ao ready.** `KSPlayerLayer.readyToPlay` (`KSPlayerLayer.swift`): `state = .readyToPlay`, redimensiona janela no macOS, habilita PiP automático no iOS, popula `MPNowPlayingInfoCenter` com duração/título/idiomas (`updateNowPlayingInfo`), e — se `isAutoPlay` — executa o seek pendente (`shouldSeekTo`, vindo de `seek` chamado antes do ready) ou `play`.
7. **Buffer → estado.** Mudanças de buffer no item alteram `loadState` do motor (`KSAVPlayer.swift`); o `didSet` de `loadState`/`playbackState` chama `playOrPause` que efetivamente dá `player.play/pause` e notifica `delegate?.changeLoadState`. `KSPlayerLayer.changeLoadState` (`KSPlayerLayer.swift`) converte para `state = .buffering/.bufferFinished`, mede tempo de primeira carga (dict `firstTime/dnsTime/tcpTime/openTime/findTime/readyTime/...` usando os timestamps de `KSOptions`) e incrementa `bufferedCount`. Progresso 0–100 flui por `changeBuffering` → `@Published bufferingProgress` (origem em `KSAVPlayer.updatePlayableDuration`, `KSAVPlayer.swift`: `loadedTime * 100 / preferredForwardBufferDuration`).
8. **Progresso de tempo.** Timer de 0,1 s (`KSPlayerLayer.swift`) chama `delegate?.player(layer:currentTime:totalTime:)` e atualiza `MPNowPlayingInfoPropertyElapsedPlaybackTime`. No `Coordinator` (`KSVideoPlayer.swift`) isso alimenta `onPlay`, `timemodel` (convertido para `Int`) e `subtitleModel.subtitle(currentTime:)` — é daqui que a legenda é sincronizada. O timer é acordado/dormido via `fireDate` em `play/pause/finish` (`KSPlayerLayer.swift`).
9. **Seek.** `KSPlayerLayer.seek(time:autoPlay:completion:)` (`KSPlayerLayer.swift`): se o player ainda não está ready, apenas armazena `shouldSeekTo` (consumido no passo 6). No `KSAVPlayer.seek` (`KSAVPlayer.swift`): `playbackState = .seeking`, tolerância `.zero` se `options.isAccurateSeek` senão `.positiveInfinity`; enquanto `shouldSeekTo > 0`, `currentPlaybackTime` retorna o alvo do seek.
10. **Fim ou erro.** `AVPlayerItemDidPlayToEndTime` → `playbackState = .finished` (se `!isLoopPlay`) → `delegate?.finish(player:error:nil)` (`KSAVPlayer.swift`). `KSPlayerLayer.finish` (`KSPlayerLayer.swift`): **com erro**, se o motor atual não é o `secondPlayerType` (default `KSMEPlayer`, `KSOptions.swift`), substitui `player` pelo segundo motor com a mesma URL e retorna — o fallback automático AVPlayer→FFmpeg; só vira `state = .error` se o segundo motor também falhar. **Sem erro**, emite tempo final, `state = .playedToTheEnd` e avança a playlist (`nextPlayer`).
11. **Troca de motor.** O `didSet` de `player` (`KSPlayerLayer.swift`) insere a view nova **abaixo** da antiga na mesma superview com constraints, remove a antiga, transfere `playbackRate`/`playbackVolume`, reseta `contentMode = .scaleAspectFit` e chama `prepareToPlay` se `isAutoPlay`.
12. **Troca de URL.** `set(url:options:)` atribui `options` e depois `url` no main thread (`KSPlayerLayer.swift`). O `didSet` de `url` reavalia o tipo de motor (AirPlay ativo força `KSAVPlayer`): mesmo tipo + mesma URL → só `play`; mesmo tipo + URL nova → `stop` + `player.replace(url:options:)`; tipo diferente → `stop` + novo motor.
13. **Estados → UI.** Toda transição de `state` notifica `delegate?.player(layer:state:)` no main thread (via `willSet`, `KSPlayerLayer.swift`). O `Coordinator` repassa a `onStateChanged`, e em `.readyToPlay` agenda a inclusão de legendas embutidas com 1 s de atraso (`KSVideoPlayer.swift`); em `.preparing` instala gesture recognizers de swipe.

## Pontos de extensão

**1. Subclassear `KSOptions`** — o mecanismo primário. Todos estes métodos são `open` e chamados pelo pipeline (a maioria pelo lado MEPlayer):

| Método | Arquivo | O que controla |
|---|---|---|
| `playable(capacitys:isFirst:isSeek:)` | `KSOptions.swift` | Algoritmo de buffering: decide `LoadingState.isPlayable` a partir de `CapacityProtocol` por trilha |
| `adaptable(state:)` | `KSOptions.swift` | ABR: retorna `(bitrateAtual, bitrateNovo)` ou `nil` |
| `wantedVideo(tracks:)` / `wantedAudio(tracks:)` | `KSOptions.swift` | Seleção inicial de trilha (retornar índice ou `nil` p/ automático) |
| `videoFrameMaxCount(fps:naturalSize:isLive:)` / `audioFrameMaxCount(fps:channelCount:)` | `KSOptions.swift` | Tamanho das filas de frames decodificados |
| `customizeDar(sar:par:)` | `KSOptions.swift` | Override do display aspect ratio |
| `isUseDisplayLayer` | `KSOptions.swift` | `AVSampleBufferDisplayLayer` vs Metal no MEPlayer |
| `urlIO(log:)` / `filter(log:)` / `sei(string:)` | `KSOptions.swift` | Hooks de log do FFmpeg: timestamps de DNS/TCP, detecção de entrelaçamento (idet), SEI |
| `process(assetTrack:)` | `KSOptions.swift` | Pré-decodificação: ex. injeta filtro `yadif` p/ deinterlace e desliga hardwareDecode |
| `updateVideo(refreshRate:isDovi:formatDescription:)` | `KSOptions.swift` | tvOS: match de refresh rate e HDR via `AVDisplayCriteria` |
| `videoClockSync(main:nextVideoTime:fps:frameCount:)` | `KSOptions.swift` | Política de A/V sync: retorna `ClockProcessType` (drop/flush/seek) |
| `availableDynamicRange(_:)` | `KSOptions.swift` | Negociação HDR entre conteúdo, `destinationDynamicRange` e display |
| `playerLayerDeinit` | `KSOptions.swift` | Cleanup no deinit do layer (reseta `preferredDisplayCriteria`) |
| `liveAdaptivePlaybackRate(loadingState:)` | `KSOptions.swift` | Rate adaptativo p/ live (catch-up); default `nil` |
| `process(url:)` | `KSOptions.swift` | Retornar um `AbstractAVIOContext` (`PlayerDefines.swift`) para I/O customizado (fonte não-URL, DRM, cache próprio) |

**2. Propriedades de instância de `KSOptions`** (por reprodução) — todas em `KSOptions.swift`:
rede/formato: `avOptions` (dicionário do `AVURLAsset`), `formatContextOptions` (opções do avformat; defaults `scan_all_pmts=1`, `reconnect=1`, `reconnect_streamed=1` setados no init), `decoderOptions` (defaults `threads=auto`, `refcounted_frames=1`), `probesize`, `maxAnalyzeDuration`, `referer`, `userAgent`, `appendHeader(_:)` (escreve **tanto** em `avOptions` quanto em `formatContextOptions["headers"]` — vale pros dois motores), `setCookie(_:)`, `cache` (quebrado — comentário), `outputURL` (gravação de stream), `seekFlags`.
Buffer/transporte: `preferredForwardBufferDuration` (`@Published`; propagado ao `AVPlayerItem` em `KSAVPlayer.swift`), `maxBufferDuration`, `isSecondOpen`, `isAccurateSeek`, `isLoopPlay`, `isSeekedAutoPlay`, `startPlayTime`, `startPlayRate` (aplicado em `KSPlayerLayer.swift`).
Vídeo: `display`, `videoDelay`, `autoDeInterlace`, `autoRotate`, `destinationDynamicRange`, `videoAdaptable`, `videoFilters`, `syncDecodeVideo`, `hardwareDecode`, `asynchronousDecompression`, `videoDisable`, `canStartPictureInPictureAutomaticallyFromInline`, `automaticWindowResize`, `videoInterlacingType` (`@Published`, saída da detecção idet), `lowres`, `nobuffer`, `codecLowDelay`.
Áudio: `audioFilters`, `syncDecodeAudio`.
Legenda: `autoSelectEmbedSubtitle`, `isSeekImageSubtitle`.
Sistema: `registerRemoteControll`.
Métricas `internal(set)` preenchidas pelo pipeline: `formatName`, `prepareTime`, `dnsStartTime`, `tcpStartTime`, `tcpConnectedTime`, `openTime`, `findTime`, `readyTime`, `readAudioTime`, `readVideoTime`, `decodeAudioTime`, `decodeVideoTime`.

**3. Estáticas de `KSOptions`** (defaults globais, `KSOptions.swift`): `firstPlayerType`/`secondPlayerType` ( — **o** ponto para escolher/registrar motor; `nil` em `secondPlayerType` desliga o fallback), `preferredForwardBufferDuration=3.0`, `maxBufferDuration=30.0`, `isSecondOpen=false`, `isAccurateSeek=false`, `isLoopPlay=false`, `isAutoPlay=true`, `isSeekedAutoPlay=true`, `hardwareDecode=true`, `asynchronousDecompression=false`, `isPipPopViewController=false`, `canStartPictureInPictureAutomaticallyFromInline=true`, `preferredFrame=true`, `useSystemHTTPProxy=true`, `logLevel`, `logger`. Estáticas **definidas em outros arquivos**: `canBackgroundPlay` e `animateDelayTimeInterval` (`Sources/Lumen/Video/VideoPlayerView.swift`), `audioPlayerType`, `yadifMode`, `deInterlaceAddIdet`, `colorSpace(...)` (`Sources/Lumen/MEPlayer/Model.swift`), `subtitleDataSouces` (`Sources/Lumen/Subtitle/SubtitleDataSouce.swift`).

**4. Novo motor de player**: implementar `MediaPlayerProtocol` (`MediaPlayerProtocol.swift`) — exige `init(url:options:)`, emissão correta dos 5 callbacks de `MediaPlayerDelegate` e os pares `playbackState`/`loadState` — e registrar em `KSOptions.firstPlayerType`/`secondPlayerType`. O `KSPlayerLayer` não conhece tipos concretos além do fallback AirPlay (`KSPlayerLayer.swift`).

**5. UI customizada**: implementar `KSPlayerLayerDelegate` (`KSPlayerLayer.swift`) e instanciar `KSPlayerLayer` direto (caminho usado por `VideoPlayerView` no subsistema Video), ou no SwiftUI usar os modifiers do `KSVideoPlayer`: `onPlay/onFinish/onStateChanged/onBufferChanged/onSwipe` (`KSVideoPlayer.swift`). `KSPlayerLayer` também é `open` — `play`, `pause`, `seek(...)` e `prepareToPlay` são sobrescrevíveis.

**6. Log**: implementar `LogHandler` (`KSOptions.swift`) e atribuir a `KSOptions.logger`; granularidade via `KSOptions.logLevel`. `FileLog` já existe.

## Pegadinhas

- **Fallback silencioso de motor.** Erro no primeiro motor não gera `state = .error`: `KSPlayerLayer.finish` troca para `KSOptions.secondPlayerType` e re-prepara a mesma URL (`KSPlayerLayer.swift`). `.error` só ocorre quando o motor atual **já é** o `secondPlayerType`. Consequências: (a) o erro original do `KSAVPlayer` é engolido; (b) o `didSet` de `player` reseta `contentMode` para `.scaleAspectFit` — zoom customizado se perde no fallback; (c) `playbackRate`/`playbackVolume` são preservados.
- **Delegate de estado é chamado no `willSet`.** `KSPlayerLayer.state` notifica em `willSet` (`KSPlayerLayer.swift`). Como `runOnMainThread` executa **sincronamente** quando já está no main thread (`Sources/Lumen/Core/Utility.swift`), o callback roda **antes** da atribuição: ler `layer.state` (ou `Coordinator.state`, que é derivado — `KSVideoPlayer.swift`) dentro do callback retorna o estado **antigo**. Use sempre o parâmetro `state` do callback.
- **`runOnMainThread` fora do main thread é assíncrono e sem ordem garantida** (usa `Task { await MainActor.run }`). Chamadas consecutivas de threads diferentes podem intercalar. Vários fluxos do subsistema dependem dele (troca de view do player, notificação de estado, `set(url:)`).
- **KVO em threads arbitrárias vs `@MainActor`.** `KSAVPlayer` é `@MainActor`, mas os handlers de KVO (`observe(\.status)` etc., `KSAVPlayer.swift`) e as notificações executam na thread em que o AVFoundation postou. `updateStatus`/`updatePlayableDuration`/`loadState` são mutados dali sem hop explícito — herança do código pré-concurrency. Ao evoluir o fork, não assuma que `didSet` de `loadState`/`playbackState`/`isReadyToPlay` roda no main thread.
- **Timer preso ao run loop da thread de criação.** O `timer` é `lazy` (`KSPlayerLayer.swift`) e `Timer.scheduledTimer` registra no run loop **corrente**. O primeiro acesso acontece em `play`. Se `play` for chamado fora do main thread, o timer nunca dispara. O timer nunca é invalidado (o closure captura `self` weak, então não há retain cycle, mas ele segue agendado até `fireDate = .distantFuture`).
- **`deinit` remove targets globais dos remote commands.** `removeTarget(nil)` (`KSPlayerLayer.swift`) remove **todos** os targets de cada comando — inclusive os de outro `KSPlayerLayer` vivo. Dois layers simultâneos com `registerRemoteControll = true` se corrompem mutuamente (o registro também não remove targets anteriores).
- **`set(url:options:)` com a mesma URL não aplica as novas options ao motor.** O `didSet` de `url` com `url == oldValue` e mesmo tipo de motor só chama `play` (`KSPlayerLayer.swift`); `player.replace(url:options:)` (que é quem injeta `avOptions` novos no `AVURLAsset`, `KSAVPlayer.swift`) só roda quando a URL muda. Para forçar reload da mesma URL: `stop` antes, ou trocar o motor.
- **`stop` reseta rate/volume.** `playbackRate = 1`, `playbackVolume = 1` (`KSPlayerLayer.swift`) — troca de episódio via `set(url:)` com URL nova perde a velocidade escolhida pelo usuário (o caminho `nextPlayer` idem, pois passa pelo `didSet` de `url` → `stop`).
- **`playbackState == .seeking` congela `changeLoadState`.** `KSPlayerLayer.changeLoadState` ignora eventos durante seek (`KSPlayerLayer.swift`). No `KSAVPlayer`, `.seeking` só é substituído quando algo chama `play/pause` (`KSAVPlayer.swift`); com `autoPlay=false` no seek, o estado de transporte fica `.seeking` indefinidamente e `currentPlaybackTime` volta a ler o player só quando `shouldSeekTo` zera.
- **PiP tem singleton estático forte.** `KSPictureInPictureController.pipController` (`KSPictureInPictureController.swift`) retém o controller (e o `KSPlayerLayer` via `view`) até `stop(restoreUserInterface:)` com `KSOptions.isPipPopViewController == true`. Com o flag `false` (default), `start` manda o app para background via truque `UIControl.sendAction(#selector(URLSessionTask.suspend)...)`. O `start` precisa ser despachado async no main — comentário em `KSPlayerLayer.swift` ("一定要async才不会pip之后就暂停播放").
- **Legendas embutidas chegam com 1 s de atraso.** O `Coordinator` agenda `subtitleModel.addSubtitle(dataSouce:)` com `asyncAfter(1s)` após `.readyToPlay` (`KSVideoPlayer.swift`), porque trilhas de legenda dentro do stream podem aparecer depois do ready. Não liste legendas imediatamente no ready.
- **`KSVideoPlayer` é `Equatable` só por `url`** (`KSVideoPlayer.swift`): mudar apenas `options` não re-renderiza; `updateView` também só recria quando a URL difere.
- **Ordem `onDisappear` vs `dismantleUIView` difere entre device e simulador** (comentário `KSVideoPlayer.swift`; SplitView re-entra chamando `makeUIView` antes do `dismantleUIView` antigo — comentário). Por isso `playerLayer` deve ser limpo no `onDisappear` do app, não apenas confiar no dismantle.
- **`updateStatus` desabilita todas as trilhas de áudio menos a primeira** (`KSAVPlayer.swift`) e `select(track:)` opera só em `AVPlayerItemTrack.isEnabled` — não usa `AVMediaSelectionGroup`; streams HLS com renditions de áudio alternativas não são selecionáveis por esse caminho no motor AV.
- **`duration` pode ser NaN em live** (`item.duration.seconds` de `CMTime.indefinite`, `KSAVPlayer.swift`); o `Coordinator` protege contra overflow ao converter para `Int` (`KSVideoPlayer.swift`), mas consumidores diretos de `KSPlayerLayerDelegate` precisam tratar.
- **`@Published` em classe que não é `ObservableObject`.** `KSOptions.preferredForwardBufferDuration` (`KSOptions.swift`) e `videoInterlacingType` usam `@Published` apenas pelo projected value Combine (assinado em `KSAVPlayer.swift`); não há `objectWillChange`.
- **Estado global mutável.** Todas as estáticas de `KSOptions` são globais sem sincronização; `setHttpProxy` escreve env var do processo (`MediaPlayerProtocol.swift`). `KSOptions.setAudioSession` é chamado em **todo** init de `KSAVPlayer` (`KSAVPlayer.swift`) e ativa a `AVAudioSession` (categoria `.playback`, modo `.moviePlayback`, policy `.longFormAudio` no tvOS — `KSOptions.swift`).
- **tvOS display criteria.** `updateVideo` seta `preferredDisplayCriteria` (match de refresh/HDR) e **rebaixa Dolby Vision para HDR10** (`KSOptions.swift`); o reset só acontece em `options.playerLayerDeinit` chamado no `deinit` do layer (`KSPlayerLayer.swift`, `KSOptions.swift`). Sair e reentrar em <3 s pode pegar `isDisplayModeSwitchInProgress` (comentário).
- **Background.** `enterBackground` só pausa se não houver PiP ativo nem external playback; com `KSOptions.canBackgroundPlay` o `KSAVPlayer` desacopla o `AVPlayerLayer.player` para manter áudio (`KSPlayerLayer.swift`, `KSAVPlayer.swift`).
- **AirPlay força motor nativo.** Com rota wireless ativa, o `didSet` de `url` sempre escolhe `KSAVPlayer` (`KSPlayerLayer.swift`); a flag é mantida por `wirelessRouteActiveDidChange` — só vira `true` se `allowsExternalPlayback == false`.
- **Métricas de startup dependem de zeragem externa.** O dict logado em `changeLoadState` (`KSPlayerLayer.swift`) usa `options.dnsStartTime/tcpStartTime/...` que são `internal(set)` e preenchidos uma única vez (guards `== 0` em `urlIO`, `KSOptions.swift`); reutilizar a mesma instância de `KSOptions` em outra reprodução produz métricas erradas.

## Relação com outros subsistemas

- **MEPlayer (`Sources/Lumen/MEPlayer/`)** — consumidor pesado desta camada: `KSMEPlayer` implementa `MediaPlayerProtocol` (`Sources/Lumen/MEPlayer/KSMEPlayer.swift`) e é o `secondPlayerType` default (`KSOptions.swift`). O pipeline FFmpeg chama os hooks `open` de `KSOptions` (`playable`, `videoClockSync`, `process(assetTrack:)`, `urlIO`, `filter`, `adaptable`, `videoFrameMaxCount`...) e consome os tipos de `PlayerDefines.swift` (`CapacityProtocol`, `LoadingState`, `ClockProcessType`, `VideoAdaptationState`, `AbstractAVIOContext`, `KSPlayerErrorCode`). Estende `KSOptions` com estáticas próprias em `Sources/Lumen/MEPlayer/Model.swift`.
- **Subtitle (`Sources/Lumen/Subtitle/`)** — `MediaPlayerProtocol.subtitleDataSouce` (`MediaPlayerProtocol.swift`) devolve o `SubtitleDataSouce` (`Sources/Lumen/Subtitle/SubtitleDataSouce.swift`) do motor (`nil` no `KSAVPlayer`, `KSAVPlayer.swift`). O `Coordinator` possui o `SubtitleModel` (`Sources/Lumen/Subtitle/KSSubtitle.swift`) e o alimenta pelo timer de 100 ms (`KSVideoPlayer.swift`) e pelo hook de `.readyToPlay` ( — respeita `options.autoSelectEmbedSubtitle`).
- **Video (`Sources/Lumen/Video/`)** — UI UIKit clássica: `VideoPlayerView` cria e observa `KSPlayerLayer` via `KSPlayerLayerDelegate`; define as estáticas `KSOptions.canBackgroundPlay` e `animateDelayTimeInterval` (`Sources/Lumen/Video/VideoPlayerView.swift`) consumidas aqui em `KSPlayerLayer.swift` e `KSVideoPlayer.swift`.
- **SwiftUI (`Sources/Lumen/SwiftUI/`)** — `KSVideoPlayerView` (player completo com controles) compõe o `KSVideoPlayer`/`Coordinator` deste subsistema (`Sources/Lumen/SwiftUI/KSVideoPlayerView.swift`).
- **Core (`Sources/Lumen/Core/`)** — utilitários: `runOnMainThread` (`Sources/Lumen/Core/Utility.swift`), usado extensivamente aqui; `PlayerToolBar` estende `KSOptions` para UI (`Sources/Lumen/Core/PlayerToolBar.swift`).
- **Frameworks de sistema** — AVFoundation/AVKit (`AVQueuePlayer`, `AVPlayerLayer`, `AVPictureInPictureController`, `AVDisplayCriteria`), MediaPlayer (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, `MPVolumeView`), `AVAudioSession` (categoria/spatial audio/canais em `KSOptions.swift`).
- **App consumidor** — integra por: subclasse de `KSOptions` (config + hooks), `KSVideoPlayer`/`KSVideoPlayerView` ou `KSPlayerLayer` direto, e as estáticas globais (`firstPlayerType`, `logLevel` etc.). Evoluções de comportamento passam principalmente por hooks de `KSOptions` (HDR/refresh match em `updateVideo`, seleção de trilha em `wantedAudio`/`wantedVideo`, buffering em `playable`) e pelo subsistema MEPlayer.
