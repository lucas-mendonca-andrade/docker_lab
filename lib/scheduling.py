"""Lógica pura do escalonamento da fila do docker_lab: FIFO com backfill.

Não acessa Docker, SQLite nem SMTP — recebe recursos livres, jobs em execução e a fila,
e devolve quem deve iniciar. Assim pode ser testada isoladamente (tests/test_scheduling.py).
Recursos considerados: CORES, RAM (MEMORY_GB) e VRAM por GPU (GPU_MEMORY_GB).
"""
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

MIN_CORRECTED_HOURS = 5 / 60


@dataclass
class Resources:
    """Recursos disponíveis (ou ocupados): cores, RAM em GB e VRAM em GB por GPU."""

    cores: int
    memory_gb: int
    vram: Dict[str, int] = field(default_factory=dict)

    def copy(self) -> "Resources":
        return Resources(self.cores, self.memory_gb, dict(self.vram))


@dataclass
class QueuedJob:
    """Experimento na fila, já com a estimativa corrigida pela margem do usuário."""

    id: int
    email: str
    cores: int
    memory_gb: int
    gpu: Optional[str]
    gpu_memory_gb: int
    corrected_hours: float


@dataclass
class RunningJob:
    """Experimento ocupando recursos. Legados não têm estimativa (remaining_hours=None)."""

    cores: int
    memory_gb: int
    gpu: Optional[str]
    gpu_memory_gb: int
    legacy: bool = False
    remaining_hours: Optional[float] = None


@dataclass
class Plan:
    """Resultado de uma rodada: jobs a iniciar (em ordem) e, para cada um que furou a
    fila, os ids dos jobs que estavam à frente dele."""

    started: List[int] = field(default_factory=list)
    backfilled: List[Tuple[int, List[int]]] = field(default_factory=list)
    time_until_head_fits: Optional[float] = None


def corrected_estimate(estimated_hours: float, margin_hours: float) -> float:
    """Estimativa informada + margem do usuário, com piso de 5 minutos."""
    return max(estimated_hours + margin_hours, MIN_CORRECTED_HOURS)


def user_margin(errors: List[float]) -> float:
    """Margem de correção do usuário: média simples dos erros (real - estimado); 0 sem
    histórico."""
    if not errors:
        return 0.0
    return sum(errors) / len(errors)


def fits(job, free: Resources) -> bool:
    """O job cabe se TODOS os recursos pedidos estão livres agora."""
    if job.cores > free.cores or job.memory_gb > free.memory_gb:
        return False
    if job.gpu is not None and job.gpu_memory_gb > free.vram.get(job.gpu, 0):
        return False
    return True


def _take(free: Resources, job) -> None:
    free.cores -= job.cores
    free.memory_gb -= job.memory_gb
    if job.gpu is not None:
        free.vram[job.gpu] = free.vram.get(job.gpu, 0) - job.gpu_memory_gb


def _give(free: Resources, job) -> None:
    free.cores += job.cores
    free.memory_gb += job.memory_gb
    if job.gpu is not None:
        free.vram[job.gpu] = free.vram.get(job.gpu, 0) + job.gpu_memory_gb


def time_until_fits(head: QueuedJob, free: Resources, running: List[RunningJob]) -> float:
    """Horas até haver recursos para `head`, liberando os jobs em execução na ordem do
    tempo restante estimado. Devolve 0 (bloqueia o backfill) se algum job já passou da
    estimativa corrigida, ou se a cabeça só caberia liberando um legado (tempo
    desconhecido)."""
    if fits(head, free):
        return 0.0
    if any(r.remaining_hours is not None and r.remaining_hours <= 0
           for r in running if not r.legacy):
        return 0.0
    simulated = free.copy()
    for job in sorted((r for r in running if not r.legacy), key=lambda r: r.remaining_hours):
        _give(simulated, job)
        if fits(head, simulated):
            return job.remaining_hours
    return 0.0


def plan(queue: List[QueuedJob], free: Resources, running: List[RunningJob]) -> Plan:
    """Decide quem inicia agora. `queue` em ordem de chegada. Inicia a cabeça enquanto ela
    couber; quando não couber, deixa passar à frente quem cabe agora e tem estimativa
    corrigida <= tempo até liberar recursos para a cabeça."""
    free = free.copy()
    running = list(running)
    pending = list(queue)
    result = Plan()

    while pending and fits(pending[0], free):
        job = pending.pop(0)
        _take(free, job)
        running.append(RunningJob(job.cores, job.memory_gb, job.gpu, job.gpu_memory_gb,
                                  remaining_hours=job.corrected_hours))
        result.started.append(job.id)

    if not pending:
        return result

    head = pending[0]
    limit = time_until_fits(head, free, running)
    result.time_until_head_fits = limit
    if limit <= 0:
        return result

    ahead = [head.id]
    for job in pending[1:]:
        if fits(job, free) and job.corrected_hours <= limit:
            _take(free, job)
            result.started.append(job.id)
            result.backfilled.append((job.id, list(ahead)))
        else:
            ahead.append(job.id)
    return result


def queue_position(queue_ids: List[int], job_id: int) -> Optional[int]:
    """Posição (1 = cabeça) de `job_id` na fila em ordem de chegada; None se não está na
    fila (já iniciou ou foi cancelado)."""
    try:
        return queue_ids.index(job_id) + 1
    except ValueError:
        return None
