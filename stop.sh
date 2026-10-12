#!/usr/bin/env bash
# Lista os jobs em execução e os que estão na fila, e deixa você escolher qual parar
# (em execução) ou cancelar (na fila).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HERE/state"
LOCK_FILE="$STATE_DIR/reservations.lock"
STATE_FILE="$STATE_DIR/reservations.json"
# Caminho fixo pro Python REAL do host — ver comentário equivalente em status.sh.
HOST_PYTHON="${DOCKER_LAB_HOST_PYTHON:-/usr/bin/python3}"
mkdir -p "$STATE_DIR"
touch "$LOCK_FILE"

# Duas origens: jobs em execução (reservas) e jobs ainda na fila (lib/queue_db.py).
# Cancelar um job da fila tira ele da fila de vez — se submeter de novo, vai pro fim.
mapfile -t RUNNING < <(flock "$LOCK_FILE" "$HOST_PYTHON" "$HERE/lib/reserve.py" --state "$STATE_FILE" list)
mapfile -t QUEUED < <("$HOST_PYTHON" "$HERE/lib/queue_db.py" queued-list)

KINDS=()
KEYS=()
DESCS=()
for line in ${RUNNING[@]+"${RUNNING[@]}"}; do
    IFS=$'\t' read -r key desc <<< "$line"
    KINDS+=("executando"); KEYS+=("$key"); DESCS+=("$desc — EM EXECUÇÃO")
done
for line in ${QUEUED[@]+"${QUEUED[@]}"}; do
    IFS=$'\t' read -r key desc <<< "$line"
    KINDS+=("fila"); KEYS+=("$key"); DESCS+=("$desc")
done

if [[ ${#KEYS[@]} -eq 0 ]]; then
    echo "Nenhum job em execução ou na fila agora."
    exit 0
fi

echo "Jobs em execução e na fila:"
PS3="Qual você quer parar/cancelar (número, ou 'Sair')? "
select CHOICE in "${DESCS[@]}" "Sair"; do
    if [[ "$CHOICE" == "Sair" || -z "${REPLY:-}" ]]; then
        echo "Nada foi alterado."
        exit 0
    fi
    if ! [[ "$REPLY" =~ ^[0-9]+$ ]] || (( REPLY < 1 || REPLY > ${#KEYS[@]} )); then
        echo "Opção inválida, tente de novo."
        continue
    fi
    KEY="${KEYS[REPLY-1]}"
    if [[ "${KINDS[REPLY-1]}" == "fila" ]]; then
        "$HOST_PYTHON" "$HERE/lib/queue_db.py" cancel --id "$KEY"
        echo "Cancelado: o experimento saiu da fila (se submeter de novo, entra no fim)."
        break
    fi
    JOB_NAME="$KEY"
    echo "Parando 'docker-lab-${JOB_NAME}'..."
    # Marcador lido pelo trap do runner script (ver run.sh) — sem ele o job apareceria
    # no histórico como "erro" (o exit code de um container morto por 'docker stop' é
    # != 0, igual um crash de verdade); com o marcador, aparece como "interrompido".
    touch "$STATE_DIR/${JOB_NAME}.stop_requested"
    docker stop "docker-lab-${JOB_NAME}"
    echo "Parado. A reserva é liberada sozinha em alguns instantes."
    break
done
