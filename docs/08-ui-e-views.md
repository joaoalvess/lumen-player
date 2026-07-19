# 08 — UI e Views (`Sources/Lumen/Core/`, `Sources/Lumen/Video/`, `Sources/Lumen/SwiftUI/`)

Documento técnico do subsistema de interface: a hierarquia de views UIKit/AppKit (caminho "clássico"), a camada de compatibilidade cross-platform e a UI SwiftUI moderna. Todos os paths são relativos à raiz do repo.

## Responsabilidade

- **Caminho UIKit/AppKit** (`Core/` + `Video/`): view base `PlayerView` que faz a ponte com `KSPlayerLayer` (`Sources/Lumen/Core/PlayerView.swift`), toolbar de controles `PlayerToolBar` (`Sources/Lumen/Core/PlayerToolBar.swift`), view completa com máscaras/gestos/legendas `VideoPlayerView` (`Sources/Lumen/Video/VideoPlayerView.swift`) e as especializações `IOSVideoPlayerView` (fullscreen modal, volume/brilho, AirPlay — `Sources/Lumen/Video/IOSVideoPlayerView.swift`) e `MacVideoPlayerView` (mouse tracking, drag & drop, scroll wheel — `Sources/Lumen/Video/MacVideoPlayerView.swift`).
- **Camada de compatibilidade**: no macOS, `AppKitExtend.swift` cria typealiases (`UIView`→`NSView` etc., `Sources/Lumen/Core/AppKitExtend.swift`) e reimplementa `UIButton`/`KSSlider`/`UILabel`/`UIAlertController` sobre AppKit; no tvOS, `UXSlider` é um `UIProgressView` fake sem interação (`Sources/Lumen/Core/UIKitExtend.swift`). Isso permite que `PlayerToolBar`/`VideoPlayerView` compilem com um só código para iOS/tvOS/macOS.
- **Caminho SwiftUI** (`SwiftUI/`): `KSVideoPlayerView` é a UI completa e independente do caminho UIKit (`Sources/Lumen/SwiftUI/KSVideoPlayerView.swift`), construída sobre `KSVideoPlayer.Coordinator` (subsistema AVPlayer). Inclui controles, legendas, painel de settings e Live Text; no tvOS, os controles de transporte vêm da camada dedicada `SwiftUI/TVOS/`.
- **Modelo de recurso**: `KSPlayerResource`/`KSPlayerResourceDefinition` (múltiplas qualidades + legendas + cover + Now Playing — `Sources/Lumen/Video/KSPlayerItem.swift`) é consumido apenas pelo caminho UIKit.
- Utilitários genéricos usados por toda a lib (parse de M3U, `runOnMainThread`, conversões de cor/imagem, conformances `RawRepresentable` para `@AppStorage`) em `Sources/Lumen/Core/Utility.swift`.

O que **não** está aqui: máquina de estados e motores (subsistema AVPlayer, doc 02), parsing/modelo de legendas (`SubtitleModel` — subsistema Subtitle), decodificação (MEPlayer).

**Os dois caminhos de UI são paralelos e não se misturam**: `VideoPlayerView` (UIKit) implementa `KSPlayerLayerDelegate` diretamente; `KSVideoPlayerView` (SwiftUI) observa o `KSVideoPlayer.Coordinator`, que é quem implementa `KSPlayerLayerDelegate` (`Sources/Lumen/AVPlayer/KSVideoPlayer.swift`). No tvOS, o caminho relevante é o SwiftUI.

## Tipos principais

### Core/

