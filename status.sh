#!/usr/bin/env bash
# Mostra quais cores/memoria/GPU estao livres agora, e quem esta usando o que.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HERE/state"
# Caminho fixo pro Python REAL do host (nao resolvido por PATH) — se
# setup_block_direct_python.sh estiver ativo, 'python3' no PATH vira um aviso em vez do
# interpretador de verdade; o docker_lab precisa continuar funcionando mesmo assim.
HOST_PYTHON="${DOCKER_LAB_HOST_PYTHON:-/usr/bin/python3}"
mkdir -p "$STATE_DIR"
touch "$STATE_DIR/reservations.lock"
flock "$STATE_DIR/reservations.lock" "$HOST_PYTHON" "$HERE/lib/reserve.py" \
    --state "$STATE_DIR/reservations.json" status
