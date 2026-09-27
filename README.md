# docker_lab — execução com recurso controlado

Roda um script dentro de um container Docker com CPU, RAM e GPU limitados, pra várias
pessoas usarem a mesma máquina sem uma execução derrubar as outras.

## Convenção central: `job.env` sempre na raiz do projeto que você quer executar

O `docker_lab` normalmente fica instalado **uma única vez**, fora de qualquer projeto
específico (ex. `/opt/amlb_ainet_lab/docker_lab`, numa instalação compartilhada — ver
seção própria abaixo). Cada pessoa cria o **próprio** `job.env`, mas ele **sempre** vai
na raiz do projeto que vai ser executado (ex. `~/meu_projeto/job.env`), nunca dentro do
`docker_lab/` nem em qualquer outra pasta solta.

Essa convenção existe porque `REPO_ROOT` (a pasta que será montada no container) é
**auto-detectado como a pasta onde o `job.env` está** — então, seguindo a convenção,
você nunca precisa preencher `REPO_ROOT` manualmente.

**Por que não cada um com sua própria cópia do `docker_lab/`?** Porque o controle de
80% (ver seção abaixo) só funciona se **todo mundo reservar no mesmo arquivo de
estado**. Com uma cópia por pessoa, cada `state/reservations.json` é independente —
cada um acharia que pode reservar até 80% da máquina sozinho, sem saber que outra
pessoa, com a cópia dela, também está reservando 80% por conta própria.

## Uso (o que você precisa fazer)

1. Copie o exemplo pra raiz do projeto que você quer executar:
   ```bash
   cp <caminho-do-docker_lab>/job.env.example <raiz-do-seu-projeto>/job.env
   ```
2. Edite só os valores do `job.env` — veja os comentários dentro dele. Os pontos que
   mais importam:
   - `SCRIPT`: caminho do `.py` a rodar, relativo à raiz do projeto (onde o `job.env`
     está).
   - `CORES`: **quantidade** de cores que o job pode usar (não IDs específicos) — o
     wrapper escolhe quais cores livres da máquina usar, mesmo que o script faça
     `taskset -c X,Y` fixo internamente (vários `run_all_frameworks_*.py` fazem). Ver
     "Como o wrapper ignora o `taskset` fixo do script" abaixo.
   - `MEMORY_GB`, `GPU`.
   - `JOB_NAME`: deixe o `{USERNAME}` como está — o `run.sh` troca isso pelo seu
     usuário real do sistema (`id -un`) sozinho. Só edite o que vem depois do `_`. Se
     não começar com `{USERNAME}_` (ou já com o seu usuário certo), o `run.sh` recusa
     antes de fazer qualquer coisa, com uma mensagem explicando o formato esperado —
     assim toda reserva/container fica rastreável a uma pessoa de verdade.
3. Rode, passando o caminho do seu `job.env` (obrigatório):
   ```bash
   <caminho-do-docker_lab>/run.sh <raiz-do-seu-projeto>/job.env
   ```
4. Antes de rodar, se quiser ver o que já está em uso: `./status.sh`.

## Rodando em segundo plano, parando e vendo o histórico

`./run.sh` já roda tudo em segundo plano por conta própria — builda a imagem (rápido
depois da 1ª vez), reserva o recurso pedido e dispara o container, mas **não fica preso
no terminal**: ele valida tudo, mostra se deu certo, e volta o prompt pra você na hora,
mesmo que o job em si leve horas. Pode fechar o terminal/desconectar do SSH sem
problema, o job continua rodando.

```
$ ./run.sh
== Buildando imagem (docker-lab-runner:latest) ==
== Reservando recurso para 'lucas_mendonca_run1' (cores=2 mem=16GB gpu=none) ==
== Reservado: cores do host = 4,5 ==
== Rodando em segundo plano: venv/bin/python run_all_frameworks_1.py ==
   Container: docker-lab-lucas_mendonca_run1
   Log:       docker_lab/logs/lucas_mendonca_run1.log   (acompanhe com: tail -f "...")
   Pra parar: ./stop.sh
```

Acompanhe com `tail -f docker_lab/logs/<seu_job_name>.log`.

