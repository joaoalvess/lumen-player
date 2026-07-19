# 08 — UI e Views (`Sources/KSPlayer/Core/`, `Sources/KSPlayer/Video/`, `Sources/KSPlayer/SwiftUI/`)

Documento técnico do subsistema de interface: a hierarquia de views UIKit/AppKit (caminho "clássico"), a camada de compatibilidade cross-platform e a UI SwiftUI moderna. Todos os paths são relativos à raiz do repo (`/Users/joaoalves/Developer/StreamHub/Player`).

## Responsabilidade

- **Caminho UIKit/AppKit** (`Core/` + `Video/`): view base `PlayerView` que faz a ponte com `KSPlayerLayer` (`Sources/KSPlayer/Core/PlayerView.swift:41-196`), toolbar de controles `PlayerToolBar` (`Sources/KSPlayer/Core/PlayerToolBar.swift:16-272`), view completa com máscaras/gestos/legendas `VideoPlayerView` (`Sources/KSPlayer/Video/VideoPlayerView.swift:32-941`) e as especializações `IOSVideoPlayerView` (fullscreen modal, volume/brilho, AirPlay — `Sources/KSPlayer/Video/IOSVideoPlayerView.swift:14-298`) e `MacVideoPlayerView` (mouse tracking, drag & drop, scroll wheel — `Sources/KSPlayer/Video/MacVideoPlayerView.swift:31-133`).
- **Camada de compatibilidade**: no macOS, `AppKitExtend.swift` cria typealiases (`UIView`→`NSView` etc., `Sources/KSPlayer/Core/AppKitExtend.swift:14-36`) e reimplementa `UIButton`/`KSSlider`/`UILabel`/`UIAlertController` sobre AppKit; no tvOS, `UXSlider` é um `UIProgressView` fake sem interação (`Sources/KSPlayer/Core/UIKitExtend.swift:94-162`). Isso permite que `PlayerToolBar`/`VideoPlayerView` compilem com um só código para iOS/tvOS/macOS.
- **Caminho SwiftUI** (`SwiftUI/`): `KSVideoPlayerView` é a UI completa e independente do caminho UIKit (`Sources/KSPlayer/SwiftUI/KSVideoPlayerView.swift:13-315`), construída sobre `KSVideoPlayer.Coordinator` (subsistema AVPlayer). Inclui controles, legendas, painel de settings, slider custom para tvOS e Live Text.
- **Modelo de recurso**: `KSPlayerResource`/`KSPlayerResourceDefinition` (múltiplas qualidades + legendas + cover + Now Playing — `Sources/KSPlayer/Video/KSPlayerItem.swift:13-147`) é consumido apenas pelo caminho UIKit.
- Utilitários genéricos usados por toda a lib (parse de M3U, `runOnMainThread`, conversões de cor/imagem, conformances `RawRepresentable` para `@AppStorage`) em `Sources/KSPlayer/Core/Utility.swift`.

O que **não** está aqui: máquina de estados e motores (subsistema AVPlayer, doc 02), parsing/modelo de legendas (`SubtitleModel` — subsistema Subtitle), decodificação (MEPlayer).

**Os dois caminhos de UI são paralelos e não se misturam**: `VideoPlayerView` (UIKit) implementa `KSPlayerLayerDelegate` diretamente; `KSVideoPlayerView` (SwiftUI) observa o `KSVideoPlayer.Coordinator`, que é quem implementa `KSPlayerLayerDelegate` (`Sources/KSPlayer/AVPlayer/KSVideoPlayer.swift:74`). Para o StreamHub (tvOS), o caminho relevante é o SwiftUI.

## Tipos principais

### Core/

