# 01 — Visão geral e build

Lumen é um fork GPL do KSPlayer (upstream `kingslay/KSPlayer`): player de vídeo Swift para iOS/tvOS/macOS/macCatalyst com três kernels de reprodução — `KSAVPlayer` (AVFoundation), `KSMEPlayer` (FFmpeg + Metal) e `ProAVPlayer` (remux para HLS fMP4 + AVFoundation). Este documento cobre exclusivamente como o pacote se monta: manifesto SPM, binários FFmpeg/libass, target ObjC `DisplayCriteria`, targets, plataformas e CI. Todos os paths são relativos à raiz do repo.

## Responsabilidade

- Declarar o pacote SPM `Lumen` com um único produto library (`Package.swift`), dois targets compiláveis (`Lumen` Swift e `DisplayCriteria` ObjC) e um test target `LumenTests`.
- Trazer todo o FFmpeg, libass e dependências nativas como **binary targets pré-compilados**, através do pacote **vendorizado** `FFmpegKit/` que vive dentro deste repo (`.package(path: "FFmpegKit")`).
- Expor a API privada `AVDisplayCriteria(refreshRate:videoDynamicRange:)` para match de refresh rate/HDR na Apple TV, via o target ObjC `DisplayCriteria` (`Sources/DisplayCriteria/include/AVDisplayCriteriaKS.h`).

## Tipos principais

Num subsistema de build, os "tipos" são manifestos, targets e artefatos:

| Tipo/artefato | Arquivo | Papel |
|---|---|---|
| `Package` (manifesto SPM) | `Package.swift` | swift-tools 5.9; plataformas macOS 10.15, macCatalyst 14, iOS 13, tvOS 13; produto único `.library(name: "Lumen")` (`.dynamic` comentado) |
| Target `Lumen` | `Package.swift` | Todo o código Swift em `Sources/Lumen/{Audio,AVPlayer,Cache,Core,MEPlayer,Metal,Subtitle,SwiftUI,Video}`; depende do produto `FFmpegKit` e de `DisplayCriteria`; recurso `.process("Metal/Shaders.metal")`; flag `.enableExperimentalFeature("StrictConcurrency")` |
| Target `DisplayCriteria` | `Package.swift` | Target ObjC por convenção de path (`Sources/DisplayCriteria/`); `DisplayCriteria.m` é **vazio** (existe só para o SPM aceitar o target); header público `include/AVDisplayCriteriaKS.h` |
| Categoria `AVDisplayCriteria` | `Sources/DisplayCriteria/include/AVDisplayCriteriaKS.h` | Declara `videoDynamicRange`, `refreshRate` e `initWithRefreshRate:videoDynamicRange:` (API privada da Apple), guardado por `__has_include(<AVFoundation/AVDisplayCriteria.h>)` |
| Test target `LumenTests` | `Package.swift` | Arquivos XCTest em `Tests/LumenTests/`; recurso processado `Tests/LumenTests/Resources/test.m3u` |
| Pacote vendorizado `FFmpegKit` | `FFmpegKit/Package.swift` | Manifesto local (não é dependência remota). Declara o target wrapper `FFmpegKit` (shims C em `FFmpegKit/Sources/FFmpegKit/include/*.h`) e ~24 `binaryTarget` com `url:`+`checksum:` apontando para release assets do projeto **MPVKit** |
| Binários FFmpeg | releases `mpvkit/MPVKit` `0.41.0-n8.1.2` | `Libavcodec`, `Libavdevice`, `Libavfilter`, `Libavformat`, `Libavutil`, `Libswresample`, `Libswscale` — builds **GPL** do **FFmpeg 8.1.2** |
| Binários libass/fontes | releases `mpvkit/libass-build` `0.17.5` | `libass`, `libfreetype`, `libfribidi`, `libharfbuzz`, `Libunibreak` — linkados por serem dependência do target `FFmpegKit`, embora este fork não tenha `import libass` em `Sources/` |
| Demais binários | releases `mpvkit/*` | `MoltenVK`, `libshaderc_combined`, `libplacebo`, `lcms2` (render/tonemap), `libdav1d` (AV1), `Libuavs3d` (AVS3), **`Libdovi`** (Dolby Vision), `libsmbclient` (SMB), `gmp`+`nettle`+`hogweed`+`gnutls` (TLS) |
| Shim `Bundle.module` | `Sources/Lumen/AVPlayer/PlayerDefines.swift` | Sob `#if !SWIFT_PACKAGE` resolve um bundle `KSPlayer_KSPlayer.bundle` — resquício de CocoaPods herdado do upstream; irrelevante na build SPM |
| CI | `.github/workflows/build.yml` | `swift build` para macOS e cross-build para simuladores iOS/tvOS via `--sdk` + `-Xswiftc -target` (alvos `arm64-apple-{ios,tvos}13.0-simulator`); `swift test -v` |
| Metadados | `.spi.yml` (`documentation_targets: [Lumen]`), `.swiftformat` (`--swiftversion 5.7`, `--ifdef noindent`), `.gitattributes` (`*.h linguist-language=Swift`) | Swift Package Index, formatação e stats do GitHub |

