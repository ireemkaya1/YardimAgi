"""
E-posta gönderimi.

SMTP ayarları .env'de boşsa e-posta GÖNDERİLMEZ, kod sunucu günlüğüne
yazılır. Böylece SMTP hesabı açmadan da şifre sıfırlama akışını
deneyebilirsiniz; terminalde kodu görüp ekrana yazarsınız.

Ek paket kullanmıyoruz: Python'un kendi smtplib'i yeterli. Gönderim
bloklayan bir işlem olduğu için ayrı bir iş parçacığında çalıştırılıyor,
yoksa e-posta gönderilirken sunucu diğer isteklere cevap veremezdi.
"""
import asyncio
import logging
import os
import smtplib
from email.message import EmailMessage

log = logging.getLogger("yardimagi.mail")

SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
SMTP_FROM = os.getenv("SMTP_FROM", SMTP_USER)


def is_configured() -> bool:
    return bool(SMTP_HOST and SMTP_USER and SMTP_PASSWORD)


def _send_blocking(to: str, subject: str, body: str) -> None:
    msg = EmailMessage()
    msg["From"] = SMTP_FROM
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as s:
        s.starttls()
        s.login(SMTP_USER, SMTP_PASSWORD)
        s.send_message(msg)


async def send_reset_code(to: str, code: str) -> bool:
    """
    Sıfırlama kodunu yollar. Gönderilemezse False döner ama ÇAĞIRAN
    TARAFA HATA FIRLATMAZ: kullanıcıya her durumda aynı cevap verilir,
    yoksa "bu e-posta kayıtlı mı" bilgisi sızar.
    """
    body = (
        f"YardımAğı şifre sıfırlama kodunuz: {code}\n\n"
        "Kod 15 dakika geçerlidir.\n"
        "Bu isteği siz yapmadıysanız bu e-postayı yok sayın."
    )

    if not is_configured():
        # SMTP kurulmamış: kodu günlüğe yaz, geliştirme sırasında yeterli.
        log.warning("SMTP ayarlanmamış. %s için sıfırlama kodu: %s", to, code)
        return False

    try:
        await asyncio.to_thread(
            _send_blocking, to, "YardımAğı şifre sıfırlama kodu", body
        )
        return True
    except Exception as e:                      # ağ hatası, yanlış şifre, kapalı port
        log.error("E-posta gönderilemedi (%s): %s", to, e)
        log.warning("%s için sıfırlama kodu: %s", to, code)
        return False
