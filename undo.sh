#!/usr/bin/env bash
# Desfaz tudo o que o setup.sh configurou na máquina:
# 1. Bloqueio de Python direto (só os symlinks que apontam pro nosso aviso, o arquivo em
#    /etc/profile.d/ e o bloco entre marcadores em /etc/bash.bashrc — o resto fica intacto).
# 2. Limite de potência da GPU (volta ao padrão de fábrica e remove o serviço systemd).
#    O modo persistente (nvidia-smi -pm 1) fica ligado — é inofensivo.
# 3. O comando /usr/local/bin/docker-lab (se for o nosso symlink).
# 4. Permissões compartilhadas de state/ e logs/ (voltam a 755/644, só o dono grava —
#    outros usuários deixam de conseguir rodar jobs).
# Não apaga state/ nem logs/ (histórico e logs continuam lá).
#
# Uso: sudo ./undo.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Precisa rodar com sudo (ex.: sudo $0)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HERE/state"
LOGS_DIR="$HERE/logs"
GENERATED="$HERE/host-python-guard/python-blocker.sh"
PROFILE_D_FILE="/etc/profile.d/99-docker_lab-python-guard.sh"
BASHRC_MARKER_BEGIN="# >>> docker_lab python guard >>>"
BASHRC_MARKER_END="# <<< docker_lab python guard <<<"
POWER_SERVICE="/etc/systemd/system/docker_lab-gpu-power-limit.service"

echo "== 1/4 Removendo bloqueio de Python direto =="
REMOVED=()
for name in python python3 python3.7 python3.8 python3.9 python3.10 python3.11 python3.12 python3.13 python3.14; do
    target="/usr/local/bin/$name"
    if [[ -L "$target" ]] && [[ "$(readlink -f "$target")" == "$(readlink -f "$GENERATED" 2>/dev/null || echo "$GENERATED")" ]]; then
        rm -f "$target"
        REMOVED+=("$target")
    fi
done
echo "Symlinks removidos: ${REMOVED[*]:-nenhum}"
rm -f "$PROFILE_D_FILE" "$GENERATED"
if [[ -f /etc/bash.bashrc ]] && grep -qF "$BASHRC_MARKER_BEGIN" /etc/bash.bashrc; then
    sed -i "/^${BASHRC_MARKER_BEGIN//\//\\/}$/,/^${BASHRC_MARKER_END//\//\\/}$/d" /etc/bash.bashrc
fi
echo "Função de shell removida (sessões já abertas mantêm até serem reabertas)."

echo
echo "== 2/4 Removendo limite de potência da GPU =="
if [[ -f "$POWER_SERVICE" ]]; then
    systemctl disable docker_lab-gpu-power-limit.service >/dev/null 2>&1 || true
    rm -f "$POWER_SERVICE"
    systemctl daemon-reload
    echo "Serviço removido."
fi
bash "$HERE/lib/gpu_power_limit.sh" reset

echo
echo "== 3/4 Removendo comando docker-lab =="
if [[ -L /usr/local/bin/docker-lab && "$(readlink -f /usr/local/bin/docker-lab)" == "$HERE/bin/docker-lab" ]]; then
    rm -f /usr/local/bin/docker-lab
    echo "Removido: /usr/local/bin/docker-lab"
fi

echo
echo "== 4/4 Removendo permissões compartilhadas de state/ e logs/ =="
[[ -d "$STATE_DIR" ]] && chmod 755 "$STATE_DIR" && find "$STATE_DIR" -maxdepth 1 -type f -exec chmod 644 {} +
[[ -d "$LOGS_DIR" ]] && chmod 755 "$LOGS_DIR"
echo "OK"

echo
echo "== Pronto — máquina de volta ao estado anterior ao setup.sh =="