| Tipo | Arquivo:linha | Papel |
|---|---|---|
| `PlayerButtonType` (enum Int) | `Core/PlayerView.swift:15-28` | Identidade dos botões via `tag` (raw values a partir de 101): play/pause/back/srt/landscape/replay/lock/rate/definition/pictureInPicture/audioSwitch/videoSwitch |
| `PlayerControllerDelegate` (protocol) | `Core/PlayerView.swift:30-39` | Contrato UI→app: `state`, `currentTime/totalTime`, `finish`, `maskShow`, `action`, `bufferedCount`, `seek` |
| `PlayerView` (open class, `UIView`, `KSPlayerLayerDelegate`, `KSSliderDelegate`) | `Core/PlayerView.swift:41-196` | Base: possui `playerLayer` (seta-se como delegate no didSet `:43-47`), `toolBar`, `srtControl: SubtitleModel` (`:50-51`), roteia botões e slider, trata `.playPause` do remote (`:116-129`) |
| `PlayerToolBar` (`UIStackView`) | `Core/PlayerToolBar.swift:16-272` | Todos os botões + labels de tempo + `timeSlider`; formatação de tempo nos didSet de `currentTime`/`totalTime` (`:41-88`); modo live stream (`:90-92`); focus tvOS (`didUpdateFocus`, `:230-251`) |
| `ControlEvents` (enum) | `Core/UXKit.swift:31-39` | Eventos abstratos cross-platform (touchDown/touchUpInside/valueChanged/mouseEntered…) |
| `KSSliderDelegate` (protocol) | `Core/UXKit.swift:41-48` | Único método: `slider(value:event:)` |
| `KSSlider` (iOS/tvOS) | `Core/UIKitExtend.swift:10-92` | `UXSlider` + tap/pan gestures que convertem posição→valor; `isPlayable` gate (`:47,55,60`) |
| `UXSlider` (tvOS) | `Core/UIKitExtend.swift:94-162` | **Fake slider**: subclasse de `UIProgressView` com `value/maximumValue/minimumValue` mapeados em `progress`; `addTarget`/`setThumbImage` são no-ops (`:135-136`) |
| `UXSlider` (iOS/macCatalyst) | `Core/UIKitExtend.swift:163-165` | `typealias UXSlider = UISlider` |
| typealiases AppKit | `Core/AppKitExtend.swift:14-36` | `UIView`→`NSView`, `UIButton`→`KSButton`, `UXSlider`→`NSSlider` etc. |
| `KSButton` (macOS) | `Core/AppKitExtend.swift:388-488` | Reimplementa states/images/titles/target-action de `UIButton` sobre `NSButton`, com tracking areas para mouseEntered/Exited |
| `KSSlider` (macOS) | `Core/AppKitExtend.swift:490-545` | `NSSlider` com `KSSliderDelegate` disparando apenas `.touchUpInside` no action (`:511-515`) |
| `UILabel` (macOS) | `Core/AppKitExtend.swift:369-386` | `NSTextField` não-editável estilizado |
| `UIAlertController`/`UIAlertAction` (macOS) | `Core/AppKitExtend.swift:560-593` | **Stubs vazios** — `present` não faz nada no macOS (`:591-593`) |
| `UIApplication.isIdleTimerDisabled` (macOS) | `Core/AppKitExtend.swift:298-323` | Via `IOPMAssertionCreateWithName` (noDisplaySleep) |
| `LayerContainerView` | `Core/Utility.swift:20-41` | `UIView` com `layerClass = CAGradientLayer` — usada nas máscaras top/bottom |
| `runOnMainThread` | `Core/Utility.swift:352-363` | Executa inline se já na main; senão `Task { await MainActor.run }` (**assíncrono nesse caso**) |
| Extensões `URL` (`isMovie/isAudio/isSubtitle/isPlaylist/parsePlaylist/download`) | `Core/Utility.swift:365-428` | Detecção de tipo e download de legendas/playlists |
| `Scanner.parseM3U` | `Core/Utility.swift:454-503` | Parser de `#EXTINF`/`#EXTVLCOPT` → `(title, URL, extinf)` |
| Conformances `RawRepresentable` (`TextAlignment`, `HorizontalAlignment`, `VerticalAlignment`, `Color`, `Array`, `Date`) | `Core/Utility.swift:531-692` | Permitem persistir configs de legenda em `@AppStorage` |
| `CGImage.combine/make/data` | `Core/Utility.swift:694-750` | Composição de imagens de legenda bitmap |

### Video/

