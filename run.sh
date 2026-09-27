#!/usr/bin/env bash
# Uso: ./run.sh <caminho/pro/job.env>
#
# Convenção: job.env SEMPRE fica na raiz do projeto que você quer executar (não dentro
# do docker_lab, não numa pasta qualquer) — REPO_ROOT é auto-detectado como a pasta
# onde o job.env está, então normalmente você nem precisa preenchê-lo (ver
# job.env.example). Ex.: ~/meu_projeto/job.env → REPO_ROOT vira ~/meu_projeto.
#
# 1. Le a config (job.env).
# 2. Builda a imagem generica deste docker_lab/ (rapido depois da 1a vez, o Docker
#    cacheia as camadas que nao mudaram).
# 3. Reserva os cores/memoria/gpu pedidos (sob flock, ver lib/reserve.py) — recusa na
#    hora se ja estiver em uso por outro job, em vez de estourar a maquina. Tudo isso
#    (1-3) acontece NA HORA, na tela — se der erro, voce fica sabendo na hora.
# 4. Sobe o container em SEGUNDO PLANO (nohup, sobrevive a fechar o terminal) e volta o
#    prompt pra voce imediatamente — o log vai pra docker_lab/logs/<job>.log.
# 5. A reserva e liberada sozinha quando o container termina (sucesso, erro, ou
#    ./stop.sh) — nao precisa fazer nada.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Caminho fixo pro Python REAL do host (nao resolvido por PATH) — se
# setup_block_direct_python.sh estiver ativo, 'python3' no PATH vira um aviso em vez do
# interpretador de verdade; o docker_lab precisa continuar funcionando mesmo assim.
HOST_PYTHON="${DOCKER_LAB_HOST_PYTHON:-/usr/bin/python3}"
STATE_DIR="$HERE/state"
LOCK_FILE="$STATE_DIR/reservations.lock"
STATE_FILE="$STATE_DIR/reservations.json"
HISTORY_LOCK="$STATE_DIR/history.lock"
HISTORY_FILE="$STATE_DIR/history.json"
LOGS_DIR="$HERE/logs"
IMAGE="docker-lab-runner:latest"

mkdir -p "$STATE_DIR" "$LOGS_DIR"
touch "$LOCK_FILE" "$HISTORY_LOCK"

if [[ -z "${1:-}" ]]; then
    echo "Uso: $0 <caminho/pro/job.env>" >&2
    echo "job.env deve ficar na raiz do projeto que você quer executar — ver job.env.example." >&2
    exit 1
fi
JOB_ENV="$1"
if [[ ! -f "$JOB_ENV" ]]; then
    echo "Config não encontrada: $JOB_ENV" >&2
    echo "Copie $HERE/job.env.example pra <raiz-do-seu-projeto>/job.env e edite." >&2
    exit 1
fi
JOB_ENV_DIR="$(cd "$(dirname "$JOB_ENV")" && pwd)"

# shellcheck disable=SC1090
set -a; source "$JOB_ENV"; set +a

: "${SCRIPT:?defina SCRIPT no job.env}"
: "${CORES:?defina CORES no job.env}"
: "${MEMORY_GB:?defina MEMORY_GB no job.env}"
: "${JOB_NAME:?defina JOB_NAME no job.env}"
: "${GPU:=none}"
: "${PYTHON_BIN:=python3}"

