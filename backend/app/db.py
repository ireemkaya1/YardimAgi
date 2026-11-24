"""
Veritabanı bağlantı havuzu.

Neden havuz: her istekte yeni bağlantı açmak pahalıdır. Havuz, açık
bağlantıları tutar ve istek geldiğinde birini ödünç verir.
"""
import json
import os

import asyncpg

DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/yardimagi"
)

_pool: asyncpg.Pool | None = None


async def _init_connection(conn: asyncpg.Connection) -> None:
    """
    Her yeni bağlantı için çalışır.

    jsonb sütunları (örn. v_request_detail.items) varsayılan olarak metin
    gelir. Bu kodek onları Python listesi/sözlüğü olarak çözer; aksi halde
    JSON yanıtının içinde kaçışlanmış bir metin görürsünüz.
    """
    await conn.set_type_codec(
        "jsonb",
        encoder=json.dumps,
        decoder=json.loads,
        schema="pg_catalog",
    )


async def open_pool() -> None:
    global _pool
    _pool = await asyncpg.create_pool(
        DATABASE_URL, min_size=1, max_size=10, init=_init_connection
    )


async def close_pool() -> None:
    if _pool is not None:
        await _pool.close()


async def get_conn():
    """
    FastAPI bağımlılığı. Uç noktada şöyle kullanılır:

        async def endpoint(conn = Depends(get_conn)):
            ...

    İstek bitince bağlantı otomatik olarak havuza geri döner.
    """
    assert _pool is not None, "Havuz açılmadı"
    async with _pool.acquire() as conn:
        yield conn
