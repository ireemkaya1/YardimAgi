"""
Giriş, kayıt ve şifre işlemleri.

Parolalar hiçbir zaman düz saklanmaz. Hem yazarken hem doğrularken
pgcrypto'nun crypt() fonksiyonu kullanılır; tek yöntem olduğu için
uyumsuzluk riski yok.

Bu dosyadaki iki yazma işlemi (kayıt ve şifre değiştirme) doğrudan SQL
çalıştırır, saklı yordam kullanmaz. Sebebi: ikisi de kimlik doğrulaması
GEREKTİRMEYEN veya kullanıcının kendi hesabına ait işlemler; yordamların
istediği "işlemi yapan yetkili kullanıcı" kavramı burada yok.
Rol, SQL metninin içine sabit yazıldığı için dışarıdan değiştirilemez.
"""
import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import mail
from ..db import get_conn
from ..security import JWT_ALG, JWT_SECRET, create_token, current_user

# E-posta alanı: EmailStr DEĞİL.
#
# email-validator paketi ".test" uzantısını reddediyor - RFC 2606'da test
# amaçlı ayrılmış özel bir alan adı olduğu için. Oysa demo verimiz tam da
# o yüzden ".test" kullanıyor; doğru olan seçim bizimki.
#
# Bunun yerine veritabanındaki ck_users_email_format kısıtıyla AYNI deseni
# kullanıyoruz. Böylece API ve veritabanı aynı kurala bakıyor; API erken ve
# anlaşılır bir hata veriyor, son söz yine veritabanında.
EPOSTA = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"

router = APIRouter(prefix="/auth", tags=["Giriş ve şifre"])

RESET_DAKIKA = 15


# ---------------------------------------------------------------------------
# Modeller
# ---------------------------------------------------------------------------

class LoginIn(BaseModel):
    email: str = Field(pattern=EPOSTA, examples=["saha1@yardimagi.test"])
    password: str


class RegisterIn(BaseModel):
    full_name: str = Field(min_length=2, examples=["Ayşe Yılmaz"])
    email: str = Field(pattern=EPOSTA, examples=["saha1@yardimagi.test"])
    password: str = Field(min_length=6)
    phone: str | None = Field(default=None, examples=["05551112233"])
    role: str = Field(
        default="VOLUNTEER",
        examples=["VOLUNTEER"],
        description="VOLUNTEER (taşıma gönüllüsü) | ATTENDANT (saha görevlisi)",
    )
    center_id: int | None = Field(
        default=None,
        description="ATTENDANT için ZORUNLU. VOLUNTEER için boş bırakılmalı.",
    )


class ChangePasswordIn(BaseModel):
    old_password: str
    new_password: str = Field(min_length=6)


class ForgotIn(BaseModel):
    email: str = Field(pattern=EPOSTA, examples=["saha1@yardimagi.test"])


class ResetIn(BaseModel):
    reset_token: str = Field(description="forgot-password yanıtından gelen değer")
    code: str = Field(min_length=6, max_length=6, examples=["482913"])
    new_password: str = Field(min_length=6)


# ---------------------------------------------------------------------------
# Giriş
# ---------------------------------------------------------------------------

SQL_LOGIN = """
    SELECT id, full_name, role::text AS role, center_id
      FROM users
     WHERE lower(email) = lower($1)
       AND password_hash = crypt($2, password_hash)
       AND is_active
"""


@router.post("/login", summary="Giriş yap, token al")
async def login(body: LoginIn, conn=Depends(get_conn)):
    row = await conn.fetchrow(SQL_LOGIN, body.email, body.password)
    if row is None:
        # Hangisinin yanlış olduğunu söylemiyoruz: "bu e-posta kayıtlı değil"
        # demek, saldırgana hangi hesapların var olduğunu öğretir.
        raise HTTPException(401, "E-posta veya parola hatalı")

    return {
        "access_token": create_token(row["id"], row["role"]),
        "token_type": "bearer",
        "user_id": row["id"],
        "full_name": row["full_name"],
        "role": row["role"],
        "center_id": row["center_id"],
    }


@router.get("/me", summary="Oturumdaki kullanıcı")
async def me(user=Depends(current_user), conn=Depends(get_conn)):
    """
    Uygulama açılışında çağrılır: token hâlâ geçerli mi, kullanıcı hâlâ
    aktif mi. 401 dönerse giriş ekranına yönlendirin.

    Token geçerli olsa bile kullanıcı pasife alınmış olabilir; bu yüzden
    token'a bakmak yetmez, veritabanına sormak gerekir.
    """
    row = await conn.fetchrow(
        """
        SELECT u.id, u.full_name, u.email, u.phone, u.role::text AS role,
               u.center_id, c.name AS center_name
          FROM users u
          LEFT JOIN centers c ON c.id = u.center_id
         WHERE u.id = $1 AND u.is_active
        """,
        user["id"],
    )
    if row is None:
        raise HTTPException(401, "Hesabınız pasife alınmış")
    return dict(row)