| Tipo | Arquivo | Papel |
|---|---|---|
| `PlayerButtonType` (enum Int) | `Core/PlayerView.swift` | Identidade dos botões via `tag` (raw values a partir de 101): play/pause/back/srt/landscape/replay/lock/rate/definition/pictureInPicture/audioSwitch/videoSwitch |
| `PlayerControllerDelegate` (protocol) | `Core/PlayerView.swift` | Contrato UI→app: `state`, `currentTime/totalTime`, `finish`, `maskShow`, `action`, `bufferedCount`, `seek` |
| `PlayerView` (open class, `UIView`, `KSPlayerLayerDelegate`, `KSSliderDelegate`) | `Core/PlayerView.swift` | Base: possui `playerLayer` (seta-se como delegate no didSet), `toolBar`, `srtControl: SubtitleModel`, roteia botões e slider, trata `.playPause` do remote |
| `PlayerToolBar` (`UIStackView`) | `Core/PlayerToolBar.swift` | Todos os botões + labels de tempo + `timeSlider`; formatação de tempo nos didSet de `currentTime`/`totalTime`; modo live stream; focus tvOS (`didUpdateFocus`) |
| `ControlEvents` (enum) | `Core/UXKit.swift` | Eventos abstratos cross-platform (touchDown/touchUpInside/valueChanged/mouseEntered…) |
| `KSSliderDelegate` (protocol) | `Core/UXKit.swift` | Único método: `slider(value:event:)` |
| `KSSlider` (iOS/tvOS) | `Core/UIKitExtend.swift` | `UXSlider` + tap/pan gestures que convertem posição→valor; `isPlayable` gate |
| `UXSlider` (tvOS) | `Core/UIKitExtend.swift` | **Fake slider**: subclasse de `UIProgressView` com `value/maximumValue/minimumValue` mapeados em `progress`; `addTarget`/`setThumbImage` são no-ops |
| `UXSlider` (iOS/macCatalyst) | `Core/UIKitExtend.swift` | `typealias UXSlider = UISlider` |
| typealiases AppKit | `Core/AppKitExtend.swift` | `UIView`→`NSView`, `UIButton`→`KSButton`, `UXSlider`→`NSSlider` etc. |
| `KSButton` (macOS) | `Core/AppKitExtend.swift` | Reimplementa states/images/titles/target-action de `UIButton` sobre `NSButton`, com tracking areas para mouseEntered/Exited |
| `KSSlider` (macOS) | `Core/AppKitExtend.swift` | `NSSlider` com `KSSliderDelegate` disparando apenas `.touchUpInside` no action |
| `UILabel` (macOS) | `Core/AppKitExtend.swift` | `NSTextField` não-editável estilizado |
| `UIAlertController`/`UIAlertAction` (macOS) | `Core/AppKitExtend.swift` | **Stubs vazios** — `present` não faz nada no macOS |
| `UIApplication.isIdleTimerDisabled` (macOS) | `Core/AppKitExtend.swift` | Via `IOPMAssertionCreateWithName` (noDisplaySleep) |
| `LayerContainerView` | `Core/Utility.swift` | `UIView` com `layerClass = CAGradientLayer` — usada nas máscaras top/bottom |
| `runOnMainThread` | `Core/Utility.swift` | Executa inline se já na main; senão `Task { await MainActor.run }` (**assíncrono nesse caso**) |
| Extensões `URL` (`isMovie/isAudio/isSubtitle/isPlaylist/parsePlaylist/download`) | `Core/Utility.swift` | Detecção de tipo e download de legendas/playlists |
| `Scanner.parseM3U` | `Core/Utility.swift` | Parser de `#EXTINF`/`#EXTVLCOPT` → `(title, URL, extinf)` |
| Conformances `RawRepresentable` (`TextAlignment`, `HorizontalAlignment`, `VerticalAlignment`, `Color`, `Array`, `Date`) | `Core/Utility.swift` | Permitem persistir configs de legenda em `@AppStorage` |
| `CGImage.combine/make/data` | `Core/Utility.swift` | Composição de imagens de legenda bitmap |

### Video/

| Tipo | Arquivo | Papel |
|---|---|---|
| `KSPanDirection` (enum) | `Video/VideoPlayerView.swift` | horizontal/vertical para gestos de pan |
| `LoadingIndector` (protocol) | `Video/VideoPlayerView.swift` | `startAnimating`/`stopAnimating`; `UIActivityIndicatorView` conforma |
| `VideoPlayerView` (open class) | `Video/VideoPlayerView.swift` | View completa: máscaras gradiente, gestos, auto-hide, legendas UIKit, replay/lock, menus/alerts, seek OSD, speed tip (long press 2x) |
| `KSPlayerTopBarShowCase` (enum) | `Video/VideoPlayerView.swift` | `always`/`horizantalOnly`/`none` |
| `KSOptions` (extensão UI estática) | `Video/VideoPlayerView.swift` | `topBarShowInCase`, `animateDelayTimeInterval` (5s), `enableBrightnessGestures`, `enableVolumeGestures`, `enablePlaytimeGestures`, `canBackgroundPlay` |
| Helpers de constraints/safe anchors (`UIView`) | `Video/VideoPlayerView.swift` | `frameConstraints`, `safeTopAnchor` etc. — usados pelo fullscreen e pelo transition animator |
| `IOSVideoPlayerView` | `Video/IOSVideoPlayerView.swift` | iOS: cover (`maskImageView`), botões back/landscape/route, volume via `MPVolumeView` hack, brilho via `UIScreen.main.brightness`, fullscreen modal |
| `AirplayStatusView` | `Video/IOSVideoPlayerView.swift` | Placa "AirPlay 投放中" central quando `isExternalPlaybackActive` |
| `MenuController` (iOS) | `Video/IOSVideoPlayerView.swift` | Menu "Open File" (⌘O) para Catalyst/iPad |
| `MacVideoPlayerView` | `Video/MacVideoPlayerView.swift` | macOS: máscara por mouseEntered/Exited, seek/volume por scroll wheel, setas/espaço no `keyDown`, drag & drop de mídia/legenda, aspect ratio da janela no readyToPlay |
| `UIActivityIndicatorView` (macOS) | `Video/MacVideoPlayerView.swift` | Loader custom com `CABasicAnimation` de rotação + label de progresso |
| `SeekViewProtocol` / `SeekView` | `Video/SeekView.swift` | OSD central de seek; seta rotaciona 180° quando retrocede |
| `UIMenu.init(title:current:list:...)` / `UIButton.setMenu` | `Video/KSMenu.swift` | Fábrica de menus checáveis; `setMenu` indisponível no tvOS (`#if !os(tvOS)`); bridge `NSMenu`/`NSMenuItem` no macOS |
| `KSPlayerResource` | `Video/KSPlayerItem.swift` | name + `[KSPlayerResourceDefinition]` + cover + `SubtitleDataSouce` + `KSNowPlayableMetadata`; `Equatable` por definitions |
| `KSPlayerResourceDefinition` | `Video/KSPlayerItem.swift` | url + label de qualidade + `KSOptions` próprios; `Equatable/Hashable` **só por url** |
| `KSNowPlayableMetadata` | `Video/KSPlayerItem.swift` | Dicionário para `MPNowPlayingInfoCenter` |
| `PlayerViewFullScreenDelegate` / `PlayerFullScreenViewController` | `Video/PlayerFullScreenViewController.swift` | VC modal de fullscreen (iOS, `!os(tvOS)`); controla orientação via `KSOptions.supportedInterfaceOrientations` e status bar |
| `PlayerTransitionAnimator` | `Video/PlayerTransitionAnimator.swift` | Transição present/dismiss animando o `player.view` entre superviews, salvando/restaurando `frameConstraints` |
| `BrightnessVolume` (@MainActor, singleton) | `Video/BrightnessVolume.swift` | HUD de brilho (KVO de `UIScreen.brightness`) e volume (notificação privada `AVSystemController_SystemVolumeDidChangeNotification`) |
| `BrightnessVolumeViewProtocol` + `SystemView`/`ProgressView` | `Video/BrightnessVolume.swift` | Duas implementações do HUD; default é `ProgressView` vertical à direita |

