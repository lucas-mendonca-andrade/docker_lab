"""Validacao do limite de CPU: tenta ocupar TODOS os cores da maquina por 45s.
Dentro do container, so os cores reservados (CORES do job.env) devem ficar a 100%.
Confira no host com 'htop' (ou 'top' e tecla 1) enquanto roda."""
import multiprocessing as mp
import os
import time

DURACAO = 45


def ocupar(_):
    fim = time.time() + DURACAO
    while time.time() < fim:
        pass


if __name__ == "__main__":
    cores = sorted(os.sched_getaffinity(0))
    total = os.cpu_count()
    print(f"Cores que o job pode usar: {cores} ({len(cores)} de {total} da maquina)", flush=True)
    print(f"Disparando {total} processos (1 por core da maquina) por {DURACAO}s...", flush=True)
    with mp.Pool(total) as pool:
        pool.map(ocupar, range(total))
    print(f"OK: so {len(cores)} core(s) deveriam ter ficado a 100% no htop.", flush=True)
