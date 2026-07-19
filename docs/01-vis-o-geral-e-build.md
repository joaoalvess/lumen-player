# 01 — Visão geral e build

Fork GPL do KSPlayer (upstream `kingslay/KSPlayer`, branch `main`, commit `1b8b46f`, `git describe` = `2.3.4-35-g1b8b46f`). Player de vídeo Swift para iOS/tvOS/macOS/macCatalyst/visionOS com dois kernels: `KSAVPlayer` (AVFoundation) e `KSMEPlayer` (FFmpeg + Metal). Este documento cobre exclusivamente como o pacote se monta: manifesto SPM, binários FFmpeg/libass, target ObjC `DisplayCriteria`, podspecs, targets, plataformas e CI. Todos os paths são relativos à raiz do repo (`/Users/joaoalves/Developer/StreamHub/Player`).

## Responsabilidade

- Declarar o pacote SPM `KSPlayer` com um único produto library (`Package.swift:12-17`), dois targets compiláveis (`KSPlayer` Swift e `DisplayCriteria` ObjC) e um test target (`Package.swift:19-42`).
- Trazer todo o FFmpeg, libass e dependências nativas como **binary targets pré-compilados** via o pacote externo `kingslay/FFmpegKit` `from: "6.1.4"` (`Package.swift:45-47`), pinado em `Package.resolved:4-11` na revisão `c32be9bfb628042737ad3ef622e930c5c7b15954`.
- Expor a API privada `AVDisplayCriteria(refreshRate:videoDynamicRange:)` para match de refresh rate/HDR na Apple TV, via o target ObjC `DisplayCriteria` (`Sources/DisplayCriteria/include/AVDisplayCriteriaKS.h`).

## Tipos principais

Num subsistema de build, os "tipos" são manifestos, targets e artefatos:

| Tipo/artefato | Arquivo | Papel |
|---|---|---|
| `Package` (manifesto SPM) | `Package.swift:5-47` | swift-tools 5.9 (`:1`); plataformas macOS 10.15, macCatalyst 14, iOS 13, tvOS 13, visionOS 1 (`:8-9`); produto único `.library(name: "KSPlayer")` (`:12-17`, `.dynamic` comentado em `:15`) |
| Target `KSPlayer` | `Package.swift:21-33` | Todo o código Swift em `Sources/KSPlayer/{Audio,AVPlayer,Core,MEPlayer,Metal,Subtitle,SwiftUI,Video}`; depende do produto `FFmpegKit` (`:24`) e de `DisplayCriteria` (`:27`); recurso `.process("Metal/Shaders.metal")` (`:29`); flag `.enableExperimentalFeature("StrictConcurrency")` (`:30-32`) |
| Target `DisplayCriteria` | `Package.swift:34-36` | Target ObjC por convenção de path (`Sources/DisplayCriteria/`); `DisplayCriteria.m` é **vazio** (existe só para o SPM aceitar o target); header público `include/AVDisplayCriteriaKS.h` |
| Categoria `AVDisplayCriteria ()` | `Sources/DisplayCriteria/include/AVDisplayCriteriaKS.h:10-17` | Declara `videoDynamicRange`, `refreshRate` e `initWithRefreshRate:videoDynamicRange:` (API privada da Apple), guardado por `__has_include(<AVFoundation/AVDisplayCriteria.h>)` |
| Test target `KSPlayerTests` | `Package.swift:37-41` | 8 arquivos XCTest em `Tests/KSPlayerTests/`; recurso processado `Tests/KSPlayerTests/Resources/test.m3u` |
| Pacote externo `FFmpegKit` | `Package.resolved:4-11` | Pin em 6.1.4/`c32be9bf`. No manifesto do FFmpegKit nessa revisão: produto `FFmpegKit` agrega o target wrapper mais ~24 `binaryTarget` com `path: "Sources/<nome>.xcframework"` — ou seja, os xcframeworks estão **commitados no repo do FFmpegKit**, não em release assets |
| Binários FFmpeg | repo FFmpegKit rev `c32be9bf`, `Sources/` | `Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample`, `Libswscale` (FFmpeg 6.1) |
| Binários libass/fontes | idem | `libass`, `libfreetype`, `libfribidi`, `libharfbuzz`, `libfontconfig` — linkados por serem dependência do target `FFmpegKit`, embora este fork não tenha `import libass` em `Sources/` |
| Demais binários | idem | `MoltenVK`, `libshaderc_combined`, `libplacebo`, `lcms2` (render/tonemap), `libdav1d` (AV1), `libsrt`, `libzvbi`, `libsmbclient` (SMB), `gmp`+`nettle`+`hogweed`+`gnutls` (TLS), `libbluray` (só macOS), `libmpv` (produto separado, não usado aqui) |
| Shim `Bundle.module` | `Sources/KSPlayer/AVPlayer/PlayerDefines.swift:284-288` | Sob `#if !SWIFT_PACKAGE` resolve `KSPlayer_KSPlayer.bundle` via `Bundle(for: KSPlayerLayer.self)` — cola que faz o mesmo código de recursos funcionar em CocoaPods |
| CI | `.github/workflows/build.yml:23-32` | `swift build` para macOS e cross-build para simuladores iOS/tvOS/xrOS via `--sdk` + `-Xswiftc -target`; `swift test -v`; Xcode 16.1 (`:20`) |
| Metadados | `.spi.yml` (`documentation_targets: [KSPlayer]`), `.swiftformat` (`--swiftversion 5.7`, `--ifdef noindent`), `.gitattributes` (`*.h linguist-language=Swift`) | Swift Package Index, formatação e stats do GitHub |

