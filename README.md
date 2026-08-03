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

- `Revela.Capture` contexto (fotos + labels + agregacao).
- `Revela.Capture.CameraServer` supervisiona o gphoto2 e o watcher.
- `Revela.Capture.Ingest` gera o preview e registra a foto.
- `RevelaWeb.ReviewLive` (`/`) tela de revisao mobile, botoes de cor,
  voltar, modo ao vivo. Identidade leve por `localStorage`.
- `RevelaWeb.HostLive` (`/host`) QR + URL da LAN, start/stop da captura,
  quem esta online e o consenso de cores.

As cores usam o mesmo mapeamento do darktable: `0` vermelho, `1` amarelo,
`2` verde, `3` azul, `4` roxo.

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

## Checklist da camera (Canon EOS Rebel T6 / 1300D)

1. **Wi-Fi/NFC = Desativar** (com Wi-Fi ligado a T6 desabilita a porta USB).
2. **Desligamento automatico = Desativar** (senao ela dorme no meio da sessao).
3. **Qualidade de imagem = RAW+JPEG** (o preview usa o JPEG, rapido; o RAW fica
   guardado para edicao). Com RAW puro nao ha preview rapido.
4. Cabo USB firme, de preferencia porta direta no chassi, sem hub.

Na tela `/host`, clique em **Conectar câmera**. Dispare na camera: a foto
aparece nos celulares em segundos.

## Fluxo de dados

- Originais (JPEG + RAW) baixam para `editorials/yyyy-mm-dd NOME/`.
- Previews web ficam em `priv/static/uploads/` e sao servidos em `/uploads/...`.
- Estado (fotos + labels) em SQLite (`*.db`).

## Pendente (proxima fase)

- **Export para o darktable**: escrever sidecars `.xmp` ao lado dos RAWs com
  `Xmp.darktable.colorlabels`, para as cores aparecerem ao importar no darktable.
  Como a classificacao e por pessoa, definir a regra de consenso na exportacao
  (revisor lider, uniao, ou maioria).
- Opcional: espelho de video ao vivo (gphoto2 `--capture-movie` + v4l2loopback).
