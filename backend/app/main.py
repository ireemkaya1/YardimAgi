"""
YardımAğı - FastAPI uygulaması.

Çalıştırmak için:
    uvicorn app.main:app --reload

Sonra tarayıcıda:
    http://localhost:8000/docs
"""
import os

from dotenv import load_dotenv

load_dotenv()  # .env'i oku - diğer app modüllerinden ÖNCE olmalı

from contextlib import asynccontextmanager  # noqa: E402

from fastapi import FastAPI  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402

from . import errors  # noqa: E402
from .db import close_pool, open_pool  # noqa: E402
from .routers import admin, auth, data, deliveries, requests  # noqa: E402


@asynccontextmanager
async def lifespan(app: FastAPI):
    await open_pool()
    yield
    await close_pool()


app = FastAPI(
    title="YardımAğı API",
    description=(
        "Afet sonrası yardım koordinasyon sistemi.\n\n"
        "**Kullanım:** `/auth/login` ile token alın, sağ üstteki "
        "**Authorize** düğmesine yapıştırın, sonra diğer uç noktaları deneyin.\n\n"
        "Demo kullanıcılar (parola `Demo123!`):\n"
        "- `saha1@yardimagi.test` — saha görevlisi (Merkez C)\n"
        "- `saha2@yardimagi.test` — saha görevlisi (merkezsiz)\n"
        "- `gonullu.c1@yardimagi.test` — taşıma gönüllüsü\n"
        "- `admin@yardimagi.test` — yönetici"
    ),
    version="1.0.0",
    lifespan=lifespan,
    # persistAuthorization: Authorize penceresine yapıştırılan token'ı
    # tarayıcının sessionStorage'ında tutar. Olmadığı zaman /docs sayfası
    # her yenilendiğinde token siliniyor ve tüm uç noktalar "Geçersiz veya
    # süresi dolmuş oturum" veriyor - oysa token hâlâ geçerlidir.
    #
    # Yalnızca /docs test sayfasını etkiler; mobil uygulama ve admin paneli
    # token'ı kendileri saklayacak.
    swagger_ui_parameters={"persistAuthorization": True},
)

# --------------------------------------------------------------------------
# CORS
#
# Tarayıcı, bir sayfadaki JavaScript'in BAŞKA adresten gelen yanıtı
# okumasına izin vermez - o adres açıkça izin vermedikçe. Admin paneli
# tarayıcıda çalışacağı için gerekli. Mobil uygulamaya işlemez.
#
# allow_origins=["*"] yazmayın: allow_credentials ile birlikte tarayıcılar
# zaten reddeder.
# --------------------------------------------------------------------------
origins = [
    o.strip()
    for o in os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
    if o.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# YA403 -> 403 gibi çevirileri yapar
errors.register(app)

app.include_router(auth.router)
app.include_router(requests.router)
app.include_router(deliveries.router)
app.include_router(data.router)
app.include_router(admin.router)


@app.get("/health", tags=["Sistem"], summary="Ayakta mı")
async def health():
    return {"status": "ok"}