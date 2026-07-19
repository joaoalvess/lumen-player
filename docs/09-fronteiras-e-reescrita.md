# 09 — Fronteiras e plano de reescrita

O núcleo de reprodução herdado do KSPlayer (demux, decode, sincronização A/V, render Metal) será **reescrito** — não portado. O objetivo é duplo: ganhar performance e fluidez com um desenho pensado do zero, e eliminar a dependência de código GPL de terceiros.

Isso vai acontecer **depois** de um bloco de features que ainda está por vir. Este documento existe para que essas features não gerem retrabalho: enquanto o núcleo antigo ainda estiver de pé, código novo não deve aprofundar o acoplamento com o que vai sair.

## O que sai e o que fica

| Área | Destino | Observação |
|---|---|---|
| `MEPlayer/` — demux, filas, decoders, resample, saídas de áudio, sync A/V | 🔴 **Reescrever** | O núcleo herdado; ~8k linhas |
| `Metal/` — `MetalRender`, shaders, modelos de projeção | 🔴 **Reescrever** | Pipeline de render |
| `AVPlayer/KSPlayerLayer`, `KSAVPlayer` | 🟡 **Redesenhar mantendo o contrato** | A orquestração muda; a interface pública não deve mudar |
| `MEPlayer/ProAV*` — engine de remux, servidor HTTP, transcoder, playlists | 🟢 **Fica** | Autoria própria |
| `Cache/` + `DiskCacheAVIOContext` + `DiskCacheResourceLoader` | 🟢 **Fica** | Autoria própria |
| `FFmpegKit/` — shims e binários do FFmpeg 8 | 🟢 **Fica** | Autoria própria |
| `SwiftUI/TVOS/` — a interface tvOS | 🟢 **Fica** | Autoria própria, já desacoplada |
| `Subtitle/` — parsers, `EmbeddedFontRegistry` | 🟢 **Fica** | Salvo a troca do parser ASS por libass, prevista no roadmap |

## O contrato que sobrevive

Estes são os símbolos que a reescrita se compromete a preservar. Código novo pode depender deles à vontade:

- **`MediaPlayerProtocol`** — a interface que todo engine implementa. É a fronteira principal.
- **`KSPlayerLayer`** — orquestração: estados, seleção de engine, fallback, remote commands, PiP.
- **`KSOptions`** — configuração.
- **`KSVideoPlayerView`** e **`KSVideoPlayer.Coordinator`** — a porta de entrada SwiftUI.
- **`TVPlayerMetadata`** — metadados do painel de informação.

A fronteira não é aspiracional: hoje a UI tvOS referencia `playerLayer` 18 vezes e **nenhum** tipo concreto de engine (`KSMEPlayer`, `MEPlayerItem`, `KSAVPlayer`, `MetalPlayView`). O app consumidor usa 7 símbolos do módulo, e o único acoplamento a engine concreto são as duas linhas de registro de `KSOptions.firstPlayerType`/`secondPlayerType`.

## Regras para código novo

1. **Prefira as camadas que ficam.** Se a feature couber em `ProAV*`, `Cache/`, `Subtitle/` ou `SwiftUI/TVOS/`, ela nasce imune à reescrita.
2. **Precisou do núcleo? Vá pelo protocolo.** Depender de `MediaPlayerProtocol` e `KSPlayerLayer` é seguro; depender de `MEPlayerItem`, dos decoders, das filas ou de `MetalRender` é dívida.
3. **Não adicione API pública nova aos internals.** Se a feature precisa de algo que só o núcleo sabe, o caminho é declarar um novo requisito em `MediaPlayerProtocol` — assim a reescrita já nasce sabendo o que precisa entregar.
4. **A UI nunca fala com engine concreto.** É o que hoje torna `SwiftUI/TVOS/` portável; manter assim.
5. **Teste o contrato, não o interior.** Testes contra protocolos e lógica pura sobrevivem à reescrita; testes contra internals do núcleo serão descartados junto com ele.
6. **Atalho inevitável entra na lista abaixo.** Melhor dívida registrada que dívida esquecida — a lista vira checklist na hora da reescrita.

## Dívida conhecida

Acoplamentos aceitos de propósito, a revisitar quando o núcleo for substituído:

- `StreamHubApp.swift` (app consumidor) referencia `ProAVPlayer.self` e `KSMEPlayer.self` para registrar a ordem de engines. É o acoplamento mínimo inevitável de quem escolhe o engine; se a reescrita mudar os nomes, são duas linhas.