| Tipo | Arquivo:linha | Papel |
|---|---|---|
| `KSPanDirection` (enum) | `Video/VideoPlayerView.swift:18-21` | horizontal/vertical para gestos de pan |
| `LoadingIndector` (protocol) | `Video/VideoPlayerView.swift:23-26` | `startAnimating`/`stopAnimating`; `UIActivityIndicatorView` conforma (`:28-30`) |
| `VideoPlayerView` (open class) | `Video/VideoPlayerView.swift:32-476` | View completa: máscaras gradiente, gestos, auto-hide, legendas UIKit, replay/lock, menus/alerts, seek OSD, speed tip (long press 2x) |
| `KSPlayerTopBarShowCase` (enum) | `Video/VideoPlayerView.swift:943-950` | `always`/`horizantalOnly`/`none` |
| `KSOptions` (extensão UI estática) | `Video/VideoPlayerView.swift:952-966` | `topBarShowInCase`, `animateDelayTimeInterval` (5s), `enableBrightnessGestures`, `enableVolumeGestures`, `enablePlaytimeGestures`, `canBackgroundPlay` |
| Helpers de constraints/safe anchors (`UIView`) | `Video/VideoPlayerView.swift:968-1054` | `frameConstraints`, `safeTopAnchor` etc. — usados pelo fullscreen e pelo transition animator |
| `IOSVideoPlayerView` | `Video/IOSVideoPlayerView.swift:14-281` | iOS: cover (`maskImageView`), botões back/landscape/route, volume via `MPVolumeView` hack (`:70-74`), brilho via `UIScreen.main.brightness` (`:39-44`), fullscreen modal |
| `AirplayStatusView` | `Video/IOSVideoPlayerView.swift:322-356` | Placa "AirPlay 投放中" central quando `isExternalPlaybackActive` |
| `MenuController` (iOS) | `Video/IOSVideoPlayerView.swift:404-474` | Menu "Open File" (⌘O) para Catalyst/iPad |
| `MacVideoPlayerView` | `Video/MacVideoPlayerView.swift:31-133` | macOS: máscara por mouseEntered/Exited (`:55-65`), seek/volume por scroll wheel (`:67-97`), setas/espaço no `keyDown` (`:103-115`), drag & drop de mídia/legenda (`:117-132`), aspect ratio da janela no readyToPlay (`:37-43`) |
| `UIActivityIndicatorView` (macOS) | `Video/MacVideoPlayerView.swift:135-208` | Loader custom com `CABasicAnimation` de rotação + label de progresso |
| `SeekViewProtocol` / `SeekView` | `Video/SeekView.swift:12-75` | OSD central de seek; seta rotaciona 180° quando retrocede (`:66-75`) |
| `UIMenu.init(title:current:list:...)` / `UIButton.setMenu` | `Video/KSMenu.swift:26-59` | Fábrica de menus checáveis; `setMenu` indisponível no tvOS (`#if !os(tvOS)`, `:50`); bridge `NSMenu`/`NSMenuItem` no macOS (`:63-99`) |
| `KSPlayerResource` | `Video/KSPlayerItem.swift:13-64` | name + `[KSPlayerResourceDefinition]` + cover + `SubtitleDataSouce` + `KSNowPlayableMetadata`; `Equatable` por definitions |
| `KSPlayerResourceDefinition` | `Video/KSPlayerItem.swift:70-98` | url + label de qualidade + `KSOptions` próprios; `Equatable/Hashable` **só por url** (`:71-73,95-97`) |
| `KSNowPlayableMetadata` | `Video/KSPlayerItem.swift:104-147` | Dicionário para `MPNowPlayingInfoCenter` |
| `PlayerViewFullScreenDelegate` / `PlayerFullScreenViewController` | `Video/PlayerFullScreenViewController.swift:11-67` | VC modal de fullscreen (iOS, `!os(tvOS)`); controla orientação via `KSOptions.supportedInterfaceOrientations` (`:30`) e status bar |
| `PlayerTransitionAnimator` | `Video/PlayerTransitionAnimator.swift:11-70` | Transição present/dismiss animando o `player.view` entre superviews, salvando/restaurando `frameConstraints` |
| `BrightnessVolume` (@MainActor, singleton) | `Video/BrightnessVolume.swift:10-64` | HUD de brilho (KVO de `UIScreen.brightness`) e volume (notificação privada `AVSystemController_SystemVolumeDidChangeNotification`, `:25-26`) |
| `BrightnessVolumeViewProtocol` + `SystemView`/`ProgressView` | `Video/BrightnessVolume.swift:66-225` | Duas implementações do HUD; default é `ProgressView` vertical à direita (`:14`) |

### SwiftUI/

