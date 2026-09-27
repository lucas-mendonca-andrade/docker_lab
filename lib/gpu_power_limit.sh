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

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi não encontrado — máquina sem GPU NVIDIA, nada a fazer."
    exit 0
fi

if [[ "$MODE" == "apply" ]]; then
    # Modo persistente: sem ele o driver pode descarregar quando nenhum processo usa a
    # GPU e o limite se perde até o próximo boot.
    nvidia-smi -pm 1 >/dev/null
fi

nvidia-smi --query-gpu=index,power.default_limit,power.min_limit --format=csv,noheader,nounits |
while IFS=', ' read -r index default_w min_w; do
    default_w="${default_w%.*}"
    min_w="${min_w%.*}"
    if ! [[ "$default_w" =~ ^[0-9]+$ && "$min_w" =~ ^[0-9]+$ ]]; then
        echo "GPU $index: não suporta limite de potência (nvidia-smi informou '$default_w'), pulando."
        continue
    fi
    if [[ "$MODE" == "apply" ]]; then
        target=$(( default_w * POWER_PCT / 100 ))
        (( target < min_w )) && target="$min_w"
    else
        target="$default_w"
    fi
    nvidia-smi -i "$index" -pl "$target" >/dev/null
    echo "GPU $index: limite de potência = ${target}W (padrão de fábrica ${default_w}W)"
done
