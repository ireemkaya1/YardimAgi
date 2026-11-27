-- =====================================================================
--  YardımAğı - Blok içeriği güncellemesi
--
--  NE DEĞİŞİYOR
--  ------------
--  Zincire yazılan özete iki alan ekleniyor:
--      picked_up_by  : paketi merkezden çıkaran kişi
--      prepared_by   : paketi hazırlayan kişi
--      verified_by   : teslimi onaylayan kişi
--
--  NEDEN
--  -----
--  Sistemin en güçlü kuralı görevler ayrılığı: paketi merkezden çıkaran
--  kişi teslimi onaylayamıyor (sp_confirm_delivery, YA403). Bu kural
--  teslim anında uygulanıyordu ama ZİNCİRE YAZILMIYORDU. Yani zincir
--  "bu teslimatı kim onayladı" sorusuna cevap veremiyordu; cevap
--  yalnızca deliveries tablosunda duruyordu ve o tablo yönetici
--  yetkisiyle değiştirilebilir.
--
--  Bu değişiklikten sonra zincir iki kişinin farklı olduğunu da
--  kanıtlıyor. Biri kaydı sonradan değiştirip "onaylayan bendim" ya da
--  "ben değildim" demeye kalkarsa fn_chain_is_valid() false döner.
--
--  ÖNEMLİ - SIRALAMA
--  -----------------
--  Mevcut blokların delivery_hash değerleri ESKİ özete göre
--  hesaplanmıştı. Bu dosyayı çalışan bir veritabanına uygularsanız o
--  bloklar geçersiz görünür (delivery_hash_ok = false). Bu bir hata
--  değil, beklenen sonuç.
--
--  Doğru sıra:
--    1) Bu dosyayı kalıcı hale getirin (aşağıdaki nota bakın)
--    2) docker compose down -v
--    3) docker compose up -d
--    4) Yeni bir teslimat akışı çalıştırın
--    5) SELECT fn_chain_is_valid();   ->  true
--
--  KALICI HALE GETİRME
--  -------------------
--  database klasörünüzde "initdb" klasörü VARSA:
--      Bu dosyayı oraya "03_blok_icerigi.sql" adıyla kopyalayın.
--      initdb dosyaları alfabetik çalışır, yani 01_schema ve 02_demo
--      dosyalarından SONRA çalışıp bu fonksiyonu günceller.
--
--  "sql" ve "docker" klasörleriniz varsa:
--      sql/04_functions.sql içindeki fn_delivery_payload fonksiyonunu
--      aşağıdakiyle değiştirin. (docker/init.sh dosya listesini elle
--      sayıyor, yeni dosyayı kendiliğinden almaz.)
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_delivery_payload(p_delivery_id BIGINT)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    d       deliveries;
    v_items TEXT;
BEGIN
    SELECT * INTO d FROM deliveries WHERE id = p_delivery_id;
    IF NOT FOUND OR d.status <> 'DELIVERED' THEN
        RETURN NULL;   -- yalnızca teslim edilmiş kayıtlar hashlenir
    END IF;

    SELECT string_agg(format('{"category_id":%s,"quantity":%s}', i.category_id, i.quantity),
                      ',' ORDER BY i.category_id)
      INTO v_items
      FROM request_items i WHERE i.request_id = d.request_id;

    -- Anahtar sırası ALFABETİK ve sabit. Sıra değişirse hash değişir ve
    -- daha önce yazılmış bloklar geçersiz görünür.
    --
    -- COALESCE(...,'null') : alan boşsa format() boş metin üretir ve
    -- JSON bozulur. Bozuk JSON sessizce yanlış hash demektir; o yüzden
    -- geçerli JSON null'u yazılıyor.
    --
    -- Afetzedenin adı ve telefonu burada YOK (KVKK). QR token da yok:
    -- token bir anahtardır, kullanıldıktan sonra değersizdir ve kalıcı
    -- denetim kaydına anahtar yazılmaz.
    RETURN format(
        '{"center_id":%s,"delivered_at":"%s","delivery_id":%s,"items":[%s],'
        '"picked_up_at":"%s","picked_up_by":%s,"prepared_by":%s,'
        '"request_id":%s,"verified_by":%s,"volunteer_id":%s}',
        d.center_id, fn_ts_canonical(d.delivered_at), d.id, COALESCE(v_items, ''),
        fn_ts_canonical(d.picked_up_at),
        COALESCE(d.picked_up_by::TEXT, 'null'),
        COALESCE(d.prepared_by::TEXT, 'null'),
        d.request_id,
        COALESCE(d.delivered_verified_by::TEXT, 'null'),
        COALESCE(d.volunteer_id::TEXT, 'null'));
END;
$$;

COMMENT ON FUNCTION fn_delivery_payload(BIGINT) IS
    'Teslimatın zincire girecek özeti. Zimmet zincirini (hazırlayan, '
    'çıkaran, taşıyan, onaylayan) içerir; kişisel veri ve QR token '
    'içermez. Anahtar sırası alfabetiktir ve değiştirilemez.';