## Fluxo de dados

Montagem via SPM:

1. `swift build`/Xcode lê `Package.swift`; `package.dependencies += [.package(path: "FFmpegKit")]` é apendado após a declaração. Como a dependência é **por path**, não há revisão remota a resolver nem `Package.resolved` versionado no repo.
2. O SPM lê `FFmpegKit/Package.swift` e **baixa** os `.xcframework.zip` declarados em cada `binaryTarget` (`url:` + `checksum:`), validando o checksum e descompactando no diretório de artefatos derivados. Não há compilação de C — os binários vêm prontos.
3. O target `Lumen` compila com o produto `FFmpegKit` no import path. Como cada `binaryTarget` é um módulo Clang próprio, os fontes importam módulos individuais transitivamente: `import FFmpegKit`/`Libavcodec`/`Libavfilter`/`Libavformat` em `Sources/Lumen/MEPlayer/MEPlayerItem.swift`, `Libswresample`/`Libswscale` em `Sources/Lumen/MEPlayer/Resample.swift`, `Libavutil` em `Sources/Lumen/Metal/PixelBufferProtocol.swift`, etc.
4. `DisplayCriteria` compila como módulo ObjC (headers de `include/` viram umbrella automático). É importado sob `#if os(tvOS) || os(xrOS)` em `Sources/Lumen/AVPlayer/KSOptions.swift` — na prática, só o branch tvOS é construído.
5. Linkagem: o target `FFmpegKit` carrega `linkerSettings` com os frameworks de sistema (AudioToolbox, VideoToolbox, Metal, Security…) e libs (`bz2`, `c++`, `expat`, `iconv`, `resolv`, `xml2`, `z`) — o app consumidor herda tudo transitivamente, sem configurar nada.
6. Recursos: `.process("Metal/Shaders.metal")` faz o SPM compilar o shader para `default.metallib` dentro do bundle sintetizado do target. Em runtime, `MetalRender.library` (`Sources/Lumen/Metal/MetalRender.swift`) tenta `device.makeDefaultLibrary()` (metallib do app) e cai para `makeDefaultLibrary(bundle: .module)`.
7. Runtime tvOS: `KSOptions.updateVideo(refreshRate:isDovi:formatDescription:)` (`KSOptions.swift`) constrói `AVDisplayCriteria(refreshRate:videoDynamicRange:)` com o raw value de `DynamicRange` (`PlayerDefines.swift`: sdr=0, hdr10=2, hlg=3, dolbyVision=5) e seta `avDisplayManager.preferredDisplayCriteria`; `playerLayerDeinit` zera o critério ao sair.

## Pontos de extensão

