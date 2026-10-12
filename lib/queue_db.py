#!/usr/bin/env python3
"""Fila persistente do docker_lab em SQLite (state/queue.db).

Guarda os experimentos submetidos (na fila, em execução, finalizados, cancelados) e o
histórico de erros de estimativa por usuário (NOTIFY_EMAIL). Também é a CLI usada por
run.sh (enfileirar e relatar), stop.sh (listar e cancelar da fila) e por
'docker-lab queue' (visualizar a fila). Sintaxe compatível com Python 3.8.
"""
import argparse
import os
import re
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import reserve  # noqa: E402
import scheduling  # noqa: E402

STATE_DIR = os.path.normpath(os.path.join(HERE, "..", "state"))
DB_PATH = os.environ.get("DOCKER_LAB_QUEUE_DB", os.path.join(STATE_DIR, "queue.db"))
WAKE_FILE = os.path.join(STATE_DIR, "queue.wake")
STATE_FILE = os.path.join(STATE_DIR, "reservations.json")
HISTORY_FILE = os.path.join(STATE_DIR, "history.json")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

NA_FILA = "na_fila"
EXECUTANDO = "executando"
FINALIZADO = "finalizado"
CANCELADO = "cancelado"

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_name TEXT NOT NULL,
    user TEXT NOT NULL,
    email TEXT NOT NULL,
    script TEXT NOT NULL,
    env_file TEXT NOT NULL,
    cores INTEGER NOT NULL,
    memory_gb INTEGER NOT NULL,
    gpu TEXT,
    gpu_memory_gb INTEGER NOT NULL DEFAULT 0,
    estimated_hours REAL NOT NULL,
    corrected_hours REAL,
    runner_script TEXT NOT NULL,
    log_file TEXT NOT NULL,
    status TEXT NOT NULL,
    submitted_at REAL NOT NULL,
    started_at REAL,
    finished_at REAL,
    run_id TEXT,
    outcome TEXT,
    head_notified INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS estimate_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL,
    job_id INTEGER NOT NULL,
    estimated_hours REAL NOT NULL,
    actual_hours REAL NOT NULL,
    error_hours REAL NOT NULL,
    recorded_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def connect(path=None):
    """Abre o banco (criando as tabelas). umask 0: o arquivo e os journals do SQLite
    precisam ser graváveis por todos os usuários da máquina e pelo escalonador (root)."""
    old = os.umask(0)
    try:
        conn = sqlite3.connect(path or DB_PATH, timeout=30, isolation_level=None)
    finally:
        os.umask(old)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def margin_for(conn, email):
    """Margem de correção do usuário: média dos erros registrados (0 sem histórico)."""
    rows = conn.execute(
        "SELECT error_hours FROM estimate_errors WHERE email = ?", (email,)
    ).fetchall()
    return scheduling.user_margin([row["error_hours"] for row in rows])


def queued_jobs(conn):
    """Fila em ordem de chegada."""
    return conn.execute(
        "SELECT * FROM jobs WHERE status = 'na_fila' ORDER BY submitted_at, id"
    ).fetchall()


def running_jobs(conn):
    """Experimentos da fila que já foram iniciados e ainda não terminaram."""
    return conn.execute(
        "SELECT * FROM jobs WHERE status = 'executando' ORDER BY started_at, id"
    ).fetchall()


def get_job(conn, job_id):
    return conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()


def record_estimate_error(conn, job, actual_hours):
    """Registra o erro (real - estimado) de um experimento que terminou por conta própria."""
    conn.execute(
        "INSERT INTO estimate_errors "
        "(email, job_id, estimated_hours, actual_hours, error_hours, recorded_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (job["email"], job["id"], job["estimated_hours"], actual_hours,
         actual_hours - job["estimated_hours"], time.time()),
    )


def set_meta(conn, key, value):
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, str(value)),
    )


def get_meta(conn, key):
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def corrected_for(conn, job):
    """Estimativa corrigida: a fixada no início, para quem já iniciou; senão a calculada
    com a margem atual do usuário."""
    if job["corrected_hours"] is not None:
        return job["corrected_hours"]
    return scheduling.corrected_estimate(job["estimated_hours"], margin_for(conn, job["email"]))


