#!/usr/bin/env bash
# Uso: docker-lab run [job.env]   (ou direto: ./run.sh <caminho/pro/job.env>)
#
# Convenção: job.env SEMPRE fica na raiz do projeto que você quer executar (não dentro
# do docker_lab, não numa pasta qualquer) — REPO_ROOT é auto-detectado como a pasta
# onde o job.env está, então normalmente você nem precisa preenchê-lo (ver
# job.env.example). Ex.: ~/meu_projeto/job.env → REPO_ROOT vira ~/meu_projeto.
#
# 1. Le a config (job.env).
# 2. Builda a imagem generica deste docker_lab/ (rapido depois da 1a vez, o Docker
#    cacheia as camadas que nao mudaram).
# 3. Reserva os cores/memoria/VRAM de GPU pedidos (sob flock, ver lib/reserve.py) — recusa na
#    hora se ja estiver em uso por outro job, em vez de estourar a maquina. Tudo isso
#    (1-3) acontece NA HORA, na tela — se der erro, voce fica sabendo na hora.
# 4. Sobe o container em SEGUNDO PLANO (nohup, sobrevive a fechar o terminal) e volta o
#    prompt pra voce imediatamente — o log vai pra docker_lab/logs/<job>.log.
# 5. A reserva e liberada sozinha quando o container termina (sucesso, erro, ou
#    docker-lab stop) — nao precisa fazer nada.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Caminho fixo pro Python REAL do host (nao resolvido por PATH) — se
# o bloqueio de Python do setup.sh estiver ativo, 'python3' no PATH vira um aviso em vez do
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
: "${GPU_MEMORY_GB:=0}"
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
elif [[ "$PYTHON_BIN" == "python3" ]]; then
    # Fallback sem venv: o requirements.txt deste diretorio e instalado no 3.12 da
    # imagem (o /usr/bin/python3 dela segue a versao do host, ver Dockerfile).
    CONTAINER_PYTHON_BIN="python3.12"
else
    CONTAINER_PYTHON_BIN="$PYTHON_BIN"
fi

