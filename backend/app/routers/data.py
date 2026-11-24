"""
Merkez, kategori ve stok.

Stok tablosuna doğrudan yazılamaz — tetikleyici engeller. Her hareket
deftere yazılır, bakiyeyi tetikleyici hesaplar. Bu yüzden burada UPDATE
yok, yalnızca yordam çağrısı var.
"""
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..db import get_conn
from ..security import current_user

router = APIRouter(tags=["Merkez, kategori, stok"])


class StockAddIn(BaseModel):
    center_id: int
    category_id: int
    quantity: int = Field(gt=0, examples=[50])
    note: str | None = Field(default=None, examples=["Bağış girişi"])


@router.get("/centers", summary="Yardım merkezleri")
async def list_centers(user=Depends(current_user), conn=Depends(get_conn)):
    rows = await conn.fetch(
        """
        SELECT id, name, address, phone, latitude, longitude
          FROM centers WHERE is_active ORDER BY name
        """
    )
    return [dict(r) for r in rows]


@router.get("/categories", summary="Yardım kategorileri")
async def list_categories(user=Depends(current_user), conn=Depends(get_conn)):
    """
    Talep açma ekranındaki liste. Talep gönderirken `code` alanı
    kullanılır (WATER, BLANKET gibi).
    """
    rows = await conn.fetch(
        "SELECT id, code, name, unit FROM categories WHERE is_active ORDER BY name"
    )
    return [dict(r) for r in rows]


@router.get("/centers/{center_id}/stocks", summary="Merkezin stok panosu")
async def center_stocks(
    center_id: int, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Kategori bazında mevcut, rezerve ve kullanılabilir miktar.
    `is_low` kritik seviyenin altındakileri işaretler.
    """
    rows = await conn.fetch(
        "SELECT * FROM v_stock_overview WHERE center_id = $1 ORDER BY category_name",
        center_id,
    )
    return [dict(r) for r in rows]


@router.post("/stocks/add", summary="Merkeze ürün girişi")
async def stock_add(
    body: StockAddIn, user=Depends(current_user), conn=Depends(get_conn)
):
    """
    Görevli yalnızca kendi merkezine giriş yapabilir, başka merkez
    denerse 403. Stok satırı yoksa yordam 0 ile açar.
    """
    row = await conn.fetchrow(
        "CALL sp_stock_add($1, $2, $3, $4, $5)",
        body.center_id, body.category_id, body.quantity, user["id"], body.note,
    )
    return {"stock_id": row["p_stock_id"]}