- **Atualizar o FFmpeg**: edite as `url:`/`checksum:` dos `binaryTarget` em `FFmpegKit/Package.swift` para outra release do MPVKit. Como o pacote é local, a troca é atômica e não depende de publicar tag em repositório externo. O `import Foundation` em `Package.swift` é vestígio do upstream, que fazia troca condicional de dependência via `FileManager`.
- **Usar libass de verdade (ASS com efeitos completos)**: descomente a linha `.product(name: "Libass", package: "FFmpegKit")` em `Package.swift`, mas o nome do produto declarado em `FFmpegKit/Package.swift` é `libass` (minúsculo, agregando `libfreetype`+`libfribidi`+`libharfbuzz`+`Libunibreak`+`libass`) — nomes de produto SPM são case-sensitive. Os binários já são linkados hoje via produto `FFmpegKit`; o que falta é declarar o produto para poder dar `import libass` no target `Lumen` (o consumo seria no subsistema Subtitle: `Sources/Lumen/MEPlayer/SubtitleDecode.swift` / `Sources/Lumen/Subtitle/`).
- **Novo shader**: adicione a função em `Sources/Lumen/Metal/Shaders.metal` (único recurso do target); é carregada por nome via `MetalRender.library.makeFunction(name:)` — nada a mudar no manifesto.
- **Nova plataforma/deployment target**: o array `platforms:` em `Package.swift` é o único ponto de configuração.
- **Comportamento de DisplayCriteria**: `KSOptions.updateVideo` e `playerLayerDeinit` são `open` — uma subclasse de `KSOptions` no app pode customizar a política de match (ex.: permitir Dolby Vision em vez do downgrade para HDR10) sem tocar no fork.
- **Testes**: fixtures processadas em `Tests/LumenTests/Resources`; para reativar os testes de mídia, adicione `h264.MP4`, `mjpeg.flac`, `hevc.mkv` lá (ver Pegadinhas sobre o lookup).

## Pegadinhas

- **API privada da Apple**: `AVDisplayCriteriaKS.h` declara init privado de `AVDisplayCriteria`. É motivo de rejeição em review da App Store. O init virou API pública só no tvOS 17; o header dá acesso desde tvOS 13.
- **`DisplayCriteria.m` vazio é obrigatório**: `Sources/DisplayCriteria/DisplayCriteria.m` contém uma linha em branco. Sem pelo menos um arquivo-fonte o SPM rejeita o target. Não deletar "por limpeza".
- **`FFmpegKit/Package.swift` ainda declara `.visionOS(.v1)`** nas plataformas, e vários `linkerSettings` referenciam `.visionOS`. O pacote raiz **não** declara visionOS — a plataforma não é suportada nem construída pelo CI. A declaração no manifesto vendorizado é inócua, mas não deve ser lida como suporte.
- **Guards `#if os(xrOS)` residuais**: existem ~45 ocorrências espalhadas por `Sources/Lumen/` (`KSVideoPlayerView.swift`, `KSSubtitle.swift`, `IOSVideoPlayerView.swift`, `AirPlayView.swift`, `ProAVPlayer.swift`…). Boa parte está na forma `#if os(tvOS) || os(xrOS)`, ou seja, o branch continua ativo para tvOS; os `#if os(xrOS)` isolados são **código inerte** nos targets construídos hoje.
- **Download de binários no build**: os `binaryTarget` usam `url:`+`checksum:`, então a primeira resolução baixa centenas de MB de xcframeworks. CI e caches precisam levar isso em conta; um checksum divergente falha o build com erro de integridade, não de compilação.
- **`StrictConcurrency` só no target principal**: código novo em `Sources/Lumen` compila com checagem estrita de Sendable/isolamento (warnings hoje, erros no Swift 6); `LumenTests` não tem a flag. Tipos de dados/parsing novos devem ser `nonisolated`/`Sendable` desde o início.
- **Ordem de fallback do metallib** (`MetalRender.swift`): `device.makeDefaultLibrary()` vem primeiro. Se o app hospedeiro tiver o próprio `default.metallib`, ele é retornado e os shaders do Lumen não estarão lá — `makeFunction(name:)` falha em runtime, não em build. Um app com shaders próprios precisa inverter a ordem ou usar sempre `.module`.
- **Testes de mídia são no-op silenciosos**: `KSAVPlayerTest`/`KSPlayerLayerTest`/`KSMEPlayerTest` buscam `h264.MP4`, `mjpeg.flac`, `hevc.mkv` via `Bundle(for: type(of: self))`, mas `Resources/` só tem `test.m3u` — os `if let` falham e o teste passa sem testar nada. Sob SPM, recursos processados vão para `Bundle.module` do test target, não para `Bundle(for:)`; ao adicionar fixtures, corrija também o lookup.
- **CI cross-builda por SDK, não testa em device**: `build.yml` usa `swift build --sdk ... -Xswiftc -target arm64-apple-*-simulator` (não `xcodebuild`); `swift test` roda só em macOS. Warnings de StrictConcurrency e regressões específicas de tvOS passam batido.
- **macCatalyst 14 é imposto pelo FFmpegKit**: baixar `.macCatalyst(.v14)` em `Package.swift` quebra a resolução de dependência contra os xcframeworks.
- **Localização declarada mas inexistente**: `defaultLocalization: "en"` sem nenhum `.strings` no pacote; `NSLocalizedString` devolve a própria chave — inclusive chaves em chinês herdadas do upstream (`Sources/Lumen/Video/IOSVideoPlayerView.swift`).
- **Nome de bundle legado**: `PlayerDefines.swift` ainda resolve `KSPlayer_KSPlayer.bundle` no branch `#if !SWIFT_PACKAGE`. Não há mais podspec no repo; esse caminho é morto sob SPM e só importaria numa reintegração com CocoaPods.

