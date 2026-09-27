#!/usr/bin/env bash
# Reverte setup_block_direct_python.sh: remove as duas camadas que ele instalou.
# 1. Os symlinks em /usr/local/bin que apontam pro nosso wrapper gerado (nunca mexe num
#    'python3'/'python' que já existisse por outro motivo — esses já eram pulados na
#    instalação).
# 2. O arquivo gerado em /etc/profile.d/ e a referência que foi adicionada em
#    /etc/bash.bashrc (só o bloco entre os marcadores, o resto do arquivo fica intacto).
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Precisa rodar com sudo (ex.: sudo $0)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED="$HERE/host-python-guard/python-blocker.sh"
PROFILE_D_FILE="/etc/profile.d/99-docker_lab-python-guard.sh"
BASHRC_MARKER_BEGIN="# >>> docker_lab python guard >>>"
BASHRC_MARKER_END="# <<< docker_lab python guard <<<"

echo "== Removendo camada 1 (symlinks em /usr/local/bin) =="
NAMES=(python python3 python3.9 python3.10 python3.11 python3.12)
REMOVED=()
for name in "${NAMES[@]}"; do
    target="/usr/local/bin/$name"
    if [[ -L "$target" ]] && [[ "$(readlink -f "$target")" == "$(readlink -f "$GENERATED" 2>/dev/null || echo "$GENERATED")" ]]; then
        rm -f "$target"
        REMOVED+=("$target")
    fi
done
if [[ ${#REMOVED[@]} -eq 0 ]]; then
    echo "Nada pra remover (nenhum symlink nosso encontrado em /usr/local/bin)."
else
    echo "Removido: ${REMOVED[*]}"
fi

echo
echo "== Removendo camada 2 (função de shell) =="
if [[ -f "$PROFILE_D_FILE" ]]; then
    rm -f "$PROFILE_D_FILE"
    echo "Removido: $PROFILE_D_FILE"
else
    echo "$PROFILE_D_FILE já não existia."
fi

if [[ -f /etc/bash.bashrc ]] && grep -qF "$BASHRC_MARKER_BEGIN" /etc/bash.bashrc; then
    sed -i "/^${BASHRC_MARKER_BEGIN//\//\\/}$/,/^${BASHRC_MARKER_END//\//\\/}$/d" /etc/bash.bashrc
    echo "Bloco removido de /etc/bash.bashrc."
else
    echo "/etc/bash.bashrc não tinha o bloco (ou o arquivo não existe), nada a fazer."
fi

echo
echo "Python direto voltou ao normal — sessões JÁ ABERTAS mantêm a função antiga até"
echo "serem recarregadas ou reiniciadas."
