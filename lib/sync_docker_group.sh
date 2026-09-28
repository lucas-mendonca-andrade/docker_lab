#!/usr/bin/env bash
# Coloca todo usuário humano da máquina (UID 1000–59999, com shell de login) no grupo
# 'docker' — sem isso o 'docker-lab run' falha com "permission denied ... docker.sock".
# Chamado pelo setup.sh (usuários que já existem) e pelo serviço systemd
# docker_lab-docker-group.service, disparado pelo docker_lab-docker-group.path sempre
# que /etc/passwd muda — ou seja, logo que um usuário NOVO é criado (adduser, useradd
# ou interface gráfica), antes do primeiro login dele.
#
# Uso: sync_docker_group.sh   (precisa de root)
set -euo pipefail

if ! getent group docker >/dev/null; then
    echo "AVISO: grupo 'docker' não existe — o Docker está instalado? (sudo apt install docker.io)" >&2
    exit 0
fi

ADDED=()
while IFS=: read -r user _ uid _ _ _ shell; do
    (( uid >= 1000 && uid < 60000 )) || continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
        usermod -aG docker "$user"
        ADDED+=("$user")
    fi
done < <(getent passwd)
echo "Adicionados ao grupo docker: ${ADDED[*]:-nenhum (todos já estavam)}"
