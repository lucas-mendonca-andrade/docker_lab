"""Validacao do limite de VRAM: aloca memoria na GPU de 256MB em 256MB (direto pela
API do driver CUDA via ctypes — nao precisa instalar PyTorch) ate a alocacao ser
negada. Deve parar perto de GPU_MEMORY_GB, nao na VRAM total da placa. Depois segura
a memoria por 60s, pra dar tempo de ver no 'docker-lab status' e no 'nvidia-smi'."""
import ctypes
import time

BLOCO = 256 * 1024 ** 2
CUDA_ERROR_OUT_OF_MEMORY = 2

cuda = ctypes.CDLL("libcuda.so.1")


def checar(resultado, operacao):
    if resultado != 0:
        raise RuntimeError(f"{operacao} falhou (CUresult={resultado})")


checar(cuda.cuInit(0), "cuInit")
dispositivo = ctypes.c_int()
checar(cuda.cuDeviceGet(ctypes.byref(dispositivo), 0), "cuDeviceGet")
nome = ctypes.create_string_buffer(100)
checar(cuda.cuDeviceGetName(nome, 100, dispositivo), "cuDeviceGetName")
contexto = ctypes.c_void_p()
checar(cuda.cuCtxCreate_v2(ctypes.byref(contexto), 0, dispositivo), "cuCtxCreate")

livre, total = ctypes.c_size_t(), ctypes.c_size_t()
checar(cuda.cuMemGetInfo_v2(ctypes.byref(livre), ctypes.byref(total)), "cuMemGetInfo")
print(f"GPU: {nome.value.decode()}", flush=True)
print(f"VRAM total vista pelo job: {total.value / 1024 ** 3:.2f} GB "
      "(com o limite ativo, deve ser ~GPU_MEMORY_GB, nao a VRAM da placa)", flush=True)

blocos = []
while True:
    ponteiro = ctypes.c_uint64()
    resultado = cuda.cuMemAlloc_v2(ctypes.byref(ponteiro), ctypes.c_size_t(BLOCO))
    if resultado == CUDA_ERROR_OUT_OF_MEMORY:
        print(f"BLOQUEADO: alocacao negada com {len(blocos) * 0.25:.2f} GB alocados "
              "(CUDA out of memory) — limite de VRAM funcionando.", flush=True)
        break
    checar(resultado, "cuMemAlloc")
    blocos.append(ponteiro)
    print(f"VRAM alocada: {len(blocos) * 0.25:.2f} GB", flush=True)

print("Segurando a memoria por 60s (confira 'docker-lab status' e 'nvidia-smi')...", flush=True)
time.sleep(60)
for ponteiro in blocos:
    cuda.cuMemFree_v2(ponteiro)
print("Fim.", flush=True)
