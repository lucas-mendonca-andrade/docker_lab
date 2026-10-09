#!/usr/bin/env bash
# docker-lab logs [arquivo.env | nome_do_job] [N]
#
# Lista todas as execuções de um job (cada uma tem o próprio log, com data e hora no
# nome) e mostra as últimas 50 linhas do log da execução N — por padrão, a mais
# recente. Também diz onde ver o log inteiro. O job pode ser indicado pelo arquivo .env
# (lê o JOB_NAME dele) ou direto pelo nome que aparece no 'docker-lab history' — assim
# dá pra ver o log de qualquer execução da lista, inclusive de outros usuários.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# Caminho fixo pro Python REAL do host — ver comentário equivalente em status.sh.
HOST_PYTHON="${DOCKER_LAB_HOST_PYTHON:-/usr/bin/python3}"
HISTORY_LOCK="$HERE/state/history.lock"
HISTORY_FILE="$HERE/state/history.json"
LINHAS=50

ALVO="${1:-job.env}"
ESCOLHA="${2:-}"

if [[ -f "$ALVO" ]]; then
    # Mesmo JOB_NAME que o run.sh usa: lê o .env do jeito que o run.sh lê (source) e
    # troca o {USERNAME} pelo usuário real.
    JOB_NAME="$(set +eu; set -a; source "$ALVO" >/dev/null 2>&1; printf '%s' "${JOB_NAME:-}")"
    if [[ -z "$JOB_NAME" ]]; then
        echo "O arquivo $ALVO não define JOB_NAME." >&2
        exit 1
    fi
    JOB_NAME="${JOB_NAME//\{USERNAME\}/$(id -un)}"
else
    # Não é um arquivo: trata como o nome do job (coluna JOB_NAME do history). Aceita
    # também com ".env" no fim, por engano comum.
    JOB_NAME="${ALVO%.env}"
fi

mapfile -t RUNS < <(flock "$HISTORY_LOCK" "$HOST_PYTHON" "$HERE/lib/reserve.py" \
    --history "$HISTORY_FILE" history-runs --name "$JOB_NAME" --logs-dir "$HERE/logs")
if [[ ${#RUNS[@]} -eq 0 ]]; then
    if [[ -f "$ALVO" ]]; then
        echo "Nenhuma execução de '$JOB_NAME' no histórico ainda."
        exit 0
    fi
    echo "Não achei '$ALVO': não é um arquivo nesta pasta nem um job do 'docker-lab history'." >&2
    echo "Uso: docker-lab logs <arquivo.env | nome_do_job> [número da execução]" >&2
    echo "     (o nome do job é a coluna JOB_NAME do 'docker-lab history')" >&2
    exit 1
fi

echo "Execuções de '$JOB_NAME':"
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
echo "   Ver outra execução:   docker-lab logs $ALVO <N>"
