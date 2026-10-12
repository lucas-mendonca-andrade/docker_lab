#!/usr/bin/env python3
"""Escalonador da fila do docker_lab (serviço systemd docker_lab-scheduler, como root).

Em loop (a cada POLL_SECONDS, ou logo após uma submissão/cancelamento, que tocam
state/queue.wake): finaliza experimentos que terminaram (registrando o erro da estimativa e
a nova margem), contabiliza os recursos ocupados — inclusive por experimentos "legados",
iniciados antes da fila e que ela não controla —, decide quem inicia com FIFO + backfill
(lib/scheduling.py) e sobe cada escolhido como o usuário que o submeteu (runuser), com o
script de execução gerado pelo run.sh. Envia os e-mails (lib/notify.py). Sintaxe
compatível com Python 3.8.

Uso: scheduler.py [--once]
"""
import argparse
import contextlib
import fcntl
import logging
import os
import pwd
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import notify  # noqa: E402
import queue_db  # noqa: E402
import reserve  # noqa: E402
import scheduling  # noqa: E402

POLL_SECONDS = 30
STATE_DIR = queue_db.STATE_DIR
LOCK_FILE = os.path.join(STATE_DIR, "reservations.lock")
HISTORY_LOCK = os.path.join(STATE_DIR, "history.lock")
STATE_FILE = queue_db.STATE_FILE
HISTORY_FILE = queue_db.HISTORY_FILE
OWN_FINISH = ("executou", "erro")

log = logging.getLogger("docker_lab.scheduler")
children = []


@contextlib.contextmanager
def locked(path):
    """flock exclusivo no mesmo arquivo de lock usado pelos scripts do docker_lab."""
    with open(path, "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def finalize_finished(conn):
    """Fecha os experimentos da fila que terminaram; devolve [(job, desfecho, horas reais,
    erro ou None, nova margem)] para os e-mails."""
    finished = []
    now = time.time()
    for job in queue_db.running_jobs(conn):
        with locked(HISTORY_LOCK):
            run = reserve.find_run(HISTORY_FILE, job["run_id"]) if job["run_id"] else None
        outcome = None
        if run is not None and run["status"] != "executando":
            outcome = run["status"]
        elif (now - job["started_at"] > reserve.GRACE_PERIOD_SECONDS
              and not reserve.container_is_running(job["job_name"])):
            outcome = "interrompido"
        if outcome is None:
            continue
        actual_hours = (now - job["started_at"]) / 3600
        conn.execute("BEGIN IMMEDIATE")
        conn.execute(
            "UPDATE jobs SET status = 'finalizado', finished_at = ?, outcome = ? WHERE id = ?",
            (now, outcome, job["id"]),
        )
        error_hours = None
        if outcome in OWN_FINISH:
            queue_db.record_estimate_error(conn, job, actual_hours)
            error_hours = actual_hours - job["estimated_hours"]
        conn.execute("COMMIT")
        new_margin = queue_db.margin_for(conn, job["email"])
        log.info("Experimento #%s (%s) terminou: %s", job["id"], job["job_name"], outcome)
        finished.append((job, outcome, actual_hours, error_hours, new_margin))
    return finished


def resources_snapshot(conn, state):
    """Recursos livres (dentro do teto) e experimentos ocupando recursos — os que não
    estão na fila como 'executando' são legados (tempo restante desconhecido)."""
    caps = reserve.machine_capacity()
    free = scheduling.Resources(
        cores=caps["cores"][1] - len(reserve.used_cores(state)),
        memory_gb=caps["memory_gb"][1] - reserve.used_mem_gb(state),
        vram={gpu: cap - reserve.used_vram_gb(state, gpu) for gpu, (_, cap) in caps["vram"].items()},
    )
    db_running = {job["job_name"]: job for job in queue_db.running_jobs(conn)}
    now = time.time()
    running = []
    for name, res in state["jobs"].items():
        job = db_running.get(name)
        common = dict(cores=len(res["cores"]), memory_gb=res["memory_gb"], gpu=res.get("gpu"),
                      gpu_memory_gb=res.get("gpu_memory_gb", 0))
        if job is None:
            running.append(scheduling.RunningJob(legacy=True, **common))
        else:
            elapsed = (now - job["started_at"]) / 3600
            running.append(scheduling.RunningJob(
                remaining_hours=job["corrected_hours"] - elapsed, **common))
    return free, running


def spawn(job, cores, run_id):
    """Sobe o script de execução do job como o usuário que submeteu, em segundo plano,
    com a saída no log do job."""
    command = ["env", f"ALLOC_CORES={cores}", f"RUN_ID={run_id}"]
    if os.geteuid() == 0:
        entry = pwd.getpwnam(job["user"])
        command = (["runuser", "-u", job["user"], "--"] + command
                   + [f"HOME={entry.pw_dir}", f"USER={job['user']}", f"LOGNAME={job['user']}"])
    command += ["bash", "-c", 'exec "$0" > "$1" 2>&1', job["runner_script"], job["log_file"]]
    children.append(subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True))


