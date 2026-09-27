#!/usr/bin/env bash
# Lista os jobs ativos agora e deixa você escolher qual parar.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HERE/state"
LOCK_FILE="$STATE_DIR/reservations.lock"
STATE_FILE="$STATE_DIR/reservations.json"
# Caminho fixo pro Python REAL do host — ver comentário equivalente em status.sh.
HOST_PYTHON="${DOCKER_LAB_HOST_PYTHON:-/usr/bin/python3}"
mkdir -p "$STATE_DIR"
touch "$LOCK_FILE"

mapfile -t LINES < <(flock "$LOCK_FILE" "$HOST_PYTHON" "$HERE/lib/reserve.py" --state "$STATE_FILE" list)

if [[ ${#LINES[@]} -eq 0 ]]; then
    echo "Nenhum job ativo agora."
    exit 0
fi

NAMES=()
DESCS=()
while IFS=$'\t' read -r name desc; do
    NAMES+=("$name")
    DESCS+=("$desc")
done < <(printf '%s\n' "${LINES[@]}")

echo "Jobs ativos:"
PS3="Qual você quer parar (número, ou 'Cancelar')? "
select CHOICE in "${DESCS[@]}" "Cancelar"; do
    if [[ "$CHOICE" == "Cancelar" || -z "${REPLY:-}" ]]; then
        echo "Cancelado."
        exit 0
    fi
    if (( REPLY < 1 || REPLY > ${#NAMES[@]} )); then
        echo "Opção inválida, tente de novo."
        continue
    fi
    JOB_NAME="${NAMES[REPLY-1]}"
    echo "Parando 'docker-lab-${JOB_NAME}'..."
    # Marcador lido pelo trap do runner script (ver run.sh) — sem ele o job apareceria
    # no histórico como "erro" (o exit code de um container morto por 'docker stop' é
    # != 0, igual um crash de verdade); com o marcador, aparece como "interrompido".
    touch "$STATE_DIR/${JOB_NAME}.stop_requested"
    docker stop "docker-lab-${JOB_NAME}"
    echo "Parado. A reserva é liberada sozinha em alguns instantes (o run.sh cuida disso)."
    break
done