| Tipo | Arquivo:linha | Papel |
|---|---|---|
| `KSVideoPlayerView` (@MainActor, iOS 16/tvOS 16/macOS 13+) | `SwiftUI/KSVideoPlayerView.swift:13-315` | View raiz: `KSVideoPlayer` (representable) + `VideoSubtitleView` + `controllerView` + `VideoSettingView`; focus/remote no tvOS; atalhos de teclado; drop de arquivos |
| `FocusableField` (enum) | `SwiftUI/KSVideoPlayerView.swift:300-302` | `play`/`controller`/`info` — máquina de foco do tvOS |
| `onKeyPressLeftArrow/RightArrow/Sapce` (View ext) | `SwiftUI/KSVideoPlayerView.swift:317-350` | Wrappers de `onKeyPress` com fallback para OS < 17 |
| `VideoControllerView` | `SwiftUI/KSVideoPlayerView.swift:352-517` | Barra de controles; layout tvOS totalmente separado (linha única inferior, `:367-403`) do layout iOS/macOS/visionOS (`:404-444`) |
| `MenuView<Label, SelectionValue, Content>` | `SwiftUI/KSVideoPlayerView.swift:519-552` | `Menu`+`Picker` inline (tvOS 17+) com fallback `.navigationLink` |
| `VideoTimeShowView` | `SwiftUI/KSVideoPlayerView.swift:554-587` | Tempo atual/total + `Slider`; pausa no início do drag e `config.seek` no fim (`:569-575`); "Live Streaming" se não seekable |
| `VideoSubtitleView` + `SubtitlePart.subtitleView` | `SwiftUI/KSVideoPlayerView.swift:593-664` | Renderiza `model.parts`: imagem (com `fitRect`) ou texto com posição/estilo de `SubtitleModel` |
| `VideoSettingView` | `SwiftUI/KSVideoPlayerView.swift:666-718` | Painel: track de vídeo, delay de legenda, busca de legenda, `DynamicInfoView`, file size |
| `DynamicInfoView` | `SwiftUI/KSVideoPlayerView.swift:720-732` | FPS, sync A/V, frames dropados, bitrates (observa `DynamicInfo`) |
| `PlatformView` | `SwiftUI/KSVideoPlayerView.swift:734-757` | tvOS: `ScrollView` + `.pickerStyle(.navigationLink)`; demais: `Form` |
| `KSVideoPlayerViewBuilder` (enum de fábricas estáticas) | `SwiftUI/KSVideoPlayerViewBuilder.swift:11-193` | Botões compartilhados: playback (±15s/play), contentMode, subtitle, rate, mute, info, title; nomes de SF Symbols por plataforma (`:108-140`) |
| `Slider` (tvOS) | `SwiftUI/Slider.swift:14-30` | Substitui o `SwiftUI.Slider` inexistente no tvOS; delega para `TVOSSlide` |
| `TVOSSlide` (`UIViewRepresentable`) | `SwiftUI/Slider.swift:33-58` | Ponte para `TVSlide`; tint vermelho quando focado (`:45-51`) |
| `TVSlide` (`UIControl`) | `SwiftUI/Slider.swift:60-170` | Seek do tvOS: press left/right com aceleração via `Timer` (rate até 10x, `:70-80`), pan no touchpad (`:140-169`); `onEditingChanged(false)` (commit) só 1.5s após soltar (`:127-138`) |
| `AirPlayView` (representable) | `SwiftUI/AirPlayView.swift:12-34` | `AVRoutePickerView` para SwiftUI |
| `View.if`/`ifLet` | `SwiftUI/AirPlayView.swift:36-68` | Modificadores condicionais |
| `LiveTextImage` | `SwiftUI/LiveTextImage.swift:14-66` | Legenda bitmap com Live Text (VisionKit), atrás da flag de compilação `enableFeatureLiveText` (`KSVideoPlayerView.swift:606`) |
| `UIImage.fitRect` | `SwiftUI/LiveTextImage.swift:77-85` | Cálculo de rect aspect-fit ancorado no rodapé para legendas de imagem |

## Fluxo de dados

### Caminho UIKit/AppKit

