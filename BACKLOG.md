# Backlog

Levantado após o primeiro uso em produção (editorial de 2026-08-04, "ludimila
estudio ta", ~2000 fotos). Cada item registra o que foi observado, o estado
atual no código e a proposta. Ainda não é plano de execução: é o material bruto
para priorizar depois.

Cenário real da sessão: o host rodava no notebook, com a tela espelhada na TV
via HDMI para folhear as fotos com a equipe. Os revisores entravam pelo celular
na LAN.

## P0 crítico: perda de dados

### 10. Finalizar o editorial apaga todas as classificações

**Status**: FEITO na `main` em 2026-08-07 via
https://github.com/dcalliari/revela/pull/2 (`20d29a5`).

**Observado** (produção 2026-08-04): depois do editorial, a equipe abriu o host
e passou a classificar as fotos com calma. Ao finalizar o editorial, **as 499
classificações foram apagadas do banco**. Elas só foram recuperadas porque o
WAL do SQLite ainda continha os registros e deu para reconstruí-los frame a
frame.

**Causa (histórico)**: `Capture.clear_all/0` fazia `delete_all` em `Label` e
`Photo` e apagava os previews, chamado por `finish_editorial` e
`start_editorial`. A confirmação tranquilizava sobre os originais e não
mencionava a classificação.

**O que entrou**: editorial virou entidade persistente; start/finish só trocam a
sessão ativa; classificações do editorial anterior ficam salvas; fotos sem
editorial ficam fora da UI idle; no máximo um editorial aberto; restore do
editorial ativo após reinício/deploy.

## P0 crítico: parada da sessão por falta de armazenamento

### 0. O disco encheu, a câmera parou e a máquina travou

**Status**: FEITO na `main` em 2026-08-07 via
https://github.com/dcalliari/revela/pull/3 (`879446a`) para aviso de espaço,
estimativa de disparos e parada preventiva entre disparos. Ainda abertos como
follow-up: descartar JPEG após preview (direção 3) e rotina de gravar fora do
disco de sistema (direção 4).

**Observado**: o armazenamento acabou rápido durante a sessão. Quando esgotou, a
câmera parou de tirar foto e travou por completo, a ponto do botão de desligar
**da própria câmera** não desligar mais.

**Números reais** (medidos em 2026-08-04, depois da sessão):

| | |
|---|---|
| Disco total | 237 GB, com 225 GB usados (97%) |
| Livre agora | 7,5 GB |
| Um editorial | 50 GB, 2168 RAWs, média de 23,4 MB cada |
| Por disparo | ~30 MB (RAW + JPEG da câmera + preview) |

Ou seja: uma sessão como a de 2026-08-04 consome ~60 GB. Não cabe outra igual no
disco atual, e não havia nada no sistema avisando disso.

**Por que a câmera travou** (hipótese principal, a confirmar em teste): o disco
cheio não para a câmera diretamente, ele trava o lado do host no meio de uma
transferência PTP pelo USB. A sequência provável:

1. O disco enche e a escrita do gphoto2 falha ou bloqueia.
2. A transferência PTP em curso nunca termina nem é reconhecida.
3. O firmware da câmera fica preso esperando o host concluir a transação. Nesse
   estado a Canon congela inteira, incluindo o botão liga/desliga, porque o
   controle não volta para o loop que atende os botões.

Isso bate com o sintoma relatado e é comportamento conhecido de DSLR Canon em
captura tethered. **Recuperação na prática: tirar a bateria**, já que o botão não
responde. Vale documentar isso no checklist da câmera no README, porque no meio
de uma produção saber disso economiza minutos de pânico.

O agravante é que **a aplicação não tem nenhuma noção de espaço em disco**. Ela
escreve até quebrar, e quem paga o preço é o equipamento do outro lado do cabo.

**Consequência para o desenho da parada preventiva**: hoje o encerramento manda
`SIGKILL` direto no gphoto2 (`camera_server.ex:470-477`, escolha deliberada
porque ele ignora `SIGTERM`). Matar o processo no meio de uma transferência
deixa a câmera exatamente no estado descrito acima. Então a parada preventiva
precisa acontecer numa janela **entre** disparos, com folga de disco suficiente
para concluir a transferência que estiver em curso, e não simplesmente matar o
processo quando o espaço acabar.

**Direções a avaliar** (ainda não decidido qual combinação vale):

1. **Avisar**: expor espaço livre no status da captura. O `CameraServer` já tem
   o canal pronto (`broadcast_status` e `public_status`), então é só acrescentar
   o dado e mostrar no card de captura do host. Mais útil que "7,5 GB livres" é
   traduzir para o que o fotógrafo entende: "cabem ~250 fotos", calculado a
   partir da média real por disparo. O OTP já resolve a leitura via `:disksup`
   (os_mon), sem precisar chamar `df`.
2. **Parar sozinho antes do fim**: com um piso de segurança (ex.: 5 GB), desligar
   a captura por conta própria, num intervalo entre disparos, e dizer por quê.
   A troca é claramente favorável: parar de forma limpa custa os próximos
   disparos, enquanto deixar chegar no limite custa a câmera travada e uma
   bateria a ser removida no meio da produção. Provavelmente é o item de maior
   valor da lista toda.
3. **Consumir menos**: o JPEG da câmera só serve para gerar o preview web. Depois
   que o preview existe, ele é redundante, porque o RAW é o que se guarda e o
   preview é o que se exibe. Descartá-lo após o ingest economiza uns 20% do
   volume. Vale notar que foi exatamente isso que aconteceu na marra: hoje a
   pasta do editorial tem 2168 RAWs e **nenhum JPEG**, porque eles foram apagados
   para liberar espaço. Transformar isso numa opção explícita e consciente é
   melhor que fazer na emergência.
4. **Gravar fora do disco de sistema**: 50 GB por editorial pede SSD externo, e
   `editorials_dir` já é configurável, então isso é mais questão de rotina de
   produção que de código. Tira a escrita pesada do disco do sistema e dá
   headroom real.

**Ação imediata, independente de código**: com 7,5 GB livres, a próxima sessão
não cabe. Os 50 GB do editorial de 2026-08-04 precisam sair para armazenamento
externo antes da próxima produção.

## P0: atrito direto observado na sessão

### 14. Tether deve armar sozinho ao detectar a câmera

**Status**: FEITO via https://github.com/dcalliari/revela/pull/5 (ship após o freio de disco do item 0).

**Observado / decisão**: na produção o caminho feliz é tether. A presença USB
já era polled (`gphoto2 --auto-detect`), mas a captura só subia no clique
**Conectar câmera** / **Vincular câmera**. Depois de `desired=true`, a
reconexão já era automática — faltava o primeiro armar.

**Contrato aceito (captain, 2026-08-07)**:

1. Auto-start só com **editorial ativo** + **câmera presente** + **disco OK**
   (reusar o piso/`disk_below_minimum?` do item 0; se `disk_awareness` for
   `:unavailable`, não armar automaticamente — exigir clique e manter o aviso).
2. **Stop explícito** (`stop_capture`) deve grudar: não remar sozinho até o
   operador pedir de novo (ou até um “retomar”/start explícito).
3. Debounce curto na borda USB para não thrashar o gphoto2.
4. Sem editorial ativo: não armar no limbo `_sem-editorial`.

**O que entrou**: `CameraServer` auto-arma sob o contrato (debounce,
`operator_stopped`, cooldown após falha de spawn, `ingest_awareness` quando o
watcher falha). Host mostra armando/retomar/degradado; README/AGENTS
documentam o comportamento.

### 1. Atalho de teclado para voltar ao vivo

**Status**: FEITO em 2026-08-07 via
https://github.com/dcalliari/revela/pull/4 (`33346ed`, ship empacotado com
itens 2 e 3).

