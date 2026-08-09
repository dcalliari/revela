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
        Phoenix PubSub -> push em tempo real -> LiveViews (celulares)
```

- `Revela.Capture` contexto (editoriais + fotos + labels + agregacao).
- `Revela.Capture.CameraServer` supervisiona o gphoto2 e o watcher; restaura
  o editorial ativo do banco no boot; auto-arma o tether (editorial ativo +
  camera USB + disco OK, com debounce e latch de stop); monitora espaco livre
  e para a captura entre disparos se o disco cair abaixo do minimo (protege a
  Canon de travar no USB).
- `Revela.Capture.Ingest` gera o preview (namespaced por editorial), registra
  a foto e associa o RAW irmao (`.cr2`/`.cr3`): basename exato ou indice
  gphoto2 N+1 com carimbo ate 2s; se o RAW chegar depois do JPEG,
  `attach_raw/1` preenche `raw_path` sem criar foto nova.
- `Revela.Capture.Export` (+ `mix revela.export_colors`) copia/move arquivos
  classificados para pastas por cor (`vermelho`…`roxo`); ver secao abaixo.
- `RevelaWeb.ReviewLive` (`/`) tela de revisao mobile, botoes de cor,
  navegacao e modo ao vivo (`follow == (idx == last)`). Identidade leve por
  `localStorage`.
- `RevelaWeb.HostLive` (`/host`) QR + URL da LAN, status honesto do tether
  (auto-arm / retomar / stop), iniciar/finalizar editorial, estimativa de
  fotos restantes no disco, quem esta online e o consenso de cores; grade de
  fotos com paginacao (24/pagina) e filtro multi-select pelas bolinhas de cor
  (`Capture.list_photos/1` + stream LiveView); o viewer imersivo reusa os
  mesmos atalhos e a lista completa (nao a pagina filtrada).
  Com `REVELA_DEMO=1`, badge **DEMO** e **Disparar (demo)** / `D` (ver abaixo).
- `RevelaWeb.ViewerComponents` visualizador compartilhado: legenda de atalhos
  no rodape, numeros `1`–`5` / `0` nas bolinhas, e pinch-zoom no celular
  (hook `PinchZoom`).

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

### Modo demo (sem camera fisica)

Para exercitar o fluxo completo (vincular → disparar → ingest → preview →
classificar) sem Canon/gphoto2:

```bash
REVELA_DEMO=1 mix phx.server
```

Com o env ligado:

- Host mostra badge **DEMO**; `camera_present` fica sempre true (detector fake).
- **Nunca** spawna `gphoto2` (mesmo com Canon no USB) — o demo ganha.
- Armar / parar / piso de disco / regras de editorial ativo seguem iguais a
  producao. Desarmar gruda: `D` / botao sem captura armada nao gravam nada.
- Com a captura armada (`status: :running`), o botao **Disparar (demo)** grava
  um JPEG sintetico na pasta observada (naming gphoto2
  `%Y%m%d-%H%M%S-%03n.jpg`; o `%03n` sobe a cada disparo nesta vida do
  processo). A tecla `D`/`d` so liga depois de haver editorial ativo (enquanto
  o formulario de nome esta aberto, use o botao).
- Ingest e o caminho real: inotify → settle → preview → PubSub. Se o watcher
  de arquivos nao sobe (ex. CI sem inotify), o `demo_fire` agenda o settle
  direto — sem mock so de UI.

Sem o env, o comportamento e o de producao. Nao ha toggle no Host — so o env
`REVELA_DEMO=1` / `true` / `yes` (compile-time `config :revela, :demo` nao
ativa o modo; `runtime.exs` sempre redefine a partir do env).

Em Arch Linux, instale `erlang-os_mon` (ou use um Erlang via mise que ja
traga `os_mon`). Sem isso o app sobe normalmente, mas o `/host` avisa
**monitoramento de disco indisponivel**, a parada preventiva fica desligada
e o auto-arm exige clique (**Vincular câmera**).

## Checklist da camera (Canon EOS Rebel T6 / 1300D)

1. **Wi-Fi/NFC = Desativar** (com Wi-Fi ligado a T6 desabilita a porta USB).
2. **Desligamento automatico = Desativar** (senao ela dorme no meio da sessao).
3. **Qualidade de imagem = RAW+JPEG** (o preview usa o JPEG, rapido; o RAW fica
   em `raw_path` para edicao). Em RAW+JPEG o gphoto2 nomeia JPEG N e RAW N+1
   (o carimbo pode diferir ~1s; o ingest tolera ate 2s); JPEG-only deixa
   `raw_path` vazio. Com RAW puro nao ha preview rapido.
4. Cabo USB firme, de preferencia porta direta no chassi, sem hub.

Na tela `/host`, com um editorial ativo e disco OK, o tether arma sozinho
quando a camera aparece no USB (debounce curto; stop explicito gruda ate
retomar). Sem editorial ou com monitoramento de disco indisponivel, use
**Vincular câmera**. Dispare na camera: a foto aparece nos celulares em
segundos. O host mostra quanto espaco livre ainda cabe em fotos
(`cabem ~N fotos`, media real do editorial). Se o disco cair abaixo do piso,
a captura para entre disparos (nunca no meio de uma transferencia PTP);
libere espaco — o tether rearma sozinho quando o espaco voltar.

## Fluxo de dados

- Um editorial e uma sessao persistente no banco (`editorials`). Fotos levam
  `editorial_id` do editorial ativo na captura. Iniciar ou finalizar um
  editorial **nao** apaga fotos nem classificacoes — so troca qual sessao esta
  ativa. Sem editorial ativo, as telas ficam vazias (fotos com `editorial_id`
  nulo nao entram na UI; nao ha backfill de `editorial_id` para sessao
  posterior).
- Originais (JPEG + RAW) baixam para pastas unicas
  `editorials/yyyy-mm-dd NOME HHMMSS-uid/` (ou `editorials/_sem-editorial/`
  quando nao ha sessao). Cada foto guarda `original_path` (JPEG) e, quando
  houver irmao, `raw_path` (unico no banco: o mesmo RAW nao gruda em duas
  fotos).
- Previews web ficam em `priv/static/uploads/<editorial_id>/` (ou
  `_sem-editorial/`) e sao servidos em `/uploads/...`.
- Estado (fotos + labels) em SQLite (`*.db`), escopado ao editorial atual.
- Fotos antigas com `raw_path` vazio (mesmo diretorio ainda com os arquivos):
  `mix revela.backfill_raw_paths` (idempotente; `--dry-run` so resume;
  ambiguidade e pulada com log).

## Export por pastas de cor

Organiza os arquivos classificados em pastas `vermelho` / `amarelo` / `verde` /
`azul` / `roxo` (mesmo vocabulario do darktable). Usa as labels de **um**
revisor (padrao `host`). Preferencia: RAW (`raw_path`); se vazio ou ausente em
disco, copia o JPEG da camera e registra aviso (e cai no preview web se o JPEG
tambem faltar). Fotos sem label desse revisor sao ignoradas.

```bash
# editorial ativo, labels do host, copia para DEST
mix revela.export_colors --dest /caminho/saida