1. **Set de mídia**: app chama `VideoPlayerView.set(resource:definitionIndex:)` (`Video/VideoPlayerView.swift:369-376`) → `PlayerView.set(url:options:)` cria `KSPlayerLayer(url:options:)` (`Core/PlayerView.swift:150-155`). O didSet de `playerLayer` em `PlayerView` seta `playerLayer.delegate = self` (`Core/PlayerView.swift:43-47`); o override em `VideoPlayerView` remove a view do player antigo e insere `playerLayer.player.view` **abaixo** de `contentOverlayView` com constraints full-bleed (`Video/VideoPlayerView.swift:121-139`). O didSet de `resource` alimenta título, legendas externas, botão de definition e `MPNowPlayingInfoCenter` (`Video/VideoPlayerView.swift:57-73`).
2. **Hierarquia resultante** (montada em `setupUIComponents`, `Video/VideoPlayerView.swift:179-239` + `addConstraint` `:743-803`): `VideoPlayerView` → [`maskImageView` (só iOS, index 0), `player.view`, `contentOverlayView`, `subtitleBackView`+`subtitleLabel`, `controllerView` → [`loadingIndector`, `seekToView`, `replayButton`, `lockButton`, `topMaskView`→`navigationBar`→`titleLabel`, `bottomMaskView`→[`toolBar`, `toolBar.timeSlider`], `speedTipLabel`]]. As máscaras são `LayerContainerView` com gradiente preto→transparente (`:183-192`).
3. **Estado (engine→UI)**: `KSPlayerLayer` chama `player(layer:state:)` — `PlayerView` atualiza `totalTime`, `isSeekable`, `playButton.isSelected` (`Core/PlayerView.swift:171-180`); `VideoPlayerView` sobrepõe para loader/replay/menus e agenda a adição de legendas embutidas com delay de 1s pós-`readyToPlay` (`Video/VideoPlayerView.swift:277-324`, delay em `:289`). `IOSVideoPlayerView` ainda faz fade-out do cover (`Video/IOSVideoPlayerView.swift:212-220`).
4. **Tempo (engine→UI)**: `player(layer:currentTime:totalTime:)` → `PlayerView` propaga para delegate/`playTimeDidChange` e escreve em `toolBar.currentTime` (`Core/PlayerView.swift:182-187`); os didSet do toolbar formatam labels e movem o slider (`Core/PlayerToolBar.swift:41-88`). `VideoPlayerView` suprime updates enquanto `isSliderSliding` e consulta `srtControl.subtitle(currentTime:)` para atualizar `subtitleLabel`/`subtitleBackView` (`Video/VideoPlayerView.swift:261-275`).
5. **Input (UI→engine)**: botões carregam `tag = PlayerButtonType`; `PlayerToolBar.addTarget` registra todos para `.primaryActionTriggered` (`Core/PlayerToolBar.swift:254-262`) → `PlayerView.onButtonPressed(_:)` resolve o tipo e trata menu (macOS popUp / iOS 14+ retorna cedo se há `UIMenu` — `Core/PlayerView.swift:74-95`) → `onButtonPressed(type:button:)` executa play/pause/back e repassa ao `PlayerControllerDelegate` (`:97-113`). No tvOS, srt/rate/definition/audio/video viram `UIAlertController` (`Video/VideoPlayerView.swift:160-169` → `:538-633`); no iOS/macOS 14+/15+ viram `UIMenu` via `buildMenusForButtons` (`:481-532`).
6. **Slider**: `KSSlider` → `KSSliderDelegate.slider(value:event:)` → `PlayerView.slider` (valueChanged atualiza label; touchUpInside chama `seek`, `Core/PlayerView.swift:159-167`); `VideoPlayerView.slider` gerencia `isSliderSliding` e o auto-hide (`Video/VideoPlayerView.swift:341-353`).
7. **Gestos**: instalados em `customizeUIComponents` (`Video/VideoPlayerView.swift:242-259`). Tap alterna `isMaskShow`; double-tap play/pause; long press ≥0.5s → playbackRate 2x com `speedTipLabel` (`:436-475`); pan → `panGestureAction` decide direção pela velocidade (`:660-681`) → horizontal acumula `tmpPanValue` e mostra `seekToView` (`:400-413`), commit no `panGestureEnded` via `slider(value:event:.touchUpInside)` (`:423-432`). No iOS, pan vertical vira volume (metade direita, via `volumeViewSlider` extraído de `MPVolumeView`) ou brilho (metade esquerda) (`Video/IOSVideoPlayerView.swift:243-272`).
8. **Auto-hide**: `isMaskShow` didSet anima alpha de masks/replay/lock e notifica `delegate.playerController(maskShow:)` (`Video/VideoPlayerView.swift:87-104`); `autoFadeOutViewWithAnimation` agenda `DispatchWorkItem` de `KSOptions.animateDelayTimeInterval` (5s) **somente se tocando** (`:722-731`).
9. **Fullscreen iOS**: `updateUI(isFullScreen:)` guarda superview/constraints/frame originais, move `self` para um `PlayerFullScreenViewController` apresentado modal (`Video/IOSVideoPlayerView.swift:128-182`); a animação é o `PlayerTransitionAnimator`, que reparenta o `player.view` para o container da transição e restaura as constraints no completion (`Video/PlayerTransitionAnimator.swift:28-69`). Orientação flui por `KSOptions.supportedInterfaceOrientations` (`Video/IOSVideoPlayerView.swift:358-361`), que o app deve retornar no AppDelegate.

### Caminho SwiftUI

1. **Composição**: `KSVideoPlayerView.body` empilha em `ZStack`+`GeometryReader`: `playView` (o `KSVideoPlayer` representable com todos os event modifiers), `VideoSubtitleView` central com `allowsHitTesting(false)` (`SwiftUI/KSVideoPlayerView.swift:61-83`, hit-testing em `:68`), `controllerView` e — só tvOS — `VideoSettingView` inline quando `isDropdownShow` (`:76-81`).
2. **Estado**: tudo flui do `KSVideoPlayer.Coordinator` (`@StateObject`, definido em `Sources/KSPlayer/AVPlayer/KSVideoPlayer.swift:74`): `state`, `isMaskShow`, `playbackRate`, `playbackVolume`, `isMuted`, `isScaleAspectFill`, `timemodel: ControllerTimeModel` (tempos como `Int` de segundos, `AVPlayer/KSVideoPlayer.swift:330`) e `subtitleModel.parts` (legendas). Views observam com `@ObservedObject` (`VideoControllerView` `:354-357`, `VideoTimeShowView` `:556-559`, `VideoSubtitleView` `:595-596`).
3. **Comandos**: botões do `KSVideoPlayerViewBuilder` chamam `config.playerLayer?.play()/pause()`, `config.skip(interval:)`, `config.isMuted.toggle()` etc. (`SwiftUI/KSVideoPlayerViewBuilder.swift:144-192`). Seek: `VideoTimeShowView` pausa quando o drag começa e chama `config.seek(time:)` quando termina (`SwiftUI/KSVideoPlayerView.swift:569-575`); no tvOS o "fim do drag" é o `onEditingChanged(false)` do `TVSlide`, disparado por select ou 1.5s após soltar a seta (`SwiftUI/Slider.swift:121-122,127-138`).
4. **tvOS focus/remote**: foco inicial em `.play` no `onAppear` (`:130`); `.onMoveCommand`: left/right = skip ±15s, up = mostra máscara sem auto-hide (`mask(show:autoHide:false)`), down = foco `.info` que abre o `VideoSettingView` via `willSet` de `focusableField` (`:21-26`, `:196-210`); `.onExitCommand`: primeiro esconde máscara, depois devolve foco a `.play`, e só então `dismiss()` (`:96-107`); `.onPlayPauseCommand` alterna play/pause (`:88-95`). Quando `isMaskShow` vira true, `VideoTimeShowView` entra na hierarquia e seu `onAppear` move o foco para `.controller` (`:230-239`).
5. **Layout tvOS**: `controllerView` ganha `padding` horizontal 80 / bottom 80 e gradiente inferior (`:252-256`); a barra é uma única linha `título + spinner + [play, audio, mute, contentMode, subtitle, rate, pip, info]` (`:367-403`).

