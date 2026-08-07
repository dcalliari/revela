# Revela

Estacao de culling ao vivo para producao fotografica. A camera fica tethered no
laptop via USB (gphoto2); cada foto disparada aparece em segundos numa tela web,
e as pessoas do estudio acessam pelo celular na mesma rede para classificar por
cor, no estilo darktable. **Classificacao por pessoa**: cada revisor tem o seu
proprio conjunto de cores; a tela do host mostra o consenso.

## Arquitetura

```
Canon (USB) -> gphoto2 --capture-tethered -> pasta observada (inotify)
                                                    |
                    CameraServer (GenServer supervisionado)
                                                    |
                     Ingest: preview web (ImageMagick) + SQLite
                                                    |
        Phoenix PubSub -> push em tempo real -> LiveViews (/ , /host, /tv)
```

- `Revela.Capture` contexto (editoriais + fotos + labels + agregacao); tambem
  publica o estado do visualizador do Host (`broadcast_host_viewer/1`) para a
  superficie `/tv`.
- `Revela.Capture.CameraServer` supervisiona o gphoto2 e o watcher; restaura
  o editorial ativo do banco no boot; monitora espaco livre e para a captura
  entre disparos se o disco cair abaixo do minimo (protege a Canon de travar
  no USB).
- `Revela.Capture.Ingest` gera o preview (namespaced por editorial) e registra
  a foto.
- `RevelaWeb.ReviewLive` (`/`) tela de revisao mobile, botoes de cor,
  navegacao e modo ao vivo (`follow == (idx == last)`). Identidade leve por
  `localStorage`.
- `RevelaWeb.HostLive` (`/host`) QR + URL da LAN, start/stop da captura,
  iniciar/finalizar editorial, estimativa de fotos restantes no disco, quem
  esta online e o consenso de cores; o viewer imersivo reusa os mesmos atalhos
  e espelha `photo_id` / `follow` / `open` para `/tv`.
- `RevelaWeb.TvLive` (`/tv`) modo apresentacao display-only (TV / segundo
  monitor): espelha o Host via PubSub, sem classificacao e sem Presence.
  Fora do ao vivo, apos ~30s de inatividade local volta sozinho a ultima foto
  (contagem "volta ao vivo em Ns"); Host e revisores nao tem esse timeout.
  Override do prazo: `config :revela, :tv_idle_ms` (padrao `30_000`).
- `RevelaWeb.ViewerComponents` visualizador compartilhado: legenda de atalhos
  no rodape, numeros `1`–`5` / `0` nas bolinhas, pinch-zoom no celular
  (hook `PinchZoom`), e `presentation/1` para `/tv`.

As cores no banco usam o mesmo mapeamento do darktable: `0` vermelho,
`1` amarelo, `2` verde, `3` azul, `4` roxo. No teclado/UI as teclas `1`–`5`
escolhem essas cores (`tecla - 1`); `0` limpa a marca.

### Atalhos do visualizador (host e revisao)

Com o viewer aberto (no host, apos abrir uma foto):

| Tecla | Acao |
|---|---|
| `1`–`5` | Marcar cor (vermelho…roxo) |
| `0` / Backspace / Delete | Limpar cor |
| ← / → | Foto anterior / proxima |
| `L` | Ir ao vivo (ultima foto) |
| Escape | Fechar viewer (so no host) |

No celular (mesmo viewer): pinçar amplia com ponto focal sob os dedos; com
zoom > 1 da para arrastar; toque duplo (um dedo) reseta. O zoom permanece
quando so mudam contagens/presence; troca de foto zera.

Estar na foto mais recente **e** estar ao vivo: qualquer caminho que chegue la
(seta, classificacao, `L`) religa o acompanhamento; um disparo novo avanca a
tela. Voltar para tras pausa o ao vivo ate voltar a ultima.

## Rodar

```bash
mix setup            # deps + banco (so na primeira vez)
mix phx.server       # sobe em 0.0.0.0:4000
```

- Host/controle (no laptop): http://localhost:4000/host
- Apresentacao / TV (segunda janela ou monitor): http://localhost:4000/tv
  (tambem ha o link **Abrir modo apresentação (/tv)** no `/host`).
- Revisao (celulares na LAN): a URL/QR que aparece na tela do host.

Se o IP da LAN detectado estiver errado (varias interfaces), fixe manualmente:

```bash
TETHER_LAN_IP=192.168.x.y mix phx.server
```

Piso de espaco livre (padrao 5 GiB). Abaixo disso a captura para sozinha
entre disparos e o `/host` mostra status **espaco cheio**. Para baixar o
piso em testes (bytes):

```bash
TETHER_MIN_FREE_DISK_BYTES=1073741824 mix phx.server
```

Em Arch Linux, instale `erlang-os_mon` (ou use um Erlang via mise que ja
traga `os_mon`). Sem isso o app sobe normalmente, mas o `/host` avisa
**monitoramento de disco indisponivel** e a parada preventiva fica
desligada.

## Checklist da camera (Canon EOS Rebel T6 / 1300D)

1. **Wi-Fi/NFC = Desativar** (com Wi-Fi ligado a T6 desabilita a porta USB).
2. **Desligamento automatico = Desativar** (senao ela dorme no meio da sessao).
3. **Qualidade de imagem = RAW+JPEG** (o preview usa o JPEG, rapido; o RAW fica
   guardado para edicao). Com RAW puro nao ha preview rapido.
4. Cabo USB firme, de preferencia porta direta no chassi, sem hub.

Na tela `/host`, clique em **Conectar câmera**. Dispare na camera: a foto
aparece nos celulares em segundos. O host mostra quanto espaco livre
ainda cabe em fotos (`cabem ~N fotos`, media real do editorial). Se o
disco cair abaixo do piso, a captura para entre disparos (nunca no meio
de uma transferencia PTP): libere espaco e vincule de novo.

## Fluxo de dados

- Um editorial e uma sessao persistente no banco (`editorials`). Fotos levam
  `editorial_id` do editorial ativo na captura. Iniciar ou finalizar um
  editorial **nao** apaga fotos nem classificacoes — so troca qual sessao esta
  ativa. Sem editorial ativo, as telas ficam vazias (fotos com `editorial_id`
  nulo nao entram na UI; nao ha backfill).
- Originais (JPEG + RAW) baixam para pastas unicas
  `editorials/yyyy-mm-dd NOME HHMMSS-uid/` (ou `editorials/_sem-editorial/`
  quando nao ha sessao).
- Previews web ficam em `priv/static/uploads/<editorial_id>/` (ou
  `_sem-editorial/`) e sao servidos em `/uploads/...`.
- Estado (fotos + labels) em SQLite (`*.db`), escopado ao editorial atual.

## Pendente (proxima fase)

- **Export para o darktable**: escrever sidecars `.xmp` ao lado dos RAWs com
  `Xmp.darktable.colorlabels`, para as cores aparecerem ao importar no darktable.
  Como a classificacao e por pessoa, definir a regra de consenso na exportacao
  (revisor lider, uniao, ou maioria).
- Opcional: espelho de video ao vivo (gphoto2 `--capture-movie` + v4l2loopback).