# ---------------------------------------------------------------------------
# Kayıt
# ---------------------------------------------------------------------------

@router.get("/centers", summary="Kayıt ekranı için merkez listesi")
async def public_centers(conn=Depends(get_conn)):
    """
    GİRİŞ GEREKTİRMEZ - kayıt ekranında kullanıcının henüz token'ı yok,
    ama görevli olarak kaydolacaksa merkez seçmesi gerekiyor.

    Yalnızca id ve ad dönüyor. Adres, telefon ve koordinat gibi bilgiler
    giriş yapmış kullanıcıların gördüğü /centers uç noktasında.
    """
    rows = await conn.fetch(
        "SELECT id, name FROM centers WHERE is_active ORDER BY name"
    )
    return [dict(r) for r in rows]


@router.post("/register", status_code=201, summary="Kayıt ol")
async def register(body: RegisterIn, conn=Depends(get_conn)):
    """
    İKİ ROL İÇİN İKİ FARKLI AKIŞ
    ----------------------------
    VOLUNTEER (taşıma gönüllüsü)
        Merkeze bağlanmaz - herhangi bir merkezin görevini alabilir.
        Hesap ANINDA aktif olur, token döner, hemen kullanmaya başlar.

    ATTENDANT (saha görevlisi)
        Tam olarak BİR merkeze bağlanır, merkez seçimi zorunludur.
        Hesap PASİF açılır, token DÖNMEZ, yönetici onayı bekler.

    Görevli neden onay bekliyor: görevlinin yetkisi geniş. Stok girişi
    yapabiliyor, paket hazırlayabiliyor ve teslimatı onaylayabiliyor -
    teslim onayı zincire blok yazıyor. Serbest kayıt olsaydı isteyen
    kendini bir merkezin görevlisi ilan edip sahte teslimat onaylayabilir
    ve zincire sahte kayıt düşürebilirdi.

    Yönetici onayı `PATCH /admin/users/{id}/active` ile verilir;
    bekleyenler `GET /admin/users/pending` ile listelenir.
    """
    rol = body.role.upper()
    if rol not in ("VOLUNTEER", "ATTENDANT"):
        raise HTTPException(400, "Rol yalnızca VOLUNTEER veya ATTENDANT olabilir")

    if rol == "ATTENDANT":
        if body.center_id is None:
            raise HTTPException(400, "Saha görevlisi bir merkez seçmek zorundadır")
        var = await conn.fetchval(
            "SELECT 1 FROM centers WHERE id = $1 AND is_active", body.center_id
        )
        if not var:
            raise HTTPException(404, "Merkez bulunamadı veya pasif")
    elif body.center_id is not None:
        # Gönüllü merkeze bağlanamaz; veritabanı kısıtı da buna izin vermez
        # ama hatayı burada anlaşılır bir mesajla veriyoruz.
        raise HTTPException(400, "Gönüllü bir merkeze bağlanmaz; merkez boş bırakılmalı")

    aktif = rol == "VOLUNTEER"
    merkez = body.center_id if rol == "ATTENDANT" else None

    try:
        row = await conn.fetchrow(
            """
            INSERT INTO users (full_name, email, phone, password_hash,
                               role, center_id, is_active)
            VALUES (btrim($1), lower(btrim($2)), $3,
                    crypt($4, gen_salt('bf', 10)), $5::user_role, $6, $7)
            RETURNING id, full_name, role::text AS role, center_id, is_active
            """,
            body.full_name, body.email, body.phone, body.password,
            rol, merkez, aktif,
        )
    except Exception as e:
        if "uq_users_email_lower" in str(e) or "unique" in str(e).lower():
            raise HTTPException(409, "Bu e-posta ile kayıtlı bir hesap var")
        raise

    if not aktif:
        # Token YOK: hesap onaylanana kadar giriş yapılamaz.
        return {
            "user_id": row["id"],
            "role": row["role"],
            "center_id": row["center_id"],
            "approved": False,
            "detail": "Kaydınız alındı. Yönetici onayından sonra giriş yapabilirsiniz.",
        }

    return {
        "access_token": create_token(row["id"], row["role"]),
        "token_type": "bearer",
        "user_id": row["id"],
        "full_name": row["full_name"],
        "role": row["role"],
        "center_id": None,
        "approved": True,
    }


# ---------------------------------------------------------------------------
# Kendi şifresini değiştirme
# ---------------------------------------------------------------------------

