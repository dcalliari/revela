# Revela no Arch Linux x86_64

Esta é a distribuição nativa suportada nesta etapa. Ela usa uma release Phoenix
(`mix release`) e mantém o estado fora de `/usr/lib/revela`.

## Dependências e pacote

O `PKGBUILD` declara `bash`, `gphoto2`, `imagemagick`, `gvfs`, `openssl`,
`ncurses` e `zlib` como dependências de execução. `gphoto2` traz a integração da
câmera (libgphoto2); `gvfs` fornece o `gio` usado para liberar a interface USB
antes da captura; `openssl`, `ncurses` e `zlib` são as bibliotecas que o ERTS
embutido carrega. Elixir, Erlang e npm são somente dependências de construção: a
release empacota o próprio ERTS (`include_erts: true` em `mix.exs`), então o
pacote não exige `erlang` instalado no sistema.

Construa em um checkout/tag, sem alterar o sistema:

```bash
makepkg --clean --syncdeps
sudo pacman -U revela-0.1.0-1-x86_64.pkg.tar.zst
```

Não use `make install`. O pacote não cria usuário, grupo, regra udev nem habilita
serviço automaticamente. O pacote pode ser validado sem instalar:

```bash
bash -n priv/revela/bin/setup
systemd-analyze verify packaging/revela.service
makepkg --printsrcinfo
```

## Primeiro uso

O operador deve criar uma conta dedicada conforme a política local e garantir o
acesso USB exigido pelas regras udev instaladas com `libgphoto2`. A unidade usa
`User=revela`, `Group=revela` e o grupo `camera`; confirme que esses nomes existem
antes de habilitá-la. Não dê sudo ao usuário do serviço.

Com a câmera conectada, valide tudo sem criar diretórios, alterar configuração,
rodar migration ou capturar:

```bash
sudo revela-setup --dry-run
```

Depois execute conscientemente o preparo, ainda com a câmera conectada:

```bash
sudo revela-setup
```

O assistente exige `gphoto2`, `magick`, `gio`, `openssl` e a release instalada
em `/usr/lib/revela/bin/revela` (sobrescrevível por `REVELA_RELEASE_BIN`),
executa somente
`gphoto2 --auto-detect` para validar a câmera, cria `/var/lib/revela/editorials`,
`/var/lib/revela/uploads` e o banco, gera `/etc/revela/revela.env` com modo 0600
e executa migrations. Ele nunca dispara captura nem apaga arquivos. O segredo é
gerado localmente e não deve ser copiado para o repositório.

Ajuste `PHX_HOST` e `TETHER_LAN_IP` em `/etc/revela/revela.env` se necessário.
Esta primeira distribuição não adiciona autenticação nem TLS: use apenas uma LAN
confiável, conforme a decisão do captain.

## Operação e LAN

```bash
sudo systemctl enable --now revela
systemctl status revela
journalctl -u revela -f
```

Abra `http://localhost:4000/host` no computador e use o QR exibido para os
celulares na mesma LAN. Verifique a presença com `gphoto2 --auto-detect` e o
endpoint abrindo `/host`; não use `gphoto2 --capture-*` para diagnóstico.

## Atualização e rollback

Faça backup de `/var/lib/revela` e `/etc/revela/revela.env`. Pare o serviço antes
da atualização para evitar fotos durante a troca:

```bash
sudo systemctl stop revela
sudo pacman -U revela-NOVO-1-x86_64.pkg.tar.zst
sudo revela-setup
sudo systemctl start revela
```

A instalação preserva os diretórios persistentes e o arquivo de ambiente. Para
rollback, pare o serviço, instale o pacote anterior pelo mesmo comando `pacman
-U`, execute `revela-setup` para conferir migrations e inicie novamente. Restaure
o backup do banco somente se a migration da versão anterior for incompatível;
nunca substitua o banco sem preservar o atual.

## Remoção sem apagar dados

```bash
sudo systemctl disable --now revela
sudo pacman -R revela
```

Isso remove release e unidade, não `/var/lib/revela` nem
`/etc/revela/revela.env`. Remova esses dados manualmente somente depois de um
backup e de uma confirmação explícita:

```bash
sudo rm -rf --one-file-system /var/lib/revela /etc/revela/revela.env
```

O diretório `editorials` contém os originais. O `uploads` contém previews. Ambos
são deliberadamente independentes do artefato instalado.