## Fluxo de dados

Montagem via SPM (caminho usado pelo StreamHub):

1. `swift build`/Xcode lê `Package.swift`; `package.dependencies += [.package(url: "https://github.com/kingslay/FFmpegKit.git", from: "6.1.4")]` é apendado após a declaração (`Package.swift:45-47`). `Package.resolved:4-11` congela a revisão exata.
2. O clone do FFmpegKit traz os `.xcframework` já dentro do git (binary targets com `path:`, não `url:`+checksum). Não há passo de download de artefato separado nem compilação de C — o clone é o download (multi-GB).
3. O target `KSPlayer` compila com o produto `FFmpegKit` no import path. Como cada `binaryTarget` é um módulo Clang próprio, os fontes importam módulos individuais transitivamente: `import FFmpegKit`/`Libavcodec`/`Libavfilter`/`Libavformat` em `Sources/KSPlayer/MEPlayer/MEPlayerItem.swift:9-12`, `Libswresample`/`Libswscale` em `Sources/KSPlayer/MEPlayer/Resample.swift:11-13`, `Libavutil` em `Sources/KSPlayer/Metal/PixelBufferProtocol.swift:11`, etc.
4. `DisplayCriteria` compila como módulo ObjC (headers de `include/` viram umbrella automático). É importado apenas sob `#if os(tvOS) || os(xrOS)` em `Sources/KSPlayer/AVPlayer/KSOptions.swift:9-11`.
5. Linkagem: o target `FFmpegKit` do pacote externo carrega `linkerSettings` com os frameworks de sistema (AudioToolbox, VideoToolbox, Metal, Security…) e libs (`bz2`, `c++`, `iconv`, `resolv`, `xml2`, `z`) — o app consumidor herda tudo transitivamente, sem configurar nada.
6. Recursos: `.process("Metal/Shaders.metal")` (`Package.swift:29`) faz o SPM compilar o shader para `default.metallib` dentro do bundle sintetizado `KSPlayer_KSPlayer.bundle`. Em runtime, `MetalRender.library` (`Sources/KSPlayer/Metal/MetalRender.swift:16-23`) tenta `device.makeDefaultLibrary()` (metallib do app) e cai para `makeDefaultLibrary(bundle: .module)`.
7. Runtime tvOS: `KSOptions.updateVideo(refreshRate:isDovi:formatDescription:)` (`KSOptions.swift:338-357`) constrói `AVDisplayCriteria(refreshRate:videoDynamicRange:)` (`:354`) com o raw value de `DynamicRange` (`PlayerDefines.swift:45-49`: sdr=0, hdr10=2, hlg=3, dolbyVision=5) e seta `avDisplayManager.preferredDisplayCriteria`; `playerLayerDeinit()` (`KSOptions.swift:426-432`) zera o critério ao sair.

## Pontos de extensão