def start_job(conn, state, job, corrected_hours):
    """Reserva os recursos, abre o registro no histórico e sobe o job. False se a reserva
    falhar (o job continua na fila)."""
    if os.geteuid() != 0 and job["user"] != pwd.getpwuid(os.geteuid()).pw_name:
        log.error("Sem root não dá para iniciar #%s de outro usuário (%s)", job["id"], job["user"])
        return False
    try:
        cores = reserve.acquire_job(state, job["job_name"], job["cores"], job["memory_gb"],
                                    job["gpu"], job["gpu_memory_gb"])
    except reserve.AcquireError as err:
        log.warning("Não foi possível reservar #%s (%s): %s", job["id"], job["job_name"], err)
        return False
    reserve.write_state(STATE_FILE, state)
    with locked(HISTORY_LOCK):
        run_id = reserve.history_start(HISTORY_FILE, job["job_name"], job["user"], job["script"],
                                       job["log_file"], job["memory_gb"],
                                       job["gpu_memory_gb"] if job["gpu"] else 0)
    conn.execute(
        "UPDATE jobs SET status = 'executando', started_at = ?, run_id = ?, corrected_hours = ? "
        "WHERE id = ?",
        (time.time(), run_id, corrected_hours, job["id"]),
    )
    spawn(job, ",".join(str(c) for c in cores), run_id)
    log.info("Experimento #%s (%s) iniciado: cores %s", job["id"], job["job_name"], cores)
    return True


def run_pass(conn):
    """Uma rodada completa do escalonador."""
    for child in list(children):
        if child.poll() is not None:
            children.remove(child)

    finished = finalize_finished(conn)
    started, jumped = [], []
    with locked(LOCK_FILE):
        state = reserve.read_state(STATE_FILE)
        if reserve.reap(state):
            reserve.write_state(STATE_FILE, state)
        queue = queue_db.queued_jobs(conn)
        corrected = {job["id"]: queue_db.corrected_for(conn, job) for job in queue}
        by_id = {job["id"]: job for job in queue}
        free, running = resources_snapshot(conn, state)
        decision = scheduling.plan(
            [scheduling.QueuedJob(job["id"], job["email"], job["cores"], job["memory_gb"],
                                  job["gpu"], job["gpu_memory_gb"], corrected[job["id"]])
             for job in queue],
            free, running,
        )
        backfill_ahead = dict(decision.backfilled)
        for job_id in decision.started:
            if not start_job(conn, state, by_id[job_id], corrected[job_id]):
                break
            started.append(job_id)
            if job_id in backfill_ahead:
                jumped.append((job_id, backfill_ahead[job_id]))
    queue_db.set_meta(conn, "last_pass_at", time.time())

    for job, outcome, actual, error, margin in finished:
        notify.notify_finished(job, job["corrected_hours"] or job["estimated_hours"], outcome,
                               actual, error, margin)
    for job_id in started:
        notify.notify_started(queue_db.get_job(conn, job_id), corrected[job_id])
    for job_id, ahead in jumped:
        victims_by_email = {}
        for victim_id in ahead:
            victim = by_id[victim_id]
            victims_by_email.setdefault(victim["email"], []).append((victim, corrected[victim_id]))
        for email, victims in victims_by_email.items():
            notify.notify_jumped(email, victims, by_id[job_id], corrected[job_id])

    queue = queue_db.queued_jobs(conn)
    if queue and not queue[0]["head_notified"]:
        head = queue[0]
        conn.execute("UPDATE jobs SET head_notified = 1 WHERE id = ?", (head["id"],))
        notify.notify_head(head, queue_db.corrected_for(conn, head))


def wake_mtime():
    try:
        return os.stat(queue_db.WAKE_FILE).st_mtime
    except OSError:
        return 0.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="Uma rodada só (para testes)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    conn = queue_db.connect()
    log.info("Escalonador iniciado (fila em %s)", queue_db.DB_PATH)
    while True:
        seen = wake_mtime()
        try:
            run_pass(conn)
        except Exception:
            log.exception("Erro na rodada do escalonador; tentando de novo na próxima")
            with contextlib.suppress(Exception):
                conn.execute("ROLLBACK")
        if args.once:
            return
        deadline = time.time() + POLL_SECONDS
        while time.time() < deadline and wake_mtime() == seen:
            time.sleep(1)


if __name__ == "__main__":
    main()
