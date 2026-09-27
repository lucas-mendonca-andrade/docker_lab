"""Validacao do limite de RAM: aloca memoria de 256MB em 256MB ate o container ser
encerrado ao passar de MEMORY_GB. O log termina de repente (sem mensagem de fim) e o
'docker-lab history' mostra status 'erro' — e o limite funcionando."""
import time

blocos = []
while True:
    blocos.append(bytearray(256 * 1024 ** 2))  # bytearray ja preenche com zeros (usa RAM de verdade)
    print(f"RAM alocada: {len(blocos) * 0.25:.2f} GB", flush=True)
    time.sleep(0.2)
