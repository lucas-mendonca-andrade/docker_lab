# Funções comuns de 'docker-lab venv' e 'docker-lab pip' (carregado com source).
#
# Os dois rodam comandos curtos (criar venv, pip) DENTRO do container, como o usuário,
# com a home e a pasta atual montadas no mesmo caminho e com limite de CORES/RAM — o
# venv aponta pro Python da imagem, então só o container consegue usá-lo.

IMAGE="docker-lab-runner:latest"
INSTALL_CORES=2
INSTALL_MEMORY_GB=8

garantir_docker() {
    if ! docker version >/dev/null 2>&1; then
        echo "Seu usuário não tem acesso ao Docker agora (grupo docker). Reconecte o SSH ou" >&2
        echo "peça ao administrador para rodar: sudo $HERE/setup.sh" >&2
        exit 1
    fi
}

buildar_imagem() {
    local host_python3_version build_output
    host_python3_version="$(readlink -f /usr/bin/python3 | grep -oE '3\.[0-9]+$' || echo 3.12)"
    echo "== Buildando imagem ($IMAGE) =="
    if ! build_output=$(docker build -q --build-arg "HOST_PYTHON3_VERSION=$host_python3_version" \
            -t "$IMAGE" "$HERE" 2>&1); then
        echo "$build_output" >&2
        echo "== Falha ao buildar a imagem — veja o erro acima. ==" >&2
        exit 1
    fi
}

# rodar_no_container <comando bash>
rodar_no_container() {
    local tty_args=()
    [[ -t 0 && -t 1 ]] && tty_args=(-it)
    docker run --rm "${tty_args[@]}" \
        --cpus="$INSTALL_CORES" --memory="${INSTALL_MEMORY_GB}g" \
        --user "$(id -u):$(id -g)" \
        -e HOME="$HOME" -e USER="$(id -un)" -e LOGNAME="$(id -un)" \
        -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
        -v "$HOME":"$HOME" -v "$PWD":"$PWD" -w "$PWD" \
        "$IMAGE" \
        bash -c "$1"
}