### SwiftUI/

| Tipo | Arquivo | Papel |
|---|---|---|
| `KSVideoPlayerView` (@MainActor, iOS 16/tvOS 16/macOS 13+) | `SwiftUI/KSVideoPlayerView.swift` | View raiz: `KSVideoPlayer` (representable) + `VideoSubtitleView` + `controllerView` + `VideoSettingView`; focus/remote no tvOS; atalhos de teclado; drop de arquivos |
| `FocusableField` (enum) | `SwiftUI/KSVideoPlayerView.swift` | `play`/`controller`/`info`, mais `timeline`/`pills`/`popover`/`panel` no tvOS — máquina de foco |
| `onKeyPressLeftArrow/RightArrow/Sapce` (View ext) | `SwiftUI/KSVideoPlayerView.swift` | Wrappers de `onKeyPress` com fallback para OS < 17 |
| `VideoControllerView` | `SwiftUI/KSVideoPlayerView.swift` | Barra de controles; layout tvOS totalmente separado (linha única inferior) do layout iOS/macOS |
| `MenuView<Label, SelectionValue, Content>` | `SwiftUI/KSVideoPlayerView.swift` | `Menu`+`Picker` inline (tvOS 17+) com fallback `.navigationLink` |
| `VideoTimeShowView` | `SwiftUI/KSVideoPlayerView.swift` | Tempo atual/total + `Slider`; pausa no início do drag e `config.seek` no fim; "Live Streaming" se não seekable |
| `VideoSubtitleView` + `SubtitlePart.subtitleView` | `SwiftUI/KSVideoPlayerView.swift` | Renderiza `model.parts`: imagem (com `fitRect`) ou texto com posição/estilo de `SubtitleModel` |
| `VideoSettingView` | `SwiftUI/KSVideoPlayerView.swift` | Painel: track de vídeo, delay de legenda, busca de legenda, `DynamicInfoView`, file size |
| `DynamicInfoView` | `SwiftUI/KSVideoPlayerView.swift` | FPS, sync A/V, frames dropados, bitrates (observa `DynamicInfo`) |
| `PlatformView` | `SwiftUI/KSVideoPlayerView.swift` | tvOS: `ScrollView` + `.pickerStyle(.navigationLink)`; demais: `Form` |
| `KSVideoPlayerViewBuilder` (enum de fábricas estáticas) | `SwiftUI/KSVideoPlayerViewBuilder.swift` | Botões compartilhados: playback (±15s/play), contentMode, subtitle, rate, mute, info, title; nomes de SF Symbols por plataforma |
| `Slider` (tvOS) | `SwiftUI/Slider.swift` | Substitui o `SwiftUI.Slider` inexistente no tvOS; delega para `TVOSSlide` |
| `TVOSSlide` (`UIViewRepresentable`) | `SwiftUI/Slider.swift` | Ponte para `TVSlide`; tint vermelho quando focado |
| `TVSlide` (`UIControl`) | `SwiftUI/Slider.swift` | **Legado**: caminho de seek anterior do tvOS, hoje substituído no player por `TVScrubberInput` + `TVTransportBar`. Press left/right com aceleração via `Timer` (rate até 10x), pan no touchpad; `onEditingChanged(false)` (commit) só 1.5s após soltar |
| `AirPlayView` (representable) | `SwiftUI/AirPlayView.swift` | `AVRoutePickerView` para SwiftUI |
| `View.if`/`ifLet` | `SwiftUI/AirPlayView.swift` | Modificadores condicionais |
| `LiveTextImage` | `SwiftUI/LiveTextImage.swift` | Legenda bitmap com Live Text (VisionKit), atrás da flag de compilação `enableFeatureLiveText` (`KSVideoPlayerView.swift`) |
| `UIImage.fitRect` | `SwiftUI/LiveTextImage.swift` | Cálculo de rect aspect-fit ancorado no rodapé para legendas de imagem |

### SwiftUI/TVOS/