**Observado**: o fotógrafo folheava as fotos e depois precisava achar o botão
"ir ao vivo" no canto do cabeçalho com o mouse. Esquecia com frequência, e a TV
ficava parada numa foto antiga enquanto a sessão continuava.

**O que entrou**: tecla `L`/`l` mapeada para `go_live` em `HostLive` e
`ReviewLive` (`handle_event("key", ...)`). O botão no cabeçalho do viewer
continua existindo.

### 2. Ao vivo deve ligar sempre que se chega na foto mais recente

**Status**: FEITO em 2026-08-07 via
https://github.com/dcalliari/revela/pull/4 (`33346ed`, ship empacotado com
itens 1 e 3).

**Observado**: o retorno automático ao vivo só acontecia quando se classificava
a penúltima foto. Chegar na última pela seta não religava. Isso "depreciava" a
funcionalidade, porque na prática quase nunca disparava.

**O que entrou**: `follow` passou a ser derivado do índice via `navigate/2` nas
duas LiveViews, com a invariante `follow == (idx == last)`. Estar na foto mais
recente **é** estar ao vivo, por qualquer caminho (seta, classificação, atalho
`L`). Aceito o tradeoff: não existe mais "parado na última foto sem avançar
quando chega um disparo novo".

### 3. Descoberta dos atalhos que já existem

