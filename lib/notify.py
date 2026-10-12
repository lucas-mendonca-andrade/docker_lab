"""Notificações por e-mail da fila do docker_lab (Gmail, SMTP com SSL na porta 465).

As credenciais ficam só na configuração do servidor (DOCKER_LAB_EMAIL_CONFIG, padrão
/etc/docker_lab/email.env, legível apenas pelo root), nunca no .env dos usuários:
DOCKERLAB_EMAIL e DOCKERLAB_EMAIL_SENHA_APP. As especificações do experimento nos
e-mails vêm de uma lista fixa de campos (SPEC_FIELDS), nunca do .env cru — segredos que o
usuário tenha posto no .env não vazam. Falha de envio só é registrada no log.
"""
import logging
import os
import smtplib
import ssl
from email.message import EmailMessage

CONFIG_PATH = os.environ.get("DOCKER_LAB_EMAIL_CONFIG", "/etc/docker_lab/email.env")
SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 465

SPEC_FIELDS = (
    ("JOB_NAME", "job_name"),
    ("SCRIPT", "script"),
    ("CORES", "cores"),
    ("MEMORY_GB", "memory_gb"),
    ("GPU", "gpu"),
    ("GPU_MEMORY_GB", "gpu_memory_gb"),
    ("ESTIMATED_RUNTIME_HOURS", "estimated_hours"),
)

log = logging.getLogger("docker_lab.notify")


def load_credentials(path=CONFIG_PATH):
    """(e-mail, senha de app) da configuração do servidor, ou None se não configurado."""
    values = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        return None
    email, password = values.get("DOCKERLAB_EMAIL"), values.get("DOCKERLAB_EMAIL_SENHA_APP")
    return (email, password) if email and password else None


def send(to, subject, body):
    """Envia um e-mail; qualquer falha é só registrada (nunca derruba o escalonador).
    Com DOCKER_LAB_EMAIL_DRY_RUN=1, apenas registra o e-mail no log."""
    if os.environ.get("DOCKER_LAB_EMAIL_DRY_RUN") == "1":
        log.info("[e-mail simulado] para=%s assunto=%s\n%s", to, subject, body)
        return
    credentials = load_credentials()
    if credentials is None:
        log.warning("E-mail não enviado para %s (%s): credenciais não configuradas em %s",
                    to, subject, CONFIG_PATH)
        return
    sender, password = credentials
    message = EmailMessage()
    message["From"] = sender
    message["To"] = to
    message["Subject"] = subject
    message.set_content(body)
    try:
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=ssl.create_default_context(),
                              timeout=30) as smtp:
            smtp.login(sender, password)
            smtp.send_message(message)
        log.info("E-mail enviado para %s: %s", to, subject)
    except Exception as err:
        log.warning("Falha ao enviar e-mail para %s (%s): %s", to, subject, err)


def _hours(value):
    total_min = int(round(value * 60))
    h, m = divmod(abs(total_min), 60)
    sign = "-" if total_min < 0 else ""
    return f"{sign}{h}h{m:02d}m" if h else f"{sign}{m}m"


def spec_block(job, corrected_hours):
    """Especificações do experimento (só os campos permitidos)."""
    lines = ["Experimento:"]
    for label, column in SPEC_FIELDS:
        value = job[column]
        if column == "gpu" and not value:
            value = "none"
        if column == "gpu_memory_gb" and not job["gpu"]:
            continue
        if column == "estimated_hours":
            value = f"{value} ({_hours(value)})"
        lines.append(f"  {label}: {value}")
    lines.append(f"  Estimativa corrigida pela sua margem: {_hours(corrected_hours)}")
    lines.append(f"  Identificador na fila: #{job['id']}")
    return "\n".join(lines)


FOOTER = '\nPara acompanhar a fila, rode no servidor: docker-lab queue\n'


def notify_head(job, corrected_hours):
    send(job["email"], f"[docker_lab] {job['job_name']} é o próximo da fila",
         f"Seu experimento agora é o PRÓXIMO da fila e vai iniciar automaticamente assim "
         f"que houver recursos livres.\n\n{spec_block(job, corrected_hours)}\n{FOOTER}")


def notify_started(job, corrected_hours):
    send(job["email"], f"[docker_lab] {job['job_name']} iniciou",
         f"Seu experimento iniciou.\n\n{spec_block(job, corrected_hours)}\n"
         f"  Log: {job['log_file']}\n"
         f"  Ver o log: docker-lab logs {job['job_name']}\n{FOOTER}")


def notify_finished(job, corrected_hours, outcome, actual_hours, error_hours, new_margin):
    if error_hours is None:
        stats = (f"  Tempo real: {_hours(actual_hours)}\n"
                 f"  Esta execução NÃO entra no cálculo da sua margem (não terminou por conta "
                 f"própria: {outcome}).\n"
                 f"  Sua margem de correção continua: {_hours(new_margin)}")
    else:
        stats = (f"  Tempo estimado: {_hours(job['estimated_hours'])}\n"
                 f"  Tempo real: {_hours(actual_hours)}\n"
                 f"  Erro desta execução (real - estimado): {_hours(error_hours)}\n"
                 f"  Nova margem de correção para os próximos experimentos: {_hours(new_margin)}")
    send(job["email"], f"[docker_lab] {job['job_name']} terminou ({outcome})",
         f"Seu experimento terminou com status: {outcome}.\n\n"
         f"{spec_block(job, corrected_hours)}\n\n{stats}\n"
         f"  Ver o log: docker-lab logs {job['job_name']}\n{FOOTER}")


def notify_jumped(email, victims, jumper, jumper_corrected):
    """Um único e-mail por usuário e evento, listando todos os experimentos dele que
    estavam à frente de `jumper`. `victims`: [(job, estimativa corrigida)]."""
    names = ", ".join(job["job_name"] for job, _ in victims)
    blocks = "\n\n".join(spec_block(job, corrected) for job, corrected in victims)
    send(email, f"[docker_lab] {jumper['job_name']} passou à frente de {names}",
         f"O experimento '{jumper['job_name']}' (de {jumper['user']}) iniciou antes do seu, que "
         f"estava à frente na fila.\n\nIsso acontece quando o outro experimento cabe nos "
         f"recursos livres agora e tem estimativa corrigida ({_hours(jumper_corrected)}) curta "
         f"o suficiente para terminar antes de liberarem os recursos que o PRIMEIRO da fila "
         f"precisa — assim ele não atrasa o seu.\n\nSeu(s) experimento(s):\n{blocks}\n{FOOTER}")