def format_hours(hours):
    """1.5 -> '1h30m'; valores negativos ou None tratados por quem chama."""
    total_min = int(round(hours * 60))
    h, m = divmod(total_min, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m"


def wake_scheduler():
    """Avisa o escalonador que algo mudou (ele confere o mtime deste arquivo)."""
    old = os.umask(0)
    try:
        with open(WAKE_FILE, "a"):
            pass
        os.utime(WAKE_FILE, None)
    finally:
        os.umask(old)


def cmd_enqueue(args):
    if not EMAIL_RE.match(args.email or ""):
        print(f"NOTIFY_EMAIL inválido ou ausente no .env: '{args.email or ''}' "
              "(esperado um e-mail, ex.: fulano@gmail.com).", file=sys.stderr)
        sys.exit(2)
    try:
        estimated = float(str(args.estimated).replace(",", "."))
    except ValueError:
        estimated = -1
    if estimated <= 0:
        print(f"ESTIMATED_RUNTIME_HOURS inválido ou ausente no .env: '{args.estimated or ''}' "
              "(esperado um número de horas maior que zero, ex.: 1.5).", file=sys.stderr)
        sys.exit(2)

    gpu = args.gpu if args.gpu and args.gpu != "none" else None
    caps = reserve.machine_capacity()
    problems = []
    if args.cores > caps["cores"][1]:
        problems.append(f"CORES={args.cores}, mas o máximo reservável nesta máquina é {caps['cores'][1]}")
    if args.mem > caps["memory_gb"][1]:
        problems.append(f"MEMORY_GB={args.mem}, mas o máximo reservável é {caps['memory_gb'][1]}GB")
    if gpu is not None:
        if gpu not in caps["vram"]:
            problems.append(f"GPU={gpu} não existe nesta máquina "
                            f"(disponíveis: {sorted(caps['vram']) or 'nenhuma'})")
        elif args.gpu_mem <= 0:
            problems.append("com GPU definida, GPU_MEMORY_GB (>= 1) é obrigatório")
        elif args.gpu_mem > caps["vram"][gpu][1]:
            problems.append(f"GPU_MEMORY_GB={args.gpu_mem}, mas o máximo reservável na GPU {gpu} "
                            f"é {caps['vram'][gpu][1]}GB")
    if problems:
        print("O experimento nunca caberia nesta máquina: " + "; ".join(problems) + ".",
              file=sys.stderr)
        sys.exit(2)

    conn = connect()
    conn.execute("BEGIN IMMEDIATE")
    active = conn.execute(
        "SELECT id FROM jobs WHERE job_name = ? AND status IN ('na_fila', 'executando')",
        (args.job_name,),
    ).fetchone()
    if active or args.job_name in reserve.read_state(STATE_FILE)["jobs"]:
        conn.execute("ROLLBACK")
        print(f"Já existe um experimento '{args.job_name}' na fila ou em execução. "
              "Use outro JOB_NAME, ou espere/cancele o atual (docker-lab stop).", file=sys.stderr)
        sys.exit(1)
    cur = conn.execute(
        "INSERT INTO jobs (job_name, user, email, script, env_file, cores, memory_gb, gpu, "
        "gpu_memory_gb, estimated_hours, runner_script, log_file, status, submitted_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'na_fila', ?)",
        (args.job_name, args.user, args.email, args.script, args.env_file, args.cores,
         args.mem, gpu, args.gpu_mem if gpu else 0, estimated, args.runner, args.log,
         time.time()),
    )
    conn.execute("COMMIT")
    wake_scheduler()
    print(cur.lastrowid)


def cmd_report(args):
    """Espera o escalonador avaliar o job recém-submetido e imprime a mensagem do 'run'."""
    conn = connect()
    job = get_job(conn, args.id)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        job = get_job(conn, args.id)
        last_pass = float(get_meta(conn, "last_pass_at") or 0)
        if job["status"] != NA_FILA or last_pass >= job["submitted_at"]:
            break
        time.sleep(0.5)
    evaluated = job["status"] != NA_FILA or float(get_meta(conn, "last_pass_at") or 0) >= job["submitted_at"]

    margin = margin_for(conn, job["email"])
    corrected = corrected_for(conn, job)
    queue_ids = [row["id"] for row in queued_jobs(conn)]
    print(f"== Experimento #{job['id']} ({job['job_name']}) entrou na fila ==")
    if job["status"] == EXECUTANDO:
        print("   Situação:    INICIOU IMEDIATAMENTE (havia recursos livres)")
        print(f"   Log:         {job['log_file']}")
    elif job["status"] == NA_FILA:
        position = scheduling.queue_position(queue_ids, job["id"])
        print(f"   Situação:    aguardando na fila — posição {position} de {len(queue_ids)}")
        if not evaluated:
            print("   Atenção:     o escalonador ainda não avaliou a fila. Se continuar assim, "
                  "avise o administrador (serviço docker_lab-scheduler).")
    else:
        print(f"   Situação:    {job['status']}")
    sign = "+" if margin >= 0 else "-"
    print(f"   Estimativa:  informada {format_hours(job['estimated_hours'])}, corrigida "
          f"{format_hours(corrected)} (sua margem atual: {sign}{format_hours(abs(margin))})")
    print(f"   E-mails:     você receberá avisos em {job['email']} (próximo da fila, início, fim)")
    print(f"   Ver o log:   docker-lab logs {job['job_name']}")
    print('Use "docker-lab queue" para acompanhar a fila')


def cmd_queued_list(args):
    """Jobs na fila para o menu do stop.sh: id<TAB>descrição."""
    conn = connect()
    for position, job in enumerate(queued_jobs(conn), start=1):
        desc = (f"{job['job_name']} — NA FILA (posição {position}, de {job['user']}, "
                f"cores={job['cores']} mem={job['memory_gb']}GB"
                + (f" gpu={job['gpu']} vram={job['gpu_memory_gb']}GB" if job["gpu"] else "")
                + ")")
        print(f"{job['id']}\t{desc}")


def cmd_cancel(args):
    """Cancela um job que ainda está na fila (ele perde o lugar)."""
    conn = connect()
    cur = conn.execute(
        "UPDATE jobs SET status = 'cancelado', finished_at = ?, outcome = 'cancelado' "
        "WHERE id = ? AND status = 'na_fila'",
        (time.time(), args.id),
    )
    if cur.rowcount == 0:
        print("Esse experimento não está mais na fila (já iniciou ou foi cancelado).", file=sys.stderr)
        sys.exit(1)
    wake_scheduler()


def _table(headers, rows):
    widths = [len(h) for h in headers]
    for _, cells in rows:
        widths = [max(w, len(str(c))) for w, c in zip(widths, cells)]
    bold = sys.stdout.isatty()
    print("    " + "  ".join(h.ljust(w) for h, w in zip(headers, widths)))
    print("    " + "  ".join("-" * w for w in widths))
    for mine, cells in rows:
        line = "  ".join(str(c).ljust(w) for c, w in zip(cells, widths))
        if mine:
            line = (f"\033[1m ➜  {line}\033[0m" if bold else f" ➜  {line}")
        else:
            line = "    " + line
        print(line)


def _resources(cores, mem, gpu, vram):
    text = f"{cores}c / {mem}GB"
    return text + (f" / GPU{gpu} {vram}GB" if gpu else " / -")


def _legacy_user(history, job_name):
    for run in reversed(history["runs"]):
        if run["job_name"] == job_name:
            return run.get("user", "-")
    return "-"


def cmd_view(args):
    """'docker-lab queue': em execução, na fila e resumo da máquina."""
    conn = connect()
    now = time.time()
    state = reserve.read_state(STATE_FILE)
    history = reserve.read_history(HISTORY_FILE)
    db_running = {job["job_name"]: job for job in running_jobs(conn)}

    print("EM EXECUÇÃO")
    rows = []
    for name, res in sorted(state["jobs"].items()):
        job = db_running.get(name)
        resources = _resources(len(res["cores"]), res["memory_gb"], res.get("gpu"),
                               res.get("gpu_memory_gb", 0))
        if job is None:
            user = _legacy_user(history, name)
            rows.append((user == args.user, [
                f"{user} (legado)", name, resources, "-", "-",
                format_hours((now - res.get("reserved_at", now)) / 3600), "desconhecido",
            ]))
            continue
        corrected = job["corrected_hours"] or job["estimated_hours"]
        elapsed = (now - job["started_at"]) / 3600
        remaining = corrected - elapsed
        rows.append((job["user"] == args.user, [
            f"{job['user']} <{job['email']}>", name, resources,
            format_hours(job["estimated_hours"]), format_hours(corrected),
            format_hours(elapsed), format_hours(remaining) if remaining > 0 else "excedido",
        ]))
    if rows:
        _table(["USUÁRIO", "EXPERIMENTO", "CORES/RAM/VRAM", "ESTIMADO", "CORRIGIDO",
                "RODANDO HÁ", "RESTANTE"], rows)
    else:
        print("    (nenhum)")

    print()
    print("NA FILA")
    rows = []
    for position, job in enumerate(queued_jobs(conn), start=1):
        rows.append((job["user"] == args.user, [
            str(position), f"{job['user']} <{job['email']}>", job["job_name"],
            _resources(job["cores"], job["memory_gb"], job["gpu"], job["gpu_memory_gb"]),
            format_hours(job["estimated_hours"]), format_hours(corrected_for(conn, job)),
            format_hours((now - job["submitted_at"]) / 3600),
        ]))
    if rows:
        _table(["POS", "USUÁRIO", "EXPERIMENTO", "CORES/RAM/VRAM", "ESTIMADO", "CORRIGIDO",
                "ESPERANDO HÁ"], rows)
    else:
        print("    (vazia)")

    print()
    print("RESUMO DA MÁQUINA")
    caps = reserve.machine_capacity()
    used_c = len(reserve.used_cores(state))
    used_m = reserve.used_mem_gb(state)
    summary = [(False, ["Cores", str(caps["cores"][0]), str(caps["cores"][1]), str(used_c),
                        str(max(0, caps["cores"][1] - used_c))]),
               (False, ["RAM (GB)", str(caps["memory_gb"][0]), str(caps["memory_gb"][1]),
                        str(used_m), str(max(0, caps["memory_gb"][1] - used_m))])]
    for gpu, (total, cap) in sorted(caps["vram"].items()):
        used_v = reserve.used_vram_gb(state, gpu)
        summary.append((False, [f"VRAM GPU {gpu} (GB)", f"{total:.0f}", str(cap), str(used_v),
                                str(max(0, cap - used_v))]))
    _table(["RECURSO", "TOTAL", "TETO", "EM USO", "LIVRE"], summary)
    print()
    print("➜ = seus experimentos. Para cancelar ou parar: docker-lab stop")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("enqueue", help="Coloca um experimento na fila (usado pelo run.sh)")
    p.add_argument("--job-name", required=True, dest="job_name")
    p.add_argument("--user", required=True)
    p.add_argument("--email", default="")
    p.add_argument("--estimated", default="")
    p.add_argument("--script", required=True)
    p.add_argument("--env-file", required=True, dest="env_file")
    p.add_argument("--cores", required=True, type=int)
    p.add_argument("--mem", required=True, type=int)
    p.add_argument("--gpu", default="none")
    p.add_argument("--gpu-mem", type=int, default=0, dest="gpu_mem")
    p.add_argument("--runner", required=True)
    p.add_argument("--log", required=True)
    p.set_defaults(func=cmd_enqueue)

    p = sub.add_parser("report", help="Mensagem do 'docker-lab run' após enfileirar")
    p.add_argument("--id", required=True, type=int)
    p.add_argument("--wait", type=float, default=10)
    p.set_defaults(func=cmd_report)

    p = sub.add_parser("queued-list", help="Jobs na fila (para o stop.sh)")
    p.set_defaults(func=cmd_queued_list)

    p = sub.add_parser("cancel", help="Cancela um job que ainda está na fila")
    p.add_argument("--id", required=True, type=int)
    p.set_defaults(func=cmd_cancel)

    p = sub.add_parser("view", help="docker-lab queue")
    p.add_argument("--user", required=True)
    p.set_defaults(func=cmd_view)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