@router.post("/change-password", summary="Kendi şifreni değiştir")
async def change_password(
    body: ChangePasswordIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Eski şifre WHERE içinde doğrulanıyor: tek ifade, ayrı kontrol yok.
    Etkilenen satır sayısı 0 ise eski şifre yanlış demektir.
    """
    sonuc = await conn.execute(
        """
        UPDATE users
           SET password_hash = crypt($3, gen_salt('bf', 10))
         WHERE id = $1
           AND password_hash = crypt($2, password_hash)
           AND is_active
        """,
        user["id"], body.old_password, body.new_password,
    )
    # asyncpg "UPDATE 1" gibi bir metin döner
    if sonuc.rsplit(" ", 1)[-1] == "0":
        raise HTTPException(400, "Mevcut şifreniz hatalı")
    return {"ok": True}


# ---------------------------------------------------------------------------
# Şifremi unuttum
#
# NASIL ÇALIŞIYOR
# ---------------
# 1. Kullanıcı e-postasını yollar.
# 2. Sunucu 6 haneli kod üretir, e-postayla gönderir ve kodun ÖZETİNİ
#    içeren 15 dakikalık bir jeton döner.
# 3. Kullanıcı kodu ekrana yazar; uygulama kod + jetonu gönderir.
# 4. Sunucu jetondaki özetle gelen kodun özetini karşılaştırır.
#
# Sunucuda hiçbir şey saklanmıyor - ayrı bir tablo açmaya gerek yok.
# Jeton kullanıcının MEVCUT şifre özetinin bir parçasına da bağlı;
# şifre değişince jeton kendiliğinden geçersiz oluyor, yani kod
# ikinci kez kullanılamıyor.
#
# Bağlantı yerine KOD kullanmamızın sebebi: e-postadaki bağlantının
# Flutter uygulamasını açabilmesi için deep link kurulumu gerekirdi.
# Kodu kullanıcı ekrana yazınca o iş tamamen ortadan kalkıyor.
# ---------------------------------------------------------------------------

def _ozet(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


@router.post("/forgot-password", summary="Şifre sıfırlama kodu iste")
async def forgot_password(body: ForgotIn, conn=Depends(get_conn)):
    """
    E-posta kayıtlı olsa da olmasa da AYNI cevabı döner. Farklı cevap
    verseydik, saldırgan hangi adreslerin sistemde olduğunu öğrenirdi.
    """
    row = await conn.fetchrow(
        "SELECT id, password_hash FROM users WHERE lower(email) = lower($1) AND is_active",
        body.email,
    )

    kod = f"{secrets.randbelow(900000) + 100000}"

    if row is not None:
        pw_parmak = row["password_hash"][:20]
        await mail.send_reset_code(body.email, kod)
    else:
        # Kayıtlı olmayan adres: jeton yine üretilir ama hiçbir şifreyle
        # eşleşmeyecek bir parmak izi taşır. Sıfırlama adımında
        # "kod hatalı" döner - yanlış kod girmiş gibi.
        pw_parmak = secrets.token_hex(10)

    simdi = datetime.now(timezone.utc)
    reset_token = jwt.encode(
        {
            "purpose": "pwreset",
            "email": body.email.lower(),
            "code": _ozet(kod),
            "pw": pw_parmak,
            "iat": simdi,
            "exp": simdi + timedelta(minutes=RESET_DAKIKA),
        },
        JWT_SECRET,
        algorithm=JWT_ALG,
    )

    return {
        "reset_token": reset_token,
        "expires_in_minutes": RESET_DAKIKA,
        "mail_sent": mail.is_configured(),
        "detail": "E-posta adresiniz kayıtlıysa sıfırlama kodu gönderildi",
    }


@router.post("/reset-password", summary="Kodla yeni şifre belirle")
async def reset_password(body: ResetIn, conn=Depends(get_conn)):
    try:
        claims = jwt.decode(body.reset_token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.ExpiredSignatureError:
        raise HTTPException(410, "Kodun süresi doldu, yeniden isteyin")
    except jwt.PyJWTError:
        raise HTTPException(400, "Geçersiz sıfırlama isteği")

    if claims.get("purpose") != "pwreset":
        # Giriş jetonu buraya gönderilemesin diye amaç kontrolü
        raise HTTPException(400, "Geçersiz sıfırlama isteği")

    if not secrets.compare_digest(claims.get("code", ""), _ozet(body.code)):
        raise HTTPException(400, "Kod hatalı")

    sonuc = await conn.execute(
        """
        UPDATE users
           SET password_hash = crypt($2, gen_salt('bf', 10))
         WHERE lower(email) = lower($1)
           AND left(password_hash, 20) = $3
           AND is_active
        """,
        claims["email"], body.new_password, claims.get("pw", ""),
    )
    if sonuc.rsplit(" ", 1)[-1] == "0":
        # Ya adres kayıtlı değil ya da şifre bu kod üretildikten sonra
        # değişti; ikisinde de aynı cevabı veriyoruz.
        raise HTTPException(400, "Kod hatalı")

    return {"ok": True, "detail": "Şifreniz güncellendi, giriş yapabilirsiniz"}