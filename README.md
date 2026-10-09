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

## Como usar

Guia rápido (exemplo completo: projeto Python, `job.env`, rodar, status, parar, histórico): [`docs/guia_rapido.pdf`](docs/guia_rapido.pdf).
Guia completo com exemplos no VS Code: [`docs/guia_docker_lab.pdf`](docs/guia_docker_lab.pdf).
Para validar a instalação (testes de CPU, RAM e GPU): [`examples/`](examples/README.md).

### 1. Instalação (administrador, uma única vez)

```bash
sudo git clone https://github.com/lucas-mendonca-andrade/docker_lab.git /opt/docker_lab
sudo /opt/docker_lab/setup.sh
```

O `setup.sh` libera o uso para todos os usuários, instala o comando `docker-lab`, limita a potência da GPU a 80% e
bloqueia a execução direta de Python. Para desfazer tudo: `sudo /opt/docker_lab/undo.sh`.

### 2. Preparar um novo script (cada usuário)

```bash
cp /opt/docker_lab/job.env.example ~/meu_projeto/job.env
```

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

### 3. Comandos

Na raiz do seu projeto (onde está o `job.env`):

```bash
docker-lab run job.env       # executa o job em segundo plano (padrão: job.env)
docker-lab status            # recursos em uso e livres
docker-lab logs job.env      # lista as execuções desse job e pergunta qual log abrir (últimas 50 linhas)
docker-lab logs job.env 2    # o log de outra execução (pelo número da lista)
docker-lab logs fulano_treino  # também aceita o nome do job (coluna JOB_NAME do history)
docker-lab stop              # para um job ativo (menu)
docker-lab history           # histórico de execuções de todos os usuários
```

Um projeto pode ter quantos arquivos `.env` precisar, cada um com um `JOB_NAME` diferente.
Cada execução guarda o próprio log (com data e hora no nome), em `/opt/docker_lab/logs/`.

Status no `history`: `executou`, `erro` (veja o motivo com `docker-lab logs`),
`interrompido` (parado com `docker-lab stop` ou máquina reiniciada), **`sem RAM`** (passou
do `MEMORY_GB`) e **`sem VRAM`** (passou do `GPU_MEMORY_GB`). Nos dois últimos, a coluna
`SUGESTAO` diz o que aumentar no `.env`, e o fim do log explica o motivo.

O job roda com o **seu usuário**: tudo o que ele gravar no projeto é seu, sem precisar
de `sudo`. Se sobraram arquivos com dono `root` de execuções antigas, rode
`docker-lab corrigir-permissoes` na pasta do projeto.
