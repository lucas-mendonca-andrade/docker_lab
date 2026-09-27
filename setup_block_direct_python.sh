#!/usr/bin/env bash
# Roda UMA VEZ, com sudo, na máquina do laboratório (depois de setup_shared_install.sh).
# Faz com que digitar 'python3'/'python' DIRETO no terminal (fora de um container do
# docker_lab) mostre um aviso explicando como rodar via ./run.sh, em vez de executar o
# script — pra ninguém esquecer de passar pelo mecanismo de controle de recurso.
#
# DUAS CAMADAS, ambas instaladas por este script (nenhuma toca nos binários reais do
# sistema — /usr/bin/python3.X fica intocado de propósito, pra não arriscar quebrar
# ferramentas do próprio SO que dependem dele, tipo apt/systemd):
#
# 1. Symlinks em /usr/local/bin/{python,python3,python3.9,...} apontando pro wrapper
#    gerado (host-python-guard/python-blocker.sh). /usr/local/bin vem ANTES de
#    /usr/bin no PATH em Debian/Ubuntu — intercepta 'python3 script.py' digitado
#    direto (sem venv ativado) e scripts com shebang '#!/usr/bin/env python3' (o 'env'
#    busca por PATH).
#
# 2. Uma FUNÇÃO de shell bash (python/python3/python3.X), instalada em
#    /etc/profile.d/ + referenciada em /etc/bash.bashrc — o bash resolve funções ANTES
#    de procurar no PATH, então isso continua interceptando mesmo com um venv JÁ
#    ATIVADO (que só prepende venv/bin ao PATH; não afeta funções já definidas na
#    sessão). Fecha o principal buraco que a camada 1 sozinha não cobria.
#
# LIMITAÇÕES que restam mesmo com as duas camadas (documentadas também no README):
# caminho absoluto digitado à mão (ex. /usr/bin/python3.9 script.py), um script
# chamado via './script.py' com QUALQUER shebang (isso é o kernel executando o
# arquivo direto — nunca passa pelo bash resolvendo um comando nem pelo 'env'), e
# scripts/shells NÃO-interativos (cron, 'bash algumacoisa.sh' chamando python por
# dentro) — esses não carregam /etc/profile.d por padrão. É uma barreira contra
# esquecimento, não uma trava de segurança contra alguém decidido a contornar.
#
# NÃO afeta o próprio docker_lab: run.sh/stop.sh/status.sh/history.sh chamam o Python
# real por um caminho fixo (HOST_PYTHON, ver esses scripts), nunca 'python3' resolvido
# por PATH/função — continuam funcionando normalmente com este bloqueio ativo. Também
# não afeta Python DENTRO de um container (filesystem e shell isolados do host, nunca
# veem /usr/local/bin nem /etc/profile.d do host).
#
# Uso:
#   sudo ./setup_block_direct_python.sh
# Reverter:
#   sudo ./undo_block_direct_python.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Precisa rodar com sudo (ex.: sudo $0)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_DIR="$HERE/host-python-guard"
PROFILE_D_FILE="/etc/profile.d/99-docker_lab-python-guard.sh"
BASHRC_MARKER_BEGIN="# >>> docker_lab python guard >>>"
BASHRC_MARKER_END="# <<< docker_lab python guard <<<"

echo "== Camada 1: symlinks em /usr/local/bin =="
TEMPLATE="$GUARD_DIR/python-blocker.sh.template"
GENERATED="$GUARD_DIR/python-blocker.sh"
sed "s|__REPO_ROOT__|$HERE|g" "$TEMPLATE" > "$GENERATED"
chmod +x "$GENERATED"

NAMES=(python python3 python3.9 python3.10 python3.11 python3.12)
INSTALLED=()
for name in "${NAMES[@]}"; do
    target="/usr/local/bin/$name"
    if [[ -e "$target" && ! -L "$target" ]]; then
        echo "AVISO: '$target' já existe e não é um symlink — pulando, não sobrescrevo às cegas." >&2
        continue
    fi
    ln -sf "$GENERATED" "$target"
    INSTALLED+=("$target")
done
echo "Instalado em: ${INSTALLED[*]}"

echo
echo "== Camada 2: função de shell (cobre venv já ativado) =="
FUNC_TEMPLATE="$GUARD_DIR/python-blocker-function.sh.template"
sed "s|__REPO_ROOT__|$HERE|g" "$FUNC_TEMPLATE" > "$PROFILE_D_FILE"
chmod 644 "$PROFILE_D_FILE"
echo "Gerado: $PROFILE_D_FILE"

if ! grep -qF "$BASHRC_MARKER_BEGIN" /etc/bash.bashrc 2>/dev/null; then
    {
        echo "$BASHRC_MARKER_BEGIN"
        echo "[ -r \"$PROFILE_D_FILE\" ] && . \"$PROFILE_D_FILE\""
        echo "$BASHRC_MARKER_END"
    } >> /etc/bash.bashrc
    echo "Referenciado em /etc/bash.bashrc (shells interativas não-login)."
else
    echo "/etc/bash.bashrc já referenciava isso, nada a fazer."
fi

echo
echo "== Pronto =="
echo "Teste: abra um terminal NOVO (sessão SSH nova, ou 'bash -l') e rode 'python3' —"
echo "deve mostrar o aviso, não abrir o REPL. Sessões JÁ ABERTAS não pegam a função nova"
echo "até serem recarregadas ('source /etc/profile' ou nova sessão)."
echo
echo "Lembrete das limitações (ver README): caminho absoluto, './script.py' com"
echo "qualquer shebang, e shells não-interativas (cron, scripts .sh chamando python por"
echo "dentro) continuam funcionando sem passar por este aviso."
