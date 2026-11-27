"""
Yönetim — admin web panelinin kullanacağı uç noktalar.

Hepsi ADMIN rolü ister, ama kontrol iki ayrı yerden geliyor:

  YAZMA  (`CALL sp_admin_...`) -> yordamın ilk satırı rolü doğruluyor.
  OKUMA  (doğrudan SELECT)     -> `Depends(require_role("ADMIN"))`.

Okuma uç noktalarında yordam yok, dolayısıyla onları açıkta bırakmak
geçerli token'ı olan her rolün kullanıcı listesini (e-posta, telefon)
okuyabilmesi demekti. require_role aynı veritabanı fonksiyonunu çağırıyor,
yani kural hâlâ tek yerde duruyor.

PAROLA: Python'da değil, SQL tarafında crypt(..., gen_salt('bf',10)) ile
hash'leniyor — giriş sorgusunun kullandığı yöntemle birebir aynı olsun diye.
"""
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..db import get_conn
from ..security import current_user, require_role

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

router = APIRouter(prefix="/admin", tags=["Yönetim"])


class UserIn(BaseModel):
    full_name: str = Field(min_length=2)
    email: str = Field(pattern=EPOSTA, examples=["yeni.gorevli@yardimagi.test"])
    password: str = Field(min_length=6)
    role: str = Field(examples=["VOLUNTEER"],
                      description="ATTENDANT | VOLUNTEER | ADMIN")
    phone: str | None = None
    center_id: int | None = Field(
        default=None, description="Yalnızca ATTENDANT için; diğer rollerde boş"
    )


class ActiveIn(BaseModel):
    is_active: bool


class PasswordIn(BaseModel):
    password: str = Field(min_length=6)


class CenterIn(BaseModel):
    name: str = Field(min_length=2)
    address: str
    latitude: float = Field(examples=[36.2025])
    longitude: float = Field(examples=[36.1606])
    phone: str | None = None
    center_id: int | None = Field(
        default=None, description="Doluysa günceller, boşsa yeni açar"
    )


@router.get("/dashboard", summary="Yönetici özeti")
async def dashboard(user=Depends(require_role("ADMIN")), conn=Depends(get_conn)):
    """Açık talep, yoldaki teslimat, kritik stok, zincir uzunluğu — tek satır."""
    row = await conn.fetchrow("SELECT * FROM v_admin_dashboard")
    return dict(row)


@router.get("/users", summary="Kullanıcı listesi")
async def list_users(user=Depends(require_role("ADMIN")), conn=Depends(get_conn)):
    # password_hash sorguya hiç konmuyor.
    rows = await conn.fetch(
        """
        SELECT u.id, u.full_name, u.email, u.phone, u.role::text AS role,
               u.center_id, c.name AS center_name, u.is_active
          FROM users u
          LEFT JOIN centers c ON c.id = u.center_id
         ORDER BY u.role, u.full_name
        """
    )
    return [dict(r) for r in rows]


@router.get("/users/pending", summary="Onay bekleyen hesaplar")
async def pending_users(user=Depends(require_role("ADMIN")), conn=Depends(get_conn)):
    """
    Kayıt olmuş ama henüz aktif edilmemiş hesaplar - çoğunlukla onay
    bekleyen saha görevlileri.

    Onaylamak için `PATCH /admin/users/{id}/active` ile is_active=true
    gönderin. Reddetmek için hiçbir şey yapmayın ya da hesabı silin.

    Not: yönetici tarafından sonradan pasife alınmış hesaplar da burada
    görünür; `created_at` ikisini ayırmanıza yardım eder.
    """
    rows = await conn.fetch(
        """
        SELECT u.id, u.full_name, u.email, u.phone, u.role::text AS role,
               u.center_id, c.name AS center_name, u.created_at
          FROM users u
          LEFT JOIN centers c ON c.id = u.center_id
         WHERE NOT u.is_active
         ORDER BY u.created_at DESC
        """
    )
    return [dict(r) for r in rows]


@router.post("/users", summary="Yeni kullanıcı aç")
async def create_user(body: UserIn, user=Depends(current_user), conn=Depends(get_conn)):
    row = await conn.fetchrow(
        """
        CALL sp_admin_create_user($1, $2, $3, crypt($4, gen_salt('bf', 10)),
                                  $5::user_role, $6, $7)
        """,
        user["id"], body.full_name, body.email, body.password,
        body.role, body.phone, body.center_id,
    )
    return {"user_id": row["p_user_id"]}


@router.patch("/users/{user_id}/active", summary="Pasife al / geri aç")
async def set_user_active(
    user_id: int, body: ActiveIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Silmek yerine pasife almak tercih edilir: geçmiş teslimat kayıtları
    sahipli kalır. Son aktif admin pasife alınamaz.
    """
    await conn.execute(
        "CALL sp_admin_set_user_active($1, $2, $3)", user["id"], user_id, body.is_active
    )
    return {"ok": True}


@router.post("/centers", summary="Merkez ekle veya güncelle")
async def save_center(
    body: CenterIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """Koordinatlar doğru olmalı: eşleştirme mesafesi bunlardan hesaplanıyor."""
    row = await conn.fetchrow(
        "CALL sp_admin_save_center($1, $2, $3, $4, $5, $6, $7)",
        user["id"], body.name, body.address, body.latitude, body.longitude,
        body.phone, body.center_id,
    )
    return {"center_id": row["p_center_id"]}


@router.get("/chain", summary="Blok zinciri denetimi")
async def chain_audit(user=Depends(require_role("ADMIN")), conn=Depends(get_conn)):
    """
    Sunumda gösterilecek ekran. Zincirin sağlam olup olmadığı ve blok
    blok döküm tek yanıtta.

    Her blok için üç kontrol: teslimat kaydı sonradan değişmiş mi,
    bir önceki bloğa doğru bağlı mı, bloğun kendi hash'i tutuyor mu.
    """
    valid = await conn.fetchval("SELECT fn_chain_is_valid()")
    rows = await conn.fetch("SELECT * FROM v_chain_audit")
    return {"valid": valid, "blocks": [dict(r) for r in rows]}


@router.patch("/users/{user_id}/password", summary="Kullanıcının şifresini sıfırla")
async def reset_user_password(
    user_id: int, body: PasswordIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    E-posta ile sıfırlamanın yedek yolu. Sunum sırasında ağ e-postayı
    engellerse veya kullanıcı e-postasına erişemiyorsa yönetici buradan
    sıfırlar.

    Parola SQL tarafında hash'leniyor - giriş sorgusunun kullandığı
    yöntemle aynı.
    """
    await conn.execute(
        "CALL sp_admin_reset_password($1, $2, crypt($3, gen_salt('bf', 10)))",
        user["id"], user_id, body.password,
    )
    return {"ok": True}