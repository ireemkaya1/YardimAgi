"""
Kimlik doğrulama: JWT üretme ve çözme.

TASARIM NOTU
------------
Rol kontrolü burada YAPILMAZ. Yetkiyi veritabanındaki yordamlar uyguluyor
(fn_require_user). Burada yalnızca "bu istek hangi kullanıcıya ait" sorusu
cevaplanır; kullanıcının o işi yapmaya hakkı olup olmadığına veritabanı
karar verir ve gerekirse YA403 fırlatır.

Böylece yetki kuralı tek yerde durur. İki yerde tutulsaydı zamanla
birbirinden ayrışırdı.
"""
import os
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

JWT_SECRET = os.getenv("JWT_SECRET", "degistirin")
JWT_ALG = "HS256"
JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "720"))

# HTTPBearer, /docs sayfasındaki Authorize penceresinde tek bir "Value"
# kutusu gösterir: /auth/login'den dönen access_token oraya yapıştırılır.
#
# (OAuth2PasswordBearer kullanılsaydı o pencere kullanıcı adı/şifre
# isterdi ve form verisi gönderirdi; bizim login uç noktamız JSON
# beklediği için çalışmazdı.)
bearer = HTTPBearer(
    description="/auth/login yanıtındaki access_token değerini yapıştırın"
)


def create_token(user_id: int, role: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),          # JWT standardı: sub metin olmalı
        "role": role,                 # istemci hangi ekranı göstereceğine karar verir
        "iat": now,
        "exp": now + timedelta(minutes=JWT_EXPIRE_MINUTES),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)


async def current_user(
    cred: HTTPAuthorizationCredentials = Depends(bearer),
) -> dict:
    """
    Token'ı çözer ve {"id": ..., "role": ...} döner.

    Uç noktada:
        async def endpoint(user = Depends(current_user)):
            ... user["id"] ...   -> yordamlara p_actor_id olarak geçer
    """
    hata = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Geçersiz veya süresi dolmuş oturum",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(cred.credentials, JWT_SECRET, algorithms=[JWT_ALG])
        return {"id": int(payload["sub"]), "role": payload["role"]}
    except (jwt.PyJWTError, KeyError, ValueError):
        raise hata