# Python do venv instalado FORA do projeto (pyenv, conda, ~/.local...): o venv guarda um
# link absoluto pra ele, que nao existiria no container (so o REPO_ROOT e montado).
# Segue a cadeia de links do PYTHON_BIN e, pra cada passo fora do projeto e fora dos
# diretorios do sistema (que a imagem ja tem), monta a instalacao inteira (<prefixo> de
# <prefixo>/bin/python) read-only no MESMO caminho. Ex.: ~/.pyenv/versions/3.9.21.
PYTHON_MOUNT_ARGS=()
EXTERNAL_PREFIXES=()
if [[ "$CONTAINER_PYTHON_BIN" == /* ]]; then
    if [[ ! -e "$CONTAINER_PYTHON_BIN" ]]; then
        echo "PYTHON_BIN não encontrado: $CONTAINER_PYTHON_BIN — edite PYTHON_BIN no job.env." >&2
        exit 1
    fi
    link="$CONTAINER_PYTHON_BIN"
    for _ in $(seq 1 20); do
        case "$link" in
            "$REPO_ROOT"/*|/usr/*|/bin/*|/lib/*|/lib64/*) ;;
            *)
                prefix="$(dirname "$(dirname "$link")")"
                if [[ " ${PYTHON_MOUNT_ARGS[*]-} " != *" $prefix:$prefix:ro "* ]]; then
                    PYTHON_MOUNT_ARGS+=(-v "$prefix:$prefix:ro")
                    EXTERNAL_PREFIXES+=("$prefix")
                fi
                ;;
        esac
        [[ -L "$link" ]] || break
        target="$(readlink "$link")"
        [[ "$target" == /* ]] || target="$(dirname "$link")/$target"
        link="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    done
fi

# Versao do /usr/bin/python3 do host (ex. 3.8 no Ubuntu 20.04) — a imagem aponta o
# /usr/bin/python3 dela pra mesma versao, senao venvs criados com 'python3 -m venv'
# quebram dentro do container (ver Dockerfile).
HOST_PYTHON3_VERSION="$(readlink -f /usr/bin/python3 | grep -oE '3\.[0-9]+$' || echo 3.12)"

# Sem acesso ao Docker (usuario fora do grupo docker), o build falharia com um
# "permission denied ... docker.sock" pouco claro — explica o que fazer.
if ! docker version >/dev/null 2>&1; then
    if getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$REAL_USER"; then
        echo "Seu usuário ($REAL_USER) já está no grupo docker, mas esta sessão é anterior a isso." >&2
        echo "Saia e conecte de novo por SSH (ou rode 'newgrp docker') e tente outra vez." >&2
    else
        echo "Seu usuário ($REAL_USER) não tem acesso ao Docker (não está no grupo docker)." >&2
        echo "Peça ao administrador da máquina para rodar:  sudo $HERE/setup.sh" >&2
        echo "(ou: sudo usermod -aG docker $REAL_USER) e depois reconecte o SSH." >&2
    fi
    exit 1
fi

echo "== Buildando imagem ($IMAGE) =="
# Saida do build so aparece se falhar — senao avisos inofensivos (ex. "legacy builder
# is deprecated" do Docker do Ubuntu 20.04, sem buildx) poluiriam todo 'docker-lab run'.
if ! BUILD_OUTPUT=$(docker build -q --build-arg "HOST_PYTHON3_VERSION=$HOST_PYTHON3_VERSION" \
        -t "$IMAGE" "$HERE" 2>&1); then
    echo "$BUILD_OUTPUT" >&2
    echo "== Falha ao buildar a imagem — veja o erro acima. ==" >&2
    exit 1
fi

# Python externo compilado NESTA maquina (ex. ~/.local/python311 num Ubuntu 20.04) usa
# bibliotecas do sistema daqui que a imagem (Ubuntu 24.04) pode nao ter — ex. o _ctypes
# linkado contra libffi.so.7, quando a imagem so tem libffi.so.8 ("ImportError:
# libffi.so.7: cannot open shared object file"). Pra cada prefixo externo, o ldd do
# host lista as libs do interpretador e dos modulos da biblioteca padrao (lib-dynload);
# so as que FALTAM na imagem sao montadas (read-only) em HOSTLIBS_DIR, que entra no
# LD_LIBRARY_PATH — nenhuma lib que a imagem ja tem e substituida.
HOSTLIBS_DIR="/docker_lab_hostlibs"
HOSTLIB_ARGS=()
if [[ ${#EXTERNAL_PREFIXES[@]} -gt 0 ]]; then
    IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$IMAGE" | cut -d: -f2 | cut -c1-12)"
    IMAGE_LIBS_CACHE="$STATE_DIR/image_libs_${IMAGE_ID}.txt"
    if [[ ! -s "$IMAGE_LIBS_CACHE" ]]; then
        docker run --rm --entrypoint ldconfig "$IMAGE" -p \
            | awk '$2 ~ /^\(/ {print $1}' | sort -u > "$IMAGE_LIBS_CACHE.$$"
        mv -f "$IMAGE_LIBS_CACHE.$$" "$IMAGE_LIBS_CACHE"
    fi
    while read -r soname host_path; do
        grep -qxF "$soname" "$IMAGE_LIBS_CACHE" && continue
        HOSTLIB_ARGS+=(-v "$(readlink -f "$host_path"):$HOSTLIBS_DIR/$soname:ro")
    done < <(
        for prefix in "${EXTERNAL_PREFIXES[@]}"; do
            find "$prefix/bin" "$prefix/lib" -maxdepth 3 -type f \
                \( -name 'python3*' -o -name 'libpython*.so*' -o -path '*/lib-dynload/*.so' \) \
                2>/dev/null
        done | xargs -r ldd 2>/dev/null \
            | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}' | sort -u
    )
    if [[ ${#HOSTLIB_ARGS[@]} -gt 0 ]]; then
        HOSTLIB_ARGS+=(-e "LD_LIBRARY_PATH=$HOSTLIBS_DIR")
    fi
fi

GPU_DESC="gpu=$GPU"
if [[ "$GPU" != "none" ]]; then
    GPU_DESC+=" vram=${GPU_MEMORY_GB}GB"
fi
echo "== Reservando recurso para '$JOB_NAME' (cores=$CORES mem=${MEMORY_GB}GB $GPU_DESC) =="
if ! ALLOC_CORES=$(flock "$LOCK_FILE" "$HOST_PYTHON" "$HERE/lib/reserve.py" --state "$STATE_FILE" \
        acquire --name "$JOB_NAME" --cores "$CORES" --mem "$MEMORY_GB" --gpu "$GPU" \
        --gpu-mem "$GPU_MEMORY_GB"); then
    echo "== Não foi possível reservar recurso — veja a mensagem acima. Rode docker-lab status para ver o que está em uso. ==" >&2
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

# GPU: o container so enxerga a GPU pedida (--gpus), e o HAMi-core (libvgpu.so, ver
# Dockerfile), carregado via LD_PRELOAD em todo processo do container, limita a VRAM ao
# que este job reservou (CUDA_DEVICE_MEMORY_LIMIT — alocar alem disso da "CUDA out of
# memory" so neste job). Processamento nao e limitado (ver docstring do reserve.py).
GPU_ARGS=()
if [[ "$GPU" != "none" ]]; then
    GPU_ARGS=(
        --gpus "device=${GPU}"
        -e "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
        -e "LD_PRELOAD=/usr/local/vgpu/libvgpu.so"
        -e "CUDA_DEVICE_MEMORY_LIMIT=${GPU_MEMORY_GB}g"
    )
fi

# Monta a HOME REAL do usuario (mesmo padrao ja usado pro REPO_ROOT: mesmo caminho
# absoluto dentro e fora do container) — nao so o REPO_ROOT. Sem isso, qualquer '~/algo'
# no codigo de um projeto (ex. dataset externo guardado fora do repo) resolveria pra
# dentro do container sem nada montado ali, e bibliotecas que gravam cache em ~/.cache
# (pip, matplotlib, etc.) quebrariam por essa pasta nao existir. Generico: nao exige
# nenhuma config no job.env, nao importa qual projeto/script esteja rodando.
#
# Isso NAO abre acesso a mais nada do que o usuario ja tem fora do container: o processo
# roda com o UID real dele (--user uid:gid, ver abaixo), entao ja teria exatamente esse
# mesmo acesso aos proprios arquivos rodando o script direto no host, sem Docker nenhum.
# Read-write (nao :ro) de proposito, pelo motivo do ~/.cache acima.
#
# HOME aqui e a home REAL (nao mais forcada pra /tmp) — com a home de verdade montada,
# nao ha mais motivo pra forcar outro valor.
HOME_MOUNT_ARGS=(-v "$HOME":"$HOME")

# O container em si roda num script gerado aqui (nao direto neste processo), pra poder
# ser disparado com nohup e sobreviver ao ./run.sh terminar/ao terminal fechar. Esse
# script e quem libera a reserva (trap EXIT), quando o container terminar por qualquer
# motivo — sucesso, erro, ou 'docker stop' via docker-lab stop.
#
# Monta o repo no MESMO caminho absoluto que ele tem no host (nao em /workspace): varios
# venvs de framework deste projeto (ex. frameworks/AutoGluon/venv) tem link simbolico
# ABSOLUTO pro venv RAIZ do repo usando o caminho real do host (nao um generico tipo
# /usr/bin/pythonX) — so resolve se o container enxergar o repo nesse EXATO mesmo
# caminho. Testado e confirmado.
#
# Roda como o USUARIO de quem chamou (--user uid:gid), nao como root: arquivos que o
# script criar no projeto ficam com o dono certo — o aluno consegue apagar/editar os
# proprios resultados sem sudo (poucos usuarios da maquina tem sudo). /etc/passwd e
# /etc/group do host entram read-only pra bibliotecas que consultam o nome do usuario
# (pwd.getpwuid) nao quebrarem; HOME aponta pra home REAL (montada acima, ver
# HOME_MOUNT_ARGS) — nao precisa mais forcar /tmp.
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
    --user "$(id -u):$(id -g)" \\
    -e HOME="$HOME" -e USER="$REAL_USER" -e LOGNAME="$REAL_USER" \\
    -v /etc/passwd:/etc/passwd:ro \\
    -v /etc/group:/etc/group:ro \\
    ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} \\
    ${PYTHON_MOUNT_ARGS[@]+"${PYTHON_MOUNT_ARGS[@]}"} \\
    ${HOSTLIB_ARGS[@]+"${HOSTLIB_ARGS[@]}"} \\
    ${HOME_MOUNT_ARGS[@]+"${HOME_MOUNT_ARGS[@]}"} \\
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
echo "   Pra parar: docker-lab stop"
