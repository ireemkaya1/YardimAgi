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

from .db import get_conn

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


def require_role(*roller: str):
    """
    Rol kontrolü yapan bağımlılık üreticisi. Uç noktada:

        async def endpoint(user = Depends(require_role("ADMIN"))):

    NEDEN GEREKLİ
    -------------
    Yazma uç noktaları `CALL sp_...` kullanıyor ve her yordamın ilk satırı
    fn_require_user ile rolü doğruluyor. Ama OKUMA uç noktaları doğrudan
    SELECT çalıştırıyor; orada yordam yok, dolayısıyla rol kontrolü de
    yoktu. Geçerli token'ı olan herhangi bir rol yönetim verisini ve
    afetzede iletişim bilgisini okuyabiliyordu.

    NEDEN PYTHON'DA "role == 'ADMIN'" YAZMIYORUZ
    --------------------------------------------
    Token'daki rol, giriş anındaki roldür. Kullanıcı sonradan pasife
    alındıysa veya rolü değiştiyse token hâlâ eski bilgiyi taşır.
    fn_require_user veritabanındaki GÜNCEL satıra bakıyor: kullanıcı pasif
    ise YA401, rol uygun değilse YA403 fırlatır. Böylece pasife alınan
    hesabın elindeki token anında işlemez hale gelir.

    Yetki kuralı da tek yerde kalır: veritabanında.
    """
    async def dep(user=Depends(current_user), conn=Depends(get_conn)) -> dict:
        await conn.execute(
            "SELECT fn_require_user($1, $2::user_role[])", user["id"], list(roller)
        )
        return user

    return dep