## Pontos de extensão

- **Subclasse de `VideoPlayerView` + `customizeUIComponents()`** (`Video/VideoPlayerView.swift:242`): é o hook oficial ("Add Customize functions here") — `IOSVideoPlayerView.customizeUIComponents` (`Video/IOSVideoPlayerView.swift:46-97`) e `MacVideoPlayerView` (`Video/MacVideoPlayerView.swift:32-35`) são os exemplos canônicos. Chamado ao final de `setupUIComponents` (`Video/VideoPlayerView.swift:236`), com toda a hierarquia já montada.
- **`onButtonPressed(type:button:)` (open)** (`Core/PlayerView.swift:97` / `Video/VideoPlayerView.swift:152` / `Video/IOSVideoPlayerView.swift:109`): interceptar ou adicionar ações. Para botão novo: criar `UIButton`, setar `tag` com um raw value novo em `PlayerButtonType` (`Core/PlayerView.swift:15-28`), adicionar ao `toolBar` via `addArrangedSubview` e registrar o target.
- **`PlayerControllerDelegate`** (`Core/PlayerView.swift:30-39`): o app recebe todos os eventos (estado, tempo, ações de botão, maskShow, rebuffer) sem subclassear.
- **`loadingIndector: UIView & LoadingIndector`** (`Video/VideoPlayerView.swift:82`) e **`seekToView: UIView & SeekViewProtocol`** (`:83`): propriedades `public var` — basta atribuir outra implementação antes de `setupUIComponents` rodar (i.e., em subclasse) para trocar o spinner/OSD.
- **`BrightnessVolume.progressView: BrightnessVolumeViewProtocol & UIView`** (`Video/BrightnessVolume.swift:14`): trocar o HUD de brilho/volume (o `SystemView` em `:72-165` é uma alternativa pronta).
- **Sensibilidade de gestos**: sobrescrever `panValue(velocity:direction:currentTime:totalTime:)` (`Video/VideoPlayerView.swift:415-421`) ou os três hooks `panGestureBegan/Changed/Ended` (`:391-432`).
- **Flags estáticas `KSOptions`**: `topBarShowInCase`, `animateDelayTimeInterval`, `enableBrightnessGestures`, `enableVolumeGestures`, `enablePlaytimeGestures`, `canBackgroundPlay` (`Video/VideoPlayerView.swift:952-966`); `supportedInterfaceOrientations` (`Video/IOSVideoPlayerView.swift:358-361`).
- **SwiftUI — `KSVideoPlayerViewBuilder`** (`SwiftUI/KSVideoPlayerViewBuilder.swift:11`): fábricas estáticas de botões; é aqui que se muda ícone/comportamento de um controle para todas as telas. Não há protocolo: modificação é por edição direta (fork GPL, ok).
- **SwiftUI — injeção de coordinator e legendas**: `KSVideoPlayerView.init(coordinator:url:options:title:subtitleDataSouce:)` (`SwiftUI/KSVideoPlayerView.swift:46-59`) permite manter o `Coordinator` fora da view (controle externo de playback) e injetar `SubtitleDataSouce` custom (adicionado no `onAppear`, `:131-133`).
- **`openURL(_:)`** (`SwiftUI/KSVideoPlayerView.swift:304-314`): troca de mídia/legenda em runtime (usado pelo onDrop, `:215-222`).
- **`MenuView`** (`SwiftUI/KSVideoPlayerView.swift:519-552`) e **`UIButton.setMenu`** (`Video/KSMenu.swift:53-59`): componentes reutilizáveis para novos seletores (tracks, qualidade, etc.).
- **`Slider` tvOS** (`SwiftUI/Slider.swift:14`): substitui `SwiftUI.Slider` em todo código tvOS; qualquer feature de scrubbing (thumbnails estilo Infuse, por exemplo) começa em `TVSlide` (`:60-170`).

## Pegadinhas