- **Trocar/atualizar o FFmpeg**: mude a versão em `Package.swift:46`. Para desenvolver o FFmpegKit localmente, substitua por `.package(path: "../FFmpegKit")` (o clone local já é esperado pelo Demo e ignorado pelo git). O `import Foundation` em `Package.swift:2` é vestígio do upstream que fazia exatamente essa troca condicional via `FileManager`.
- **Recompilar FFmpeg com outras flags** (ex.: habilitar decoders/protocolos que a versão paga tem): o pacote FFmpegKit expõe o plugin de comando `BuildFFmpeg` (produto `.plugin` no manifesto do FFmpegKit) — `swift package BuildFFmpeg` no clone do FFmpegKit regenera os xcframeworks.
- **Usar libass de verdade (paridade com a versão paga/Infuse para ASS)**: descomente `Package.swift:25`, mas o nome do produto na 6.1.4 é `libass` (minúsculo, agregando `libfreetype`+`libfribidi`+`libharfbuzz`+`libass`), não `Libass` — nomes de produto SPM são case-sensitive. Os binários já são linkados hoje via produto `FFmpegKit`; o que falta é declarar o produto para poder dar `import libass` no target `KSPlayer` (o consumo seria no subsistema Subtitle: `Sources/KSPlayer/MEPlayer/SubtitleDecode.swift` / `Sources/KSPlayer/Subtitle/`).
- **libmpv**: produto `libmpv` existe no FFmpegKit (comentado em `Package.swift:26`) — rota alternativa se a paridade com Infuse for buscada via kernel mpv em vez de evoluir o `KSMEPlayer`.
- **Executáveis de debug**: o FFmpegKit também expõe `ffmpeg`/`ffprobe`/`ffplay` como `executableTarget` — úteis para inspecionar streams com exatamente o mesmo FFmpeg embarcado.
- **Novo shader**: adicione a função em `Sources/KSPlayer/Metal/Shaders.metal` (único recurso do target); é carregada por nome via `MetalRender.library.makeFunction(name:)` — nada a mudar no manifesto.
- **Nova plataforma/deployment target**: `Package.swift:8-9` é o único ponto de configuração.
- **Comportamento de DisplayCriteria**: `KSOptions.updateVideo` e `playerLayerDeinit` são `open` (`KSOptions.swift:338-357`, `:426-432`) — subclasse de `KSOptions` no app pode customizar a política de match (ex.: permitir Dolby Vision em vez do downgrade para HDR10 feito em `:351-353`) sem tocar no fork.
- **Testes**: fixtures processadas em `Tests/KSPlayerTests/Resources` (`Package.swift:40`); para reativar os testes de mídia, adicione `h264.MP4`, `mjpeg.flac`, `hevc.mkv` lá (ver Pegadinhas sobre o lookup).

## Pegadinhas