Camada exclusiva do tvOS (todo o diretório sob `#if os(tvOS)`, com os tipos de View marcados `@available(tvOS 16.0, *)`). Substitui, no tvOS, a `VideoControllerView`/`VideoTimeShowView` genéricas por uma interface própria de transporte, scrubbing e painéis.

| Tipo | Arquivo | Papel |
|---|---|---|
| `TVOverlayMode`, `TVPanelTab`, `TVTrackPopoverKind` | `SwiftUI/TVOS/TVOverlayMode.swift` | Máquina de estados da UI: `.transport` / `.popover(kind)` / `.panel(tab)`; abas `info`/`cast`/`continueWatching`/`advanced` |
| `TVPlayerMetadata`, `TVPlayerCredit` | `SwiftUI/TVOS/TVPlayerMetadata.swift` | **Modelo público** que o app consumidor preenche: subtítulo, temporada/episódio, sinopse, artwork, ano, gêneros, duração, classificação, elenco e direção. `Sendable`, sem dependência do player |
| `TVControlsOverlayView` | `SwiftUI/TVOS/TVControlsOverlayView.swift` | Composição raiz do overlay: bloco de título, linha de chips (legendas/áudio/PiP), transport bar, linha de pills e painel; ancora o popover no chip via `PreferenceKey` |
| `TVTransportBar` | `SwiftUI/TVOS/TVTransportBar.swift` | Timeline: track de 3 camadas (fundo/buffer/progresso), playhead, rótulos de tempo e preview de thumbnail; gerencia o ciclo begin/commit/cancel do scrub. Mostra "Ao vivo" se a mídia não é seekable |
| `TVScrubberInput` / `TVScrubberControl` | `SwiftUI/TVOS/TVScrubberInput.swift` | Ponte `UIViewRepresentable` para o Siri Remote: setas com repetição acelerada, `select`/`playPause` commitam, `menu` cancela, pan horizontal no touchpad, auto-commit por timer e traços de acessibilidade `.adjustable` |
| `TVScrubberTuning` | `SwiftUI/TVOS/TVScrubberTuning.swift` | Constantes e matemática do scrub (passo de seta, delays de repetição, mapeamento velocidade→span do pan). Único arquivo do diretório sem `#if os(tvOS)` — por isso é testável (`Tests/LumenTests/TVScrubberTuningTests.swift`) |
| `TVPanelView` | `SwiftUI/TVOS/TVPanelView.swift` | Painéis inferiores: info (artwork, sinopse, badges 4K/DV/HDR/CC derivados das tracks), elenco (scroll horizontal de créditos), continue assistindo (placeholder) e avançado (linhas de `DynamicInfo`) |
| `TVTrackPopover` | `SwiftUI/TVOS/TVTrackPopover.swift` | Seleção de trilha de legenda (com linha "Desativadas") ou de áudio; foco default na trilha ativa |
| `TVGlassStyles` (+ `TVPlayerMetrics`, `TVPlayerMotion`) | `SwiftUI/TVOS/TVGlassStyles.swift` | Sistema de design: materiais de vidro (com `glassEffect` no tvOS 26+ e fallback `.ultraThinMaterial`), métricas de layout, curvas de animação e quatro `ButtonStyle` que reagem a `isFocused` |
| `ScrubThumbnailProvider` | `SwiftUI/TVOS/ScrubThumbnailProvider.swift` | `@MainActor ObservableObject` que faz cache e coordenação das thumbnails de scrubbing sobre o `ScrubThumbnailEngine` (doc 04) |

**Wiring**: `KSVideoPlayerView.controllerView(playerWidth:)` instancia `TVControlsOverlayView` dentro de `#if os(tvOS)`. O `FocusableField` ganha os casos `timeline`, `pills` e `popover`/`panel` só nesse alvo. O app consumidor injeta os metadados pelo modificador público `.tvPlayerMetadata(_:)` — que é a única API de entrada dessa camada e não tem nenhum call site interno.

**Thumbnails de scrubbing** — o `ScrubThumbnailProvider` é instanciado pelo `KSVideoPlayer.Coordinator` (e desligado no reset) e repassado à `TVTransportBar`. Estratégia:

- **Bucketização**: a duração é dividida em no máximo ~240 buckets (`bucketLength = max(2, duration / 240)`); o frame pedido ao engine é sempre o centro do bucket, o que torna o cache reaproveitável durante o arrasto.
- **Cache LRU** de 48 imagens, com **lookup tolerante**: se o bucket exato não está em cache, tenta os vizinhos (`b−1`, `b+1`, `b−2`, `b+2`) antes de desistir — é isso que evita buraco visual no scrub rápido.
- **Serialização**: uma única requisição em voo; pedidos intermediários são descartados, não enfileirados. Toda continuação valida a identidade do engine antes de aplicar o resultado, protegendo contra troca de mídia.
- **Gate**: só age se `KSOptions.enableScrubPreview` (default `true`); largura em `KSOptions.scrubThumbnailWidth`. A `TVTransportBar` ainda aplica um debounce de ~120 ms antes de pedir.

## Fluxo de dados

### Caminho UIKit/AppKit

