# docker_lab

## Objetivo

- Organizar e limitar múltiplas execuções simultâneas em um servidor de experimentos
  compartilhado (CPU, RAM e GPU, com teto de 80% da máquina).

## Como faz isso?

- **Bloqueio de execução direta de `.py`**: `python3 script.py` no terminal mostra um
  aviso em vez de executar.
- **Execução obrigatória em Docker**: todo script roda em um container com recursos
  limitados e reservados, sem derrubar a máquina para os outros usuários.

## Como usar

### 1. Instalação (administrador, uma única vez)

```bash
sudo git clone https://github.com/lucas-mendonca-andrade/docker_lab.git /opt/docker_lab
sudo /opt/docker_lab/setup_shared_install.sh
sudo /opt/docker_lab/setup_block_direct_python.sh   # bloqueio de python direto
```

Para desfazer o bloqueio: `sudo /opt/docker_lab/undo_block_direct_python.sh`.

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
| `GPU`        | `none` ou `0`                  | GPU a reservar                           |
| `JOB_NAME`   | `{USERNAME}_experimento1`      | Nome do job (mantenha o `{USERNAME}_`)   |

### 3. Comandos

**Ver status** (recursos em uso e livres):
```bash
/opt/docker_lab/status.sh
```

**Executar** (roda em segundo plano; log em `/opt/docker_lab/logs/<JOB_NAME>.log`):
```bash
/opt/docker_lab/run.sh ~/meu_projeto/job.env
```

**Parar** (menu com os jobs ativos):
```bash
/opt/docker_lab/stop.sh
```

**Ver histórico** de execuções:
```bash
/opt/docker_lab/history.sh
```