# REPO_ROOT: raiz do projeto de quem esta rodando (onde SCRIPT/PYTHON_BIN vao ser
# resolvidos e o que sera montado no container). Auto-detectado como a pasta onde o
# job.env esta — pela convencao de que job.env SEMPRE fica na raiz do projeto (ver
# job.env.example). So precisa ser definido explicitamente no job.env se, por algum
# motivo, o job.env nao estiver na raiz do projeto de verdade.
: "${REPO_ROOT:=$JOB_ENV_DIR}"
if [[ "$REPO_ROOT" != /* ]]; then
    echo "REPO_ROOT precisa ser um caminho absoluto: '$REPO_ROOT' — edite REPO_ROOT no job.env." >&2
    exit 1
fi
if [[ ! -d "$REPO_ROOT" ]]; then
    echo "REPO_ROOT não existe: '$REPO_ROOT' — edite REPO_ROOT no job.env." >&2
    exit 1
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

# JOB_NAME precisa comecar com o usuario REAL do sistema (id -un, nao $USER — mais
# dificil de forjar) + '_', pra toda reserva/container ficar rastreavel a uma pessoa de
# verdade. O job.env usa o placeholder literal '{USERNAME}' (ver job.env.example) —
# substituimos aqui pelo usuario de quem esta rodando, entao a pessoa nao precisa saber/
# digitar o proprio usuario certinho. A validacao continua depois da substituicao, como
# rede de seguranca pra quem editar JOB_NAME na mao sem usar o placeholder.
REAL_USER="$(id -un)"
JOB_NAME="${JOB_NAME//\{USERNAME\}/$REAL_USER}"
case "$JOB_NAME" in
    "${REAL_USER}_"?*) ;;
    *)
        echo "JOB_NAME inválido: '$JOB_NAME'." >&2
        echo "Precisa começar com '{USERNAME}_' (ou já com o seu usuário real, '${REAL_USER}_')" >&2
        echo "seguido de algo, ex.: {USERNAME}_run_all_frameworks_1 — edite JOB_NAME no job.env." >&2
        exit 1
        ;;
esac

if [[ ! -f "$REPO_ROOT/$SCRIPT" ]]; then
    echo "SCRIPT não encontrado: $REPO_ROOT/$SCRIPT" >&2
    exit 1
fi

# PYTHON_BIN: se vier com "/" no meio (ex. "venv/bin/python") e nao for ja absoluto,
# resolvemos relativo a raiz do repo. Se for um comando puro sem "/" (ex. "python3"),
# deixamos como esta — procurado no PATH de dentro do container, normal.
if [[ "$PYTHON_BIN" == /* ]]; then
    CONTAINER_PYTHON_BIN="$PYTHON_BIN"
elif [[ "$PYTHON_BIN" == */* ]]; then
    CONTAINER_PYTHON_BIN="$REPO_ROOT/$PYTHON_BIN"
else
    CONTAINER_PYTHON_BIN="$PYTHON_BIN"
fi

echo "== Buildando imagem ($IMAGE) =="
docker build -q -t "$IMAGE" "$HERE" >/dev/null

echo "== Reservando recurso para '$JOB_NAME' (cores=$CORES mem=${MEMORY_GB}GB gpu=$GPU) =="
if ! ALLOC_CORES=$(flock "$LOCK_FILE" "$HOST_PYTHON" "$HERE/lib/reserve.py" --state "$STATE_FILE" \
        acquire --name "$JOB_NAME" --cores "$CORES" --mem "$MEMORY_GB" --gpu "$GPU"); then
    echo "== Não foi possível reservar recurso — veja a mensagem acima. Rode ./status.sh para ver o que está em uso. ==" >&2
    exit 1
fi
echo "== Reservado: cores do host = $ALLOC_CORES =="

CONTAINER_NAME="docker-lab-${JOB_NAME}"
LOG_FILE="$LOGS_DIR/${JOB_NAME}.log"
RUNNER_SCRIPT="$STATE_DIR/${JOB_NAME}.runner.sh"
# Marcador que o stop.sh cria ANTES de mandar 'docker stop' — o trap abaixo confere se
# ele existe pra saber se o fim do container foi um stop deliberado (status
# "interrompido") em vez de um erro de verdade (o exit code sozinho nao distingue os
# dois: um 'docker stop' tambem sai com exit code != 0, igual um crash real). Limpo aqui
# tambem por seguranca, caso tenha sobrado de uma execucao anterior com o mesmo nome.
STOP_MARKER="$STATE_DIR/${JOB_NAME}.stop_requested"
rm -f "$STOP_MARKER"