1. **Set de mídia**: app chama `VideoPlayerView.set(resource:definitionIndex:)` (`Video/VideoPlayerView.swift`) → `PlayerView.set(url:options:)` cria `KSPlayerLayer(url:options:)` (`Core/PlayerView.swift`). O didSet de `playerLayer` em `PlayerView` seta `playerLayer.delegate = self` (`Core/PlayerView.swift`); o override em `VideoPlayerView` remove a view do player antigo e insere `playerLayer.player.view` **abaixo** de `contentOverlayView` com constraints full-bleed (`Video/VideoPlayerView.swift`). O didSet de `resource` alimenta título, legendas externas, botão de definition e `MPNowPlayingInfoCenter` (`Video/VideoPlayerView.swift`).
2. **Hierarquia resultante** (montada em `setupUIComponents`, `Video/VideoPlayerView.swift` + `addConstraint`): `VideoPlayerView` → [`maskImageView` (só iOS, index 0), `player.view`, `contentOverlayView`, `subtitleBackView`+`subtitleLabel`, `controllerView` → [`loadingIndector`, `seekToView`, `replayButton`, `lockButton`, `topMaskView`→`navigationBar`→`titleLabel`, `bottomMaskView`→[`toolBar`, `toolBar.timeSlider`], `speedTipLabel`]]. As máscaras são `LayerContainerView` com gradiente preto→transparente.
3. **Estado (engine→UI)**: `KSPlayerLayer` chama `player(layer:state:)` — `PlayerView` atualiza `totalTime`, `isSeekable`, `playButton.isSelected` (`Core/PlayerView.swift`); `VideoPlayerView` sobrepõe para loader/replay/menus e agenda a adição de legendas embutidas com delay de 1s pós-`readyToPlay` (`Video/VideoPlayerView.swift`, delay em). `IOSVideoPlayerView` ainda faz fade-out do cover (`Video/IOSVideoPlayerView.swift`).
4. **Tempo (engine→UI)**: `player(layer:currentTime:totalTime:)` → `PlayerView` propaga para delegate/`playTimeDidChange` e escreve em `toolBar.currentTime` (`Core/PlayerView.swift`); os didSet do toolbar formatam labels e movem o slider (`Core/PlayerToolBar.swift`). `VideoPlayerView` suprime updates enquanto `isSliderSliding` e consulta `srtControl.subtitle(currentTime:)` para atualizar `subtitleLabel`/`subtitleBackView` (`Video/VideoPlayerView.swift`).
5. **Input (UI→engine)**: botões carregam `tag = PlayerButtonType`; `PlayerToolBar.addTarget` registra todos para `.primaryActionTriggered` (`Core/PlayerToolBar.swift`) → `PlayerView.onButtonPressed(_:)` resolve o tipo e trata menu (macOS popUp / iOS 14+ retorna cedo se há `UIMenu` — `Core/PlayerView.swift`) → `onButtonPressed(type:button:)` executa play/pause/back e repassa ao `PlayerControllerDelegate`. No tvOS, srt/rate/definition/audio/video viram `UIAlertController` (`Video/VideoPlayerView.swift` →); no iOS/macOS 14+/15+ viram `UIMenu` via `buildMenusForButtons`.
6. **Slider**: `KSSlider` → `KSSliderDelegate.slider(value:event:)` → `PlayerView.slider` (valueChanged atualiza label; touchUpInside chama `seek`, `Core/PlayerView.swift`); `VideoPlayerView.slider` gerencia `isSliderSliding` e o auto-hide (`Video/VideoPlayerView.swift`).
7. **Gestos**: instalados em `customizeUIComponents` (`Video/VideoPlayerView.swift`). Tap alterna `isMaskShow`; double-tap play/pause; long press ≥0.5s → playbackRate 2x com `speedTipLabel`; pan → `panGestureAction` decide direção pela velocidade → horizontal acumula `tmpPanValue` e mostra `seekToView`, commit no `panGestureEnded` via `slider(value:event:.touchUpInside)`. No iOS, pan vertical vira volume (metade direita, via `volumeViewSlider` extraído de `MPVolumeView`) ou brilho (metade esquerda) (`Video/IOSVideoPlayerView.swift`).
8. **Auto-hide**: `isMaskShow` didSet anima alpha de masks/replay/lock e notifica `delegate.playerController(maskShow:)` (`Video/VideoPlayerView.swift`); `autoFadeOutViewWithAnimation` agenda `DispatchWorkItem` de `KSOptions.animateDelayTimeInterval` (5s) **somente se tocando**.
9. **Fullscreen iOS**: `updateUI(isFullScreen:)` guarda superview/constraints/frame originais, move `self` para um `PlayerFullScreenViewController` apresentado modal (`Video/IOSVideoPlayerView.swift`); a animação é o `PlayerTransitionAnimator`, que reparenta o `player.view` para o container da transição e restaura as constraints no completion (`Video/PlayerTransitionAnimator.swift`). Orientação flui por `KSOptions.supportedInterfaceOrientations` (`Video/IOSVideoPlayerView.swift`), que o app deve retornar no AppDelegate.

### Caminho SwiftUI

