"""Testes da lógica de escalonamento da fila (lib/scheduling.py), sem Docker nem SMTP.

Rodar: /usr/bin/python3 -m unittest discover -s tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from scheduling import (  # noqa: E402
    QueuedJob,
    Resources,
    RunningJob,
    corrected_estimate,
    plan,
    queue_position,
    user_margin,
)


def queued(job_id, cores=1, mem=1, hours=1.0, gpu=None, vram=0, email="a@x"):
    return QueuedJob(job_id, email, cores, mem, gpu, vram, hours)


def running(cores=1, mem=1, remaining=1.0, gpu=None, vram=0, legacy=False):
    return RunningJob(cores, mem, gpu, vram, legacy=legacy,
                      remaining_hours=None if legacy else remaining)


class FifoTest(unittest.TestCase):
    def test_inicia_em_ordem_de_chegada_enquanto_couber(self):
        free = Resources(cores=4, memory_gb=8)
        result = plan([queued(1, cores=2), queued(2, cores=2), queued(3, cores=2)], free, [])
        self.assertEqual(result.started, [1, 2])
        self.assertEqual(result.backfilled, [])

    def test_cabeca_que_nao_cabe_segura_a_fila_sem_tempo_para_backfill(self):
        free = Resources(cores=1, memory_gb=8)
        result = plan([queued(1, cores=2), queued(2, cores=1)], free, [])
        self.assertEqual(result.started, [])

    def test_considera_vram_da_gpu_pedida(self):
        free = Resources(cores=8, memory_gb=32, vram={"0": 4})
        result = plan([queued(1, gpu="0", vram=8), queued(2, gpu="0", vram=2, hours=0.5)],
                      free, [running(cores=1, remaining=2.0, gpu="0", vram=6)])
        self.assertEqual(result.started, [2])


class BackfillTest(unittest.TestCase):
    def test_backfill_permitido_quando_cabe_e_e_curto(self):
        free = Resources(cores=2, memory_gb=16)
        result = plan(
            [queued(1, cores=4, hours=3.0), queued(2, cores=2, hours=1.0)],
            free,
            [running(cores=4, remaining=2.0)],
        )
        self.assertEqual(result.time_until_head_fits, 2.0)
        self.assertEqual(result.started, [2])
        self.assertEqual(result.backfilled, [(2, [1])])

    def test_backfill_negado_por_tempo(self):
        free = Resources(cores=2, memory_gb=16)
        result = plan(
            [queued(1, cores=4), queued(2, cores=2, hours=3.0)],
            free,
            [running(cores=4, remaining=2.0)],
        )
        self.assertEqual(result.started, [])

    def test_backfill_negado_pela_margem_de_correcao_caso_zezinho(self):
        margem_zezinho = user_margin([3.0])
        estimativa_zezinho = corrected_estimate(1.0, margem_zezinho)
        self.assertEqual(estimativa_zezinho, 4.0)
        free = Resources(cores=2, memory_gb=16)
        result = plan(
            [queued(1, cores=4), queued(2, cores=2, hours=estimativa_zezinho, email="zezinho@x")],
            free,
            [running(cores=4, remaining=2.0)],
        )
        self.assertEqual(result.started, [])

    def test_job_acima_da_estimativa_bloqueia_backfill(self):
        free = Resources(cores=2, memory_gb=16)
        result = plan(
            [queued(1, cores=4), queued(2, cores=2, hours=0.1)],
            free,
            [running(cores=4, remaining=-0.5)],
        )
        self.assertEqual(result.time_until_head_fits, 0.0)
        self.assertEqual(result.started, [])

    def test_legado_ocupando_recursos_bloqueia_backfill(self):
        free = Resources(cores=2, memory_gb=16)
        result = plan(
            [queued(1, cores=4), queued(2, cores=2, hours=0.1)],
            free,
            [running(cores=4, legacy=True)],
        )
        self.assertEqual(result.time_until_head_fits, 0.0)
        self.assertEqual(result.started, [])

    def test_legado_irrelevante_para_a_cabeca_nao_bloqueia(self):
        free = Resources(cores=2, memory_gb=16)
        result = plan(
            [queued(1, cores=4, hours=5.0), queued(2, cores=2, hours=1.0)],
            free,
            [running(cores=4, remaining=2.0), running(cores=2, legacy=True)],
        )
        self.assertEqual(result.started, [2])

    def test_backfill_atualiza_recursos_e_avisa_quem_estava_a_frente(self):
        free = Resources(cores=3, memory_gb=16)
        result = plan(
            [queued(1, cores=4), queued(2, cores=2, hours=1.0), queued(3, cores=2, hours=1.0),
             queued(4, cores=1, hours=1.0)],
            free,
            [running(cores=4, remaining=2.0)],
        )
        self.assertEqual(result.started, [2, 4])
        self.assertEqual(result.backfilled, [(2, [1]), (4, [1, 3])])


class EstimativaTest(unittest.TestCase):
    def test_margem_media_dos_erros(self):
        self.assertEqual(user_margin([]), 0.0)
        self.assertAlmostEqual(user_margin([1.0, -0.5]), 0.25)
        self.assertAlmostEqual(user_margin([2.0, 1.0, 0.0]), 1.0)

    def test_estimativa_corrigida_tem_piso_de_5_minutos(self):
        self.assertAlmostEqual(corrected_estimate(1.0, 0.5), 1.5)
        self.assertAlmostEqual(corrected_estimate(0.5, -2.0), 5 / 60)


class PosicaoTest(unittest.TestCase):
    def test_posicao_na_fila(self):
        self.assertEqual(queue_position([7, 3, 9], 7), 1)
        self.assertEqual(queue_position([7, 3, 9], 9), 3)
        self.assertIsNone(queue_position([7, 3, 9], 5))


if __name__ == "__main__":
    unittest.main()
