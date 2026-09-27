# Imagem base generica pra rodar scripts deste repo dentro de um container com
# recurso (CPU/RAM/GPU) controlado pelo wrapper (run.sh) — nao a imagem que roda os
# frameworks do AMLB em si (esses continuam usando os venvs proprios de cada
# framework, que ja existem no repo montado no MESMO caminho absoluto do host —
# ver run.sh, nao em /workspace).
#
# Ubuntu 24.04 (mesma distro da maquina do laboratorio) + deadsnakes: cada aluno pode
# ter um venv proprio (PYTHON_BIN no job.env) criado com uma versao diferente de
# Python — um venv guarda um link simbolico ABSOLUTO pro python do SISTEMA de quem o
# criou (ex. /usr/bin/python3.11), que precisa existir de verdade dentro do container
# pra esse link resolver. deadsnakes instala cada versao exatamente nesse caminho
# padrao do Ubuntu, entao qualquer venv dessas versoes funciona sem hack por versao.

# Estagio 1: compila o HAMi-core (libvgpu.so), que limita a VRAM da GPU por container
# (ver run.sh: CUDA_DEVICE_MEMORY_LIMIT via LD_PRELOAD). So precisa dos headers do CUDA pra compilar, nao de GPU. CUDA 12.8: minimo
# com suporte a Blackwell (RTX 5090) e o mesmo que o driver 570 das maquinas do lab
# expoe — headers mais novos que o driver poderiam referenciar funcoes que ele nao tem.
# Commit fixado pra build reproduzivel.
FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS hami-core
ARG HAMI_CORE_COMMIT=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e
RUN apt-get update && apt-get install -y --no-install-recommends cmake git ca-certificates \
    && git clone https://github.com/Project-HAMi/HAMi-core.git /hami-core \
    && cd /hami-core && git checkout "$HAMI_CORE_COMMIT" \
    && bash ./build.sh

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# software-properties-common: add-apt-repository, pra registrar o PPA deadsnakes.
# procps: nproc/ps, uteis pra debugar dentro do container.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
        gnupg \
        curl \
        procps \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.9  python3.9-venv \
        python3.10 python3.10-venv \
        python3.11 python3.11-venv \
        python3.12 python3.12-venv \
    && rm -rf /var/lib/apt/lists/*
# Versoes cobertas: 3.9-3.12. Se algum aluno precisar de outra, adicione aqui
# (python3.X python3.X-venv) e rebuilde — nao precisa mudar mais nada.

# python3/pip3 genericos da imagem — usados so pelo fallback PYTHON_BIN=python3 (quem
# NAO estiver usando um venv proprio, ver requirements.txt deste diretorio). Cada venv
# de aluno usa a versao dele mesmo (instalada acima), nao esta.
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12 - --break-system-packages
# --break-system-packages: seguro aqui porque esta imagem NAO e um sistema real (nao
# tem gerenciador de pacotes do sistema tentando controlar essas libs) — o aviso do
# Ubuntu 24.04 (PEP 668) e pensado pra proteger uma instalacao de SO de verdade, que
# nao e o caso de uma imagem Docker de uso unico como esta.

# Substitui 'taskset' por um shim que ignora o '-c <lista>' hardcoded em varios
# run_all_frameworks_*.py deste repo — a restricao real de cores ja vem do
# --cpuset-cpus do 'docker run' (ver run.sh e fake-bin/taskset). /usr/local/bin vem
# antes de /usr/bin no PATH desta imagem, entao este shim sempre tem prioridade sobre
# qualquer 'taskset' real que venha a ser instalado depois.
COPY fake-bin/taskset /usr/local/bin/taskset
RUN chmod +x /usr/local/bin/taskset

# HAMi-core: so e carregado (LD_PRELOAD) em jobs com GPU — ver run.sh. /tmp/vgpulock e
# o diretorio de lock que ele exige.
COPY --from=hami-core /hami-core/build/libvgpu.so /usr/local/vgpu/libvgpu.so
RUN mkdir -p /tmp/vgpulock && chmod 1777 /tmp/vgpulock

# Sem WORKDIR fixo aqui de proposito: o run.sh monta o repo no MESMO caminho absoluto
# que ele tem no host (nao em /workspace) e sempre passa `-w` explicito no `docker run`
# — ver comentario no run.sh sobre por que isso e necessario (venvs de framework com
# link simbolico absoluto pro venv raiz do repo, que so resolve se o caminho bater).

# Dependencias extras que o SEU script precise (fora do que ja vem no venv do repo,
# se voce for usar um). Vazio por padrao — cada aluno mantem o proprio requirements.txt.
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m pip install --no-cache-dir --break-system-packages -r /tmp/requirements.txt