1. **Composição**: `KSVideoPlayerView.body` empilha em `ZStack`+`GeometryReader`: `playView` (o `KSVideoPlayer` representable com todos os event modifiers), `VideoSubtitleView` central com `allowsHitTesting(false)` (`SwiftUI/KSVideoPlayerView.swift`, hit-testing em), `controllerView` e — só tvOS — `VideoSettingView` inline quando `isDropdownShow`.
2. **Estado**: tudo flui do `KSVideoPlayer.Coordinator` (`@StateObject`, definido em `Sources/Lumen/AVPlayer/KSVideoPlayer.swift`): `state`, `isMaskShow`, `playbackRate`, `playbackVolume`, `isMuted`, `isScaleAspectFill`, `timemodel: ControllerTimeModel` (tempos como `Int` de segundos, `AVPlayer/KSVideoPlayer.swift`) e `subtitleModel.parts` (legendas). Views observam com `@ObservedObject` (`VideoControllerView`, `VideoTimeShowView`, `VideoSubtitleView`).
3. **Comandos**: botões do `KSVideoPlayerViewBuilder` chamam `config.playerLayer?.play/pause`, `config.skip(interval:)`, `config.isMuted.toggle` etc. (`SwiftUI/KSVideoPlayerViewBuilder.swift`). Seek: `VideoTimeShowView` pausa quando o drag começa e chama `config.seek(time:)` quando termina (`SwiftUI/KSVideoPlayerView.swift`); no tvOS o commit vem do ciclo de scrub da `TVTransportBar` (`SwiftUI/TVOS/`), disparado por select/playPause ou por auto-commit após ~1s de inatividade.
4. **tvOS focus/remote**: `.onMoveCommand`: left/right = skip de `KSOptions.tvSkipInterval` (10s por padrão) com dica visual (`TVSkipHint`), up = mostra o transporte, down = foco nas pills; `.onExitCommand` sobe a hierarquia em ordem — loading fecha, painel/popover voltam ao transporte, máscara visível esconde, e só então `dismiss`; `.onPlayPauseCommand` alterna play/pause. Quando o overlay aparece, o foco vai para `.timeline`; ao sumir, volta para `.transport`/`.play`. Um overlay preto de loading inicial cobre a tela enquanto `tvIsInitialLoading`.
5. **Layout tvOS**: `controllerView` instancia a `TVControlsOverlayView`, que empilha bloco de título, chips (legendas/áudio/PiP), `TVTransportBar`, pills e painel opcional, com as métricas de `TVPlayerMetrics` (margem horizontal 80, inferior 60).

## Pontos de extensão

- **Subclasse de `VideoPlayerView` + `customizeUIComponents`** (`Video/VideoPlayerView.swift`): é o hook oficial ("Add Customize functions here") — `IOSVideoPlayerView.customizeUIComponents` (`Video/IOSVideoPlayerView.swift`) e `MacVideoPlayerView` (`Video/MacVideoPlayerView.swift`) são os exemplos canônicos. Chamado ao final de `setupUIComponents` (`Video/VideoPlayerView.swift`), com toda a hierarquia já montada.
- **`onButtonPressed(type:button:)` (open)** (`Core/PlayerView.swift` / `Video/VideoPlayerView.swift` / `Video/IOSVideoPlayerView.swift`): interceptar ou adicionar ações. Para botão novo: criar `UIButton`, setar `tag` com um raw value novo em `PlayerButtonType` (`Core/PlayerView.swift`), adicionar ao `toolBar` via `addArrangedSubview` e registrar o target.
- **`PlayerControllerDelegate`** (`Core/PlayerView.swift`): o app recebe todos os eventos (estado, tempo, ações de botão, maskShow, rebuffer) sem subclassear.
- **`loadingIndector: UIView & LoadingIndector`** (`Video/VideoPlayerView.swift`) e **`seekToView: UIView & SeekViewProtocol`**: propriedades `public var` — basta atribuir outra implementação antes de `setupUIComponents` rodar (i.e., em subclasse) para trocar o spinner/OSD.
- **`BrightnessVolume.progressView: BrightnessVolumeViewProtocol & UIView`** (`Video/BrightnessVolume.swift`): trocar o HUD de brilho/volume (o `SystemView` em é uma alternativa pronta).
- **Sensibilidade de gestos**: sobrescrever `panValue(velocity:direction:currentTime:totalTime:)` (`Video/VideoPlayerView.swift`) ou os três hooks `panGestureBegan/Changed/Ended`.
- **Flags estáticas `KSOptions`**: `topBarShowInCase`, `animateDelayTimeInterval`, `enableBrightnessGestures`, `enableVolumeGestures`, `enablePlaytimeGestures`, `canBackgroundPlay` (`Video/VideoPlayerView.swift`); `supportedInterfaceOrientations` (`Video/IOSVideoPlayerView.swift`).
- **SwiftUI — `KSVideoPlayerViewBuilder`** (`SwiftUI/KSVideoPlayerViewBuilder.swift`): fábricas estáticas de botões; é aqui que se muda ícone/comportamento de um controle para todas as telas. Não há protocolo: modificação é por edição direta (fork GPL, ok).
- **SwiftUI — injeção de coordinator e legendas**: `KSVideoPlayerView.init(coordinator:url:options:title:subtitleDataSouce:)` (`SwiftUI/KSVideoPlayerView.swift`) permite manter o `Coordinator` fora da view (controle externo de playback) e injetar `SubtitleDataSouce` custom (adicionado no `onAppear`).
- **`openURL(_:)`** (`SwiftUI/KSVideoPlayerView.swift`): troca de mídia/legenda em runtime (usado pelo onDrop).
- **`MenuView`** (`SwiftUI/KSVideoPlayerView.swift`) e **`UIButton.setMenu`** (`Video/KSMenu.swift`): componentes reutilizáveis para novos seletores (tracks, qualidade, etc.).
- **`Slider` tvOS** (`SwiftUI/Slider.swift`): substitui `SwiftUI.Slider` em todo código tvOS; permanece para usos genéricos, mas o scrubbing do player tvOS mudou para `TVScrubberInput`/`TVTransportBar` (`SwiftUI/TVOS/`) — é ali que features de scrubbing devem ser feitas.