# Registra o inicio no historico (docker_lab/history.sh le isso depois) — so agora,
# porque so a partir daqui o job foi de fato aceito (recurso reservado). Um pedido
# recusado por falta de recurso nunca chega a "executar", entao nao entra no historico.
RUN_ID=$(flock "$HISTORY_LOCK" "$HOST_PYTHON" "$HERE/lib/reserve.py" --history "$HISTORY_FILE" \
    history-start --name "$JOB_NAME" --user "$REAL_USER" --script "$SCRIPT")

GPU_ARGS=()
if [[ "$GPU" != "none" ]]; then
    GPU_ARGS=(--gpus "device=${GPU}")
fi

# O container em si roda num script gerado aqui (nao direto neste processo), pra poder
# ser disparado com nohup e sobreviver ao ./run.sh terminar/ao terminal fechar. Esse
# script e quem libera a reserva (trap EXIT), quando o container terminar por qualquer
# motivo — sucesso, erro, ou 'docker stop' via ./stop.sh.
#
# Monta o repo no MESMO caminho absoluto que ele tem no host (nao em /workspace): varios
# venvs de framework deste projeto (ex. frameworks/AutoGluon/venv) tem link simbolico
# ABSOLUTO pro venv RAIZ do repo usando o caminho real do host (nao um generico tipo
# /usr/bin/pythonX) — so resolve se o container enxergar o repo nesse EXATO mesmo
# caminho. Testado e confirmado.
#
# Sem -i/-t (nunca aloca terminal) e stdin explicitamente vindo de /dev/null: se algum
# setup.sh de framework tentar fazer uma pergunta interativa (ex. "confirma? [y/N]"),
# ele recebe EOF na hora em vez de ficar esperando um terminal que nunca vai responder —
# essencial rodando em background, sem ninguem na frente do terminal.
cat > "$RUNNER_SCRIPT" <<EOF
#!/usr/bin/env bash
trap '
EC=\$?
INTERRUPT_ARGS=()
if [[ -f "$STOP_MARKER" ]]; then
    INTERRUPT_ARGS=(--interrupted)
    rm -f "$STOP_MARKER"
fi
flock "$LOCK_FILE" "$HOST_PYTHON" "$HERE/lib/reserve.py" --state "$STATE_FILE" release --name "$JOB_NAME"
flock "$HISTORY_LOCK" "$HOST_PYTHON" "$HERE/lib/reserve.py" --history "$HISTORY_FILE" history-finish --run-id "$RUN_ID" --exit-code "\$EC" "\${INTERRUPT_ARGS[@]}"
rm -f "$RUNNER_SCRIPT"
' EXIT
docker run --rm \\
    --name "$CONTAINER_NAME" \\
    --cpuset-cpus="$ALLOC_CORES" \\
    --memory="${MEMORY_GB}g" \\
    --memory-swap="${MEMORY_GB}g" \\
    ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} \\
    -v "$REPO_ROOT":"$REPO_ROOT" \\
    -w "$REPO_ROOT" \\
    "$IMAGE" \\
    "$CONTAINER_PYTHON_BIN" "$SCRIPT" \\
    < /dev/null
EOF
chmod +x "$RUNNER_SCRIPT"

# Nota: "cmd & " quase nunca falha em si (so no caso raro de o fork() do SO falhar) —
# erros reais (ex. docker run falhando de verdade) sao capturados pelo `trap` DENTRO do
# $RUNNER_SCRIPT (exit code != 0 -> history "erro"), nao aqui.
nohup "$RUNNER_SCRIPT" > "$LOG_FILE" 2>&1 &
disown

echo "== Rodando em segundo plano: $CONTAINER_PYTHON_BIN $SCRIPT =="
echo "   Container: $CONTAINER_NAME"
echo "   Log:       $LOG_FILE   (acompanhe com: tail -f \"$LOG_FILE\")"
echo "   Pra parar: ./stop.sh"
