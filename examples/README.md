# Validação da instalação

Scripts de teste que tentam **passar** dos limites, para confirmar que o docker_lab
os impõe. Nenhum precisa de venv nem de bibliotecas extras.

```bash
cp -r /opt/docker_lab/examples ~/validacao_docker_lab && cd ~/validacao_docker_lab
sed -i "s/^NOTIFY_EMAIL=.*/NOTIFY_EMAIL=seu_email@gmail.com/" job_*.env   # troque pelo seu e-mail
```

| Comando | O que deve acontecer |
|---|---|
| `docker-lab run job_cpu.env` | O script tenta ocupar todos os cores; no `htop`, só 2 ficam a 100%. |
| `docker-lab run job_ram.env` | O log para perto de 2 GB e o `docker-lab history` mostra `sem RAM`. |
| `docker-lab run job_gpu.env` | O log mostra `BLOQUEADO` perto de 2 GB de VRAM, não nos 12 GB da placa. |
| `docker-lab run job_gpu_grande.env` (com o `job_gpu` ativo) | Fica **na fila** (não cabe no teto de 80% da VRAM) e inicia sozinho quando o `job_gpu` terminar. Acompanhe com `docker-lab queue`. |

Logs: `docker-lab logs job_gpu.env` (troque pelo `.env` do teste).