## Relação com outros subsistemas

- **MEPlayer (kernel FFmpeg)**: maior consumidor dos binary targets — demux/decode/filter/resample importam `FFmpegKit`, `Libavcodec`, `Libavformat`, `Libavfilter`, `Libavutil`, `Libswresample`, `Libswscale` (`Sources/Lumen/MEPlayer/*.swift`). Qualquer upgrade de FFmpeg impacta primeiro esse subsistema (a ABI das structs de C atravessa `AVFFmpegExtension.swift`).
- **ProAV (kernel de remux)**: usa o muxer `mp4` do `Libavformat` e o encoder FLAC do `Libavcodec`; consome os metadados Dolby Vision que o FFmpeg expõe como side data (`AV_PKT_DATA_DOVI_CONF`) e, na conversão de perfil 7, importa **`Libdovi` diretamente** (`import Libdovi` em `DOVIPacketRewriter.swift`, API `dovi_*` de RPU) — é o único ponto do fork que chama esse binário.
- **Metal (render)**: consome o recurso `Shaders.metal` processado pelo manifesto e importa `Libavutil` para pixel formats (`PixelBufferProtocol.swift`).
- **AVPlayer (kernel AVFoundation + KSOptions/KSPlayerLayer)**: único consumidor do target `DisplayCriteria`; `PlayerDefines.swift` hospeda o shim de bundle e o enum `DynamicRange` cujos raw values alimentam a API privada.
- **Subtitle**: hoje 100% Swift (parse SRT/VTT/ASS próprio + `SubtitleDecode` via FFmpeg + `EmbeddedFontRegistry` via CoreText); é o subsistema que ganharia o produto `libass` se ele for reativado no manifesto (ver Pontos de extensão).
- **Cache**: `Sources/Lumen/Cache/` usa só Foundation + CryptoKit; o acoplamento com FFmpeg é via `AVIOContext` customizado, sem binários adicionais.
- **Core/SwiftUI/Video/Audio**: apenas código Swift sobre os anteriores; nenhuma dependência direta de binários — no SPM é tudo um target único.
- **App consumidor**: integra por referência de pacote local ao diretório deste repo, ou por dependência de pacote remota apontando para o produto `Lumen`.