**Status**: FEITO em 2026-08-07 via
https://github.com/dcalliari/revela/pull/4 (`33346ed`, ship empacotado com
itens 1 e 2).

**Observado**: pedido de atalhos `1`-`5` para as cores, no estilo darktable. Os
atalhos já existiam nas duas telas, mas nada na interface indicava.

**O que entrou**: legenda discreta `#shortcuts-legend` no rodapé do viewer
(`1–5` cores, `0` limpar, setas, `L` ao vivo) e número pequeno (`1`–`5` / `0`)
sobre cada bolinha de cor/limpar.

### 4. Zoom instável no celular

**Status**: EM ANDAMENTO (ship PinchZoom: false double-tap, focal point, persist across LiveView).

**Observado**: o pinçar às vezes só dava zoom enquanto o dedo estava na tela, o
zoom só funcionava no centro da imagem, e o comportamento era inconsistente.

**Estado atual**: hook `PinchZoom` em `assets/js/app.js:57-100`. Três causas
distintas, todas confirmadas na leitura do código:

1. **Fim do pinçar é lido como toque duplo** (`app.js:91-97`). Ao soltar dois
   dedos, o `touchend` dispara duas vezes seguidas. O segundo evento cai na
   condição de toque duplo (`now - s.lastTap < 300`) e chama `reset()`. É
   exatamente o sintoma "só dá zoom enquanto o dedo encosta". Precisa distinguir
   fim de gesto multi-toque de toque duplo real.
2. **Zoom ancorado no centro fixo** (`transform-origin: center center` em
   `viewer_components.ex:77`). A escala não segue o ponto médio entre os dedos,
   então só dá para ampliar o centro da foto. Precisa de zoom com ponto focal:
   ajustar `tx`/`ty` para manter sob os dedos o ponto que estava sob eles.
3. **Qualquer re-render zera o zoom** (`app.js:99`, `updated()` chama
   `resetZoom()`). O `updated()` roda a cada mudança de assign, inclusive quando
   outro revisor classifica uma foto e as contagens mudam. Explica o "às vezes
   funcionava". Resetar deve depender da foto ter trocado de verdade, não de ter
   havido re-render.

### 5. Paginação e filtro por cor na grade do host

**Observado**: com ~2000 fotos, a grade do host mostra só as 24 mais recentes.
Não havia como chegar nas primeiras fotos do editorial. Uma paginação temporária
foi feita e desfeita na sessão de 2026-08-04, justamente para pensar numa
organização melhor.

**Estado atual**: `host_live.ex:209` corta em `@recent 24` fixas. As bolinhas de
cor no cabeçalho (`host_live.ex:353`) são só legenda, não clicáveis.