## Pegadinhas

- **`cancellable` do PiP nunca conecta**: em `VideoPlayerView.init`, `playerLayer?.$isPipActive.assign(...)` roda quando `playerLayer` ainda é nil (`Video/VideoPlayerView.swift`) — o binding do estado de PiP para `pipButton.isSelected` está morto no caminho UIKit. Ao evoluir o fork, refazer a assinatura no didSet de `playerLayer`.
- **Slider do tvOS UIKit é decorativo**: `UXSlider` tvOS é `UIProgressView` (`Core/UIKitExtend.swift`); `addTarget` é no-op e os gestos do `KSSlider` (tap/pan por posição, `Core/UIKitExtend.swift`) não fazem sentido no Siri Remote. Seek no tvOS UIKit vem exclusivamente de `addRemoteControllerGestures` (±15s, `Video/VideoPlayerView.swift`). No SwiftUI o scrubbing real está em `TVScrubberInput` (`SwiftUI/TVOS/`).
- **Modo live stream implícito**: `isLiveStream == (totalTime == 0)` (`Core/PlayerToolBar.swift`); nesse modo o slider vira relógio do dia (`todayInterval`,, max = 86400 em). Qualquer mudança na toolbar precisa preservar esse branch.
- **iOS 14+ com menu engole o delegate**: `PlayerView.onButtonPressed(_:)` retorna cedo se `button.menu != nil` (`Core/PlayerView.swift`) — o `PlayerControllerDelegate.playerController(action:)` **não** dispara para botões com `UIMenu`.
- **Legendas embutidas chegam 1s depois**: `readyToPlay` agenda `asyncAfter(1s)` para adicionar o `subtitleDataSouce` do player (algumas legendas vêm no stream de vídeo — comentário em `Video/VideoPlayerView.swift`). `srtButton.isHidden` e os menus só ficam corretos após esse delay.
- **`delayItem` é compartilhado**: o mesmo `DispatchWorkItem` controla auto-hide da máscara (`Video/VideoPlayerView.swift`) e o fade do `speedTipLabel` — `showSpeedTip` cancela um auto-hide pendente.
- **Auto-hide só quando tocando**: `autoFadeOutViewWithAnimation` sai cedo se `playButton.isSelected == false` (`Video/VideoPlayerView.swift`) — pausado, a máscara fica visível para sempre.
- **Fullscreen iOS é frágil por design**: `updateUI(isFullScreen:)` desativa constraints originais, reparenta a view e restaura no completion do dismiss (`Video/IOSVideoPlayerView.swift`); `PlayerTransitionAnimator` reparenta o `player.view` no meio da transição (`Video/PlayerTransitionAnimator.swift`). Alterações na hierarquia de `VideoPlayerView` podem quebrar os dois. Nada disso existe no tvOS (`PlayerFullScreenViewController` é `!os(tvOS)`, `Video/PlayerFullScreenViewController.swift`).
- **`UIAlertController` no macOS é stub**: `present` é vazio (`Core/AppKitExtend.swift`), logo os fluxos de alert de `VideoPlayerView` (`changeSrt` etc.) silenciosamente não fazem nada no macOS — lá os menus reais são `NSMenu.popUp` (`Core/PlayerView.swift`).
- **Bug herdado no `KSButton` (macOS)**: `mouseEntered` dispara a action de `.mouseExited` (`Core/AppKitExtend.swift`) — copy/paste; corrigir se hover for usado.
- **API privada no `BrightnessVolume`**: usa a notificação `AVSystemController_SystemVolumeDidChangeNotification` (`Video/BrightnessVolume.swift`) — privada; irrelevante para uso pessoal, mas reprovável em App Store. É singleton `@MainActor` com KVO de `UIScreen.brightness` no init.
- **Dois renderizadores de legenda**: o UIKit usa `subtitleLabel`/`subtitleBackView` (`Video/VideoPlayerView.swift`, estilo aplicado só em `updateSrt` — chamar após mudar `SubtitleModel.textFont/textColor`); o SwiftUI usa `VideoSubtitleView`/`SubtitlePart.subtitleView` com suporte a posição/itálico/imagem (`SwiftUI/KSVideoPlayerView.swift`). Features de legenda precisam ser feitas duas vezes ou o caminho UIKit ser abandonado.
- **`Text("")` obrigatório**: no branch sem imagem/texto de `subtitleView`, o `Text("")` vazio é workaround para o SwiftUI limpar a imagem anterior (comentário em `SwiftUI/KSVideoPlayerView.swift`). Não remover.
- **`VideoTimeShowView` entra/sai da hierarquia de propósito**: opacity 0 continuaria atualizando a view (comentário `SwiftUI/KSVideoPlayerView.swift`), e os `onAppear/onDisappear` são quem move o foco tvOS entre `.controller` e `.play`. Trocar por `.opacity` quebra foco e performance.
- **Vazamentos conhecidos do `Coordinator`**: monitor de `NSEvent.addLocalMonitorForEvents` no macOS (comentário `SwiftUI/KSVideoPlayerView.swift`) e `keyboardShortcut` no simulador iOS (comentário `SwiftUI/KSVideoPlayerViewBuilder.swift`) impedem o release do `Coordinator`.
- **Commit de seek atrasado no tvOS**: no caminho atual (`TVScrubberInput`), o seek só é aplicado no `select`/`playPause`, ao perder foco, ou por auto-commit ~1s após a última interação; `menu` cancela e restaura o tempo âncora. O `TVSlide` legado (`SwiftUI/Slider.swift`) tem comportamento análogo com 1,5s, mas não está mais no caminho do player.
- **`runOnMainThread` fora da main é assíncrono** (`Core/Utility.swift`): usa `Task { await MainActor.run }`, sem garantia de ordem com outras tasks — não usar quando a ordem importa.
- **`PlayerToolBar.addArrangedSubview` força `isHidden = false`** (`Core/PlayerToolBar.swift`): esconder um botão antes de adicioná-lo não funciona; esconda depois.
- **Concorrência**: o target compila com `StrictConcurrency` experimental (`Package.swift`); as views são `@MainActor` por herdarem de UIView/NSView, e os callbacks de `KSPlayerLayerDelegate` já chegam na main (protocolo `@MainActor`, `Sources/Lumen/AVPlayer/KSPlayerLayer.swift`). Helpers puros novos (parsing, structs de dados) devem ficar `nonisolated`.
- **`KSPlayerResourceDefinition` é `Equatable/Hashable` só por `url`** (`Video/KSPlayerItem.swift`): duas definitions com mesma URL e `KSOptions` diferentes são "iguais" — cuidado ao usar em `Set`/diffing.
- **`isSliderSliding` suprime o clock da UI** (`Video/VideoPlayerView.swift`): setado no `.touchDown` e limpo no `.touchUpInside` e também usado pelo pan horizontal; um caminho de código que dispare `.touchDown` sem `.touchUpInside` congela os labels de tempo.