- **`cancellable` do PiP nunca conecta**: em `VideoPlayerView.init`, `playerLayer?.$isPipActive.assign(...)` roda quando `playerLayer` ainda é nil (`Video/VideoPlayerView.swift:144`) — o binding do estado de PiP para `pipButton.isSelected` está morto no caminho UIKit. Ao evoluir o fork, refazer a assinatura no didSet de `playerLayer`.
- **Slider do tvOS UIKit é decorativo**: `UXSlider` tvOS é `UIProgressView` (`Core/UIKitExtend.swift:94-162`); `addTarget` é no-op (`:136`) e os gestos do `KSSlider` (tap/pan por posição, `Core/UIKitExtend.swift:66-91`) não fazem sentido no Siri Remote. Seek no tvOS UIKit vem exclusivamente de `addRemoteControllerGestures` (±15s, `Video/VideoPlayerView.swift:878-901`). No SwiftUI o scrubbing real está em `TVSlide`.
- **Modo live stream implícito**: `isLiveStream == (totalTime == 0)` (`Core/PlayerToolBar.swift:90-92`); nesse modo o slider vira relógio do dia (`todayInterval`, `:60-70`, max = 86400 em `:84-86`). Qualquer mudança na toolbar precisa preservar esse branch.
- **iOS 14+ com menu engole o delegate**: `PlayerView.onButtonPressed(_:)` retorna cedo se `button.menu != nil` (`Core/PlayerView.swift:90-92`) — o `PlayerControllerDelegate.playerController(action:)` **não** dispara para botões com `UIMenu`.
- **Legendas embutidas chegam 1s depois**: `readyToPlay` agenda `asyncAfter(1s)` para adicionar o `subtitleDataSouce` do player (algumas legendas vêm no stream de vídeo — comentário em `Video/VideoPlayerView.swift:288-299`). `srtButton.isHidden` e os menus só ficam corretos após esse delay.
- **`delayItem` é compartilhado**: o mesmo `DispatchWorkItem` controla auto-hide da máscara (`Video/VideoPlayerView.swift:722-731`) e o fade do `speedTipLabel` (`:465-475`) — `showSpeedTip` cancela um auto-hide pendente.
- **Auto-hide só quando tocando**: `autoFadeOutViewWithAnimation` sai cedo se `playButton.isSelected == false` (`Video/VideoPlayerView.swift:725`) — pausado, a máscara fica visível para sempre.
- **Fullscreen iOS é frágil por design**: `updateUI(isFullScreen:)` desativa constraints originais, reparenta a view e restaura no completion do dismiss (`Video/IOSVideoPlayerView.swift:139-178`); `PlayerTransitionAnimator` reparenta o `player.view` no meio da transição (`Video/PlayerTransitionAnimator.swift:46-66`). Alterações na hierarquia de `VideoPlayerView` podem quebrar os dois. Nada disso existe no tvOS (`PlayerFullScreenViewController` é `!os(tvOS)`, `Video/PlayerFullScreenViewController.swift:7`).
- **`UIAlertController` no macOS é stub**: `present` é vazio (`Core/AppKitExtend.swift:591-593`), logo os fluxos de alert de `VideoPlayerView` (`changeSrt` etc.) silenciosamente não fazem nada no macOS — lá os menus reais são `NSMenu.popUp` (`Core/PlayerView.swift:77-86`).
- **Bug herdado no `KSButton` (macOS)**: `mouseEntered` dispara a action de `.mouseExited` (`Core/AppKitExtend.swift:469-474`) — copy/paste; corrigir se hover for usado.
- **API privada no `BrightnessVolume`**: usa a notificação `AVSystemController_SystemVolumeDidChangeNotification` (`Video/BrightnessVolume.swift:25-26`) — privada; irrelevante para uso pessoal, mas reprovável em App Store. É singleton `@MainActor` com KVO de `UIScreen.brightness` no init (`:17-24`).
- **Dois renderizadores de legenda**: o UIKit usa `subtitleLabel`/`subtitleBackView` (`Video/VideoPlayerView.swift:692-717`, estilo aplicado só em `updateSrt()` `:684-690` — chamar após mudar `SubtitleModel.textFont/textColor`); o SwiftUI usa `VideoSubtitleView`/`SubtitlePart.subtitleView` com suporte a posição/itálico/imagem (`SwiftUI/KSVideoPlayerView.swift:593-664`). Features de legenda precisam ser feitas duas vezes ou o caminho UIKit ser abandonado.
- **`Text("")` obrigatório**: no branch sem imagem/texto de `subtitleView`, o `Text("")` vazio é workaround para o SwiftUI limpar a imagem anterior (comentário em `SwiftUI/KSVideoPlayerView.swift:658-661`). Não remover.
- **`VideoTimeShowView` entra/sai da hierarquia de propósito**: opacity 0 continuaria atualizando a view (comentário `SwiftUI/KSVideoPlayerView.swift:230`), e os `onAppear/onDisappear` são quem move o foco tvOS entre `.controller` e `.play` (`:233-238`). Trocar por `.opacity` quebra foco e performance.
- **Vazamentos conhecidos do `Coordinator`**: monitor de `NSEvent.addLocalMonitorForEvents` no macOS (comentário `SwiftUI/KSVideoPlayerView.swift:134-140`) e `keyboardShortcut` no simulador iOS (comentário `SwiftUI/KSVideoPlayerViewBuilder.swift:101-104`) impedem o release do `Coordinator`.
- **Commit de seek atrasado no tvOS**: `TVSlide` só chama `onEditingChanged(false)` (que executa o `config.seek`) 1.5s depois do último press de seta (`SwiftUI/Slider.swift:127-138`) ou imediatamente no select (`:120-122`). O `Timer` de repetição é ligado/desligado via `fireDate = distantPast/distantFuture` (`:115-121,128`) e acelera até 10x (`:74`).
- **`runOnMainThread` fora da main é assíncrono** (`Core/Utility.swift:352-363`): usa `Task { await MainActor.run }`, sem garantia de ordem com outras tasks — não usar quando a ordem importa.
- **`PlayerToolBar.addArrangedSubview` força `isHidden = false`** (`Core/PlayerToolBar.swift:224-227`): esconder um botão antes de adicioná-lo não funciona; esconda depois.
- **Concorrência**: o target compila com `StrictConcurrency` experimental (`Package.swift:31`); as views são `@MainActor` por herdarem de UIView/NSView, e os callbacks de `KSPlayerLayerDelegate` já chegam na main (protocolo `@MainActor`, `Sources/KSPlayer/AVPlayer/KSPlayerLayer.swift:60`). Helpers puros novos (parsing, structs de dados) devem ficar `nonisolated`.
- **`KSPlayerResourceDefinition` é `Equatable/Hashable` só por `url`** (`Video/KSPlayerItem.swift:71-73,95-97`): duas definitions com mesma URL e `KSOptions` diferentes são "iguais" — cuidado ao usar em `Set`/diffing.
- **`isSliderSliding` suprime o clock da UI** (`Video/VideoPlayerView.swift:261-263`): setado no `.touchDown` e limpo no `.touchUpInside` (`:348-352`) e também usado pelo pan horizontal (`:405`); um caminho de código que dispare `.touchDown` sem `.touchUpInside` congela os labels de tempo.

