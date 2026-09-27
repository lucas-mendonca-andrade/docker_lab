#!/usr/bin/env bash
# Mostra o histórico de execuções (data de início/fim, usuário, job, status).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HERE/state"
HISTORY_LOCK="$STATE_DIR/history.lock"
HISTORY_FILE="$STATE_DIR/history.json"
# Caminho fixo pro Python REAL do host — ver comentário equivalente em status.sh.
HOST_PYTHON="${DOCKER_LAB_HOST_PYTHON:-/usr/bin/python3}"
mkdir -p "$STATE_DIR"
touch "$HISTORY_LOCK"
flock "$HISTORY_LOCK" "$HOST_PYTHON" "$HERE/lib/reserve.py" --history "$HISTORY_FILE" history-list