## Relação com outros subsistemas

- **AVPlayer (doc 02)** — dependência central: `KSPlayerLayer` é criado por `PlayerView.set(url:options:)` (`Core/PlayerView.swift`) e consumido via `KSPlayerLayerDelegate`; o caminho SwiftUI depende de `KSVideoPlayer`, `KSVideoPlayer.Coordinator` e `ControllerTimeModel` (`Sources/Lumen/AVPlayer/KSVideoPlayer.swift`); `TimeType`/`toString(for:)` usados pela toolbar vêm de `Sources/Lumen/AVPlayer/PlayerDefines.swift`; todas as flags de UI são extensões estáticas de `KSOptions`.
- **Subtitle** — `PlayerView.srtControl` e `Coordinator.subtitleModel` são `SubtitleModel`; a UI consome `subtitle(currentTime:)`/`parts` para renderizar e `subtitleInfos`/`selectedSubtitleInfo` para os seletores; `URLSubtitleInfo` é criado no drag & drop/document picker (`Video/MacVideoPlayerView.swift`, `Video/IOSVideoPlayerView.swift`); `SubtitleModel.textFont/textColor/textBackgroundColor/textPosition` estilizam ambos os renderizadores.
- **Motores (KSAVPlayer/KSMEPlayer)** — acesso indireto por `playerLayer.player` (`MediaPlayerProtocol`): a UI insere `player.view`, lê `tracks(mediaType:)`, `select(track:)`, `naturalSize`, `seekable`, `dynamicInfo`, `fileSize`, `thumbnailImageAtCurrentTime` (`Video/IOSVideoPlayerView.swift`).
- **Sistema/frameworks**: `MPNowPlayingInfoCenter` (`Video/VideoPlayerView.swift`), `MPVolumeView` (hack para slider de volume, `Video/IOSVideoPlayerView.swift`), `AVRoutePickerView`/`AVRouteDetector` (AirPlay, `Video/IOSVideoPlayerView.swift`, `SwiftUI/AirPlayView.swift`), `AVPictureInPictureController.isPictureInPictureSupported` (`Core/PlayerToolBar.swift`), VisionKit (`SwiftUI/LiveTextImage.swift`), IOKit para impedir sleep no macOS (`Core/AppKitExtend.swift`).
- **No tvOS**: a superfície efetivamente exercitada é `KSVideoPlayerView` + `Coordinator` + `VideoSubtitleView` + `Slider`/`TVSlide` + `KSVideoPlayerViewBuilder`, mais a camada dedicada em `Sources/Lumen/SwiftUI/TVOS/` (transport bar, painel de info, popover de trilhas, scrubber e thumbnails). O caminho UIKit (`VideoPlayerView` e derivados) compila no tvOS mas não é o usado — trabalho novo de UI deve ser feito no caminho SwiftUI.