Se algum `setup.sh` de framework tentar fazer uma pergunta interativa (tipo "confirma
[y/N]?"), o container não tem terminal nenhum associado (nem `-i`/`-t`) e a entrada
vem de `/dev/null` — a pergunta recebe EOF na hora em vez de travar esperando alguém
responder.

**Pra parar** um job (seu ou de qualquer outra pessoa, se precisar), use:

```bash
./stop.sh
```

Ele lista os jobs ativos agora num menu numerado — escolha qual parar. Isso dispara o
mesmo `trap` que libera a reserva e fecha o registro no histórico em caso de erro/fim
normal, então não precisa fazer mais nada depois.

**Pra ver o histórico** de execuções (data de início/fim, usuário, job, status —
`executando`/`executou`/`erro`/`interrompido`):

```bash
./history.sh
```

`interrompido` aparece só se o container correspondente não existir mais e o job ainda
estava marcado como `executando` há mais de ~90s (uma queda abrupta, sem passar pelo
encerramento normal — reinício da máquina, `docker kill` direto, etc.).

## Teto de 80% da máquina, sempre

A máquina nunca fica com mais de **80%** de nenhum recurso reservado — somando **todos
os jobs juntos**, não por job. Vale igual pra cores, memória e GPU. Ex.: numa máquina
de 10 cores, se já tem 8 reservados (80%, o teto), um pedido de mais 2 cores é
recusado na hora — mesmo que esses 2 cores estejam fisicamente livres no momento —
porque passaria do teto. Sempre sobra pelo menos 20% pro SO/SSH/outros processos da
máquina.

Isso não é por job — é o teto agregado da máquina inteira. `./status.sh` mostra quanto
ainda pode ser reservado dentro do teto (`X ainda reserváveis`), não só o que está
fisicamente sem uso.

O `run.sh` recusa na hora, sem enfileirar — não fica esperando sozinho, você tenta de
novo depois (ou pede menos recurso).

**GPU é um caso especial:** como GPU normalmente não dá pra dividir (a máquina deste
laboratório tem 1 só), 80% de 1 arredondaria pra 0 e ninguém jamais conseguiria usá-la.
Por isso o teto nunca fica abaixo de 1 unidade quando o recurso existe — na prática,
com 1 GPU só, ela pode ser reservada inteira por um job de cada vez (o "teto de 80%"
não deixa nada de fora nesse caso, porque não tem como).

## Instalação compartilhada (vários alunos, cada um com o próprio projeto)

Passo a passo pra quem administra a máquina (precisa de sudo, uma vez só):

1. Clone este repositório (`docker_lab`, um projeto próprio, separado de qualquer
   projeto de aluno) num local fixo do sistema, fora da home de qualquer aluno — ex.
   `sudo git clone <url-do-docker_lab> /opt/amlb_ainet_lab/docker_lab`.
2. Rode o setup, uma vez: `sudo /opt/amlb_ainet_lab/docker_lab/setup_shared_install.sh`.
   Isso libera `state/`/`logs/` pra qualquer usuário da máquina ler/escrever (assumindo
   que é uma máquina dedicada ao laboratório, onde toda conta que existe é confiável —
   ver comentários no próprio script se precisar restringir isso a um grupo específico
   em vez de liberar geral). **Não precisa de nenhum passo por aluno** — nem agora, nem
   quando uma conta nova for criada depois; qualquer usuário Unix da máquina já
   funciona direto.
3. Cada aluno cria o **próprio** `job.env` na raiz do projeto dele (ver convenção acima)
   e roda:
   ```bash
   /opt/amlb_ainet_lab/docker_lab/run.sh ~/meu_projeto/job.env
   ```

**Atualizar depois**: `cd /opt/amlb_ainet_lab/docker_lab && git pull` — `state/`/`logs/`
estão no `.gitignore`, então um `git pull` nunca mexe nas permissões já configuradas ali.

## Bloquear execução direta de Python fora do container (opcional)

Pra evitar que alguém esqueça de usar o `run.sh` e rode `python3 script.py` direto no
terminal (sem limite de recurso nenhum), tem um setup opcional que faz isso mostrar um
aviso em vez de executar:

```bash
sudo ./setup_block_direct_python.sh
```

**Duas camadas, nenhuma toca nos binários reais do sistema** (`/usr/bin/python3.X` fica
intocado de propósito — mexer nele quebraria ferramentas do próprio SO, tipo apt/systemd):

1. Symlinks em `/usr/local/bin/{python,python3,python3.9,...}` apontando pra um script
   que só imprime instruções e sai com erro — não executa nada. `/usr/local/bin` vem
   antes de `/usr/bin` no PATH, então isso cobre quem digita `python3 script.py` direto
   (sem venv ativado) e scripts com shebang `#!/usr/bin/env python3` (o `env` busca por
   PATH).
2. Uma **função de shell bash**, instalada em `/etc/profile.d/` + referenciada em
   `/etc/bash.bashrc` — o bash confere funções **antes** de procurar no PATH, então isso
   continua interceptando mesmo com um venv **já ativado** (`source venv/bin/activate`
   só prepende `venv/bin` ao PATH; não afeta uma função que já existia na sessão). É o
   que fecha o buraco do venv que a camada 1 sozinha não cobria.

**⚠️ Mesmo com as duas camadas, não é uma trava de segurança, é uma barreira contra
esquecimento.** O que ainda passa despercebido:
- Caminho absoluto digitado à mão (`/usr/bin/python3.9 script.py`);
- `./script.py` executado direto, com **qualquer** shebang (isso é o kernel executando
  o arquivo, nunca passa pelo bash resolvendo comando nem pelo `env`);
- Shells/scripts **não-interativos** (cron, um `.sh` chamando `python3` por dentro) —
  esses não carregam `/etc/profile.d` por padrão.

Um usuário tecnicamente capaz e decidido a contornar sempre consegue. Isso resolve o
caso comum (esquecimento, inclusive com venv ativado), não um cenário adversarial.

**Não afeta o próprio `docker_lab`**: `run.sh`/`stop.sh`/`status.sh`/`history.sh` chamam
o Python real por um caminho fixo (`/usr/bin/python3`, não resolvido por PATH), então
continuam funcionando normalmente com o bloqueio ativo. Também não afeta Python **dentro**
de um container (cada container tem seu próprio `/usr/bin` isolado, nunca vê o
`/usr/local/bin` do host).

**Reverter**: `sudo ./undo_block_direct_python.sh` (remove só os symlinks que este setup
criou, nunca um `python3` que já existisse por outro motivo).

## Como o wrapper ignora o `taskset` fixo do script

Vários `run_all_frameworks_*.py` deste repo fazem `taskset -c X,Y` fixo, dentro do
próprio código Python, com X,Y hardcoded. Testamos (ver `lib/reserve.py`, docstring)
que o `--cpuset-cpus` do Docker **não renumera** as CPUs pra começar em 0 dentro do
container — o container enxerga os números reais do host. Então, se deixássemos o
`taskset` real rodar dentro do container, esse `-c X,Y` hardcoded ia falhar toda vez
que os cores de verdade reservados pra esse job fossem outros (`Invalid argument`).

Por isso a imagem substitui o `taskset` por um shim (`fake-bin/taskset`) que **ignora**
o `-c X,Y` do script e só roda o comando — a restrição de verdade já vem do
`--cpuset-cpus` que o `run.sh` define, com os cores que o `reserve.py` escolheu como
livres. Resultado: o `CORES` do `job.env` é só uma quantidade, e o wrapper decide quais
cores de verdade usar — nem você nem o script precisam saber quais são.

## Estrutura

- `Dockerfile` / `requirements.txt`: imagem genérica (Ubuntu 24.04 + Python 3.9-3.12 +
  `taskset`), a mesma pra todo mundo. Deixe `requirements.txt` vazio se seu script só
  precisa do que já tem no venv apontado por `PYTHON_BIN` (ver abaixo) — só preencha se
  estiver rodando sem um venv pronto.
- `job.env.example`: modelo de config. **Você não edita mais nada além disso.**
- `run.sh`: builda a imagem, reserva recurso, dispara o container em segundo plano
  (via um script gerado em `state/<job>.runner.sh`, chamado com `nohup`) e volta o
  prompt. Log de cada job em `logs/<job>.log`.
- `stop.sh`: lista os jobs ativos num menu e para o escolhido (`docker stop`).
- `status.sh`: mostra o que está livre e quem está usando o quê agora.
- `history.sh`: mostra o histórico de execuções (início/fim/usuário/status).
- `setup_shared_install.sh`: roda uma vez, com sudo, pra habilitar a instalação
  compartilhada (ver seção acima) — não precisa disso no uso individual/embutido.
- `setup_block_direct_python.sh` / `undo_block_direct_python.sh`: opcional, bloqueia
  (com aviso) quem tentar rodar Python direto fora de um container — ver seção acima.
- `lib/reserve.py`: o controle de quem-usa-o-quê (`state/reservations.json`) e o
  histórico (`state/history.json`), cada um com seu próprio `flock` — chamado sempre
  sob lock pelos scripts acima, nunca direto.

## `PYTHON_BIN`: usando um venv já pronto vs. instalando na imagem

Por padrão o `job.env.example` aponta `PYTHON_BIN` pro venv raiz do seu projeto
(`venv/bin/python`, caminho relativo a `REPO_ROOT`, igual o `SCRIPT`). Como
`REPO_ROOT` inteiro é montado dentro do container (não copiado, e no MESMO caminho
absoluto que ele tem no host — ver seção abaixo sobre por quê), esse venv já existente
é usado direto — a imagem não precisa reinstalar nada.

**Alunos diferentes podem ter venvs em versões diferentes de Python** — isso já é
esperado. Um venv guarda um link simbólico *absoluto* pro Python do sistema de quem o
criou (ex. `/usr/bin/python3.11`), então a imagem já vem com Python **3.9 a 3.12**
instalados nesses mesmos caminhos padrão do Ubuntu (via PPA deadsnakes) — qualquer venv
criado com uma dessas versões funciona sem precisar de nenhum ajuste. Se alguém
precisar de uma versão fora desse intervalo, é só adicionar `python3.X python3.X-venv`
na lista do `Dockerfile` e rebuildar — não muda mais nada.

Se seu script não depender de nenhum venv específico, use `PYTHON_BIN=python3` (a
versão default da imagem, 3.12) e liste as libs que faltarem no `requirements.txt`
deste diretório — elas entram na imagem no próximo `./run.sh` (o Docker rebuilda só a
camada que mudou).

## Por que `REPO_ROOT` é montado no mesmo caminho absoluto do host (não em `/workspace`)

Achado rodando `run_all_frameworks_1.py` de verdade neste repo: o venv de cada
framework do AMLB (ex. `frameworks/AutoGluon/venv`) não é independente — ele tem um
link simbólico **absoluto** apontando pro Python do venv **raiz** do repo, usando o
caminho real completo de onde o repo está no host (ex.
`/home/fulano/.../amlb_ainet/venv/bin/python3`), não um caminho genérico do sistema.
Se o container monta o projeto em `/workspace` (um caminho diferente), esse link não
resolve, e o `setup.sh` de qualquer framework quebra com `No such file or directory`.
Isso não é exclusivo deste repo — qualquer projeto com venvs aninhados apontando uns
pros outros por caminho absoluto teria o mesmo problema.

Por isso o `run.sh` monta `REPO_ROOT` no **mesmo caminho absoluto** que ele já tem no
host (não em `/workspace`) — assim esses links continuam válidos dentro do container.
Isso é automático, você não precisa fazer nada — só saiba que `SCRIPT`/`PYTHON_BIN` no
`job.env` continuam sendo caminhos relativos a `REPO_ROOT`, e o `run.sh` resolve o
resto.

## Limitação conhecida

A reserva de cores/memória/GPU só existe **dentro deste mecanismo** — se alguém rodar
algo fora do `run.sh` (direto, sem Docker), isso não aparece pro `status.sh` e pode
conflitar mesmo assim. Ele só protege quem usa o `run.sh` pra tudo.
