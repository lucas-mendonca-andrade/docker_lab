#!/usr/bin/env bash
# docker-lab logs [arquivo.env] [N]
#
# Lista todas as execuções do job descrito no arquivo .env (cada uma tem o próprio log,
# com data e hora no nome) e mostra as últimas 50 linhas do log da execução N — por
# padrão, a mais recente. Também diz onde ver o log inteiro.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# Caminho fixo pro Python REAL do host — ver comentário equivalente em status.sh.
HOST_PYTHON="${DOCKER_LAB_HOST_PYTHON:-/usr/bin/python3}"
HISTORY_LOCK="$HERE/state/history.lock"
HISTORY_FILE="$HERE/state/history.json"
LINHAS=50

ENV_FILE="${1:-job.env}"
ESCOLHA="${2:-}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Arquivo não encontrado: $ENV_FILE" >&2
    echo "Uso: docker-lab logs <arquivo.env> [número da execução]" >&2
    exit 1
fi

# Mesmo JOB_NAME que o run.sh usa: lê o .env do jeito que o run.sh lê (source) e troca
# o {USERNAME} pelo usuário real.
JOB_NAME="$(set +eu; set -a; source "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${JOB_NAME:-}")"
if [[ -z "$JOB_NAME" ]]; then
    echo "O arquivo $ENV_FILE não define JOB_NAME." >&2
    exit 1
fi
JOB_NAME="${JOB_NAME//\{USERNAME\}/$(id -un)}"

mapfile -t RUNS < <(flock "$HISTORY_LOCK" "$HOST_PYTHON" "$HERE/lib/reserve.py" \
    --history "$HISTORY_FILE" history-runs --name "$JOB_NAME" --logs-dir "$HERE/logs")
if [[ ${#RUNS[@]} -eq 0 ]]; then
    echo "Nenhuma execução de '$JOB_NAME' no histórico ainda."
    exit 0
fi

echo "Execuções de '$JOB_NAME' ($ENV_FILE):"
printf '  %3s  %-20s  %-20s  %-13s %s\n' "N" "INICIO" "FIM" "STATUS" "SUGESTAO"
LOGS=()
for i in "${!RUNS[@]}"; do
    IFS=$'\t' read -r status inicio fim log dica <<< "${RUNS[$i]}"
    LOGS+=("$log")
    printf '  %3d  %-20s  %-20s  %-13s %s\n' "$((i + 1))" "$inicio" "$fim" "$status" "$dica"
done

TOTAL=${#RUNS[@]}
N="${ESCOLHA:-$TOTAL}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 1 || N > TOTAL )); then
    echo >&2
    echo "Número de execução inválido: '$N' (escolha de 1 a $TOTAL)." >&2
    exit 1
fi
LOG="${LOGS[$((N - 1))]}"

echo
if [[ "$LOG" == "-" || ! -f "$LOG" ]]; then
    echo "O log da execução $N não está disponível (antes, cada execução sobrescrevia o log da anterior)."
else
    echo "== Últimas $LINHAS linhas do log da execução $N =="
    tail -n "$LINHAS" "$LOG"
    echo
    echo "== Log completo da execução $N: $LOG"
    echo "   Ver tudo:             less \"$LOG\""
    echo "   Acompanhar ao vivo:   tail -f \"$LOG\""
fi
echo "   Ver outra execução:   docker-lab logs $ENV_FILE <N>"
