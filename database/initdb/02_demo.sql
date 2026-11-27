-- =====================================================================
--  YardımAğı - 10_demo.sql : DEMO verisi (canlı ortamda ÇALIŞTIRMAYIN)
--
--  Dokümandaki 6.1 örneğini kurar:
--    Merkez A = 8 km, 100 su | Merkez B = 2 km, su YOK | Merkez C = 4 km, 40 su
--  Böylece "en yakın merkez değil, stoğu yeten en yakın merkez" kuralı
--  gözle görülür. tests/e2e_test.sql bu verinin kurulu olmasını bekler.
--
--  Tüm demo kullanıcılarının şifresi: Demo123!
--  Görevliler bir merkeze bağlıdır (stok ve paket işlemleri için).
--  Gönüllüler merkeze bağlı değildir; hepsi her merkezden görev alabilir.
--  Docker'da LOAD_DEMO=false yaparsanız bu dosya atlanır.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 3) Merkezler (talep referans noktası: 36.202500, 36.160600)
-- ---------------------------------------------------------------------
INSERT INTO centers (name, address, phone, latitude, longitude) VALUES
    ('Merkez A - Güney Spor Salonu',    'Demo adres A', '03260000001', 36.130500, 36.160600),  -- ~8 km
    ('Merkez B - Kuzey Okul Bahçesi',   'Demo adres B', '03260000002', 36.220500, 36.160600),  -- ~2 km
    ('Merkez C - Doğu Kültür Merkezi',  'Demo adres C', '03260000003', 36.202500, 36.205200),  -- ~4 km
    ('Merkez D - Sahil Lojistik Deposu','Demo adres D', '03260000004', 36.587200, 36.173500);  -- ~43 km

-- ---------------------------------------------------------------------
-- 4) Kullanıcılar (3 rol)
-- ---------------------------------------------------------------------
INSERT INTO users (full_name, email, phone, password_hash, role, center_id)
SELECT v.full_name, v.email, v.phone, crypt('Demo123!', gen_salt('bf', 10)), v.role::user_role,
       (SELECT id FROM centers WHERE name LIKE v.center_prefix || '%')
FROM (VALUES
    -- Admin ve gönüllüler merkeze bağlanamaz / bağlı değildir
    ('Koordinatör Admin',    'admin@yardimagi.test',       '05550000001', 'ADMIN',      NULL),
    -- Görevliler: biri Merkez C sorumlusu, biri merkezi olmayan saha görevlisi
    ('Görevli Ayşe (C)',     'saha1@yardimagi.test',       '05550000002', 'ATTENDANT', 'Merkez C'),
    ('Görevli Mehmet (saha)','saha2@yardimagi.test',       '05550000003', 'ATTENDANT', NULL),
    ('Görevli Burak (A)',    'saha3@yardimagi.test',       '05550000004', 'ATTENDANT', 'Merkez A'),
    -- Gönüllüler: hiçbiri merkeze bağlı değil, hepsi her merkezden alabilir
    ('Gönüllü Ali',          'gonullu.a1@yardimagi.test',  '05550000021', 'VOLUNTEER',  NULL),
    ('Gönüllü Zeynep',       'gonullu.b1@yardimagi.test',  '05550000022', 'VOLUNTEER',  NULL),
    ('Gönüllü Can',          'gonullu.c1@yardimagi.test',  '05550000023', 'VOLUNTEER',  NULL),
    ('Gönüllü Elif',         'gonullu.c2@yardimagi.test',  '05550000024', 'VOLUNTEER',  NULL),
    ('Gönüllü Deniz',        'gonullu.d1@yardimagi.test',  '05550000025', 'VOLUNTEER',  NULL),
    ('Gönüllü Mert',         'gonullu.yeni@yardimagi.test','05550000026', 'VOLUNTEER',  NULL)
) AS v(full_name, email, phone, role, center_prefix);

-- ---------------------------------------------------------------------
-- 5) Stok girişleri (defter üzerinden: her giriş bir IN hareketi yazar)
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_admin BIGINT := (SELECT id FROM users WHERE email = 'admin@yardimagi.test');
    v_sid   BIGINT;
    r       RECORD;
BEGIN
    FOR r IN
        SELECT c.id AS center_id, cat.id AS category_id, v.qty
        FROM (VALUES
            -- Merkez A: bol su, uzak (8 km)
            ('Merkez A', 'WATER', 100), ('Merkez A', 'BLANKET', 50), ('Merkez A', 'FOOD', 40),
            ('Merkez A', 'HYGIENE', 30),
            -- Merkez B: su YOK, en yakın (2 km) -> su isteyen talepte elenir
            ('Merkez B', 'BLANKET', 30), ('Merkez B', 'FOOD', 50), ('Merkez B', 'BABY_SUPPLY', 20),
            -- Merkez C: 40 su, 4 km -> 10 su + 4 battaniye talebinde seçilir
            ('Merkez C', 'WATER', 40), ('Merkez C', 'BLANKET', 20), ('Merkez C', 'FOOD', 30),
            ('Merkez C', 'HYGIENE', 15), ('Merkez C', 'MEDICAL', 10),
            -- Merkez D: büyük depo, çok uzak
            ('Merkez D', 'WATER', 1000), ('Merkez D', 'BLANKET', 500), ('Merkez D', 'FOOD', 400),
            ('Merkez D', 'HYGIENE', 300), ('Merkez D', 'BABY_SUPPLY', 200), ('Merkez D', 'MEDICAL', 100),
            ('Merkez D', 'CLOTHING', 300), ('Merkez D', 'SHELTER', 50)
        ) AS v(center_prefix, code, qty)
        JOIN centers c      ON c.name LIKE v.center_prefix || '%'
        JOIN categories cat ON cat.code = v.code
    LOOP
        CALL sp_stock_add(r.center_id, r.category_id, r.qty, v_admin, 'Açılış stoğu (demo)', v_sid);
    END LOOP;
END;
$$;

-- Kritik stok eşikleri (miktar değil eşik olduğu için doğrudan güncellenir)
UPDATE stocks s SET low_stock_alert = CASE WHEN c.code IN ('WATER','FOOD') THEN 20 ELSE 5 END
FROM categories c WHERE c.id = s.category_id;
