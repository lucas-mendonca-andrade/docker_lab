#!/usr/bin/env bash
# Devolve pro usuário os arquivos com dono root dentro de uma pasta DELE — sobra de jobs
# que rodaram antes do docker_lab executar os containers com o usuário de quem chamou
# (antes rodavam como root). Sem isto o aluno precisaria de sudo pra apagar/editar os
# próprios resultados, e poucos usuários da máquina têm sudo.
#
# Faz o chown dentro de um container (quem está no grupo docker já pode isso), e só:
# - numa pasta cujo dono é quem chamou (não mexe em pasta de outra pessoa);
# - em arquivos/pastas cujo dono é root (não mexe em arquivos de outros usuários).
#
# Uso: docker-lab corrigir-permissoes [pasta]   (padrão: pasta atual)
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
IMAGE="docker-lab-runner:latest"
ALVO="$(cd "${1:-.}" && pwd)"
MEU_UID="$(id -u)"
MEU_GID="$(id -g)"

if [[ "$(stat -c %u "$ALVO")" != "$MEU_UID" ]]; then
    echo "A pasta '$ALVO' não é sua (dono: $(stat -c %U "$ALVO")) — só corrijo pastas suas." >&2
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Imagem $IMAGE ainda não existe — rode um 'docker-lab run' primeiro." >&2
    exit 1
fi

QTD="$(docker run --rm -v "$ALVO":"$ALVO" "$IMAGE" \
    find "$ALVO" -xdev -user 0 -print0 | tr -cd '\0' | wc -c)"
if [[ "$QTD" -eq 0 ]]; then
    echo "Nada a corrigir: nenhum arquivo com dono root em $ALVO."
    exit 0
fi
docker run --rm -v "$ALVO":"$ALVO" "$IMAGE" \
    find "$ALVO" -xdev -user 0 -exec chown -h "$MEU_UID:$MEU_GID" {} +
echo "Corrigido: $QTD arquivo(s)/pasta(s) em $ALVO agora são de $(id -un)."
