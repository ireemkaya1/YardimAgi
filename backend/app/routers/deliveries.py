"""
Görevler ve teslimat.

Akış: görev üstlen -> paket hazırla (PICKUP QR) -> merkezden çık (QR okut,
DROPOFF QR al) -> sahada teslim onayla (QR okut) -> zincire blok yazılır.

Stok hareketleri burada YOK. Teslimat satırı değiştikçe tetikleyici
rezerve ediyor, serbest bırakıyor veya düşüyor.
"""
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..db import get_conn
from ..security import current_user, require_role

router = APIRouter(tags=["Görevler ve teslimat"])


class TokenIn(BaseModel):
    """
    QR token'ı gövdede taşınır, adres satırında değil: adres satırındaki
    değerler sunucu günlüklerine ve tarayıcı geçmişine düşer.
    """
    token: str = Field(min_length=16)


class ReasonIn(BaseModel):
    reason: str = Field(min_length=3, examples=["Araç arızalandı"])


# --------------------------------------------------------------------------
# Listeler
# --------------------------------------------------------------------------

@router.get("/tasks/available", summary="Üstlenilmeyi bekleyen görevler")
async def available_tasks(user=Depends(current_user), conn=Depends(get_conn)):
    """Gönüllünün ana ekranı. Hangi merkezden alınacak, nereye gidecek, kaç km."""
    rows = await conn.fetch("SELECT * FROM v_available_tasks")
    return [dict(r) for r in rows]


@router.get("/tasks/mine", summary="Gönüllünün kendi görevi")
async def my_tasks(
    active_only: bool = True, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    "Şu an bir görevim var mı, hangi aşamada." Adres, kalemler, zaman
    çizelgesi hepsi burada.

    Not: `/tasks/{request_id}/claim` TANIMINDAN ÖNCE gelmeli; sabit
    adresler değişkenlerden önce yazılır, yoksa FastAPI "mine" kelimesini
    id sanar.
    """
    rows = await conn.fetch(
        """
        SELECT * FROM v_delivery_detail
         WHERE volunteer_id = $1
           AND ($2 = FALSE OR status IN ('ASSIGNED','PREPARING','IN_TRANSIT'))
         ORDER BY assigned_at DESC
        """,
        user["id"], active_only,
    )
    return [dict(r) for r in rows]


@router.get("/centers/{center_id}/deliveries", summary="Merkezin teslimat kuyruğu")
async def center_deliveries(
    center_id: int,
    user=Depends(require_role("ATTENDANT", "ADMIN")),
    conn=Depends(get_conn),
):
    """
    Görevlinin ekranı: hangi paket hazırlanmayı bekliyor, hangisi yolda.

    Gönüllüye KAPALI: yanıt gönüllü telefonunu (volunteer_phone) içeriyor
    ve her merkezin kuyruğu sorgulanabiliyor. Gönüllü kendi görevini
    /tasks/mine ile görüyor.
    """
    rows = await conn.fetch(
        """
        SELECT * FROM v_delivery_detail
         WHERE center_id = $1
           AND status IN ('ASSIGNED','PREPARING','IN_TRANSIT')
         ORDER BY urgency DESC, assigned_at
        """,
        center_id,
    )
    return [dict(r) for r in rows]


# --------------------------------------------------------------------------
# Akış
# --------------------------------------------------------------------------

@router.post("/tasks/{request_id}/claim", summary="Görevi üstlen")
async def claim_task(
    request_id: int, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Stok rezervasyonunu tetikleyici yapıyor, ayrı çağrı yok.
    İki gönüllü aynı anda basarsa ikincisi 409 alır.
    """
    row = await conn.fetchrow("CALL sp_claim_task($1, $2)", request_id, user["id"])
    return {"delivery_id": row["p_delivery_id"]}


@router.post("/deliveries/{delivery_id}/prepare", summary="Paket hazır, PICKUP QR üret")
async def mark_prepared(
    delivery_id: int, user=Depends(current_user), conn=Depends(get_conn)
):
    """Ham token yalnızca burada bir kez döner; veritabanında hash'i saklanır."""
    row = await conn.fetchrow("CALL sp_mark_prepared($1, $2)", delivery_id, user["id"])
    return {"pickup_token": row["p_pickup_token"]}


@router.post("/deliveries/scan-pickup", summary="Merkezden çıkış: PICKUP QR okut")
async def scan_pickup(body: TokenIn, user=Depends(current_user), conn=Depends(get_conn)):
    """Karşılığında DROPOFF token'ı döner — sahada teslim ederken o okutulacak."""
    row = await conn.fetchrow("CALL sp_scan_pickup($1, $2)", body.token, user["id"])
    return {
        "delivery_id": row["p_delivery_id"],
        "dropoff_token": row["p_dropoff_token"],
    }


@router.post("/deliveries/confirm", summary="Teslimi onayla, zincire yaz")
async def confirm_delivery(
    body: TokenIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Tek çağrıyla: stok düşer, teslimat ve talep DELIVERED olur, blok
    zincire yazılır. Hepsini tetikleyiciler yapıyor.

    GÖREVLER AYRILIĞI: paketi merkezden çıkaran kişi aynı teslimatı
    onaylayamaz, denerse 403 alır. Test ederken iki farklı görevli
    hesabı kullanmanız gerekir.
    """
    row = await conn.fetchrow("CALL sp_confirm_delivery($1, $2)", body.token, user["id"])
    return {"delivery_id": row["p_delivery_id"], "block_hash": row["p_block_hash"]}


@router.post("/deliveries/{delivery_id}/cancel", summary="Görevi bırak / iptal et")
async def cancel_delivery(
    delivery_id: int, body: ReasonIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """Rezerve stok serbest bırakılır, talep yeniden açık görev olur."""
    await conn.execute(
        "CALL sp_cancel_delivery($1, $2, $3)", delivery_id, user["id"], body.reason
    )
    return {"ok": True}