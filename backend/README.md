# YardımAğı — Backend (FastAPI)

25 uç nokta, 5 dosya. Projenin çalışması için gereken her şey, fazlası yok.

## Çalıştırma

Veritabanı ayakta olmalı (`database` klasöründe `docker compose up -d`).

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate          # Windows  (macOS/Linux: source .venv/bin/activate)
pip install -r requirements.txt
copy .env.example .env          # JWT_SECRET'ı değiştirin
uvicorn app.main:app --reload
```

→ **http://localhost:8000/docs**

Denemek için: `POST /auth/login` → *Try it out* →
`{"email": "saha1@yardimagi.test", "password": "Demo123!"}` → dönen
`access_token`'ı sağ üstteki **Authorize** düğmesine yapıştırın.

---

## Hangi ekran hangi uç noktayı kullanır

### Gönüllü (mobil)

| Ekran | Uç nokta |
|---|---|
| Giriş | `POST /auth/login` |
| Açık görevler | `GET /tasks/available` |
| Görevi al | `POST /tasks/{id}/claim` |
| Benim görevim | `GET /tasks/mine` |
| Paket hazır, QR al | `POST /deliveries/{id}/prepare` |
| Merkezden çıkış | `POST /deliveries/scan-pickup` |
| Görevi bırak | `POST /deliveries/{id}/cancel` |

### Saha görevlisi (mobil)

| Ekran | Uç nokta |
|---|---|
| Giriş | `POST /auth/login` |
| Açık talepler | `GET /requests/open` |
| Yeni talep | `GET /categories` + `POST /requests` |
| Talep detayı | `GET /requests/{id}` |
| Merkez seç | `POST /requests/{id}/match` |
| Neden bu merkez | `GET /requests/{id}/matching-analysis` |
| Talebi iptal et | `POST /requests/{id}/cancel` |
| Merkezimin kuyruğu | `GET /centers/{id}/deliveries` |
| Teslimi onayla | `POST /deliveries/confirm` |
| Stok panosu | `GET /centers/{id}/stocks` |
| Stok girişi | `POST /stocks/add` |

### Yönetici (web)

| Ekran | Uç nokta |
|---|---|
| Giriş | `POST /auth/login` |
| Pano | `GET /admin/dashboard` |
| Kullanıcılar | `GET /admin/users`, `POST /admin/users`, `PATCH /admin/users/{id}/active` |
| Merkezler | `GET /centers`, `POST /admin/centers` |
| Zincir denetimi | `GET /admin/chain` |

---

## Dosyalar

| Dosya | İçerik |
|---|---|
| `app/main.py` | Uygulama, CORS, router'lar |
| `app/db.py` | Bağlantı havuzu + jsonb kodeki |
| `app/security.py` | Parola kontrolü, JWT |
| `app/errors.py` | `YA###` → HTTP çevirisi (tek yer) |
| `app/routers/auth.py` | Giriş |
| `app/routers/requests.py` | Talepler ve eşleştirme |
| `app/routers/deliveries.py` | Görevler, QR akışı, teslimat |
| `app/routers/data.py` | Merkez, kategori, stok |
| `app/routers/admin.py` | Yönetim ve zincir |

---

## Tasarım

**Yazma** → `CALL sp_...`  ·  **Okuma** → `SELECT * FROM v_...`

Stok rezervasyonu, durum geçişleri ve zincire yazma veritabanında.
Burada tekrar yazılmıyor. Rol kontrolü de orada: gönüllü talep açmayı
denerse yordam `YA403` fırlatır, `errors.py` 403'e çevirir.

### Üç kalıp

Yeni uç nokta eklerseniz bunlardan birini kopyalayın.

```python
# Liste okuma
rows = await conn.fetch("SELECT * FROM v_stock_overview WHERE center_id = $1", cid)
return [dict(r) for r in rows]

# Yazma, geri değer yok
await conn.execute("CALL sp_cancel_request($1, $2, $3)", rid, user["id"], reason)

# Yazma, INOUT geri değer var  (anahtar = yordamın parametre adı)
row = await conn.fetchrow("CALL sp_claim_task($1, $2)", rid, user["id"])
return {"delivery_id": row["p_delivery_id"]}
```

### Hata kodları

| Kod | Arayüzde ne yapmalı |
|---|---|
| 401 | Giriş ekranına at |
| 403 | "Yetkiniz yok" |
| 404 | "Bulunamadı" |
| 409 | Listeyi yenile, mesajı göster (görev alınmış, stok yetersiz) |
| 410 | "QR süresi doldu, yenisini üretin" |
| 422 | Mesajı doğrudan göster |

Her yanıtın gövdesinde Türkçe bir `detail` alanı var.

---

## Telefondan test

```bash
uvicorn app.main:app --reload --host 0.0.0.0
```

Flutter tarafında `http://192.168.1.X:8000` (bilgisayarınızın yerel IP'si).
İkisi aynı Wi-Fi'de olmalı. İlk çalıştırmada Windows güvenlik duvarı
izin soracak — **izin verin**, yoksa telefon bağlanamaz ve hata mesajı
hiçbir şey söylemez.

**Bunu erken deneyin**, 15. haftada değil.

---

## Çıkarılanlar

Veritabanı daha fazlasını destekliyor ama bu uç noktalar projenin işine
yaramıyordu, karmaşa yaratıyordu:

- Rapor görünümleri (`v_request_timeline`, `v_matching_metrics`,
  `v_stock_utilization`) — final raporuna sayı lazım olursa SQL'den
  doğrudan çekin, uç noktaya gerek yok
- Yapay zeka modülü (`sp_save_ai_prediction` ve iki görünüm) — o modülü
  yapmaya karar verirseniz eklenir
- Kullanıcı rol/merkez/parola değiştirme, anonimleştirme, silme —
  yordamlar duruyor, gerekirse eklenir
- Kategori yönetimi, merkez pasife alma, stok düzeltme
- `/auth/me`, `/requests/unmatched`, `/matches/{id}/reject`,
  QR yenileme, stok geçmişi, tek teslimat doğrulama

Hepsinin yordamı veritabanında hazır; ihtiyaç duyarsanız yukarıdaki üç
kalıptan biriyle 5 satırda eklenir.
