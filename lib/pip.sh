#!/usr/bin/env bash
# docker-lab pip [--venv pasta] <argumentos do pip>
#
# Roda o pip de um venv criado com 'docker-lab venv' (padrão: ./venv) DENTRO do container:
# esse venv aponta pro Python da imagem, então 'venv/bin/pip' direto no terminal não
# funciona. Ex.: docker-lab pip install -r requirements.txt / install pandas / list.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
source "$HERE/lib/container_tools.sh"

uso() {
    echo "Uso: docker-lab pip [--venv pasta] <comando do pip>   (padrão: venv da pasta atual)" >&2
    echo "  ex.: docker-lab pip install -r requirements.txt" >&2
    echo "       docker-lab pip install pandas" >&2
    echo "       docker-lab pip list" >&2
    echo "       docker-lab pip --venv venv2 install -r requirements.txt" >&2
}

PASTA="venv"
if [[ "${1:-}" == "--venv" ]]; then
    PASTA="${2:-}"
    shift 2 || true
fi
if [[ -z "$PASTA" || $# -eq 0 ]]; then
    uso
    exit 1
fi

PYTHON="$PASTA/bin/python"
if [[ ! -e "$PYTHON" && ! -L "$PYTHON" ]]; then
    echo "Não existe venv em '$PASTA' nesta pasta. Crie com: docker-lab venv" >&2
    exit 1
fi
# Só funciona se o venv usa um Python que a imagem tem (/usr/bin/python3.X), como os
# criados por 'docker-lab venv'. Venv sobre pyenv/conda/Python compilado: recriar.
ALVO="$(readlink -m "$PYTHON")"
if [[ ! "$ALVO" =~ ^/usr/bin/python3\.[0-9]+$ ]]; then
    echo "O venv '$PASTA' não foi criado com 'docker-lab venv' (usa $ALVO)." >&2
    echo "Recrie: mv $PASTA ${PASTA}_antigo && docker-lab venv" >&2
    exit 1
fi

garantir_docker
buildar_imagem

echo "== pip $* (no venv '$PASTA', dentro do container) =="
rodar_no_container "$(printf '%q ' "$PYTHON" -m pip "$@")"
