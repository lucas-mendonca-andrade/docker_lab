#!/usr/bin/env bash
# Limita a potência de cada GPU a 80% do padrão de fábrica (apply) ou volta ao padrão
# (reset). Chamado pelo setup.sh/undo.sh e, a cada boot, pelo serviço systemd
# docker_lab-gpu-power-limit.service (o limite do nvidia-smi -pl se perde ao reiniciar).
#
# Por quê: na máquina do laboratório, GPU a 100% por horas + CPU cheia derrubava o
# acesso remoto e reiniciava a máquina (fonte/temperatura no limite). Diferente de
# VRAM/RAM/CPU, isso não dá pra dividir por job — é um teto físico da GPU inteira,
# imposto pelo próprio driver, que nenhum job consegue contornar.
#
# Uso: gpu_power_limit.sh apply|reset   (precisa de root)
set -euo pipefail

# Mesmo teto de 80% do MAX_UTILIZATION em lib/reserve.py.
POWER_PCT=80
MODE="${1:-apply}"
# O teto é 80% do limite ATUAL da GPU (não do padrão de fábrica): 400W -> 320W,
# 500W -> 400W. A base e o valor aplicado ficam guardados: rodar de novo (setup ou
# boot) não reduz em cascata, e o reset volta pra base.
ORIGINAL_DIR="${DOCKER_LAB_POWER_STATE_DIR:-/var/lib/docker_lab}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi não encontrado — máquina sem GPU NVIDIA, nada a fazer."
    exit 0
fi

if [[ "$MODE" == "apply" ]]; then
    # Modo persistente: sem ele o driver pode descarregar quando nenhum processo usa a
    # GPU e o limite se perde até o próximo boot.
    nvidia-smi -pm 1 >/dev/null
    mkdir -p "$ORIGINAL_DIR"
fi

nvidia-smi --query-gpu=index,power.default_limit,power.min_limit,power.limit --format=csv,noheader,nounits |
while IFS=', ' read -r index default_w min_w current_w; do
    default_w="${default_w%.*}"
    min_w="${min_w%.*}"
    current_w="${current_w%.*}"
    if ! [[ "$default_w" =~ ^[0-9]+$ && "$min_w" =~ ^[0-9]+$ && "$current_w" =~ ^[0-9]+$ ]]; then
        echo "GPU $index: não suporta limite de potência (nvidia-smi informou '$default_w'), pulando."
        continue
    fi
    original_file="$ORIGINAL_DIR/gpu${index}_power_original"

    if [[ "$MODE" == "apply" ]]; then
        # Base = limite ATUAL da GPU. Se o atual é o que nós mesmos aplicamos antes
        # (rerun do setup / boot), mantém a base guardada — senão reduziria em cascata.
        # Se alguém mudou o limite depois (ex. pra 500W), o novo valor vira a base.
        applied_file="$ORIGINAL_DIR/gpu${index}_power_applied"
        if [[ ! -f "$original_file" ]]; then
            if (( current_w == default_w * POWER_PCT / 100 )); then
                # Instalação de antes destes arquivos: o atual já é o nosso 80% do padrão.
                echo "$default_w" > "$original_file"
            else
                echo "$current_w" > "$original_file"
            fi
        elif [[ "$current_w" != "$(cat "$applied_file" 2>/dev/null)" ]]; then
            echo "$current_w" > "$original_file"
        fi
        original_w="$(cat "$original_file")"
        wanted=$(( original_w * POWER_PCT / 100 ))
        target="$wanted"
        (( target < min_w )) && target="$min_w"
        nvidia-smi -i "$index" -pl "$target" >/dev/null
        echo "$target" > "$applied_file"
        if (( target > wanted )); then
            echo "GPU $index: limite de potência = ${target}W — 80% dos ${original_w}W seria ${wanted}W, mas o mínimo que esta GPU aceita é ${min_w}W"
        else
            echo "GPU $index: limite de potência = ${target}W (80% dos ${original_w}W atuais)"
        fi
    else
        target="$default_w"
        [[ -f "$original_file" ]] && target="$(cat "$original_file")"
        nvidia-smi -i "$index" -pl "$target" >/dev/null
        rm -f "$original_file" "$ORIGINAL_DIR/gpu${index}_power_applied"
        echo "GPU $index: limite de potência restaurado para ${target}W"
    fi
done