## Relação com outros subsistemas

- **AVPlayer (doc 02)** — dependência central: `KSPlayerLayer` é criado por `PlayerView.set(url:options:)` (`Core/PlayerView.swift:154`) e consumido via `KSPlayerLayerDelegate`; o caminho SwiftUI depende de `KSVideoPlayer`, `KSVideoPlayer.Coordinator` e `ControllerTimeModel` (`Sources/KSPlayer/AVPlayer/KSVideoPlayer.swift:19,74,330`); `TimeType`/`toString(for:)` usados pela toolbar vêm de `Sources/KSPlayer/AVPlayer/PlayerDefines.swift:290-306`; todas as flags de UI são extensões estáticas de `KSOptions`.
- **Subtitle** — `PlayerView.srtControl` e `Coordinator.subtitleModel` são `SubtitleModel`; a UI consome `subtitle(currentTime:)`/`parts` para renderizar e `subtitleInfos`/`selectedSubtitleInfo` para os seletores; `URLSubtitleInfo` é criado no drag & drop/document picker (`Video/MacVideoPlayerView.swift:127`, `Video/IOSVideoPlayerView.swift:396`); `SubtitleModel.textFont/textColor/textBackgroundColor/textPosition` estilizam ambos os renderizadores.
- **Motores (KSAVPlayer/KSMEPlayer)** — acesso indireto por `playerLayer.player` (`MediaPlayerProtocol`): a UI insere `player.view`, lê `tracks(mediaType:)`, `select(track:)`, `naturalSize`, `seekable`, `dynamicInfo`, `fileSize`, `thumbnailImageAtCurrentTime()` (`Video/IOSVideoPlayerView.swift:234`).
- **Sistema/frameworks**: `MPNowPlayingInfoCenter` (`Video/VideoPlayerView.swift:70`), `MPVolumeView` (hack para slider de volume, `Video/IOSVideoPlayerView.swift:70-74`), `AVRoutePickerView`/`AVRouteDetector` (AirPlay, `Video/IOSVideoPlayerView.swift:26-28`, `SwiftUI/AirPlayView.swift:12-34`), `AVPictureInPictureController.isPictureInPictureSupported()` (`Core/PlayerToolBar.swift:178-180`), VisionKit (`SwiftUI/LiveTextImage.swift:9-66`), IOKit para impedir sleep no macOS (`Core/AppKitExtend.swift:298-323`).
- **Para o StreamHub (tvOS)**: a superfície efetivamente exercitada é `KSVideoPlayerView` + `Coordinator` + `VideoSubtitleView` + `Slider`/`TVSlide` + `KSVideoPlayerViewBuilder`; o caminho UIKit (`VideoPlayerView` e derivados) compila no tvOS mas não é o usado — paridade com Infuse deve ser construída no caminho SwiftUI.
