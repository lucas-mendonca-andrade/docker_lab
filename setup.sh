#!/usr/bin/env bash
# Configura a máquina do laboratório pra usar o docker_lab. Roda UMA VEZ, com sudo,
# depois de clonar este repo num local fixo do sistema (ex. /opt/docker_lab). Pode ser
# rodado de novo sem problema (ex. depois de um git pull) — cada passo é idempotente.
# Desfazer tudo: sudo ./undo.sh
#
# Faz 3 coisas:
#
# 1. INSTALAÇÃO COMPARTILHADA: libera state/ e logs/ pra QUALQUER usuário Unix da
#    máquina (chmod 777) — todos precisam gravar no MESMO state/reservations.json, senão
#    o teto de 80% não vale entre usuários. Pensado pra uma máquina dedicada ao
#    laboratório, onde toda conta é confiável; cobre automaticamente usuários criados
#    depois. Se a máquina tiver contas não relacionadas ao laboratório, troque o chmod
#    777 por um grupo (groupadd + chgrp + chmod 2775 + usermod -aG por aluno).
#
# 2. LIMITE DE POTÊNCIA DA GPU em 80% do padrão (lib/gpu_power_limit.sh), reaplicado a
#    cada boot por um serviço systemd — GPU no máximo por horas derrubava o acesso
#    remoto e reiniciava a máquina.
#
# 3. BLOQUEIO DE PYTHON DIRETO no host: 'python3 script.py' fora de um container mostra
#    um aviso explicando como usar o run.sh, em vez de executar. Duas camadas, nenhuma
#    toca nos binários reais (/usr/bin/python3.X fica intocado — mexer nele quebraria
#    apt/systemd):
#    a. Symlinks em /usr/local/bin/{python,python3,python3.X} pro aviso gerado a partir
#       de host-python-guard/python-blocker.sh.template (/usr/local/bin vem antes de
#       /usr/bin no PATH).
#    b. Uma FUNÇÃO bash em /etc/profile.d/ + /etc/bash.bashrc — o bash resolve funções
#       antes do PATH, então intercepta mesmo com venv já ativado.
#    É barreira contra esquecimento, não trava de segurança: caminho absoluto
#    (/usr/bin/python3.9 x.py), './script.py' com qualquer shebang e shells
#    não-interativas (cron, .sh chamando python) passam. Não afeta o próprio docker_lab
#    (usa HOST_PYTHON com caminho fixo) nem Python dentro dos containers.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Precisa rodar com sudo (ex.: sudo $0)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HERE/state"
LOGS_DIR="$HERE/logs"
GUARD_DIR="$HERE/host-python-guard"
PROFILE_D_FILE="/etc/profile.d/99-docker_lab-python-guard.sh"
BASHRC_MARKER_BEGIN="# >>> docker_lab python guard >>>"
BASHRC_MARKER_END="# <<< docker_lab python guard <<<"
POWER_SERVICE="/etc/systemd/system/docker_lab-gpu-power-limit.service"

echo "== 1/3 Instalação compartilhada: liberando state/ e logs/ pra todos os usuários =="
mkdir -p "$STATE_DIR" "$LOGS_DIR"
touch "$STATE_DIR/reservations.lock" "$STATE_DIR/history.lock"
# 777 SEM sticky bit: reservations.json/history.json são reescritos via arquivo
# temporário + rename atômico (os.replace), que só exige escrita no DIRETÓRIO; um
# sticky bit bloquearia justamente esse rename entre usuários diferentes.
chmod 777 "$STATE_DIR" "$LOGS_DIR"
chmod 666 "$STATE_DIR/reservations.lock" "$STATE_DIR/history.lock"
[[ -f "$STATE_DIR/reservations.json" ]] && chmod 666 "$STATE_DIR/reservations.json"
[[ -f "$STATE_DIR/history.json" ]] && chmod 666 "$STATE_DIR/history.json"
echo "OK"

echo
echo "== 2/3 Limite de potência da GPU (80%) =="
chmod +x "$HERE/lib/gpu_power_limit.sh"
if command -v nvidia-smi >/dev/null 2>&1; then
    cat > "$POWER_SERVICE" <<EOF
[Unit]
Description=docker_lab: limita a potencia das GPUs a 80% do padrao
After=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HERE/lib/gpu_power_limit.sh apply

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable docker_lab-gpu-power-limit.service >/dev/null 2>&1
    "$HERE/lib/gpu_power_limit.sh" apply
    echo "Serviço $POWER_SERVICE habilitado (reaplica o limite a cada boot)."
else
    echo "nvidia-smi não encontrado — máquina sem GPU NVIDIA, pulando."
fi

echo
echo "== 3/3 Bloqueio de Python direto no host =="
GENERATED="$GUARD_DIR/python-blocker.sh"
sed "s|__REPO_ROOT__|$HERE|g" "$GUARD_DIR/python-blocker.sh.template" > "$GENERATED"
chmod +x "$GENERATED"
INSTALLED=()
for name in python python3 python3.9 python3.10 python3.11 python3.12; do
    target="/usr/local/bin/$name"
    if [[ -e "$target" && ! -L "$target" ]]; then
        echo "AVISO: '$target' já existe e não é um symlink — pulando, não sobrescrevo às cegas." >&2
        continue
    fi
    ln -sf "$GENERATED" "$target"
    INSTALLED+=("$target")
done
echo "Symlinks: ${INSTALLED[*]}"

sed "s|__REPO_ROOT__|$HERE|g" "$GUARD_DIR/python-blocker-function.sh.template" > "$PROFILE_D_FILE"
chmod 644 "$PROFILE_D_FILE"
if ! grep -qF "$BASHRC_MARKER_BEGIN" /etc/bash.bashrc 2>/dev/null; then
    {
        echo "$BASHRC_MARKER_BEGIN"
        echo "[ -r \"$PROFILE_D_FILE\" ] && . \"$PROFILE_D_FILE\""
        echo "$BASHRC_MARKER_END"
    } >> /etc/bash.bashrc
fi
echo "Função de shell: $PROFILE_D_FILE (referenciada em /etc/bash.bashrc)"

echo
echo "== Pronto =="
echo "Qualquer usuário já pode usar: $HERE/run.sh ~/meu_projeto/job.env"
echo "O bloqueio de Python vale pra sessões NOVAS (nova conexão SSH ou 'bash -l')."
echo "Desfazer tudo: sudo $HERE/undo.sh"