# editorial ja finalizado, so verde e azul, ids explicitos
mix revela.export_colors --dest /caminho/saida \
  --editorial 3 --color verde,azul --ids 10,11,12

# outro revisor; mover em vez de copiar
mix revela.export_colors --dest /caminho/saida \
  --reviewer cliente --mode move
```

Em `--mode move`, RAW/JPEG movidos atualizam `raw_path` / `original_path` no
banco; o preview web **nunca** e movido (quebraria a UI — fica como skip
`:preview_move_refused`).

A API reutilizavel e `Revela.Capture.Export.export/1` (a tela de pos-producao
pode chama-la sobre um intervalo selecionado quando existir).

### Google Drive vs Google Fotos (fase 2)

Sao fluxos distintos — este release para na pasta local:

| Destino | Uso real ate agora | Conteudo tipico |
|---|---|---|
| **Google Fotos** | Album para a cliente/modelo ver | JPEG/preview visualizavel (nao RAW de 24 MB) |
| **Google Drive** | Arquivo/backup bruto | RAW + estrutura de pastas por cor |

Upload automatico fica para depois; o export local ja deixa a pasta pronta para
subir no produto certo.

## Pendente (proxima fase)

- **Export para o darktable**: escrever sidecars `.xmp` ao lado dos RAWs
  (`raw_path`) com `Xmp.darktable.colorlabels`, para as cores aparecerem ao
  importar no darktable. Como a classificacao e por pessoa, definir a regra de
  consenso na exportacao (revisor lider, uniao, ou maioria).
- Opcional: espelho de video ao vivo (gphoto2 `--capture-movie` + v4l2loopback).
- Upload Google Fotos (entrega) / Drive (arquivo) a partir do export por cor.
