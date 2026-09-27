#!/usr/bin/env bash
# Roda UMA VEZ, com sudo, na máquina do laboratório — depois que este repo já estiver
# clonado num local fixo do sistema (ex. /opt/amlb_ainet_lab). Prepara este docker_lab/
# pra ser usado por VÁRIOS usuários Unix diferentes ao mesmo tempo, cada um com o
# próprio projeto (ver REPO_ROOT no job.env.example) — sem isso, cada usuário só
# conseguiria gravar em state/reservations.json e state/history.json se fosse dono do
# arquivo, o que quebraria o controle de recurso compartilhado (o objetivo inteiro deste
# projeto: uma única fonte de verdade sobre quem está usando o quê na máquina).
#
# Uso:
#   sudo ./setup_shared_install.sh
#
# Libera state/ e logs/ pra QUALQUER usuário Unix da máquina ler/escrever (chmod 777,
# sem grupo nenhum de permeio) — pensado pra uma máquina de laboratório dedicada, onde
# toda conta que existe é de alguém confiável (aluno/professor). Isso cobre
# automaticamente qualquer usuário criado DEPOIS também, sem precisar rodar comando
# nenhum por aluno novo (nem usermod, nem re-rodar este script).
#
# Se a máquina tiver OUTRAS contas Unix não relacionadas ao laboratório (serviço,
# contas antigas, etc.) e você quiser restringir a um grupo específico em vez de
# liberar geral, adapte a chamada de chmod abaixo pra usar um grupo (groupadd + chgrp +
# chmod 2775) e adicione cada aluno a esse grupo com `usermod -aG`.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Precisa rodar com sudo (ex.: sudo $0)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HERE/state"
LOGS_DIR="$HERE/logs"

mkdir -p "$STATE_DIR" "$LOGS_DIR"
touch "$STATE_DIR/reservations.lock" "$STATE_DIR/history.lock"

echo "== Liberando state/ e logs/ pra qualquer usuário da máquina =="
# 777 sem sticky bit (diferente de /tmp): reservations.json/history.json são reescritos
# via arquivo-temporário + rename atômico (os.replace) — isso só exige permissão de
# ESCRITA no DIRETÓRIO (pra criar o temporário e renomear por cima), nunca no arquivo em
# si; e um sticky bit bloquearia exatamente esse rename/delete entre usuários diferentes
# (só o dono do arquivo poderia substituí-lo), quebrando o mecanismo. Por isso 777 puro.
chmod 777 "$STATE_DIR" "$LOGS_DIR"
chmod 666 "$STATE_DIR/reservations.lock" "$STATE_DIR/history.lock"
[[ -f "$STATE_DIR/reservations.json" ]] && chmod 666 "$STATE_DIR/reservations.json"
[[ -f "$STATE_DIR/history.json" ]] && chmod 666 "$STATE_DIR/history.json"

echo
echo "== Pronto =="
echo "Qualquer usuário Unix desta máquina (atual ou criado depois) já pode usar, sem"
echo "nenhum comando extra. Cada aluno cria o PRÓPRIO job.env (na pasta pessoal dele,"
echo "não aqui — ver docker_lab/job.env.example), com REPO_ROOT apontando pro projeto"
echo "dele, e roda:"
echo "    $HERE/run.sh ~/caminho/pro/seu/job.env"
