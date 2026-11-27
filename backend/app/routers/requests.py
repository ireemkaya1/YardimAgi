"""
Talepler.

Yazma  -> CALL sp_...   (INOUT değerleri satır olarak döner)
Okuma  -> SELECT * FROM v_...

YAZMA uç noktalarında rol kontrolü burada yok; yordamlar yapıyor. Gönüllü
talep açmayı denerse veritabanı YA403 fırlatır, errors.py onu 403'e çevirir.

OKUMA uç noktalarında yordam olmadığı için require_role gerekiyor.
v_open_requests ve v_request_detail görünümleri afetzedenin adını ve
telefonunu içeriyor (contact_name, contact_phone); bunlar yalnızca saha
görevlisine ve yöneticiye açık.

Gönüllünün göreceği ekran bunlar değil: /tasks/available ve /tasks/mine.
O görünümlerde iletişim bilgisi hiç yok, gönüllü de zaten adresten
fazlasına ihtiyaç duymuyor.
"""
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..db import get_conn
from ..security import current_user, require_role

router = APIRouter(prefix="/requests", tags=["Talepler"])


class Item(BaseModel):
    category_code: str = Field(examples=["WATER"])
    quantity: int = Field(gt=0, examples=[10])


class RequestIn(BaseModel):
    latitude: float = Field(examples=[36.2025])
    longitude: float = Field(examples=[36.1606])
    items: list[Item] = Field(min_length=1)
    people_number: int = Field(default=1, ge=1)
    urgency: str = Field(default="MEDIUM", examples=["HIGH"],
                         description="LOW | MEDIUM | HIGH | CRITICAL")
    address: str | None = None
    description: str | None = None
    contact_name: str | None = None
    contact_phone: str | None = None


class ReasonIn(BaseModel):
    reason: str = Field(min_length=3, examples=["Afetzede başka merkeze taşındı"])


@router.post("", summary="Yeni yardım talebi aç")
async def create_request(
    body: RequestIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    items alanı NEDEN json.dumps ile metne çevrilmiyor
    ---------------------------------------------------
    db.py içinde jsonb için bir kodek kurulu: encoder=json.dumps. Yani
    jsonb parametrelerini asyncpg kendisi JSON'a çeviriyor. Burada bir kez
    daha çevirirsek değer iki kez kodlanır ve veritabanına dizi değil
    METİN olarak gider; sp_create_request'in ilk kontrolü
    (jsonb_typeof(p_items) <> 'array') buna takılır ve "Talep en az bir
    kalem içermeli" hatası verir.

    Doğrusu: Python listesini olduğu gibi vermek.
    """
    row = await conn.fetchrow(
        """
        CALL sp_create_request($1, $2, $3, $4::jsonb, $5, $6::request_urgency,
                               $7, $8, $9, $10)
        """,
        user["id"], body.latitude, body.longitude,
        [i.model_dump() for i in body.items],
        body.people_number, body.urgency, body.address, body.description,
        body.contact_name, body.contact_phone,
    )
    return {"request_id": row["p_request_id"]}


@router.get("/open", summary="Açık talepler")
async def open_requests(
    limit: int = Query(50, le=200),
    user=Depends(require_role("ATTENDANT", "ADMIN")),
    conn=Depends(get_conn),
):
    """
    Aciliyet ve yaşa göre sıralı. Saha görevlisinin ana ekranı.

    Gönüllüye KAPALI: yanıt afetzede telefonunu içeriyor. Gönüllünün
    karşılığı /tasks/available.
    """
    rows = await conn.fetch("SELECT * FROM v_open_requests LIMIT $1", limit)
    return [dict(r) for r in rows]


@router.get("/mine", summary="Benim açtığım talepler")
async def my_requests(
    limit: int = Query(50, le=200), user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Görevlinin kendi açtığı talepler - teslim edilmiş ve iptal edilmiş
    olanlar dahil. "Benim taleplerim" ekranı için.

    Not: `/{request_id}` TANIMINDAN ÖNCE gelmeli, yoksa FastAPI "mine"
    kelimesini id sanar.
    """
    rows = await conn.fetch(
        """
        SELECT * FROM v_request_detail
         WHERE created_by = $1
         ORDER BY created_at DESC
         LIMIT $2
        """,
        user["id"], limit,
    )
    return [dict(r) for r in rows]


@router.get("/{request_id}", summary="Talep detayı")
async def request_detail(
    request_id: int,
    user=Depends(require_role("ATTENDANT", "ADMIN")),
    conn=Depends(get_conn),
):
    """
    Gönüllüye KAPALI: yanıt afetzede adını ve telefonunu içeriyor, hem de
    herhangi bir id ile sorgulanabiliyor. Gönüllü kendi görevinin
    ayrıntısını /tasks/mine ile görüyor.
    """
    row = await conn.fetchrow("SELECT * FROM v_request_detail WHERE id = $1", request_id)
    if row is None:
        raise HTTPException(404, "Talep bulunamadı")
    return dict(row)


@router.get("/{request_id}/matching-analysis", summary="Hangi merkez neden seçilemiyor")
async def matching_analysis(
    request_id: int,
    user=Depends(require_role("ATTENDANT", "ADMIN")),
    conn=Depends(get_conn),
):
    """
    Her merkez için mesafe, karşılayabiliyor mu, hangi kalem eksik.
    "Merkez B daha yakın ama 10 su eksik" gerekçesini ekranda göstermek için.
    """
    rows = await conn.fetch("SELECT * FROM fn_matching_analysis($1)", request_id)
    return [dict(r) for r in rows]


@router.post("/{request_id}/match", summary="En uygun merkezi seç")
async def run_matching(
    request_id: int, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Uygun merkez bulunamazsa HATA VERMEZ: matched=false döner ve talep
    OPEN kalır. Bu normal bir sonuç.
    """
    row = await conn.fetchrow(
        "CALL sp_run_matching($1, $2, 'NEAREST'::match_strategy)",
        request_id, user["id"],
    )
    return {
        "match_id": row["p_match_id"],
        "center_id": row["p_center_id"],
        "distance_km": row["p_distance_km"],
        "matched": row["p_match_id"] is not None,
    }


@router.post("/{request_id}/cancel", summary="Talebi iptal et")
async def cancel_request(
    request_id: int, body: ReasonIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """Açık görev varsa o da iptal edilir, rezerve stok geri döner."""
    await conn.execute(
        "CALL sp_cancel_request($1, $2, $3)", request_id, user["id"], body.reason
    )
    return {"ok": True}