"""
Veritabanı hata kodlarını HTTP durumlarına çeviren TEK yer.

Yordamlar özel SQLSTATE kodlarıyla hata fırlatıyor:

    ERROR:  YA403: Bu işlem için yetkiniz yok (rol=VOLUNTEER, ...)

Bu sayede her uç noktada ayrı try/except yazmanıza gerek kalmaz.
Yeni bir hata kodu eklerseniz yalnızca aşağıdaki sözlüğe eklersiniz.
"""
import asyncpg
from fastapi import Request
from fastapi.responses import JSONResponse

YA_HTTP = {
    "YA400": 400,  # geçersiz girdi
    "YA401": 401,  # kullanıcı yok veya pasif
    "YA403": 403,  # yetki yok
    "YA404": 404,  # kayıt bulunamadı
    "YA409": 409,  # çakışma (görev alınmış, stok yetersiz)
    "YA410": 410,  # QR süresi dolmuş veya kullanılmış
    "YA422": 422,  # geçersiz durum geçişi
}


async def postgres_error_handler(request: Request, exc: asyncpg.PostgresError):
    kod = getattr(exc, "sqlstate", None)
    durum = YA_HTTP.get(kod)

    if durum is None:
        # Bizim kodumuz değil: veritabanı seviyesinde beklenmeyen bir hata.
        # Ayrıntıyı istemciye sızdırmıyoruz, sunucu günlüğüne bırakıyoruz.
        return JSONResponse(
            status_code=500,
            content={"detail": "Sunucu hatası", "code": kod},
        )

    return JSONResponse(
        status_code=durum,
        content={"detail": exc.message, "code": kod},
    )


def register(app) -> None:
    app.add_exception_handler(asyncpg.PostgresError, postgres_error_handler)