**Proposta**: paginação de verdade mais filtro por cor clicando nas bolinhas
(alternar cada cor, combinando com a paginação). Considerar
[LiveView streams](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#stream/4)
para não carregar as 2000 fotos na memória do socket a cada render, e filtrar no
banco em vez de em memória. Ver também o item 8.

## P1: melhorias de fluxo

### 6. Modo apresentação em janela separada

**Observado**: para mostrar as fotos na TV, a tela do notebook foi espelhada via
HDMI. Enquanto isso o notebook fica preso: não dá para usar o host para outra
coisa sem que apareça na TV.

**Ideia original descartada**: entrar no sistema como um revisor chamado "tv".
Traz identidade e classificação que não fazem sentido para um telão.

**Proposta**: rota nova (ex.: `/tv`) que abre em aba ou janela separada,
arrastável para o monitor da TV em tela cheia. Só exibe, não classifica, não
entra no Presence. Segue o ao vivo por padrão e aceita ser controlada pelo host
via PubSub, de modo que folhear no host mude o que está na TV enquanto o
notebook continua livre para outras coisas.

**Ponto de decisão**: a TV espelha o que o host está vendo, ou tem navegação
própria? A primeira é mais simples e cobre o caso relatado.

### 7. Retorno automático ao vivo por inatividade

**Ideia levantada**: se a pessoa para de folhear e esquece de voltar ao vivo,
retornar sozinho à foto mais recente depois de ~10s.

**Análise**: os itens 1 e 2 já cobrem boa parte do esquecimento relatado, e
custam muito menos. O timeout tem risco real de atrapalhar: quem voltou de
propósito para corrigir uma classificação seria puxado para longe no meio da
decisão, e 10s é pouco para olhar uma foto. Onde ele é claramente certo é no
modo apresentação do item 6, que é só exibição e onde ninguém está decidindo
nada.

**Proposta**: implementar o timeout **apenas** no modo apresentação. Reavaliar
para o host depois que 1 e 2 estiverem em uso, e se for adiante, usar janela
maior (~30s), reiniciada a cada interação e com indicação visível de que vai
voltar. Nos celulares dos revisores, não aplicar.

### 8. `raw_path` vazio para todas as fotos

**Status**: EM ANDAMENTO (ship JPEG↔RAW sibling match + backfill).

**Observado**: ao separar os `.cr2` das fotos marcadas de azul, o campo
`raw_path` estava vazio nas 2025 fotos do editorial. Os RAWs tiveram que ser
localizados manualmente, casando índice de sequência e horário do nome.

**Causa**: `find_raw_sibling` (`lib/revela/capture/ingest.ex:79`) procura um RAW
com o mesmo nome do JPEG. Mas em RAW+JPEG a câmera grava os dois com índices
sequenciais diferentes: o JPEG sai com índice ímpar e o `.cr2` com o índice
seguinte (ex.: `20260804-133708-027.jpg` e `20260804-133708-028.cr2`). O carimbo
de tempo também pode variar em 1s, porque o arquivo maior demora mais para
transferir.

**Impacto**: qualquer funcionalidade que dependa do RAW fica inviável, incluindo
o export de sidecars `.xmp` para o darktable que já está previsto no README.
Vale corrigir antes desse export, e fazer um backfill dos registros existentes.

### 11. Tela de pós-produção

**Observado**: terminado o editorial, a equipe quis rever e classificar as fotos
com calma pelo host. A tela do host é feita para acompanhar a captura ao vivo,
não para isso: mostra só as 24 mais recentes. Foi preciso improvisar uma
paginação temporária no código durante a própria sessão para conseguir chegar
nas primeiras fotos.

**Proposta**: uma tela própria de pós-produção, separada da de captura ao vivo,
com navegação por todo o conjunto, filtro por cor e classificação. É o destino
natural do item 5 (paginação e filtro), e evita continuar espremendo esse uso
dentro da tela de captura.

**Relacionado**: depende do item 10. Não faz sentido investir numa tela de
revisão pós-editorial enquanto finalizar o editorial apaga o resultado dela.

#### O índice de contato validou a ideia na prática

Em 2026-08-05 foi gerado um índice HTML estático fora da aplicação: miniaturas
de 320px extraídas do preview embutido no RAW (2160 fotos, 15 KB cada, 30 MB no
total, cerca de 1 minuto de processamento), numa grade agrupada pelas pastas de
cor, com filtro por nome de arquivo, posição e nome sob cada foto. Fica em
`_indice/index.html` dentro da pasta do editorial. Os scripts que geraram isso
servem de base para a implementação.

Ele resolveu o problema real de imediato, e o **jeito como foi usado** diz mais
sobre o que a tela precisa ter do que qualquer suposição:

1. A grade serviu para bater o olho e identificar visualmente o grupo desejado.
2. Dois prints da tela foram mandados direto para a modelo. O índice virou
   superfície de comunicação, não só de trabalho.
3. A seleção de verdade foi feita **memorizando o nome do arquivo da primeira e
   da última foto do grupo** e depois procurando esses dois nomes no gerenciador
   de arquivos.
4. As fotos foram subidas para um álbum do Google Fotos.

**O que isso ensina**: o passo 3 é o gargalo, e é manual porque o índice só
mostra, não seleciona. Repare que a unidade natural de seleção não é a foto
solta nem a cor: é o **intervalo contíguo** ("da foto X até a Y"), porque um
editorial é uma sequência de blocos por pose, roupa e luz. Uma tela de
pós-produção deveria permitir selecionar um intervalo direto na grade (clicar na
primeira, shift-clicar na última) e agir sobre ele, em vez de obrigar a
transcrever nomes de arquivo para outro programa.

O passo 2 sugere um segundo recurso barato e de valor alto: exportar a própria
grade como imagem ou link compartilhável, já que hoje isso é feito com print de
tela.

#### Mover pelo índice, e o que o desfazer ensinou

Em 2026-08-05 o índice ganhou botões para mover a foto direto para
`vermelho (descartadas)` ou `amarelo (backstage)`, com um servidor local
mínimo, porque uma página em `file://` não mexe em arquivos. Em uma passada
foram classificadas 100 fotos, o que confirma que agir de dentro da grade é o
fluxo certo.

**O desfazer existia e não foi encontrado.** Ele aparecia só num aviso
temporário no rodapé, que some em 4 segundos, enquanto a atenção estava na
grade. Duas fotos acabaram sendo devolvidas à mão pelo gerenciador de arquivos,
e o manifesto ficou dessincronizado por isso.

É o mesmo padrão do item 3, e já é a segunda ocorrência: **funcionalidade que
existe, funciona, e não é usada porque nada a anuncia.** Vale tratar como
critério recorrente de projeto, não como detalhe de cada tela. No caso do
desfazer, a lição concreta é que ele não pode viver apenas num aviso efêmero:
precisa de lugar fixo na interface, atalho (`Ctrl+Z`) e, idealmente, um
histórico visível da sessão.

### 12. Organização por cor e entrega no Google

**Observado**: a organização das fotos por cor foi feita à mão, fora da
aplicação, cruzando as classificações recuperadas com os arquivos RAW em disco.
Depois, a entrega para a modelo passou por um álbum do Google Fotos, montado
também à mão a partir de um intervalo de arquivos localizado pelo índice.

**Proposta**: exportar a organização a partir do próprio sistema, movendo ou
copiando os RAWs para pastas por cor. Adiante, integração direta com o Google
para eliminar a etapa manual de upload.

**Atenção ao destino**: Drive e Fotos são produtos diferentes, com APIs e
semânticas diferentes, e o uso real até agora foi o **Fotos** (álbum para a
modelo ver), não o Drive (arquivo bruto). Vale decidir qual dos dois é o alvo,
ou se são dois fluxos distintos: entrega para a cliente (Fotos, imagens
visualizáveis) e backup/arquivo (Drive, RAW). Enviar RAW de 24 MB para o Google
Fotos provavelmente não é o que se quer.

**Depende do item 11**: só faz sentido exportar depois de existir uma forma de
selecionar o intervalo dentro do sistema. Hoje a seleção mora na cabeça de quem
memorizou o nome da primeira e da última foto.

**Nota de implementação**: o casamento entre foto e RAW não é trivial e vale
guardar o aprendizado. O gphoto2 nomeia com `%Y%m%d-%H%M%S-%03n.%C`, e em
RAW+JPEG cada disparo gera dois arquivos: o JPEG com índice N e o RAW com N+1.
O índice reinicia a cada restart do gphoto2, então ele não é único no editorial:
é preciso casar por índice **mais** proximidade de horário (o RAW pode sair 1s
depois, porque o arquivo é maior). Resolver o item 8 (`raw_path` vazio) elimina
essa reconstrução por completo.

### 13. Fotos capturadas com a câmera desconectada

**Status**: EM ANDAMENTO (ship import pasta → editorial ativo).

**Observado**: quando o disco encheu, a saída foi desconectar a câmera e seguir
fotografando no cartão microSD, para não interromper o editorial. Essas fotos
depois foram juntadas à pasta na mão. Elas nunca passaram pelo Revela, então não
têm classificação nenhuma e têm nomenclatura própria da câmera (`IMG_*.CR2`, 142
arquivos no editorial de 2026-08-04).

**Proposta**: importar uma pasta de fotos avulsas para o editorial atual,
gerando preview e registro como se tivessem chegado pela captura. Isso
transforma o contorno de emergência num caminho suportado, útil sempre que a
captura tethered cair no meio da produção.

**Contexto relacionado**: conectar a câmera direto na TV por HDMI foi testado
como alternativa para ter o feed, mas a experiência é bem inferior à do Revela,
o que reforça o valor do item 6.

## P2: exploração, ainda sem forma definida

### 9. Operar sem depender de LAN/WiFi

Ideia ainda não concreta: hoje tudo depende de os celulares e o notebook
estarem na mesma rede, o que amarra a sessão à infraestrutura do local. Vale
levantar as opções (notebook como ponto de acesso próprio, por exemplo) e o que
cada uma custa em setup no dia da produção, antes de decidir qualquer coisa.

---

Ver também a seção "Pendente (proxima fase)" do [README](README.md), que já
registra o export de sidecars `.xmp` para o darktable (dependente do item 8) e o
espelho de vídeo ao vivo.
