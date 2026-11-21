# YardımAğı — Veritabanı

## Kurulum

```bash
cp .env.example .env
docker compose up -d
```

Hazır olduğunda kontrol:

```bash
docker compose exec db psql -U postgres -d yardimagi -c "SELECT * FROM v_install_check;"
```

Tüm satırlarda **TAMAM** yazmalı.

## Bağlantı

```
postgresql://postgres:postgres@localhost:5432/yardimagi
```

## Komutlar

| Komut | Ne yapar |
|---|---|
| `docker compose up -d` | Başlatır |
| `docker compose logs -f db` | Kurulum günlüğünü gösterir |
| `docker compose down` | Durdurur, veri kalır |
| `docker compose down -v` | **Sıfırlar**, veriyi de siler |

`initdb/` içindeki dosyalar yalnızca veritabanı **ilk kez** oluşturulurken
çalışır. Şemayı değiştirdiyseniz `down -v` yapıp yeniden `up` edin.

## Dosyalar

| Dosya | İçerik |
|---|---|
| `initdb/01_schema.sql` | Şema: 14 tablo, 22 fonksiyon, 19 tetikleyici, 23 yordam, 19 view + genesis bloğu ve 8 kategori |
| `initdb/02_demo.sql` | Demo merkez, kullanıcı ve stoklar. İstemezseniz `docker-compose.yml` içindeki ilgili satırı silin |

Demo kullanıcılarının şifresi `Demo123!` (örn. `saha1@yardimagi.test`).
