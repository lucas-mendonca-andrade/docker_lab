#!/usr/bin/env python3
"""
Controla quem esta usando quais cores/memoria/GPU da maquina, num arquivo JSON
compartilhado (state/reservations.json). SEMPRE chamado sob flock (ver run.sh/status.sh
— este script em si nao faz seu proprio lock, pra nao serializar leitura+escrita em
duas chamadas separadas e abrir brecha de corrida entre elas).

CORES e uma QUANTIDADE (ex. --cores 2), nao uma lista de IDs — este gestor escolhe os
N cores livres de menor numero e devolve os IDs escolhidos. Varios run_all_frameworks_*.py
deste repo fazem 'taskset -c X,Y' FIXO no proprio codigo Python, e testamos que
'docker run --cpuset-cpus=A,B' NAO remapeia os IDs pra 0-based dentro do container (o
container ve os numeros reais do host) — um taskset interno pedindo cores que o
container nao tem liberados falharia com "Invalid argument". Por isso o run.sh
substitui o 'taskset' real dentro do container por um shim que ignora o '-c X,Y' do
script (ver fake-bin/taskset) — a restricao de verdade vem so do --cpuset-cpus com os
IDs que ESTE gestor escolheu, nunca dos que o script pede.

Reaping: antes de qualquer decisao, remove do estado qualquer job cujo container
("docker-lab-<nome>") nao esteja mais rodando de verdade — cobre o caso de alguem
matar o container na mao, o processo cair sem passar pelo `trap` do run.sh, ou a
maquina reiniciar. Sem isso uma reserva travada ficaria "presa" pra sempre.

Historico (--history, arquivo separado de --state, com seu proprio lock — ver
history.sh/run.sh): history-start grava uma linha por execucao aceita (status
"executando"); history-finish atualiza essa MESMA linha (por run_id) quando o
container termina, com o status final e o horario de fim. Status final e
"executou" (exit 0), "erro" (exit != 0) ou "interrompido" (--interrupted, passado
pelo run.sh quando existe um marcador de stop.sh — ver stop.sh/run.sh: sem o
marcador, um `docker stop`/`kill` externo tambem cai em "erro", ja que exit code
sozinho nao distingue um stop deliberado de um crash real, ex. OOM tambem sai 137).

GPU: cada GPU e dividida entre jobs como a maquina e dividida em cores/RAM — cada job
reserva uma QUANTIDADE de VRAM (--gpu-mem, GB) de uma GPU especifica (--gpu, indice).
A soma dos pedidos de todos os jobs numa mesma GPU nunca passa de MAX_UTILIZATION da VRAM
total. O limite POR JOB e imposto dentro do container pelo HAMi-core (ver
Dockerfile/run.sh). O processamento da GPU NAO e reservado: jobs na mesma GPU dividem o
processamento pelo time-slicing padrao da NVIDIA (ninguem sabe estimar "% de GPU" que
precisa, e GPU a 100% nao trava a maquina — o que derruba jobs e estourar VRAM).
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time

CONTAINER_PREFIX = "docker-lab-"

# Teto de uso: a SOMA de tudo que estiver reservado (todos os jobs juntos) nunca passa
# disso, pra cada tipo de recurso (cores, memoria, VRAM) — sempre sobra pelo menos 20%
# da maquina livre pro SO/SSH/outros processos, mesmo com varios jobs concorrentes.
MAX_UTILIZATION = 0.8
# RAM tem teto proprio, mais alto (decisao do Lucas, 2026-10-05: 95%): a RAM e o recurso que
# os jobs mais pedem; 5% da maquina sobra pro SO/SSH.
MEMORY_MAX_UTILIZATION = 0.95


def resource_cap(total, utilization=MAX_UTILIZATION):
    """Teto (em unidades inteiras do recurso) equivalente a MAX_UTILIZATION do total.
    Nunca menor que 1 quando existe pelo menos 1 unidade — evita que um recurso muito
    pequeno fique permanentemente inutilizavel (80% de 1 arredondaria pra 0)."""
    if total <= 0:
        return 0
    return max(1, int(total * utilization))

# Janela de tolerancia entre "acquire" e o container aparecer de verdade no `docker ps`
# (build de imagem cacheado + docker run ainda levam alguns segundos) — reap() so
# derruba uma reserva sem container rodando depois desse tempo, senao uma consulta de
# status.sh no meio desse intervalo apagaria uma reserva legitima por engano.
GRACE_PERIOD_SECONDS = 90


def total_cores():
    return os.cpu_count() or 1


def total_mem_gb():
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) // (1024 * 1024)
    raise RuntimeError("MemTotal nao encontrado em /proc/meminfo")


def gpu_inventory():
    """{indice: VRAM total em GB (float)} das GPUs da maquina ({} se nao houver
    nvidia-smi). DOCKER_LAB_FAKE_GPUS="0:32607,1:24576" (indice:MiB) simula GPUs —
    so pra testar a logica de reserva numa maquina de dev sem GPU."""
    fake = os.environ.get("DOCKER_LAB_FAKE_GPUS")
    if fake:
        lines = [item.replace(":", ",") for item in fake.split(",") if item.strip()]
    else:
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-gpu=index,memory.total",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=5,
            )
        except FileNotFoundError:
            return {}
        if out.returncode != 0:
            return {}
        lines = out.stdout.splitlines()
    inventory = {}
    for line in lines:
        if not line.strip():
            continue
        index, mib = (part.strip() for part in line.split(","))
        inventory[index] = int(mib) / 1024
    return inventory


def container_is_running(job_name):
    out = subprocess.run(
        ["docker", "ps", "-q", "--filter", f"name=^{CONTAINER_PREFIX}{job_name}$"],
        capture_output=True, text=True, timeout=10,
    )
    return bool(out.stdout.strip())


def read_state(state_path):
    if not os.path.isfile(state_path):
        return {"jobs": {}}
    with open(state_path, encoding="utf-8") as f:
        return json.load(f)


def write_state(state_path, state):
    tmp = state_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(tmp, state_path)


def reap(state):
    """Remove do estado jobs cujo container nao esta mais rodando de verdade — mas so
    depois de GRACE_PERIOD_SECONDS desde o acquire, pra nao derrubar uma reserva
    legitima no intervalo entre o acquire e o `docker run` aparecer no `docker ps`."""
    now = time.time()
    stale = [
        name for name, job in state["jobs"].items()
        if now - job.get("reserved_at", 0) > GRACE_PERIOD_SECONDS
        and not container_is_running(name)
    ]
    for name in stale:
        del state["jobs"][name]
    return stale


def used_cores(state, exclude=None):
    used = set()
    for name, job in state["jobs"].items():
        if name == exclude:
            continue
        used.update(job["cores"])
    return used


def used_mem_gb(state, exclude=None):
    return sum(job["memory_gb"] for name, job in state["jobs"].items() if name != exclude)


def used_vram_gb(state, gpu):
    """VRAM (GB) ja reservada na GPU `gpu`, somando todos os jobs."""
    return sum(
        job.get("gpu_memory_gb", 0) for job in state["jobs"].values() if job.get("gpu") == gpu
    )


def pick_free_cores(count, state):
    """Escolhe os `count` cores livres de menor numero, sem deixar o total reservado
    (somando todos os jobs) passar do teto de MAX_UTILIZATION. O script rodando dentro
    do container nao precisa (nem deve) saber quais IDs sao esses — ver
    fake-bin/taskset, que neutraliza qualquer 'taskset -c X,Y' hardcoded no script."""
    try:
        count = int(count)
    except ValueError:
        print(f"CORES inválido: '{count}' (esperado um número, ex.: 2).", file=sys.stderr)
        sys.exit(2)
    if count <= 0:
        print("CORES precisa ser >= 1.", file=sys.stderr)
        sys.exit(2)

    total = total_cores()
    cap = resource_cap(total)
    used = used_cores(state)
    if len(used) + count > cap:
        print(
            f"Pedido de {count} core(s) ultrapassaria o teto de {int(MAX_UTILIZATION * 100)}% "
            f"da máquina: já {len(used)} em uso, limite é {cap} de {total} cores totais "
            f"(sempre sobra pelo menos {total - cap} core(s) livre).",
            file=sys.stderr,
        )
        sys.exit(2)

    free = sorted(set(range(total)) - used)
    return free[:count]


def cmd_acquire(args):
    state = read_state(args.state)
    reap(state)

    if args.name in state["jobs"]:
        print(
            f"Job '{args.name}' já tem uma reserva ativa (container "
            f"'{CONTAINER_PREFIX}{args.name}' rodando). Escolha outro JOB_NAME, ou espere "
            "esse terminar.",
            file=sys.stderr,
        )
        sys.exit(1)

    cores = pick_free_cores(args.cores, state)

    total_mem = total_mem_gb()
    mem_cap = resource_cap(total_mem, MEMORY_MAX_UTILIZATION)
    used_mem = used_mem_gb(state)
    if used_mem + args.mem > mem_cap:
        print(
            f"Pedido de {args.mem}GB ultrapassaria o teto de {int(MEMORY_MAX_UTILIZATION * 100)}% "
            f"da máquina: já {used_mem}GB em uso, limite é {mem_cap}GB de {total_mem}GB "
            f"totais (sempre sobra pelo menos {total_mem - mem_cap}GB livre).",
            file=sys.stderr,
        )
        sys.exit(3)

    gpu = args.gpu if args.gpu and args.gpu != "none" else None
    gpu_mem = 0
    if gpu is not None:
        inventory = gpu_inventory()
        if gpu not in inventory:
            print(
                f"GPU '{gpu}' não existe nesta máquina (disponíveis: {sorted(inventory) or 'nenhuma'}).",
                file=sys.stderr,
            )
            sys.exit(4)
        gpu_mem = args.gpu_mem
        if gpu_mem is None or gpu_mem <= 0:
            print("Com GPU definida, GPU_MEMORY_GB (>= 1) é obrigatório no job.env.",
                  file=sys.stderr)
            sys.exit(2)
        total_vram = inventory[gpu]
        cap_vram = resource_cap(total_vram)
        used_vram = used_vram_gb(state, gpu)
        if used_vram + gpu_mem > cap_vram:
            print(
                f"Pedido de {gpu_mem}GB de VRAM na GPU {gpu} ultrapassaria o teto de "
                f"{int(MAX_UTILIZATION * 100)}%: já {used_vram}GB em uso, limite é "
                f"{cap_vram}GB de {total_vram:.0f}GB totais.",
                file=sys.stderr,
            )
            sys.exit(5)

    state["jobs"][args.name] = {
        "cores": cores, "memory_gb": args.mem, "gpu": gpu,
        "gpu_memory_gb": gpu_mem, "reserved_at": time.time(),
    }
    write_state(args.state, state)
    # stdout: so os cores confirmados, pro run.sh usar direto em --cpuset-cpus
    print(",".join(str(c) for c in cores))


def cmd_release(args):
    state = read_state(args.state)
    reap(state)
    state["jobs"].pop(args.name, None)
    write_state(args.state, state)


def cmd_status(args):
    state = read_state(args.state)
    stale = reap(state)
    if stale:
        write_state(args.state, state)

    pct = int(MAX_UTILIZATION * 100)

    total_c = total_cores()
    cap_c = resource_cap(total_c)
    busy_cores = used_cores(state)
    free_cores = sorted(set(range(total_c)) - busy_cores)
    reservable_cores = max(0, cap_c - len(busy_cores))

    total_m = total_mem_gb()
    cap_m = resource_cap(total_m, MEMORY_MAX_UTILIZATION)
    used_m = used_mem_gb(state)
    reservable_mem = max(0, cap_m - used_m)

    print(f"Cores: {len(busy_cores)} em uso, {reservable_cores} ainda reserváveis "
          f"(teto {pct}% = {cap_c} de {total_c} totais) — livres de verdade: {free_cores}")
    print(f"Memória: {used_m}GB em uso, {reservable_mem}GB ainda reserváveis "
          f"(teto {int(MEMORY_MAX_UTILIZATION * 100)}% = {cap_m}GB de {total_m}GB totais)")
    inventory = gpu_inventory()
    for gpu, total_vram in sorted(inventory.items()):
        cap_vram = resource_cap(total_vram)
        used_vram = used_vram_gb(state, gpu)
        print(f"GPU {gpu} VRAM: {used_vram}GB em uso, {max(0, cap_vram - used_vram)}GB ainda "
              f"reserváveis (teto {pct}% = {cap_vram}GB de {total_vram:.0f}GB totais)")
    if not inventory:
        print("GPUs: máquina sem GPU (nvidia-smi não encontrado ou sem dispositivos)")
    print()
    if state["jobs"]:
        print("Jobs ativos:")
        for name, job in sorted(state["jobs"].items()):
            print(f"  {name}: {describe_job(job)}")
    else:
        print("Nenhum job ativo no momento.")


def describe_job(job):
    desc = f"cores={job['cores']} mem={job['memory_gb']}GB"
    if job.get("gpu"):
        desc += f" gpu={job['gpu']} vram={job.get('gpu_memory_gb', 0)}GB"
    return desc


def _now_iso():
    return datetime.datetime.now().isoformat(timespec="seconds")


def read_history(history_path):
    if not os.path.isfile(history_path):
        return {"runs": []}
    with open(history_path, encoding="utf-8") as f:
        return json.load(f)


def write_history(history_path, history):
    tmp = history_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(history, f, indent=2, sort_keys=True)
    os.replace(tmp, history_path)


def cmd_history_start(args):
    history = read_history(args.history)
    run_id = f"{args.name}@{_now_iso()}"
    history["runs"].append({
        "run_id": run_id,
        "job_name": args.name,
        "user": args.user,
        "script": args.script,
        "started_at": _now_iso(),
        "ended_at": None,
        "status": "executando",
        "exit_code": None,
    })
    write_history(args.history, history)
    print(run_id)  # stdout: run.sh guarda isso pra passar pro history-finish depois


def cmd_history_finish(args):
    history = read_history(args.history)
    for run in history["runs"]:
        if run["run_id"] == args.run_id:
            run["ended_at"] = _now_iso()
            run["exit_code"] = args.exit_code
            if args.interrupted:
                run["status"] = "interrompido"
            else:
                run["status"] = "executou" if args.exit_code == 0 else "erro"
            break
    else:
        print(f"Aviso: run_id '{args.run_id}' não encontrado no histórico.", file=sys.stderr)
        return
    write_history(args.history, history)


def cmd_history_list(args):
    history = read_history(args.history)
    runs = history["runs"]
    if not runs:
        print("Nenhuma execução registrada ainda.")
        return
    # Execuções que ficaram "executando" mas cujo container ja nao existe mais (crash,
    # maquina reiniciada, etc. — nunca passaram pelo history-finish de verdade) aparecem
    # como "interrompido" aqui, sem alterar o arquivo (so um ajuste de exibicao). Mesma
    # folga de GRACE_PERIOD_SECONDS do reap() — senao um history-list chamado bem na
    # hora do inicio (container ainda nao apareceu no `docker ps`) mostraria
    # "interrompido" por engano num job que na verdade acabou de comecar.
    now = time.time()
    header = f"{'JOB_NAME':40s} {'USUARIO':16s} {'INICIO':20s} {'FIM':20s} {'STATUS':12s}"
    print(header)
    print("-" * len(header))
    for run in sorted(runs, key=lambda r: r["started_at"]):
        status = run["status"]
        if status == "executando":
            started_ts = datetime.datetime.fromisoformat(run["started_at"]).timestamp()
            if now - started_ts > GRACE_PERIOD_SECONDS and not container_is_running(run["job_name"]):
                status = "interrompido"
        ended = run["ended_at"] or "-"
        print(f"{run['job_name']:40s} {run['user']:16s} {run['started_at']:20s} "
              f"{ended:20s} {status:12s}")


def cmd_list(args):
    """Lista os jobs ativos, 1 por linha: '<nome>\\t<descricao>' — usado pelo stop.sh
    pra montar o menu de seleção (o nome puro vai depois do TAB de volta pro
    docker stop, a descricao e so pra mostrar pro usuario)."""
    state = read_state(args.state)
    stale = reap(state)
    if stale:
        write_state(args.state, state)
    for name, job in sorted(state["jobs"].items()):
        desc = f"{name} ({describe_job(job)})"
        print(f"{name}\t{desc}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", help="Caminho do reservations.json (subcomandos de reserva)")
    parser.add_argument("--history", help="Caminho do history.json (subcomandos de historico)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_acquire = sub.add_parser("acquire", help="Reserva cores/memoria/gpu para um job")
    p_acquire.add_argument("--name", required=True)
    p_acquire.add_argument("--cores", required=True, help="quantidade de cores, ex.: 2")
    p_acquire.add_argument("--mem", required=True, type=int, help="GB")
    p_acquire.add_argument("--gpu", default="none", help="indice da GPU, ou none")
    p_acquire.add_argument("--gpu-mem", type=int, dest="gpu_mem", help="VRAM em GB")
    p_acquire.set_defaults(func=cmd_acquire)

    p_release = sub.add_parser("release", help="Libera a reserva de um job")
    p_release.add_argument("--name", required=True)
    p_release.set_defaults(func=cmd_release)

    p_status = sub.add_parser("status", help="Mostra reservas ativas e recurso livre")
    p_status.set_defaults(func=cmd_status)

    p_list = sub.add_parser("list", help="Lista nomes dos jobs ativos (pro stop.sh)")
    p_list.set_defaults(func=cmd_list)

    p_hstart = sub.add_parser("history-start", help="Registra o inicio de uma execucao")
    p_hstart.add_argument("--name", required=True)
    p_hstart.add_argument("--user", required=True)
    p_hstart.add_argument("--script", required=True)
    p_hstart.set_defaults(func=cmd_history_start)

    p_hfinish = sub.add_parser("history-finish", help="Registra o fim de uma execucao")
    p_hfinish.add_argument("--run-id", required=True, dest="run_id")
    p_hfinish.add_argument("--exit-code", required=True, type=int, dest="exit_code")
    p_hfinish.add_argument(
        "--interrupted", action="store_true",
        help="Forca status 'interrompido' (job parado deliberadamente via stop.sh, "
             "nao um erro de verdade) independente do exit code",
    )
    p_hfinish.set_defaults(func=cmd_history_finish)

    p_hlist = sub.add_parser("history-list", help="Mostra o historico de execucoes")
    p_hlist.set_defaults(func=cmd_history_list)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
