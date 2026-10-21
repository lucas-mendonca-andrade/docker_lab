#!/usr/bin/env bash
# docker-lab venv [versão] [requirements.txt] [pasta]   (sem versão: menu de escolha)
#
# Cria o ambiente virtual do projeto DENTRO do container, com o Python da própria
# imagem do docker_lab (3.7 a 3.14), e instala os pacotes do requirements.txt. Assim o
# venv aponta para um Python feito para o sistema da imagem — sem depender do Python da
# máquina (que pode nem ter a versão pedida) e sem misturar bibliotecas de dois sistemas
# (causa de travamentos nativos com Python compilado à mão no host).
#
# O venv criado só funciona dentro do docker_lab (o PYTHON_BIN do job.env aponta pra ele).
# Roda como o usuário, com a home montada (cache do pip em ~/.cache) e com limite de
# CORES/RAM, pra instalação não pesar na máquina dos outros.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
IMAGE="docker-lab-runner:latest"
INSTALL_CORES=2
INSTALL_MEMORY_GB=8
VERSOES="3.7 3.8 3.9 3.10 3.11 3.12 3.13 3.14"

uso() {
    echo "Uso: docker-lab venv [versão do Python] [requirements.txt] [pasta do venv]" >&2
    echo "  sem a versão, mostra um menu para escolher" >&2
    echo "  ex.: docker-lab venv 3.11 requirements.txt          (cria ./venv)" >&2
    echo "       docker-lab venv 3.12 requirements.txt venv2    (cria ./venv2)" >&2
    echo "Versões disponíveis: $VERSOES" >&2
}

VERSAO="${1:-}"
REQUIREMENTS="${2:-}"
PASTA="${3:-venv}"

if [[ -e "$PASTA" ]]; then
    echo "Já existe '$PASTA' nesta pasta. Para recriar, renomeie ou apague antes:" >&2
    echo "  mv $PASTA ${PASTA}_antigo      (ou: rm -rf $PASTA)" >&2
    exit 1
fi

if [[ -z "$VERSAO" ]]; then
    if [[ ! -t 0 ]]; then
        uso
        exit 1
    fi
    echo "Versões do Python disponíveis no docker_lab:"
    PS3="Qual versão usar no venv (número)? "
    select VERSAO in $VERSOES; do
        [[ -n "$VERSAO" ]] && break
        echo "Opção inválida, tente de novo."
    done
    if [[ -z "$REQUIREMENTS" && -f requirements.txt ]]; then
        read -r -p "Instalar os pacotes de requirements.txt? [S/n] " RESPOSTA
        [[ "${RESPOSTA,,}" == "n" ]] || REQUIREMENTS="requirements.txt"
    fi
fi
if [[ " $VERSOES " != *" $VERSAO "* ]]; then
    echo "Versão '$VERSAO' não disponível na imagem do docker_lab." >&2
    uso
    exit 1
fi
if [[ -n "$REQUIREMENTS" && ! -f "$REQUIREMENTS" ]]; then
    echo "Arquivo de pacotes não encontrado: $REQUIREMENTS" >&2
    exit 1
fi
if ! docker version >/dev/null 2>&1; then
    echo "Seu usuário não tem acesso ao Docker agora (grupo docker). Reconecte o SSH ou" >&2
    echo "peça ao administrador para rodar: sudo $HERE/setup.sh" >&2
    exit 1
fi

HOST_PYTHON3_VERSION="$(readlink -f /usr/bin/python3 | grep -oE '3\.[0-9]+$' || echo 3.12)"
echo "== Buildando imagem ($IMAGE) =="
if ! BUILD_OUTPUT=$(docker build -q --build-arg "HOST_PYTHON3_VERSION=$HOST_PYTHON3_VERSION" \
        -t "$IMAGE" "$HERE" 2>&1); then
    echo "$BUILD_OUTPUT" >&2
    echo "== Falha ao buildar a imagem — veja o erro acima. ==" >&2
    exit 1
fi

INSTALAR="true"
if [[ -n "$REQUIREMENTS" ]]; then
    INSTALAR="\"$PASTA/bin/pip\" install -r \"$REQUIREMENTS\""
fi

echo "== Criando '$PASTA' com Python $VERSAO (dentro do container) =="
docker run --rm \
    --cpus="$INSTALL_CORES" --memory="${INSTALL_MEMORY_GB}g" \
    --user "$(id -u):$(id -g)" \
    -e HOME="$HOME" -e USER="$(id -un)" -e LOGNAME="$(id -un)" \
    -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
    -v "$HOME":"$HOME" -v "$PWD":"$PWD" -w "$PWD" \
    "$IMAGE" \
    bash -c "set -e
        python$VERSAO -m venv \"$PASTA\"
        \"$PASTA/bin/python\" -m pip install --upgrade pip
        $INSTALAR
        echo
        \"$PASTA/bin/python\" --version" < /dev/null

echo
echo "== Pronto: '$PASTA' criado com Python $VERSAO =="
echo "   No seu .env:  PYTHON_BIN=$PASTA/bin/python"
echo "   Esse venv só funciona dentro do docker_lab (docker-lab run), não direto na máquina."