- **API privada da Apple**: `AVDisplayCriteriaKS.h:12-16` declara init privado de `AVDisplayCriteria`. Para app pessoal (caso StreamHub) é irrelevante, mas é motivo de rejeição em review da App Store. O init virou API pública só no tvOS 17; o header dá acesso desde tvOS 13. O uso real é só tvOS/visionOS (`KSOptions.swift:340`/`:427` sob `#if os(tvOS) || os(xrOS)`).
- **`DisplayCriteria.m` vazio é obrigatório**: `Sources/DisplayCriteria/DisplayCriteria.m` contém uma linha em branco. Sem pelo menos um arquivo-fonte o SPM rejeita o target. Não deletar "por limpeza".
- **Clone gigante do FFmpegKit**: os xcframeworks estão commitados no git do FFmpegKit (binary targets com `path:`). Resolver o pacote baixa o histórico com binários. CI/caches precisam levar isso em conta; `Package.resolved` deve ficar versionado para builds reprodutíveis.
- **`StrictConcurrency` só no target principal** (`Package.swift:30-32`): código novo em `Sources/KSPlayer` compila com checagem estrita de Sendable/isolamento (warnings hoje, erros no Swift 6); `KSPlayerTests` não tem a flag. Tipos de dados/parsing novos devem ser `nonisolated`/`Sendable` desde o início.
- **Ordem de fallback do metallib** (`MetalRender.swift:16-23`): `device.makeDefaultLibrary()` vem primeiro. Se o app hospedeiro tiver o próprio `default.metallib`, ele é retornado e os shaders do KSPlayer não estarão lá — `makeFunction(name:)` falha em runtime, não em build. Se o StreamHub um dia adicionar shaders próprios, inverter a ordem ou usar sempre `.module`. Além disso `MetalRender.device` é `MTLCreateSystemDefaultDevice()!` (`MetalRender.swift:15`) — crash imediato em ambiente sem Metal.
- **Case-sensitivity de produtos**: `.product(name: "Libass", ...)` comentado em `Package.swift:25` não corresponde ao produto atual `libass` do FFmpegKit 6.1.4 — descomentar sem corrigir o case falha na resolução.
- **Testes de mídia são no-op silenciosos**: `KSAVPlayerTest`/`KSPlayerLayerTest`/`KSMEPlayerTest` buscam `h264.MP4`, `mjpeg.flac`, `hevc.mkv` via `Bundle(for: type(of: self))` (`Tests/KSPlayerTests/KSAVPlayerTest.swift:8-18`), mas `Resources/` só tem `test.m3u` — os `if let` falham e o teste passa sem testar nada. Sob SPM, recursos processados vão para `Bundle.module` do test target, não para `Bundle(for:)`; ao adicionar fixtures, corrija também o lookup.
- **CI cross-builda por SDK, não testa em device**: `build.yml:26-30` usa `swift build --sdk ... -Xswiftc -target x86_64-*-simulator` (não `xcodebuild`); `swift test` roda só em macOS. Warnings de StrictConcurrency e regressões específicas de tvOS passam batido.
- **macCatalyst 14 é imposto pelo FFmpegKit** (commit `ea67e3a` neste fork): baixar `.macCatalyst(.v14)` em `Package.swift:8` quebra a resolução de dependência.
- **Localização declarada mas inexistente**: `defaultLocalization: "en"` (`Package.swift:7`) sem nenhum `.strings` no pacote; `NSLocalizedString` devolve a própria chave — inclusive chaves em chinês (`Sources/KSPlayer/Video/IOSVideoPlayerView.swift:331`).
- **Repo aninhado**: este diretório tem `.git` próprio dentro do repo externo do StreamHub (`/Users/joaoalves/Developer/StreamHub`), sem ser submodule e sem estar no `.gitignore` externo. O `StreamHub.xcodeproj` ainda **não** referencia o pacote (nenhuma ocorrência de KSPlayer no `project.pbxproj`) — a integração via local package está pendente.

## Relação com outros subsistemas

- **MEPlayer (kernel FFmpeg)**: maior consumidor dos binary targets — demux/decode/filter/resample importam `FFmpegKit`, `Libavcodec`, `Libavformat`, `Libavfilter`, `Libavutil`, `Libswresample`, `Libswscale` (`Sources/KSPlayer/MEPlayer/*.swift`). Qualquer upgrade do pin em `Package.swift:46` impacta primeiro esse subsistema (ABI das structs de C atravessa `AVFFmpegExtension.swift`).
- **Metal (render)**: consome o recurso `Shaders.metal` processado pelo manifesto (`Package.swift:29` → `MetalRender.swift:16-23`) e importa `Libavutil` para pixel formats (`PixelBufferProtocol.swift:11`).
- **AVPlayer (kernel AVFoundation + KSOptions/KSPlayerLayer)**: único consumidor do target `DisplayCriteria` (`KSOptions.swift:9-11`, `:354`); `PlayerDefines.swift` hospeda o shim de bundle e o enum `DynamicRange` cujos raw values alimentam a API privada.
- **Subtitle**: hoje 100% Swift (parse SRT/VTT/ASS próprio + `SubtitleDecode` via FFmpeg); é o subsistema que ganharia o produto `libass` se ele for reativado no manifesto (ver Pontos de extensão).
- **Core/SwiftUI/Video/Audio**: apenas código Swift sobre os anteriores; nenhuma dependência direta de binários — no CocoaPods essa estratificação está explícita nos subspecs (`KSPlayer.podspec:20-68`), no SPM é tudo um target único.
- **App StreamHub**: consumidor final previsto (tvOS 13+ coberto por `Package.swift:8`); integração será por referência de pacote local ao diretório `Player/` — ainda não existe no `StreamHub.xcodeproj`.
