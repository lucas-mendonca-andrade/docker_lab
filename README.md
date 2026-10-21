# docker_lab

## Objetivo

- Organizar e limitar múltiplas execuções simultâneas em um servidor de experimentos
  compartilhado (CPU, RAM e VRAM da GPU), com teto da máquina somando todos os jobs
  (80% de CPU e VRAM, 95% de RAM), e cada job limitado ao que pediu.

## Como faz isso?

- **Bloqueio de execução direta de `.py`**: `python3 script.py` no terminal mostra um
  aviso em vez de executar.
- **Limite de potência da GPU em 80%**: evita que a GPU no máximo derrube a máquina.
- **Execução obrigatória em Docker**: todo script roda em um container com recursos
  limitados e reservados, sem derrubar a máquina para os outros usuários.
- **Fila automática com backfill e e-mails**: `docker-lab run` coloca o experimento na
  fila, e ele inicia sozinho quando houver recursos. A ordem é de chegada, mas um
  experimento curto que cabe agora pode passar na frente se não atrasar o primeiro da fila.
  Cada usuário recebe e-mails quando o experimento vira o próximo, inicia, termina ou é
  ultrapassado.

## Como usar

Guia rápido (exemplo completo: projeto Python, `job.env`, rodar, status, parar, histórico): [`docs/guia_rapido.pdf`](docs/guia_rapido.pdf).
Guia completo com exemplos no VS Code: [`docs/guia_docker_lab.pdf`](docs/guia_docker_lab.pdf).
Para validar a instalação (testes de CPU, RAM e GPU): [`examples/`](examples/README.md).

### 1. Instalação (administrador, uma única vez)

```bash
sudo git clone https://github.com/lucas-mendonca-andrade/docker_lab.git /opt/docker_lab
sudo /opt/docker_lab/setup.sh
```

O `setup.sh` libera o uso para todos os usuários, instala o comando `docker-lab`, limita a potência da GPU a 80%,
bloqueia a execução direta de Python e instala o **escalonador da fila** (serviço
`docker_lab-scheduler`). Para desfazer tudo: `sudo /opt/docker_lab/undo.sh`.

**E-mails da fila (uma vez):** use uma conta Gmail com verificação em duas etapas e crie
uma *senha de app* (Conta Google → Segurança → Senhas de app). Depois:

```bash
sudo nano /etc/docker_lab/email.env      # preencha as duas linhas abaixo
#   DOCKERLAB_EMAIL=conta.do.lab@gmail.com
#   DOCKERLAB_EMAIL_SENHA_APP=abcdefghijklmnop
sudo systemctl restart docker_lab-scheduler
```

O arquivo só pode ser lido pelo root. Sem ele preenchido, a fila funciona normalmente,
só não envia e-mails. Logs do escalonador: `journalctl -u docker_lab-scheduler`.

### 2. Preparar um novo script (cada usuário)

Crie o venv do projeto com o Python do docker_lab (versões 3.7 a 3.14) e copie o `job.env`:

```bash
cd ~/meu_projeto
docker-lab venv 3.11 requirements.txt    # cria ./venv com Python 3.11 e instala os pacotes
docker-lab venv                          # ou: menu para escolher a versão
cp /opt/docker_lab/job.env.example job.env
```

O venv é criado dentro do container, então funciona só pelo `docker-lab run` (no
terminal ele aparece quebrado, e isso é esperado). Só existem as versões da imagem: para
outra versão, peça ao administrador.

Edite o `job.env` (ele fica **sempre na raiz do seu projeto**):

| Variável     | Exemplo                        | Significado                              |
|--------------|--------------------------------|------------------------------------------|
| `SCRIPT`     | `meu_script.py`                | Script a rodar, relativo à raiz          |
| `PYTHON_BIN` | `venv/bin/python`              | Python usado (venv do projeto)           |
| `CORES`      | `2`                            | Quantidade de cores                      |
| `MEMORY_GB`  | `16`                           | Memória máxima                           |
| `GPU`        | `none` ou `0`                  | GPU a usar (índice)                      |
| `GPU_MEMORY_GB` | `4`                         | VRAM máxima (só com GPU)                 |
| `JOB_NAME`   | `{USERNAME}_experimento1`      | Nome do job (mantenha o `{USERNAME}_`)   |
| `NOTIFY_EMAIL` | `fulano@gmail.com`           | **Obrigatório.** E-mail para os avisos da fila |
| `ESTIMATED_RUNTIME_HOURS` | `1.5`             | **Obrigatório.** Tempo estimado, em horas |

### 3. Comandos

Na raiz do seu projeto (onde está o `job.env`):

```bash
docker-lab run job.env       # coloca o job na fila (inicia sozinho quando houver recursos)
docker-lab queue             # fila: em execução, aguardando e resumo da máquina
docker-lab status            # recursos em uso e livres
docker-lab logs job.env      # lista as execuções desse job e pergunta qual log abrir (últimas 50 linhas)
docker-lab logs job.env 2    # o log de outra execução (pelo número da lista)
docker-lab logs fulano_treino  # também aceita o nome do job (coluna JOB_NAME do history)
docker-lab stop              # para um job em execução ou cancela um da fila (menu)
docker-lab history           # histórico de execuções de todos os usuários
```

Um projeto pode ter quantos arquivos `.env` precisar, cada um com um `JOB_NAME` diferente.

**Como a fila funciona.** Os experimentos iniciam em ordem de chegada, desde que **todos**
os recursos pedidos (cores, RAM e VRAM) estejam livres. Se o primeiro da fila não cabe,
um experimento de trás pode passar na frente se couber agora **e** se a estimativa
corrigida dele for menor ou igual ao tempo até liberarem os recursos do primeiro. A
**estimativa corrigida** é o `ESTIMATED_RUNTIME_HOURS` mais a sua **margem**: a média dos
seus erros anteriores (tempo real − estimado), com piso de 5 minutos. Só entram na margem
os experimentos que terminaram sozinhos (`executou` ou `erro`). Cancelar um job da fila
com `docker-lab stop` faz ele **perder o lugar**: se submeter de novo, vai para o fim.
Cada execução guarda o próprio log (com data e hora no nome), em `/opt/docker_lab/logs/`.

Status no `history`: `executou`, `erro` (veja o motivo com `docker-lab logs`),
`interrompido` (parado com `docker-lab stop` ou máquina reiniciada), **`sem RAM`** (passou
do `MEMORY_GB`) e **`sem VRAM`** (passou do `GPU_MEMORY_GB`). Nos dois últimos, a coluna
`SUGESTAO` diz o que aumentar no `.env`, e o fim do log explica o motivo.

O job roda com o **seu usuário**: tudo o que ele gravar no projeto é seu, sem precisar
de `sudo`. Se sobraram arquivos com dono `root` de execuções antigas, rode
`docker-lab corrigir-permissoes` na pasta do projeto.
