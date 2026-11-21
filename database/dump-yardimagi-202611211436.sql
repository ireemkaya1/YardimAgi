--
-- PostgreSQL database dump
--

\restrict hbLVrdR8XiiGisTrd3tPFzdOA6CDvLUvggIdh0XA6gNevl1fw2wcvmBDJJmJxkt

-- Dumped from database version 16.15 (Debian 16.15-1.pgdg13+2)
-- Dumped by pg_dump version 18.6

-- Started on 2026-11-21 14:36:49

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 2 (class 3079 OID 16389)
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- TOC entry 3893 (class 0 OID 0)
-- Dependencies: 2
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- TOC entry 985 (class 1247 OID 16460)
-- Name: delivery_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.delivery_status AS ENUM (
    'ASSIGNED',
    'PREPARING',
    'IN_TRANSIT',
    'DELIVERED',
    'CANCELLED'
);


--
-- TOC entry 1039 (class 1247 OID 25253)
-- Name: match_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.match_status AS ENUM (
    'ACCEPTED',
    'REJECTED',
    'EXPIRED'
);


--
-- TOC entry 994 (class 1247 OID 16498)
-- Name: match_strategy; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.match_strategy AS ENUM (
    'NEAREST',
    'RANDOM',
    'FIRST_AVAILABLE'
);


--
-- TOC entry 991 (class 1247 OID 16492)
-- Name: qr_purpose; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.qr_purpose AS ENUM (
    'PICKUP',
    'DROPOFF'
);


--
-- TOC entry 982 (class 1247 OID 16444)
-- Name: request_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.request_status AS ENUM (
    'OPEN',
    'MATCHED',
    'ASSIGNED',
    'PREPARING',
    'IN_TRANSIT',
    'DELIVERED',
    'CANCELLED'
);


--
-- TOC entry 979 (class 1247 OID 16434)
-- Name: request_urgency; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.request_urgency AS ENUM (
    'LOW',
    'MEDIUM',
    'HIGH',
    'CRITICAL'
);


--
-- TOC entry 988 (class 1247 OID 16480)
-- Name: stock_tx_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.stock_tx_type AS ENUM (
    'IN',
    'RESERVE',
    'RELEASE',
    'OUT',
    'CORRECTION'
);


--
-- TOC entry 976 (class 1247 OID 16427)
-- Name: user_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.user_role AS ENUM (
    'ATTENDANT',
    'VOLUNTEER',
    'ADMIN'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 236 (class 1259 OID 16821)
-- Name: blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.blocks (
    block_index bigint NOT NULL,
    delivery_id bigint,
    delivery_hash character(64) NOT NULL,
    previous_hash character(64) NOT NULL,
    current_hash character(64) NOT NULL,
    block_timestamp timestamp with time zone NOT NULL,
    CONSTRAINT blocks_block_index_check CHECK ((block_index >= 0)),
    CONSTRAINT ck_blocks_genesis CHECK (((block_index = 0) = (delivery_id IS NULL))),
    CONSTRAINT ck_blocks_hex CHECK (((delivery_hash ~ '^[0-9a-f]{64}$'::text) AND (previous_hash ~ '^[0-9a-f]{64}$'::text) AND (current_hash ~ '^[0-9a-f]{64}$'::text)))
);


--
-- TOC entry 326 (class 1255 OID 25106)
-- Name: fn_append_block(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_append_block(p_delivery_id bigint) RETURNS public.blocks
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_last blocks;
    v_new  blocks;
    v_dh   TEXT;
    v_ts   TIMESTAMPTZ := date_trunc('second', now());
BEGIN
    -- Eşzamanlı iki teslimat aynı block_index'i almasın
    PERFORM pg_advisory_xact_lock(hashtext('yardimagi_chain'));
    PERFORM fn_init_chain();

    IF EXISTS (SELECT 1 FROM blocks WHERE delivery_id = p_delivery_id) THEN
        RAISE EXCEPTION 'Teslimat % zaten zincirde', p_delivery_id USING ERRCODE = 'YA409';
    END IF;

    v_dh := fn_delivery_hash(p_delivery_id);
    IF v_dh IS NULL THEN
        RAISE EXCEPTION 'Teslimat % DELIVERED değil, bloğa eklenemez', p_delivery_id USING ERRCODE = 'YA422';
    END IF;

    SELECT * INTO v_last FROM blocks ORDER BY block_index DESC LIMIT 1;

    INSERT INTO blocks (block_index, delivery_id, delivery_hash, previous_hash, current_hash, block_timestamp)
    VALUES (v_last.block_index + 1, p_delivery_id, v_dh, v_last.current_hash,
            fn_block_hash(v_last.block_index + 1, v_dh, v_last.current_hash, v_ts), v_ts)
    RETURNING * INTO v_new;
    RETURN v_new;
END;
$$;


--
-- TOC entry 312 (class 1255 OID 25104)
-- Name: fn_block_hash(bigint, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_block_hash(p_block_index bigint, p_delivery_hash text, p_previous_hash text, p_ts timestamp with time zone) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT fn_sha256_hex(format('%s|%s|%s|%s',
            p_block_index, p_delivery_hash, p_previous_hash, fn_ts_canonical(p_ts)));
$$;


--
-- TOC entry 219 (class 1259 OID 16534)
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    full_name character varying(120) NOT NULL,
    email character varying(254) NOT NULL,
    phone character varying(20),
    password_hash text NOT NULL,
    role public.user_role NOT NULL,
    center_id bigint,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_users_email_format CHECK (((email)::text ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::text)),
    CONSTRAINT ck_users_role_center CHECK (((role = 'ATTENDANT'::public.user_role) OR (center_id IS NULL)))
);


--
-- TOC entry 330 (class 1255 OID 25092)
-- Name: fn_can_operate_center(public.users, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_can_operate_center(p_user public.users, p_center_id bigint) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT COALESCE(
        p_user.role = 'ADMIN'
        OR (p_user.role = 'ATTENDANT' AND p_user.center_id = p_center_id),
        FALSE);
$$;


--
-- TOC entry 304 (class 1255 OID 25109)
-- Name: fn_chain_is_valid(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_chain_is_valid() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT COALESCE((SELECT bool_and(v.is_valid) FROM fn_verify_chain() v), FALSE)
       AND NOT EXISTS (
            SELECT 1 FROM deliveries d
             WHERE d.status = 'DELIVERED'
               AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.delivery_id = d.id));
$$;


--
-- TOC entry 316 (class 1255 OID 25100)
-- Name: fn_consume_qr_token(text, public.qr_purpose, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_consume_qr_token(p_raw_token text, p_purpose public.qr_purpose, p_actor_id bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    t qr_tokens;
BEGIN
    SELECT * INTO t FROM qr_tokens WHERE token_hash = fn_sha256_hex(btrim(p_raw_token)) FOR UPDATE;

    IF NOT FOUND OR t.purpose <> p_purpose THEN
        RAISE EXCEPTION 'Geçersiz QR kodu' USING ERRCODE = 'YA404';
    END IF;
    IF t.used_at IS NOT NULL THEN
        RAISE EXCEPTION 'Bu QR kodu daha önce kullanılmış (%)', t.used_at USING ERRCODE = 'YA409';
    END IF;
    IF t.revoked_at IS NOT NULL THEN
        RAISE EXCEPTION 'Bu QR kodu iptal edilmiş; yeni kod üretilmeli' USING ERRCODE = 'YA409';
    END IF;
    IF t.expires_at < now() THEN
        RAISE EXCEPTION 'QR kodunun süresi dolmuş' USING ERRCODE = 'YA410';
    END IF;

    UPDATE qr_tokens SET used_at = now(), used_by = p_actor_id WHERE id = t.id;
    RETURN t.delivery_id;
END;
$$;


--
-- TOC entry 278 (class 1255 OID 25088)
-- Name: fn_current_actor(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_current_actor() RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
    SELECT NULLIF(current_setting('app.user_id', true), '')::BIGINT;
$$;


--
-- TOC entry 349 (class 1255 OID 25103)
-- Name: fn_delivery_hash(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_delivery_hash(p_delivery_id bigint) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT fn_sha256_hex(fn_delivery_payload(p_delivery_id));
$$;


--
-- TOC entry 305 (class 1255 OID 25102)
-- Name: fn_delivery_payload(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_delivery_payload(p_delivery_id bigint) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
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

    RETURN format(
        '{"center_id":%s,"delivered_at":"%s","delivery_id":%s,"items":[%s],"picked_up_at":"%s","request_id":%s,"volunteer_id":%s}',
        d.center_id, fn_ts_canonical(d.delivered_at), d.id, COALESCE(v_items, ''),
        fn_ts_canonical(d.picked_up_at), d.request_id, d.volunteer_id);
END;
$$;


--
-- TOC entry 354 (class 1255 OID 25097)
-- Name: fn_delivery_transition_allowed(public.delivery_status, public.delivery_status); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_delivery_transition_allowed(p_old public.delivery_status, p_new public.delivery_status) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE p_old
        WHEN 'ASSIGNED'   THEN p_new IN ('PREPARING','CANCELLED')
        WHEN 'PREPARING'  THEN p_new IN ('IN_TRANSIT','CANCELLED')
        WHEN 'IN_TRANSIT' THEN p_new IN ('DELIVERED','CANCELLED')
        ELSE FALSE
    END;
$$;


--
-- TOC entry 340 (class 1255 OID 25095)
-- Name: fn_find_candidate_centers(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_find_candidate_centers(p_request_id bigint) RETURNS TABLE(center_id bigint, center_name character varying, distance_km numeric)
    LANGUAGE sql STABLE
    AS $$
    SELECT a.center_id, a.center_name, a.distance_km
    FROM fn_matching_analysis(p_request_id) a
    WHERE a.is_eligible AND NOT a.is_rejected
    ORDER BY a.distance_km, a.center_id;
$$;


--
-- TOC entry 309 (class 1255 OID 25093)
-- Name: fn_haversine_km(double precision, double precision, double precision, double precision); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_haversine_km(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision) RETURNS double precision
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT 2 * 6371.0088 * asin(sqrt(
              power(sin(radians(lat2 - lat1) / 2), 2) +
              cos(radians(lat1)) * cos(radians(lat2)) *
              power(sin(radians(lon2 - lon1) / 2), 2)));
$$;


--
-- TOC entry 292 (class 1255 OID 25105)
-- Name: fn_init_chain(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_init_chain() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_ts   TIMESTAMPTZ := date_trunc('second', now());
    v_dh   TEXT := fn_sha256_hex('GENESIS');
    v_prev TEXT := repeat('0', 64);
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('yardimagi_chain'));
    IF NOT EXISTS (SELECT 1 FROM blocks WHERE block_index = 0) THEN
        INSERT INTO blocks (block_index, delivery_id, delivery_hash, previous_hash, current_hash, block_timestamp)
        VALUES (0, NULL, v_dh, v_prev, fn_block_hash(0, v_dh, v_prev, v_ts), v_ts);
    END IF;
END;
$$;


--
-- TOC entry 262 (class 1255 OID 25090)
-- Name: fn_is_manager(public.users); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_is_manager(p_user public.users) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT p_user.role IN ('ATTENDANT', 'ADMIN');
$$;


--
-- TOC entry 297 (class 1255 OID 25099)
-- Name: fn_issue_qr_token(bigint, public.qr_purpose, bigint, interval); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_issue_qr_token(p_delivery_id bigint, p_purpose public.qr_purpose, p_actor_id bigint DEFAULT NULL::bigint, p_ttl interval DEFAULT '24:00:00'::interval) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_raw TEXT;
BEGIN
    UPDATE qr_tokens SET revoked_at = now()
     WHERE delivery_id = p_delivery_id AND purpose = p_purpose
       AND used_at IS NULL AND revoked_at IS NULL;

    v_raw := encode(gen_random_bytes(24), 'hex');   -- 192 bit
    INSERT INTO qr_tokens (delivery_id, purpose, token_hash, expires_at, created_by)
    VALUES (p_delivery_id, p_purpose, fn_sha256_hex(v_raw), now() + p_ttl, p_actor_id);
    RETURN v_raw;
END;
$$;


--
-- TOC entry 265 (class 1255 OID 25094)
-- Name: fn_matching_analysis(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_matching_analysis(p_request_id bigint) RETURNS TABLE(center_id bigint, center_name character varying, distance_km numeric, is_eligible boolean, is_rejected boolean, missing jsonb)
    LANGUAGE sql STABLE
    AS $$
    WITH req AS (
        SELECT r.latitude, r.longitude FROM requests r WHERE r.id = p_request_id
    ),
    gaps AS (
        SELECT c.id AS center_id,
               jsonb_agg(jsonb_build_object(
                    'category_id', i.category_id,
                    'code',        cat.code,
                    'requested',   i.quantity,
                    'available',   COALESCE(s.available, 0))
                    ORDER BY i.category_id
               ) FILTER (WHERE COALESCE(s.available, 0) < i.quantity) AS missing
        FROM centers c
        CROSS JOIN request_items i
        JOIN categories cat ON cat.id = i.category_id
        LEFT JOIN stocks s ON s.center_id = c.id AND s.category_id = i.category_id
        WHERE i.request_id = p_request_id AND c.is_active
        GROUP BY c.id
    )
    SELECT c.id,
           c.name,
           round(fn_haversine_km(req.latitude, req.longitude, c.latitude, c.longitude)::numeric, 3),
           g.missing IS NULL,
           EXISTS (SELECT 1 FROM matches m
                    WHERE m.request_id = p_request_id AND m.center_id = c.id AND m.status = 'REJECTED'),
           COALESCE(g.missing, '[]'::jsonb)
    FROM centers c
    CROSS JOIN req
    JOIN gaps g ON g.center_id = c.id
    WHERE c.is_active
    ORDER BY (g.missing IS NULL) DESC, 3 ASC;
$$;


--
-- TOC entry 268 (class 1255 OID 25096)
-- Name: fn_request_transition_allowed(public.request_status, public.request_status); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_request_transition_allowed(p_old public.request_status, p_new public.request_status) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE p_old
        WHEN 'OPEN'       THEN p_new IN ('MATCHED','CANCELLED')
        WHEN 'MATCHED'    THEN p_new IN ('OPEN','ASSIGNED','CANCELLED')
        WHEN 'ASSIGNED'   THEN p_new IN ('PREPARING','MATCHED','CANCELLED')   -- ->MATCHED: görev iptali
        WHEN 'PREPARING'  THEN p_new IN ('IN_TRANSIT','MATCHED','CANCELLED')
        WHEN 'IN_TRANSIT' THEN p_new IN ('DELIVERED','MATCHED','CANCELLED')
        ELSE FALSE      -- DELIVERED ve CANCELLED son durumlardır
    END;
$$;


--
-- TOC entry 298 (class 1255 OID 25089)
-- Name: fn_require_user(bigint, public.user_role[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_require_user(p_user_id bigint, p_roles public.user_role[] DEFAULT NULL::public.user_role[]) RETURNS public.users
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    u users;
BEGIN
    SELECT * INTO u FROM users WHERE id = p_user_id;
    IF NOT FOUND OR NOT u.is_active THEN
        RAISE EXCEPTION 'Kullanıcı bulunamadı veya pasif (id=%)', p_user_id USING ERRCODE = 'YA401';
    END IF;
    IF p_roles IS NOT NULL AND NOT (u.role = ANY (p_roles)) THEN
        RAISE EXCEPTION 'Bu işlem için yetkiniz yok (rol=%, gereken=%)', u.role, p_roles USING ERRCODE = 'YA403';
    END IF;
    RETURN u;
END;
$$;


--
-- TOC entry 333 (class 1255 OID 25087)
-- Name: fn_set_actor(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_set_actor(p_user_id bigint) RETURNS void
    LANGUAGE sql
    AS $$
    SELECT set_config('app.user_id', COALESCE(p_user_id::text, ''), true);
$$;


--
-- TOC entry 320 (class 1255 OID 25098)
-- Name: fn_sha256_hex(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_sha256_hex(p_text text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT encode(sha256(convert_to(p_text, 'UTF8')), 'hex');
$$;


--
-- TOC entry 267 (class 1255 OID 25101)
-- Name: fn_ts_canonical(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_ts_canonical(p_ts timestamp with time zone) RETURNS text
    LANGUAGE sql STABLE STRICT
    AS $$
    SELECT to_char(p_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
$$;


--
-- TOC entry 274 (class 1255 OID 25107)
-- Name: fn_verify_chain(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_verify_chain() RETURNS TABLE(block_index bigint, delivery_id bigint, delivery_hash_ok boolean, link_ok boolean, block_hash_ok boolean, is_valid boolean, stored_delivery_hash text, recomputed_delivery_hash text)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    b    blocks;
    prev blocks;
    v_re TEXT;
BEGIN
    FOR b IN SELECT * FROM blocks ORDER BY blocks.block_index LOOP
        IF b.block_index = 0 THEN
            v_re    := fn_sha256_hex('GENESIS');
            link_ok := (b.previous_hash = repeat('0', 64));
        ELSE
            v_re    := fn_delivery_hash(b.delivery_id);
            link_ok := prev.block_timestamp IS NOT NULL
                       AND b.previous_hash = prev.current_hash
                       AND b.block_index = prev.block_index + 1;
        END IF;

        block_index              := b.block_index;
        delivery_id              := b.delivery_id;
        stored_delivery_hash     := b.delivery_hash;
        recomputed_delivery_hash := v_re;
        delivery_hash_ok         := (v_re IS NOT DISTINCT FROM b.delivery_hash);
        block_hash_ok            := (b.current_hash = fn_block_hash(b.block_index, b.delivery_hash,
                                                                    b.previous_hash, b.block_timestamp));
        is_valid                 := delivery_hash_ok AND link_ok AND block_hash_ok;
        RETURN NEXT;
        prev := b;
    END LOOP;
END;
$$;


--
-- TOC entry 332 (class 1255 OID 25108)
-- Name: fn_verify_delivery(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_verify_delivery(p_delivery_id bigint) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT COALESCE((SELECT v.is_valid FROM fn_verify_chain() v WHERE v.delivery_id = p_delivery_id), FALSE);
$$;


--
-- TOC entry 282 (class 1255 OID 25157)
-- Name: sp_admin_anonymize_user(bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_anonymize_user(IN p_admin_id bigint, IN p_user_id bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);
    IF p_user_id = p_admin_id THEN
        RAISE EXCEPTION 'Kendi hesabınızı anonimleştiremezsiniz' USING ERRCODE = 'YA403';
    END IF;

    UPDATE users
       SET full_name     = 'Silinmiş kullanıcı #' || id,
           email         = 'silinmis-' || id || '@anonim.invalid',
           phone         = NULL,
           password_hash = 'DISABLED',
           is_active     = FALSE
     WHERE id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Kullanıcı bulunamadı (id=%)', p_user_id USING ERRCODE = 'YA404';
    END IF;
END;
$$;


--
-- TOC entry 293 (class 1255 OID 25154)
-- Name: sp_admin_change_role(bigint, bigint, public.user_role, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_change_role(IN p_admin_id bigint, IN p_user_id bigint, IN p_new_role public.user_role, IN p_center_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);
    IF p_user_id = p_admin_id THEN
        RAISE EXCEPTION 'Kendi rolünüzü değiştiremezsiniz' USING ERRCODE = 'YA403';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'Kullanıcı bulunamadı (id=%)', p_user_id USING ERRCODE = 'YA404';
    END IF;
    IF p_center_id IS NOT NULL AND p_new_role <> 'ATTENDANT' THEN
        RAISE EXCEPTION 'Merkez yalnızca görevliye atanabilir' USING ERRCODE = 'YA400';
    END IF;

    UPDATE users
       SET role = p_new_role,
           center_id = CASE WHEN p_new_role = 'ATTENDANT' THEN p_center_id END
     WHERE id = p_user_id;
END;
$$;


--
-- TOC entry 323 (class 1255 OID 25153)
-- Name: sp_admin_create_user(bigint, text, text, text, public.user_role, text, bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_create_user(IN p_admin_id bigint, IN p_full_name text, IN p_email text, IN p_password_hash text, IN p_role public.user_role, IN p_phone text DEFAULT NULL::text, IN p_center_id bigint DEFAULT NULL::bigint, INOUT p_user_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);

    IF p_center_id IS NOT NULL AND p_role <> 'ATTENDANT' THEN
        RAISE EXCEPTION 'Merkez yalnızca görevliye atanabilir; gönüllü merkeze bağlı değildir'
            USING ERRCODE = 'YA400';
    END IF;
    IF p_center_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM centers WHERE id = p_center_id AND is_active) THEN
        RAISE EXCEPTION 'Merkez bulunamadı veya pasif' USING ERRCODE = 'YA404';
    END IF;

    BEGIN
        INSERT INTO users (full_name, email, phone, password_hash, role, center_id)
        VALUES (btrim(p_full_name), lower(btrim(p_email)), p_phone, p_password_hash, p_role, p_center_id)
        RETURNING id INTO p_user_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'Bu e-posta ile kayıtlı kullanıcı var: %', p_email USING ERRCODE = 'YA409';
    END;
END;
$$;


--
-- TOC entry 347 (class 1255 OID 25156)
-- Name: sp_admin_delete_user(bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_delete_user(IN p_admin_id bigint, IN p_user_id bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);
    IF p_user_id = p_admin_id THEN
        RAISE EXCEPTION 'Kendi hesabınızı silemezsiniz' USING ERRCODE = 'YA403';
    END IF;

    BEGIN
        DELETE FROM users WHERE id = p_user_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Kullanıcı bulunamadı (id=%)', p_user_id USING ERRCODE = 'YA404';
        END IF;
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Kullanıcının sistemde kayıtları var; kalıcı silinemez. Anonimleştirin (sp_admin_anonymize_user) veya pasifleştirin'
            USING ERRCODE = 'YA409';
    END;
END;
$$;


--
-- TOC entry 361 (class 1255 OID 25158)
-- Name: sp_admin_reset_password(bigint, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_reset_password(IN p_admin_id bigint, IN p_user_id bigint, IN p_new_password_hash text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);
    IF p_new_password_hash IS NULL OR length(p_new_password_hash) < 20 THEN
        RAISE EXCEPTION 'Geçersiz parola hash''i' USING ERRCODE = 'YA400';
    END IF;
    UPDATE users SET password_hash = p_new_password_hash WHERE id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Kullanıcı bulunamadı (id=%)', p_user_id USING ERRCODE = 'YA404';
    END IF;
END;
$$;


--
-- TOC entry 302 (class 1255 OID 25161)
-- Name: sp_admin_save_category(bigint, text, text, text, boolean, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_save_category(IN p_admin_id bigint, IN p_code text, IN p_name text, IN p_unit text, IN p_is_active boolean DEFAULT true, INOUT p_category_id integer DEFAULT NULL::integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);
    BEGIN
        IF p_category_id IS NULL THEN
            INSERT INTO categories (code, name, unit, is_active)
            VALUES (upper(btrim(p_code)), btrim(p_name), btrim(p_unit), COALESCE(p_is_active, TRUE))
            RETURNING id INTO p_category_id;
        ELSE
            UPDATE categories
               SET code = upper(btrim(p_code)), name = btrim(p_name), unit = btrim(p_unit),
                   is_active = COALESCE(p_is_active, is_active)
             WHERE id = p_category_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Kategori bulunamadı (id=%)', p_category_id USING ERRCODE = 'YA404';
            END IF;
        END IF;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Bu kodda kategori zaten var: %', p_code USING ERRCODE = 'YA409';
        WHEN check_violation THEN
            RAISE EXCEPTION 'Kategori kodu BÜYÜK_HARF_VE_ALT_ÇİZGİ olmalı (ör. WATER)' USING ERRCODE = 'YA400';
    END;
END;
$$;


--
-- TOC entry 327 (class 1255 OID 25159)
-- Name: sp_admin_save_center(bigint, text, text, numeric, numeric, text, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_save_center(IN p_admin_id bigint, IN p_name text, IN p_address text, IN p_latitude numeric, IN p_longitude numeric, IN p_phone text DEFAULT NULL::text, INOUT p_center_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);
    BEGIN
        IF p_center_id IS NULL THEN
            INSERT INTO centers (name, address, phone, latitude, longitude)
            VALUES (btrim(p_name), p_address, p_phone, p_latitude, p_longitude)
            RETURNING id INTO p_center_id;
        ELSE
            UPDATE centers
               SET name = btrim(p_name), address = p_address, phone = p_phone,
                   latitude = p_latitude, longitude = p_longitude
             WHERE id = p_center_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Merkez bulunamadı (id=%)', p_center_id USING ERRCODE = 'YA404';
            END IF;
        END IF;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Bu isimde merkez zaten var: %', p_name USING ERRCODE = 'YA409';
        WHEN check_violation THEN
            RAISE EXCEPTION 'Geçersiz koordinat' USING ERRCODE = 'YA400';
    END;
END;
$$;


--
-- TOC entry 266 (class 1255 OID 25160)
-- Name: sp_admin_set_center_active(bigint, bigint, boolean); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_set_center_active(IN p_admin_id bigint, IN p_center_id bigint, IN p_is_active boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
    r RECORD;
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);

    UPDATE centers SET is_active = p_is_active WHERE id = p_center_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Merkez bulunamadı (id=%)', p_center_id USING ERRCODE = 'YA404';
    END IF;

    IF NOT p_is_active THEN
        FOR r IN
            SELECT m.id AS match_id, m.request_id
              FROM matches m JOIN requests q ON q.id = m.request_id
             WHERE m.center_id = p_center_id AND m.status = 'ACCEPTED' AND q.status = 'MATCHED'
             FOR UPDATE OF q
        LOOP
            UPDATE matches SET status = 'EXPIRED', decided_at = now() WHERE id = r.match_id;
            UPDATE requests SET status = 'OPEN' WHERE id = r.request_id;
        END LOOP;
    END IF;
END;
$$;


--
-- TOC entry 341 (class 1255 OID 25155)
-- Name: sp_admin_set_user_active(bigint, bigint, boolean); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_set_user_active(IN p_admin_id bigint, IN p_user_id bigint, IN p_is_active boolean)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_admin_id);
    IF p_user_id = p_admin_id AND NOT p_is_active THEN
        RAISE EXCEPTION 'Kendi hesabınızı pasifleştiremezsiniz' USING ERRCODE = 'YA403';
    END IF;
    UPDATE users SET is_active = p_is_active WHERE id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Kullanıcı bulunamadı (id=%)', p_user_id USING ERRCODE = 'YA404';
    END IF;
END;
$$;


--
-- TOC entry 348 (class 1255 OID 25162)
-- Name: sp_admin_set_user_center(bigint, bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_admin_set_user_center(IN p_admin_id bigint, IN p_user_id bigint, IN p_center_id bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u users;
BEGIN
    PERFORM fn_require_user(p_admin_id, ARRAY['ADMIN']::user_role[]);
    u := fn_require_user(p_user_id);
    PERFORM fn_set_actor(p_admin_id);

    IF u.role <> 'ATTENDANT' THEN
        RAISE EXCEPTION 'Merkez yalnızca görevliye atanabilir (bu kullanıcının rolü %)', u.role
            USING ERRCODE = 'YA400';
    END IF;
    IF p_center_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM centers WHERE id = p_center_id AND is_active) THEN
        RAISE EXCEPTION 'Merkez bulunamadı veya pasif' USING ERRCODE = 'YA404';
    END IF;

    UPDATE users SET center_id = p_center_id WHERE id = p_user_id;
END;
$$;


--
-- TOC entry 321 (class 1255 OID 25148)
-- Name: sp_cancel_delivery(bigint, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_cancel_delivery(IN p_delivery_id bigint, IN p_actor_id bigint, IN p_reason text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u users;
    d deliveries;
BEGIN
    u := fn_require_user(p_actor_id);
    PERFORM fn_set_actor(p_actor_id);

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'İptal nedeni zorunlu' USING ERRCODE = 'YA400';
    END IF;

    SELECT * INTO d FROM deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teslimat bulunamadı (id=%)', p_delivery_id USING ERRCODE = 'YA404';
    END IF;
    IF d.status IN ('DELIVERED', 'CANCELLED') THEN
        RAISE EXCEPTION 'Teslimat zaten % durumunda', d.status USING ERRCODE = 'YA422';
    END IF;
    IF NOT (fn_is_manager(u)
            OR (d.volunteer_id = p_actor_id AND d.status IN ('ASSIGNED', 'PREPARING'))) THEN
        RAISE EXCEPTION 'Bu görevi iptal etmeye yetkiniz yok' USING ERRCODE = 'YA403';
    END IF;

    UPDATE deliveries SET status = 'CANCELLED', cancel_reason = p_reason WHERE id = p_delivery_id;
END;
$$;


--
-- TOC entry 352 (class 1255 OID 25149)
-- Name: sp_cancel_request(bigint, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_cancel_request(IN p_request_id bigint, IN p_actor_id bigint, IN p_reason text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    r requests;
BEGIN
    PERFORM fn_require_user(p_actor_id, ARRAY['ATTENDANT','ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_actor_id);

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'İptal nedeni zorunlu' USING ERRCODE = 'YA400';
    END IF;

    SELECT * INTO r FROM requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Talep bulunamadı (id=%)', p_request_id USING ERRCODE = 'YA404';
    END IF;
    IF r.status IN ('DELIVERED', 'CANCELLED') THEN
        RAISE EXCEPTION 'Talep zaten % durumunda', r.status USING ERRCODE = 'YA422';
    END IF;

    UPDATE deliveries SET status = 'CANCELLED', cancel_reason = 'Talep iptal edildi: ' || p_reason
     WHERE request_id = p_request_id AND status IN ('ASSIGNED', 'PREPARING', 'IN_TRANSIT');

    UPDATE matches SET status = 'EXPIRED', decided_at = now()
     WHERE request_id = p_request_id AND status = 'ACCEPTED';

    UPDATE requests SET status = 'CANCELLED', cancel_reason = p_reason WHERE id = p_request_id;
END;
$$;


--
-- TOC entry 290 (class 1255 OID 25143)
-- Name: sp_claim_task(bigint, bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_claim_task(IN p_request_id bigint, IN p_volunteer_id bigint, INOUT p_delivery_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u users;
    r requests;
    m matches;
BEGIN
    u := fn_require_user(p_volunteer_id, ARRAY['VOLUNTEER']::user_role[]);
    PERFORM fn_set_actor(p_volunteer_id);

    -- Talep satırını kilitle: iki gönüllü aynı anda basarsa ikincisi bekler
    SELECT * INTO r FROM requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Talep bulunamadı (id=%)', p_request_id USING ERRCODE = 'YA404';
    END IF;
    IF r.status <> 'MATCHED' THEN
        RAISE EXCEPTION 'Görev üstlenilemez: talep % durumunda (başka gönüllü almış olabilir)', r.status
            USING ERRCODE = 'YA409';
    END IF;

    SELECT * INTO m FROM matches WHERE request_id = p_request_id AND status = 'ACCEPTED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Talebin aktif eşleşmesi yok' USING ERRCODE = 'YA409';
    END IF;
    -- Gönüllü herhangi bir merkezden görev alabilir; merkez kısıtı yoktur.
    -- Paketi hangi merkezden aldığı deliveries.center_id'de kayıtlıdır ve
    -- merkezden çıkışta QR ile doğrulanır.
    IF EXISTS (SELECT 1 FROM deliveries WHERE volunteer_id = p_volunteer_id
                AND status IN ('ASSIGNED','PREPARING','IN_TRANSIT')) THEN
        RAISE EXCEPTION 'Gönüllünün tamamlanmamış bir görevi var' USING ERRCODE = 'YA409';
    END IF;

    INSERT INTO deliveries (match_id, request_id, center_id, volunteer_id)
    VALUES (m.id, p_request_id, m.center_id, p_volunteer_id)
    RETURNING id INTO p_delivery_id;
END;
$$;


--
-- TOC entry 357 (class 1255 OID 25146)
-- Name: sp_confirm_delivery(text, bigint, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_confirm_delivery(IN p_token text, IN p_actor_id bigint, INOUT p_delivery_id bigint DEFAULT NULL::bigint, INOUT p_block_hash text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    d deliveries;
BEGIN
    PERFORM fn_require_user(p_actor_id, ARRAY['ATTENDANT','ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_actor_id);

    p_delivery_id := fn_consume_qr_token(p_token, 'DROPOFF', p_actor_id);

    SELECT * INTO d FROM deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF d.status <> 'IN_TRANSIT' THEN
        RAISE EXCEPTION 'Teslimat % durumunda; yalnızca IN_TRANSIT teslim edilebilir', d.status
            USING ERRCODE = 'YA422';
    END IF;
    IF d.picked_up_by = p_actor_id THEN
        RAISE EXCEPTION 'Paketi merkezden çıkaran kişi teslimi onaylayamaz; başka bir saha görevlisi onaylamalı'
            USING ERRCODE = 'YA403';
    END IF;

    UPDATE deliveries SET status = 'DELIVERED', delivered_verified_by = p_actor_id WHERE id = p_delivery_id;
    SELECT current_hash INTO p_block_hash FROM blocks WHERE delivery_id = p_delivery_id;
END;
$$;


--
-- TOC entry 331 (class 1255 OID 25140)
-- Name: sp_create_request(bigint, numeric, numeric, jsonb, integer, public.request_urgency, text, text, text, text, bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_create_request(IN p_created_by bigint, IN p_latitude numeric, IN p_longitude numeric, IN p_items jsonb, IN p_people_number integer DEFAULT 1, IN p_urgency public.request_urgency DEFAULT 'MEDIUM'::public.request_urgency, IN p_address text DEFAULT NULL::text, IN p_description text DEFAULT NULL::text, IN p_contact_name text DEFAULT NULL::text, IN p_contact_phone text DEFAULT NULL::text, IN p_ai_prediction_id bigint DEFAULT NULL::bigint, INOUT p_request_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item   JSONB;
    v_cat_id INTEGER;
    v_qty    INTEGER;
BEGIN
    PERFORM fn_require_user(p_created_by, ARRAY['ATTENDANT','ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_created_by);

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Talep en az bir kalem içermeli' USING ERRCODE = 'YA400';
    END IF;

    INSERT INTO requests (created_by, latitude, longitude, address, people_number, urgency,
                              description, contact_name, contact_phone)
    VALUES (p_created_by, p_latitude, p_longitude, p_address, COALESCE(p_people_number, 1),
            COALESCE(p_urgency, 'MEDIUM'), p_description, p_contact_name, p_contact_phone)
    RETURNING id INTO p_request_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        IF v_item ? 'category_id' THEN
            SELECT id INTO v_cat_id FROM categories
             WHERE id = (v_item->>'category_id')::INTEGER AND is_active;
        ELSE
            SELECT id INTO v_cat_id FROM categories
             WHERE code = upper(v_item->>'category_code') AND is_active;
        END IF;
        IF v_cat_id IS NULL THEN
            RAISE EXCEPTION 'Geçersiz veya pasif kategori: %', v_item USING ERRCODE = 'YA400';
        END IF;

        v_qty := (v_item->>'quantity')::INTEGER;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'Miktar pozitif olmalı: %', v_item USING ERRCODE = 'YA400';
        END IF;

        BEGIN
            INSERT INTO request_items (request_id, category_id, quantity)
            VALUES (p_request_id, v_cat_id, v_qty);
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'Aynı kategori talepte iki kez geçiyor (kategori %)', v_cat_id USING ERRCODE = 'YA400';
        END;
        v_cat_id := NULL;
    END LOOP;

    IF p_ai_prediction_id IS NOT NULL THEN
        UPDATE predictions SET request_id = p_request_id
         WHERE id = p_ai_prediction_id AND request_id IS NULL;
    END IF;
END;
$$;


--
-- TOC entry 355 (class 1255 OID 25144)
-- Name: sp_mark_prepared(bigint, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_mark_prepared(IN p_delivery_id bigint, IN p_actor_id bigint, INOUT p_pickup_token text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u users;
    d deliveries;
BEGIN
    u := fn_require_user(p_actor_id, ARRAY['VOLUNTEER','ATTENDANT','ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_actor_id);

    SELECT * INTO d FROM deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teslimat bulunamadı (id=%)', p_delivery_id USING ERRCODE = 'YA404';
    END IF;
    -- Paketi görevi üstlenen gönüllü hazırlayabilir (merkezdedir),
    -- ya da o merkezin görevlisi / admin.
    IF NOT (d.volunteer_id = p_actor_id OR fn_can_operate_center(u, d.center_id)) THEN
        RAISE EXCEPTION 'Bu paketi hazırlamaya yetkiniz yok: görev size ait değil ve bu merkezin görevlisi değilsiniz'
            USING ERRCODE = 'YA403';
    END IF;
    IF d.status <> 'ASSIGNED' THEN
        RAISE EXCEPTION 'Teslimat % durumunda; yalnızca ASSIGNED hazırlanabilir', d.status USING ERRCODE = 'YA422';
    END IF;

    UPDATE deliveries SET status = 'PREPARING', prepared_by = p_actor_id WHERE id = p_delivery_id;
    p_pickup_token := fn_issue_qr_token(p_delivery_id, 'PICKUP', p_actor_id);
END;
$$;


--
-- TOC entry 337 (class 1255 OID 25147)
-- Name: sp_reissue_qr(bigint, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_reissue_qr(IN p_delivery_id bigint, IN p_actor_id bigint, INOUT p_token text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u       users;
    d       deliveries;
    v_allow BOOLEAN;
BEGIN
    u := fn_require_user(p_actor_id);
    PERFORM fn_set_actor(p_actor_id);
    SELECT * INTO d FROM deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Teslimat bulunamadı (id=%)', p_delivery_id USING ERRCODE = 'YA404';
    END IF;

    v_allow := d.volunteer_id = p_actor_id OR fn_is_manager(u);
    IF d.status = 'PREPARING' AND v_allow THEN
        p_token := fn_issue_qr_token(p_delivery_id, 'PICKUP', p_actor_id);
    ELSIF d.status = 'IN_TRANSIT' AND v_allow THEN
        p_token := fn_issue_qr_token(p_delivery_id, 'DROPOFF', p_actor_id);
    ELSE
        RAISE EXCEPTION 'Bu durumda (%) veya bu rolle QR yeniden üretilemez', d.status USING ERRCODE = 'YA403';
    END IF;
END;
$$;


--
-- TOC entry 310 (class 1255 OID 25142)
-- Name: sp_reject_match(bigint, bigint, bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_reject_match(IN p_match_id bigint, IN p_actor_id bigint, INOUT p_new_match_id bigint DEFAULT NULL::bigint, INOUT p_new_center_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
    m          matches;
    v_dist     NUMERIC;
    v_strategy match_strategy;
BEGIN
    PERFORM fn_require_user(p_actor_id, ARRAY['ATTENDANT','ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_actor_id);

    SELECT * INTO m FROM matches WHERE id = p_match_id FOR UPDATE;
    IF NOT FOUND OR m.status <> 'ACCEPTED' THEN
        RAISE EXCEPTION 'Aktif eşleşme bulunamadı (id=%)', p_match_id USING ERRCODE = 'YA404';
    END IF;
    IF EXISTS (SELECT 1 FROM deliveries WHERE match_id = m.id AND status <> 'CANCELLED') THEN
        RAISE EXCEPTION 'Bu eşleşme için görev alınmış; önce görevi iptal edin' USING ERRCODE = 'YA409';
    END IF;

    UPDATE matches SET status = 'REJECTED', decided_at = now() WHERE id = m.id;
    v_strategy := m.strategy;   -- CALL argümanında alt sorgu kullanılamaz
    CALL sp_run_matching(m.request_id, p_actor_id, v_strategy, p_new_match_id, p_new_center_id, v_dist);
END;
$$;


--
-- TOC entry 306 (class 1255 OID 25141)
-- Name: sp_run_matching(bigint, bigint, public.match_strategy, bigint, bigint, numeric); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_run_matching(IN p_request_id bigint, IN p_actor_id bigint DEFAULT NULL::bigint, IN p_strategy public.match_strategy DEFAULT 'NEAREST'::public.match_strategy, INOUT p_match_id bigint DEFAULT NULL::bigint, INOUT p_center_id bigint DEFAULT NULL::bigint, INOUT p_distance_km numeric DEFAULT NULL::numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    r requests;
BEGIN
    IF p_actor_id IS NOT NULL THEN
        PERFORM fn_require_user(p_actor_id, ARRAY['ATTENDANT','ADMIN']::user_role[]);
    END IF;
    PERFORM fn_set_actor(p_actor_id);

    SELECT * INTO r FROM requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Talep bulunamadı (id=%)', p_request_id USING ERRCODE = 'YA404';
    END IF;
    IF r.status NOT IN ('OPEN', 'MATCHED') THEN
        RAISE EXCEPTION 'Talep % durumunda; yalnızca OPEN/MATCHED talepler eşleştirilebilir', r.status
            USING ERRCODE = 'YA422';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM request_items WHERE request_id = p_request_id) THEN
        RAISE EXCEPTION 'Talebin kalemi yok' USING ERRCODE = 'YA400';
    END IF;

    -- Önceki seçim geçersiz (red kayıtları korunur)
    UPDATE matches SET status = 'EXPIRED', decided_at = now()
     WHERE request_id = p_request_id AND status = 'ACCEPTED';

    p_match_id := NULL;
    SELECT c.center_id, c.distance_km INTO p_center_id, p_distance_km
      FROM fn_find_candidate_centers(p_request_id) c
     ORDER BY CASE p_strategy WHEN 'NEAREST'         THEN c.distance_km END,
              CASE p_strategy WHEN 'FIRST_AVAILABLE' THEN c.center_id   END,
              CASE p_strategy WHEN 'RANDOM'          THEN random()      END,
              c.center_id
     LIMIT 1;

    IF p_center_id IS NULL THEN
        IF r.status = 'MATCHED' THEN
            UPDATE requests SET status = 'OPEN' WHERE id = p_request_id;
        END IF;
        RAISE NOTICE 'Talep % için tüm kalemleri karşılayan merkez yok; talep OPEN kaldı', p_request_id;
        RETURN;
    END IF;

    INSERT INTO matches (request_id, center_id, distance_km, strategy, status, decided_at)
    VALUES (p_request_id, p_center_id, p_distance_km, p_strategy, 'ACCEPTED', now())
    RETURNING id INTO p_match_id;

    IF r.status = 'OPEN' THEN
        UPDATE requests SET status = 'MATCHED' WHERE id = p_request_id;
    END IF;
END;
$$;


--
-- TOC entry 315 (class 1255 OID 25152)
-- Name: sp_save_ai_prediction(text, text, text, jsonb, numeric, integer, bigint, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_save_ai_prediction(IN p_input_text text, IN p_model_name text, IN p_model_version text, IN p_scores jsonb, IN p_threshold numeric DEFAULT 0.5, IN p_latency_ms integer DEFAULT NULL::integer, IN p_actor_id bigint DEFAULT NULL::bigint, INOUT p_prediction_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_code TEXT;
    v_cat  INTEGER;
BEGIN
    IF p_actor_id IS NOT NULL THEN
        PERFORM fn_require_user(p_actor_id);
        PERFORM fn_set_actor(p_actor_id);
    END IF;
    IF p_scores IS NULL OR jsonb_typeof(p_scores) <> 'object' OR p_scores = '{}'::jsonb THEN
        RAISE EXCEPTION 'En az bir kategori olasılığı gerekli' USING ERRCODE = 'YA400';
    END IF;

    INSERT INTO predictions (input_text, model_name, model_version, threshold, latency_ms, created_by)
    VALUES (p_input_text, p_model_name, p_model_version, COALESCE(p_threshold, 0.5), p_latency_ms, p_actor_id)
    RETURNING id INTO p_prediction_id;

    FOR v_code IN SELECT jsonb_object_keys(p_scores) LOOP
        SELECT id INTO v_cat FROM categories WHERE code = upper(v_code);
        IF v_cat IS NULL THEN
            RAISE EXCEPTION 'Bilinmeyen kategori kodu: %', v_code USING ERRCODE = 'YA400';
        END IF;
        INSERT INTO prediction_scores (prediction_id, category_id, probability)
        VALUES (p_prediction_id, v_cat, (p_scores->>v_code)::NUMERIC);
    END LOOP;
END;
$$;


--
-- TOC entry 281 (class 1255 OID 25145)
-- Name: sp_scan_pickup(text, bigint, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_scan_pickup(IN p_token text, IN p_actor_id bigint, INOUT p_delivery_id bigint DEFAULT NULL::bigint, INOUT p_dropoff_token text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u users;
    d deliveries;
BEGIN
    u := fn_require_user(p_actor_id);
    PERFORM fn_set_actor(p_actor_id);

    p_delivery_id := fn_consume_qr_token(p_token, 'PICKUP', p_actor_id);

    SELECT * INTO d FROM deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT (d.volunteer_id = p_actor_id OR fn_can_operate_center(u, d.center_id)) THEN
        RAISE EXCEPTION 'Bu paketi teslim almaya yetkiniz yok: görev size ait değil ve bu merkezin görevlisi değilsiniz'
            USING ERRCODE = 'YA403';
    END IF;
    IF d.status <> 'PREPARING' THEN
        RAISE EXCEPTION 'Teslimat % durumunda; çıkış yalnızca PREPARING iken yapılabilir', d.status
            USING ERRCODE = 'YA422';
    END IF;

    UPDATE deliveries SET status = 'IN_TRANSIT', picked_up_by = p_actor_id WHERE id = p_delivery_id;
    p_dropoff_token := fn_issue_qr_token(p_delivery_id, 'DROPOFF', p_actor_id);
END;
$$;


--
-- TOC entry 359 (class 1255 OID 25150)
-- Name: sp_stock_add(bigint, integer, integer, bigint, text, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_stock_add(IN p_center_id bigint, IN p_category_id integer, IN p_quantity integer, IN p_actor_id bigint, IN p_note text DEFAULT NULL::text, INOUT p_stock_id bigint DEFAULT NULL::bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u users;
BEGIN
    u := fn_require_user(p_actor_id, ARRAY['ATTENDANT','ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_actor_id);
    IF NOT fn_can_operate_center(u, p_center_id) THEN
        RAISE EXCEPTION 'Yalnızca kendi merkezinizin stoğunu güncelleyebilirsiniz' USING ERRCODE = 'YA403';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM centers WHERE id = p_center_id AND is_active) THEN
        RAISE EXCEPTION 'Merkez bulunamadı veya pasif' USING ERRCODE = 'YA404';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Giriş miktarı pozitif olmalı' USING ERRCODE = 'YA400';
    END IF;

    INSERT INTO stocks (center_id, category_id) VALUES (p_center_id, p_category_id)
    ON CONFLICT (center_id, category_id) DO NOTHING;
    SELECT id INTO p_stock_id FROM stocks WHERE center_id = p_center_id AND category_id = p_category_id;

    INSERT INTO stock_transactions (stock_id, type, quantity, note, created_by)
    VALUES (p_stock_id, 'IN', p_quantity, p_note, p_actor_id);
END;
$$;


--
-- TOC entry 342 (class 1255 OID 25151)
-- Name: sp_stock_correct(bigint, integer, integer, bigint, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_stock_correct(IN p_center_id bigint, IN p_category_id integer, IN p_delta integer, IN p_actor_id bigint, IN p_note text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    u          users;
    v_stock_id BIGINT;
BEGIN
    u := fn_require_user(p_actor_id, ARRAY['ATTENDANT','ADMIN']::user_role[]);
    PERFORM fn_set_actor(p_actor_id);
    IF NOT fn_can_operate_center(u, p_center_id) THEN
        RAISE EXCEPTION 'Yalnızca kendi merkezinizin stoğunu düzeltebilirsiniz' USING ERRCODE = 'YA403';
    END IF;
    IF p_note IS NULL OR btrim(p_note) = '' THEN
        RAISE EXCEPTION 'Düzeltme için açıklama zorunlu' USING ERRCODE = 'YA400';
    END IF;

    SELECT id INTO v_stock_id FROM stocks WHERE center_id = p_center_id AND category_id = p_category_id;
    IF v_stock_id IS NULL THEN
        RAISE EXCEPTION 'Stok kaydı yok' USING ERRCODE = 'YA404';
    END IF;

    INSERT INTO stock_transactions (stock_id, type, quantity, note, created_by)
    VALUES (v_stock_id, 'CORRECTION', p_delta, p_note, p_actor_id);
END;
$$;


--
-- TOC entry 350 (class 1255 OID 25116)
-- Name: trg_fn_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION '% tablosu yalnızca eklemeye açıktır (% engellendi)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'YA400';
END;
$$;


--
-- TOC entry 275 (class 1255 OID 25136)
-- Name: trg_fn_centers_deactivate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_centers_deactivate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.is_active AND NOT NEW.is_active AND EXISTS (
        SELECT 1 FROM deliveries
         WHERE center_id = NEW.id AND status IN ('ASSIGNED','PREPARING','IN_TRANSIT')) THEN
        RAISE EXCEPTION 'Merkezin aktif görevleri var; önce tamamlayın veya iptal edin' USING ERRCODE = 'YA409';
    END IF;
    RETURN NEW;
END;
$$;


--
-- TOC entry 360 (class 1255 OID 25134)
-- Name: trg_fn_deliveries_after(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_deliveries_after() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    it   RECORD;
    v_tx stock_tx_type;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_tx := 'RESERVE';
    ELSIF NEW.status = 'CANCELLED' THEN
        v_tx := 'RELEASE';
    ELSIF NEW.status = 'DELIVERED' THEN
        v_tx := 'OUT';
    END IF;

    -- Stok hareketleri: talebin kalemleri üzerinden (ayrı teslimat kalemi yok)
    IF v_tx IS NOT NULL THEN
        FOR it IN
            SELECT i.quantity, s.id AS stock_id
              FROM request_items i
              JOIN stocks s ON s.center_id = NEW.center_id AND s.category_id = i.category_id
             WHERE i.request_id = NEW.request_id
             ORDER BY s.id                       -- sabit sıra: deadlock önleme
        LOOP
            INSERT INTO stock_transactions (stock_id, type, quantity, delivery_id, note)
            VALUES (it.stock_id, v_tx, it.quantity, NEW.id,
                    CASE v_tx WHEN 'RESERVE' THEN 'Görev üstlenildi'
                              WHEN 'RELEASE' THEN 'Görev iptali'
                              ELSE 'Teslimat tamamlandı' END);
        END LOOP;

        IF v_tx = 'RESERVE' AND (SELECT count(*) FROM stock_transactions
                                  WHERE delivery_id = NEW.id AND type = 'RESERVE')
                               <> (SELECT count(*) FROM request_items WHERE request_id = NEW.request_id) THEN
            RAISE EXCEPTION 'Merkezde talebin bazı kategorileri için stok kaydı yok; yeniden eşleştirin'
                USING ERRCODE = 'YA409';
        END IF;
    END IF;

    IF TG_OP = 'INSERT' THEN
        UPDATE requests SET status = 'ASSIGNED' WHERE id = NEW.request_id;
        RETURN NULL;
    END IF;

    IF NEW.status = 'CANCELLED' THEN
        UPDATE qr_tokens SET revoked_at = now()
         WHERE delivery_id = NEW.id AND used_at IS NULL AND revoked_at IS NULL;
    END IF;

    -- Talep durumunu senkronla (talep zaten kapandıysa dokunma)
    UPDATE requests r
       SET status = CASE NEW.status
                        WHEN 'PREPARING'  THEN 'PREPARING'::request_status
                        WHEN 'IN_TRANSIT' THEN 'IN_TRANSIT'::request_status
                        WHEN 'DELIVERED'  THEN 'DELIVERED'::request_status
                        WHEN 'CANCELLED'  THEN 'MATCHED'::request_status   -- başka gönüllü alabilsin
                    END
     WHERE r.id = NEW.request_id AND r.status NOT IN ('CANCELLED', 'DELIVERED');

    IF NEW.status = 'DELIVERED' THEN
        PERFORM fn_append_block(NEW.id);
    END IF;

    RETURN NULL;
END;
$$;


--
-- TOC entry 289 (class 1255 OID 25132)
-- Name: trg_fn_deliveries_before(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_deliveries_before() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'ASSIGNED' THEN
            RAISE EXCEPTION 'Yeni teslimat ASSIGNED durumunda oluşturulmalı' USING ERRCODE = 'YA422';
        END IF;
        PERFORM fn_require_user(NEW.volunteer_id, ARRAY['VOLUNTEER']::user_role[]);
        RETURN NEW;
    END IF;

    -- Tamamlanmış/iptal edilmiş teslimat kilitlidir (zincirdeki kaydın kaynağı)
    IF OLD.status IN ('DELIVERED', 'CANCELLED') THEN
        RAISE EXCEPTION 'Teslimat % durumunda; değiştirilemez', OLD.status USING ERRCODE = 'YA422';
    END IF;
    IF NEW.match_id <> OLD.match_id OR NEW.request_id <> OLD.request_id
       OR NEW.center_id <> OLD.center_id OR NEW.volunteer_id <> OLD.volunteer_id THEN
        RAISE EXCEPTION 'Teslimatın eşleşme/talep/merkez/gönüllü bilgisi değiştirilemez; iptal edip yeni görev açın'
            USING ERRCODE = 'YA422';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT fn_delivery_transition_allowed(OLD.status, NEW.status) THEN
            RAISE EXCEPTION 'Geçersiz teslimat durum geçişi: % -> %', OLD.status, NEW.status USING ERRCODE = 'YA422';
        END IF;
        CASE NEW.status
            WHEN 'PREPARING'  THEN NEW.prepared_at  := COALESCE(NEW.prepared_at,  now());
            WHEN 'IN_TRANSIT' THEN NEW.picked_up_at := COALESCE(NEW.picked_up_at, now());
            WHEN 'DELIVERED'  THEN NEW.delivered_at := COALESCE(NEW.delivered_at, now());
            WHEN 'CANCELLED'  THEN NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
            ELSE NULL;
        END CASE;
    END IF;
    RETURN NEW;
END;
$$;


--
-- TOC entry 317 (class 1255 OID 25130)
-- Name: trg_fn_request_items_lock(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_request_items_lock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status request_status;
    v_req    BIGINT := CASE WHEN TG_OP = 'DELETE' THEN OLD.request_id ELSE NEW.request_id END;
BEGIN
    SELECT status INTO v_status FROM requests WHERE id = v_req;
    -- Talep CASCADE ile silinirken üst satır yok -> izin ver
    IF FOUND AND v_status <> 'OPEN' THEN
        RAISE EXCEPTION 'Talep % durumunda; kalemler yalnızca OPEN iken değiştirilebilir', v_status
            USING ERRCODE = 'YA422';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- TOC entry 294 (class 1255 OID 25126)
-- Name: trg_fn_requests_before(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_requests_before() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM fn_require_user(NEW.created_by, ARRAY['ATTENDANT','ADMIN']::user_role[]);
        IF NEW.status <> 'OPEN' THEN
            RAISE EXCEPTION 'Yeni talep OPEN durumunda oluşturulmalı' USING ERRCODE = 'YA422';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT fn_request_transition_allowed(OLD.status, NEW.status) THEN
            RAISE EXCEPTION 'Geçersiz talep durum geçişi: % -> %', OLD.status, NEW.status USING ERRCODE = 'YA422';
        END IF;
        IF NEW.status = 'CANCELLED' THEN
            NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


--
-- TOC entry 318 (class 1255 OID 25128)
-- Name: trg_fn_requests_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_requests_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO request_status_history (request_id, old_status, new_status, changed_by)
        VALUES (NEW.id, NULL, NEW.status, COALESCE(fn_current_actor(), NEW.created_by));
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO request_status_history (request_id, old_status, new_status, changed_by, note)
        VALUES (NEW.id, OLD.status, NEW.status, fn_current_actor(),
                CASE WHEN NEW.status = 'CANCELLED' THEN NEW.cancel_reason END);
    END IF;
    RETURN NULL;
END;
$$;


--
-- TOC entry 288 (class 1255 OID 25110)
-- Name: trg_fn_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


--
-- TOC entry 338 (class 1255 OID 25124)
-- Name: trg_fn_stock_tx_apply(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_stock_tx_apply() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    s       stocks;
    v_total INTEGER;
    v_res   INTEGER;
    v_cat   TEXT;
    v_ctr   TEXT;
BEGIN
    SELECT * INTO s FROM stocks WHERE id = NEW.stock_id FOR UPDATE;   -- satır kilidi
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stok satırı bulunamadı (id=%)', NEW.stock_id USING ERRCODE = 'YA404';
    END IF;

    v_total := s.total;
    v_res   := s.reserved;

    CASE NEW.type
        WHEN 'IN' THEN
            v_total := v_total + NEW.quantity;
        WHEN 'RESERVE' THEN
            IF s.available < NEW.quantity THEN
                SELECT code INTO v_cat FROM categories WHERE id = s.category_id;
                SELECT name INTO v_ctr FROM centers    WHERE id = s.center_id;
                RAISE EXCEPTION 'Stok yetersiz: % / % (kullanılabilir %, istenen %)',
                    v_ctr, v_cat, s.available, NEW.quantity USING ERRCODE = 'YA409';
            END IF;
            v_res := v_res + NEW.quantity;
        WHEN 'RELEASE' THEN
            IF v_res < NEW.quantity THEN
                RAISE EXCEPTION 'Serbest bırakılacak rezervasyon yok (rezerve %, istenen %)', v_res, NEW.quantity
                    USING ERRCODE = 'YA409';
            END IF;
            v_res := v_res - NEW.quantity;
        WHEN 'OUT' THEN
            IF v_res < NEW.quantity THEN
                RAISE EXCEPTION 'Rezerve edilmemiş stok çıkışı yapılamaz (rezerve %, çıkış %)', v_res, NEW.quantity
                    USING ERRCODE = 'YA409';
            END IF;
            v_total := v_total - NEW.quantity;
            v_res   := v_res   - NEW.quantity;
        WHEN 'CORRECTION' THEN
            v_total := v_total + NEW.quantity;
            IF v_total < v_res THEN
                RAISE EXCEPTION 'Düzeltme sonrası toplam stok (%) rezerve miktarın (%) altına düşemez', v_total, v_res
                    USING ERRCODE = 'YA409';
            END IF;
    END CASE;

    PERFORM set_config('yardimagi.ledger', 'on', true);
    UPDATE stocks SET total = v_total, reserved = v_res WHERE id = s.id;
    PERFORM set_config('yardimagi.ledger', 'off', true);

    NEW.created_by := COALESCE(NEW.created_by, fn_current_actor());
    RETURN NEW;
END;
$$;


--
-- TOC entry 301 (class 1255 OID 25122)
-- Name: trg_fn_stocks_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_stocks_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF COALESCE(current_setting('yardimagi.ledger', true), 'off') = 'on' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' AND (NEW.total <> 0 OR NEW.reserved <> 0) THEN
        RAISE EXCEPTION 'Stok satırı 0 ile açılmalı; giriş için sp_stock_add kullanın' USING ERRCODE = 'YA400';
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.total    IS DISTINCT FROM OLD.total OR
                             NEW.reserved IS DISTINCT FROM OLD.reserved) THEN
        RAISE EXCEPTION 'Stok miktarı doğrudan güncellenemez; stock_transactions üzerinden hareket ekleyin'
            USING ERRCODE = 'YA400';
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.center_id <> OLD.center_id OR NEW.category_id <> OLD.category_id) THEN
        RAISE EXCEPTION 'Stok satırının merkez/kategorisi değiştirilemez' USING ERRCODE = 'YA400';
    END IF;
    RETURN NEW;
END;
$$;


--
-- TOC entry 264 (class 1255 OID 25138)
-- Name: trg_fn_users_protect(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_users_protect() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_loses_admin BOOLEAN;
BEGIN
    v_loses_admin := OLD.role = 'ADMIN' AND OLD.is_active AND (
        TG_OP = 'DELETE' OR NEW.role <> 'ADMIN' OR NOT NEW.is_active);

    IF v_loses_admin AND NOT EXISTS (
        SELECT 1 FROM users WHERE role = 'ADMIN' AND is_active AND id <> OLD.id) THEN
        RAISE EXCEPTION 'Sistemde en az bir aktif admin kalmalı' USING ERRCODE = 'YA409';
    END IF;

    IF OLD.role = 'VOLUNTEER'
       AND (TG_OP = 'DELETE' OR NEW.role <> 'VOLUNTEER' OR NOT NEW.is_active)
       AND EXISTS (SELECT 1 FROM deliveries WHERE volunteer_id = OLD.id
                    AND status IN ('ASSIGNED','PREPARING','IN_TRANSIT')) THEN
        RAISE EXCEPTION 'Gönüllünün tamamlanmamış görevi var; önce görevi tamamlayın veya iptal edin'
            USING ERRCODE = 'YA409';
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- TOC entry 221 (class 1259 OID 16553)
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id integer NOT NULL,
    code character varying(30) NOT NULL,
    name character varying(60) NOT NULL,
    unit character varying(20) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_categories_code CHECK (((code)::text ~ '^[A-Z][A-Z0-9_]*$'::text))
);


--
-- TOC entry 220 (class 1259 OID 16552)
-- Name: categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.categories ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 217 (class 1259 OID 16506)
-- Name: centers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.centers (
    id bigint NOT NULL,
    name character varying(150) NOT NULL,
    address text NOT NULL,
    phone character varying(20),
    latitude numeric(9,6) NOT NULL,
    longitude numeric(9,6) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT centers_latitude_check CHECK (((latitude >= ('-90'::integer)::numeric) AND (latitude <= (90)::numeric))),
    CONSTRAINT centers_longitude_check CHECK (((longitude >= ('-180'::integer)::numeric) AND (longitude <= (180)::numeric)))
);


--
-- TOC entry 216 (class 1259 OID 16505)
-- Name: centers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.centers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.centers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 231 (class 1259 OID 16655)
-- Name: deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deliveries (
    id bigint NOT NULL,
    match_id bigint NOT NULL,
    request_id bigint NOT NULL,
    center_id bigint NOT NULL,
    volunteer_id bigint NOT NULL,
    status public.delivery_status DEFAULT 'ASSIGNED'::public.delivery_status NOT NULL,
    prepared_at timestamp with time zone,
    prepared_by bigint,
    picked_up_at timestamp with time zone,
    picked_up_by bigint,
    delivered_at timestamp with time zone,
    delivered_verified_by bigint,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_deliveries_cancelled CHECK (((status = 'CANCELLED'::public.delivery_status) = (cancelled_at IS NOT NULL))),
    CONSTRAINT ck_deliveries_delivered CHECK (((status = 'DELIVERED'::public.delivery_status) = (delivered_at IS NOT NULL))),
    CONSTRAINT ck_deliveries_picked CHECK (((status <> ALL (ARRAY['IN_TRANSIT'::public.delivery_status, 'DELIVERED'::public.delivery_status])) OR (picked_up_at IS NOT NULL))),
    CONSTRAINT ck_deliveries_prepared CHECK (((status = ANY (ARRAY['ASSIGNED'::public.delivery_status, 'CANCELLED'::public.delivery_status])) OR (prepared_at IS NOT NULL)))
);


--
-- TOC entry 230 (class 1259 OID 16654)
-- Name: deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.deliveries ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 229 (class 1259 OID 16632)
-- Name: matches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.matches (
    id bigint NOT NULL,
    request_id bigint NOT NULL,
    center_id bigint NOT NULL,
    distance_km numeric(9,3) NOT NULL,
    strategy public.match_strategy DEFAULT 'NEAREST'::public.match_strategy NOT NULL,
    status public.match_status DEFAULT 'ACCEPTED'::public.match_status NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone,
    CONSTRAINT matches_distance_km_check CHECK ((distance_km >= (0)::numeric))
);


--
-- TOC entry 228 (class 1259 OID 16631)
-- Name: matches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.matches ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.matches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 241 (class 1259 OID 16879)
-- Name: prediction_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prediction_scores (
    prediction_id bigint NOT NULL,
    category_id integer NOT NULL,
    probability numeric(5,4) NOT NULL,
    CONSTRAINT prediction_scores_probability_check CHECK (((probability >= (0)::numeric) AND (probability <= (1)::numeric)))
);


--
-- TOC entry 240 (class 1259 OID 16858)
-- Name: predictions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.predictions (
    id bigint NOT NULL,
    request_id bigint,
    input_text text NOT NULL,
    model_name character varying(50) NOT NULL,
    model_version character varying(30) NOT NULL,
    threshold numeric(4,3) DEFAULT 0.5 NOT NULL,
    latency_ms integer,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT predictions_latency_ms_check CHECK ((latency_ms >= 0)),
    CONSTRAINT predictions_threshold_check CHECK (((threshold > (0)::numeric) AND (threshold < (1)::numeric)))
);


--
-- TOC entry 239 (class 1259 OID 16857)
-- Name: predictions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.predictions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.predictions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 235 (class 1259 OID 16794)
-- Name: qr_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.qr_tokens (
    id bigint NOT NULL,
    delivery_id bigint NOT NULL,
    purpose public.qr_purpose NOT NULL,
    token_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    used_by bigint,
    revoked_at timestamp with time zone,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_qr_tokens_hash_hex CHECK ((token_hash ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_qr_tokens_not_both CHECK (((used_at IS NULL) OR (revoked_at IS NULL))),
    CONSTRAINT ck_qr_tokens_used CHECK (((used_at IS NULL) = (used_by IS NULL)))
);


--
-- TOC entry 234 (class 1259 OID 16793)
-- Name: qr_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.qr_tokens ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.qr_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 227 (class 1259 OID 16613)
-- Name: request_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_items (
    id bigint NOT NULL,
    request_id bigint NOT NULL,
    category_id integer NOT NULL,
    quantity integer NOT NULL,
    CONSTRAINT request_items_quantity_check CHECK ((quantity > 0))
);


--
-- TOC entry 226 (class 1259 OID 16612)
-- Name: request_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.request_items ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.request_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 238 (class 1259 OID 16839)
-- Name: request_status_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_status_history (
    id bigint NOT NULL,
    request_id bigint NOT NULL,
    old_status public.request_status,
    new_status public.request_status NOT NULL,
    changed_by bigint,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    note text
);


--
-- TOC entry 237 (class 1259 OID 16838)
-- Name: request_status_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.request_status_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.request_status_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 225 (class 1259 OID 16591)
-- Name: requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.requests (
    id bigint NOT NULL,
    created_by bigint NOT NULL,
    latitude numeric(9,6) NOT NULL,
    longitude numeric(9,6) NOT NULL,
    address text,
    people_number integer DEFAULT 1 NOT NULL,
    urgency public.request_urgency DEFAULT 'MEDIUM'::public.request_urgency NOT NULL,
    description text,
    contact_name character varying(120),
    contact_phone character varying(20),
    status public.request_status DEFAULT 'OPEN'::public.request_status NOT NULL,
    cancel_reason text,
    cancelled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_requests_cancel CHECK (((status = 'CANCELLED'::public.request_status) = (cancelled_at IS NOT NULL))),
    CONSTRAINT requests_latitude_check CHECK (((latitude >= ('-90'::integer)::numeric) AND (latitude <= (90)::numeric))),
    CONSTRAINT requests_longitude_check CHECK (((longitude >= ('-180'::integer)::numeric) AND (longitude <= (180)::numeric))),
    CONSTRAINT requests_people_number_check CHECK (((people_number >= 1) AND (people_number <= 10000)))
);


--
-- TOC entry 224 (class 1259 OID 16590)
-- Name: requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.requests ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 233 (class 1259 OID 16709)
-- Name: stock_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_transactions (
    id bigint NOT NULL,
    stock_id bigint NOT NULL,
    type public.stock_tx_type NOT NULL,
    quantity integer NOT NULL,
    delivery_id bigint,
    note text,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_stock_tx_delivery CHECK (((type <> ALL (ARRAY['RESERVE'::public.stock_tx_type, 'RELEASE'::public.stock_tx_type, 'OUT'::public.stock_tx_type])) OR (delivery_id IS NOT NULL))),
    CONSTRAINT ck_stock_tx_quantity CHECK ((((type = 'CORRECTION'::public.stock_tx_type) AND (quantity <> 0)) OR ((type <> 'CORRECTION'::public.stock_tx_type) AND (quantity > 0))))
);


--
-- TOC entry 232 (class 1259 OID 16708)
-- Name: stock_transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stock_transactions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.stock_transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 223 (class 1259 OID 16564)
-- Name: stocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stocks (
    id bigint NOT NULL,
    center_id bigint NOT NULL,
    category_id integer NOT NULL,
    total integer DEFAULT 0 NOT NULL,
    reserved integer DEFAULT 0 NOT NULL,
    available integer GENERATED ALWAYS AS ((total - reserved)) STORED,
    low_stock_alert integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_stocks_reserved_le_total CHECK ((reserved <= total)),
    CONSTRAINT ck_stocks_reserved_nonneg CHECK ((reserved >= 0)),
    CONSTRAINT ck_stocks_threshold_nonneg CHECK ((low_stock_alert >= 0)),
    CONSTRAINT ck_stocks_total_nonneg CHECK ((total >= 0))
);


--
-- TOC entry 222 (class 1259 OID 16563)
-- Name: stocks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stocks ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.stocks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 218 (class 1259 OID 16533)
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.users ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 248 (class 1259 OID 25301)
-- Name: v_stock_overview; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_stock_overview AS
 SELECT s.id AS stock_id,
    s.center_id,
    ac.name AS center_name,
    s.category_id,
    c.code AS category_code,
    c.name AS category_name,
    c.unit,
    s.total,
    s.reserved,
    s.available,
    s.low_stock_alert,
    (s.available <= s.low_stock_alert) AS is_low,
    s.updated_at
   FROM ((public.stocks s
     JOIN public.centers ac ON ((ac.id = s.center_id)))
     JOIN public.categories c ON ((c.id = s.category_id)))
  WHERE ac.is_active;


--
-- TOC entry 250 (class 1259 OID 25311)
-- Name: v_admin_dashboard; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_admin_dashboard AS
 SELECT ( SELECT count(*) AS count
           FROM public.requests
          WHERE (requests.status = 'OPEN'::public.request_status)) AS requests_open,
    ( SELECT count(*) AS count
           FROM public.requests
          WHERE (requests.status = 'MATCHED'::public.request_status)) AS requests_matched,
    ( SELECT count(*) AS count
           FROM public.requests
          WHERE (requests.status = ANY (ARRAY['ASSIGNED'::public.request_status, 'PREPARING'::public.request_status, 'IN_TRANSIT'::public.request_status]))) AS requests_in_progress,
    ( SELECT count(*) AS count
           FROM public.requests
          WHERE (requests.status = 'DELIVERED'::public.request_status)) AS requests_delivered,
    ( SELECT count(*) AS count
           FROM public.requests
          WHERE (requests.status = 'CANCELLED'::public.request_status)) AS requests_cancelled,
    ( SELECT count(*) AS count
           FROM public.requests
          WHERE ((requests.status = ANY (ARRAY['OPEN'::public.request_status, 'MATCHED'::public.request_status])) AND (requests.urgency = ANY (ARRAY['HIGH'::public.request_urgency, 'CRITICAL'::public.request_urgency])))) AS urgent_waiting,
    ( SELECT count(*) AS count
           FROM public.deliveries
          WHERE (deliveries.status = 'IN_TRANSIT'::public.delivery_status)) AS deliveries_in_transit,
    ( SELECT count(*) AS count
           FROM public.deliveries
          WHERE ((deliveries.status = 'DELIVERED'::public.delivery_status) AND (deliveries.delivered_at >= date_trunc('day'::text, now())))) AS delivered_today,
    ( SELECT count(*) AS count
           FROM public.v_stock_overview
          WHERE v_stock_overview.is_low) AS low_stock_items,
    ( SELECT count(*) AS count
           FROM public.centers
          WHERE centers.is_active) AS active_centers,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE ((users.role = 'VOLUNTEER'::public.user_role) AND users.is_active)) AS active_volunteers,
    ( SELECT count(*) AS count
           FROM public.blocks) AS chain_length,
    ( SELECT max(blocks.block_timestamp) AS max
           FROM public.blocks) AS last_block_at;


--
-- TOC entry 257 (class 1259 OID 25343)
-- Name: v_ai_prediction_eval; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_ai_prediction_eval AS
SELECT
    NULL::bigint AS prediction_id,
    NULL::bigint AS request_id,
    NULL::character varying(50) AS model_name,
    NULL::character varying(30) AS model_version,
    NULL::numeric(4,3) AS threshold,
    NULL::bigint AS tp,
    NULL::bigint AS fp,
    NULL::bigint AS fn;


--
-- TOC entry 258 (class 1259 OID 25348)
-- Name: v_ai_model_metrics; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_ai_model_metrics AS
 SELECT model_name,
    model_version,
    count(*) AS n,
    round((sum(tp) / NULLIF((sum(tp) + sum(fp)), (0)::numeric)), 4) AS micro_precision,
    round((sum(tp) / NULLIF((sum(tp) + sum(fn)), (0)::numeric)), 4) AS micro_recall,
    round(((2.0 * sum(tp)) / NULLIF(((((2)::numeric * sum(tp)) + sum(fp)) + sum(fn)), (0)::numeric)), 4) AS micro_f1,
    round(avg((((fp = 0) AND (fn = 0)))::integer), 4) AS subset_accuracy
   FROM public.v_ai_prediction_eval
  GROUP BY model_name, model_version;


--
-- TOC entry 242 (class 1259 OID 25271)
-- Name: v_request_items_json; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_request_items_json AS
 SELECT i.request_id,
    jsonb_agg(jsonb_build_object('category_id', c.id, 'code', c.code, 'name', c.name, 'unit', c.unit, 'quantity', i.quantity) ORDER BY c.id) AS items,
    sum(i.quantity) AS total_units
   FROM (public.request_items i
     JOIN public.categories c ON ((c.id = i.category_id)))
  GROUP BY i.request_id;


--
-- TOC entry 246 (class 1259 OID 25291)
-- Name: v_available_tasks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_available_tasks AS
 SELECT r.id AS request_id,
    m.id AS match_id,
    m.center_id,
    ac.name AS center_name,
    m.distance_km,
    r.urgency,
    r.people_number,
    r.latitude,
    r.longitude,
    r.address,
    ij.items,
    ij.total_units,
    r.created_at,
    (now() - r.created_at) AS waiting_for
   FROM (((public.requests r
     JOIN public.matches m ON (((m.request_id = r.id) AND (m.status = 'ACCEPTED'::public.match_status))))
     JOIN public.centers ac ON ((ac.id = m.center_id)))
     JOIN public.v_request_items_json ij ON ((ij.request_id = r.id)))
  WHERE ((r.status = 'MATCHED'::public.request_status) AND ac.is_active)
  ORDER BY r.urgency DESC, r.created_at;


--
-- TOC entry 252 (class 1259 OID 25320)
-- Name: v_chain_audit; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_chain_audit AS
 SELECT v.block_index,
    v.delivery_id,
    b.block_timestamp,
    b.current_hash,
    v.delivery_hash_ok,
    v.link_ok,
    v.block_hash_ok,
    v.is_valid
   FROM (public.fn_verify_chain() v(block_index, delivery_id, delivery_hash_ok, link_ok, block_hash_ok, is_valid, stored_delivery_hash, recomputed_delivery_hash)
     JOIN public.blocks b ON ((b.block_index = v.block_index)))
  ORDER BY v.block_index;


--
-- TOC entry 253 (class 1259 OID 25324)
-- Name: v_deliveries_without_block; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_deliveries_without_block AS
 SELECT id,
    delivered_at
   FROM public.deliveries d
  WHERE ((status = 'DELIVERED'::public.delivery_status) AND (NOT (EXISTS ( SELECT 1
           FROM public.blocks b
          WHERE (b.delivery_id = d.id)))));


--
-- TOC entry 247 (class 1259 OID 25296)
-- Name: v_delivery_detail; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_delivery_detail AS
 SELECT d.id,
    d.status,
    d.match_id,
    d.request_id,
    d.center_id,
    ac.name AS center_name,
    d.volunteer_id,
    v.full_name AS volunteer_name,
    v.phone AS volunteer_phone,
    r.urgency,
    r.latitude,
    r.longitude,
    r.address,
    r.people_number,
    ij.items,
    ij.total_units,
    d.created_at AS assigned_at,
    d.prepared_at,
    pb.full_name AS prepared_by_name,
    d.picked_up_at,
    pu.full_name AS picked_up_by_name,
    d.delivered_at,
    fv.full_name AS verified_by_name,
    d.cancelled_at,
    d.cancel_reason,
    b.block_index,
    b.current_hash AS block_hash
   FROM ((((((((public.deliveries d
     JOIN public.centers ac ON ((ac.id = d.center_id)))
     JOIN public.users v ON ((v.id = d.volunteer_id)))
     JOIN public.requests r ON ((r.id = d.request_id)))
     LEFT JOIN public.v_request_items_json ij ON ((ij.request_id = d.request_id)))
     LEFT JOIN public.users pb ON ((pb.id = d.prepared_by)))
     LEFT JOIN public.users pu ON ((pu.id = d.picked_up_by)))
     LEFT JOIN public.users fv ON ((fv.id = d.delivered_verified_by)))
     LEFT JOIN public.blocks b ON ((b.delivery_id = d.id)));


--
-- TOC entry 259 (class 1259 OID 25353)
-- Name: v_install_check; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_install_check AS
 WITH beklenen(sira, nesne, dosya, adet) AS (
         VALUES (1,'ENUM tipi'::text,'01_types.sql'::text,8), (2,'Tablo'::text,'02_tables.sql'::text,14), (3,'Fonksiyon'::text,'04_functions.sql'::text,22), (4,'Trigger'::text,'05_triggers.sql'::text,19), (5,'Procedure'::text,'06_procedures.sql'::text,23), (6,'View'::text,'07_views.sql'::text,19), (7,'Yardım kategorisi'::text,'09_seed.sql'::text,8), (8,'Genesis blok'::text,'09_seed.sql'::text,1)
        ), bulunan(nesne, adet) AS (
         SELECT 'ENUM tipi'::text AS "?column?",
            (count(*))::integer AS count
           FROM (pg_type t
             JOIN pg_namespace n ON ((n.oid = t.typnamespace)))
          WHERE ((n.nspname = 'public'::name) AND (t.typtype = 'e'::"char"))
        UNION ALL
         SELECT 'Tablo'::text,
            (count(*))::integer AS count
           FROM pg_tables
          WHERE (pg_tables.schemaname = 'public'::name)
        UNION ALL
         SELECT 'Fonksiyon'::text,
            (count(*))::integer AS count
           FROM (pg_proc p
             JOIN pg_namespace n ON ((n.oid = p.pronamespace)))
          WHERE ((n.nspname = 'public'::name) AND (p.prokind = 'f'::"char") AND (p.proname ~~ 'fn\_%'::text))
        UNION ALL
         SELECT 'Trigger'::text,
            (count(*))::integer AS count
           FROM ((pg_trigger t
             JOIN pg_class c ON ((c.oid = t.tgrelid)))
             JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
          WHERE ((NOT t.tgisinternal) AND (n.nspname = 'public'::name))
        UNION ALL
         SELECT 'Procedure'::text,
            (count(*))::integer AS count
           FROM (pg_proc p
             JOIN pg_namespace n ON ((n.oid = p.pronamespace)))
          WHERE ((n.nspname = 'public'::name) AND (p.prokind = 'p'::"char"))
        UNION ALL
         SELECT 'View'::text,
            (count(*))::integer AS count
           FROM pg_views
          WHERE (pg_views.schemaname = 'public'::name)
        UNION ALL
         SELECT 'Yardım kategorisi'::text,
            (count(*))::integer AS count
           FROM public.categories
        UNION ALL
         SELECT 'Genesis blok'::text,
            (count(*))::integer AS count
           FROM public.blocks
          WHERE (blocks.block_index = 0)
        )
 SELECT b.nesne,
    b.dosya,
    b.adet AS beklenen,
    f.adet AS bulunan,
        CASE
            WHEN (f.adet >= b.adet) THEN 'TAMAM'::text
            ELSE 'EKSIK'::text
        END AS durum
   FROM (beklenen b
     JOIN bulunan f USING (nesne))
  ORDER BY b.sira;


--
-- TOC entry 255 (class 1259 OID 25333)
-- Name: v_matching_metrics; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_matching_metrics AS
 SELECT m.strategy,
    count(*) AS matches_made,
    round(avg(m.distance_km), 3) AS avg_distance_km,
    round((percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((m.distance_km)::double precision)))::numeric, 3) AS median_distance_km,
    round(max(m.distance_km), 3) AS max_distance_km,
    count(*) FILTER (WHERE (r.urgency = ANY (ARRAY['HIGH'::public.request_urgency, 'CRITICAL'::public.request_urgency]))) AS high_urgency_matched,
    count(*) FILTER (WHERE ((r.urgency = ANY (ARRAY['HIGH'::public.request_urgency, 'CRITICAL'::public.request_urgency])) AND (r.status = 'DELIVERED'::public.request_status))) AS high_urgency_delivered,
    round(((100.0 * (count(*) FILTER (WHERE (r.status = 'DELIVERED'::public.request_status)))::numeric) / (NULLIF(count(*), 0))::numeric), 2) AS delivered_pct
   FROM (public.matches m
     JOIN public.requests r ON ((r.id = m.request_id)))
  WHERE (m.status = ANY (ARRAY['ACCEPTED'::public.match_status, 'EXPIRED'::public.match_status]))
  GROUP BY m.strategy;


--
-- TOC entry 243 (class 1259 OID 25276)
-- Name: v_request_detail; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_request_detail AS
 SELECT r.id,
    r.status,
    r.urgency,
    r.people_number,
    r.latitude,
    r.longitude,
    r.address,
    r.description,
    r.contact_name,
    r.contact_phone,
    r.created_by,
    u.full_name AS created_by_name,
    r.created_at,
    r.updated_at,
    r.cancelled_at,
    r.cancel_reason,
    ij.items,
    ij.total_units,
    m.id AS match_id,
    m.center_id AS matched_center_id,
    ac.name AS matched_center_name,
    m.distance_km AS matched_distance_km,
    d.id AS delivery_id,
    d.status AS delivery_status,
    d.volunteer_id,
    vu.full_name AS volunteer_name
   FROM ((((((public.requests r
     JOIN public.users u ON ((u.id = r.created_by)))
     LEFT JOIN public.v_request_items_json ij ON ((ij.request_id = r.id)))
     LEFT JOIN public.matches m ON (((m.request_id = r.id) AND (m.status = 'ACCEPTED'::public.match_status))))
     LEFT JOIN public.centers ac ON ((ac.id = m.center_id)))
     LEFT JOIN public.deliveries d ON (((d.request_id = r.id) AND (d.status <> 'CANCELLED'::public.delivery_status))))
     LEFT JOIN public.users vu ON ((vu.id = d.volunteer_id)));


--
-- TOC entry 244 (class 1259 OID 25281)
-- Name: v_open_requests; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_open_requests AS
 SELECT id,
    status,
    urgency,
    people_number,
    latitude,
    longitude,
    address,
    description,
    contact_name,
    contact_phone,
    created_by,
    created_by_name,
    created_at,
    updated_at,
    cancelled_at,
    cancel_reason,
    items,
    total_units,
    match_id,
    matched_center_id,
    matched_center_name,
    matched_distance_km,
    delivery_id,
    delivery_status,
    volunteer_id,
    volunteer_name
   FROM public.v_request_detail
  WHERE (status = ANY (ARRAY['OPEN'::public.request_status, 'MATCHED'::public.request_status]))
  ORDER BY urgency DESC, created_at;


--
-- TOC entry 251 (class 1259 OID 25316)
-- Name: v_request_status_counts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_request_status_counts AS
 SELECT status,
    urgency,
    count(*) AS cnt
   FROM public.requests
  GROUP BY status, urgency;


--
-- TOC entry 254 (class 1259 OID 25328)
-- Name: v_request_timeline; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_request_timeline AS
SELECT
    NULL::bigint AS request_id,
    NULL::public.request_urgency AS urgency,
    NULL::public.request_status AS status,
    NULL::timestamp with time zone AS created_at,
    NULL::timestamp with time zone AS matched_at,
    NULL::timestamp with time zone AS assigned_at,
    NULL::timestamp with time zone AS in_transit_at,
    NULL::timestamp with time zone AS delivered_at,
    NULL::numeric AS minutes_to_match,
    NULL::numeric AS minutes_to_assign,
    NULL::numeric AS minutes_to_deliver;


--
-- TOC entry 249 (class 1259 OID 25306)
-- Name: v_stock_history; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_stock_history AS
 SELECT t.id,
    t.created_at,
    s.center_id,
    ac.name AS center_name,
    c.code AS category_code,
    t.type,
    t.quantity,
    sum(
        CASE t.type
            WHEN 'IN'::public.stock_tx_type THEN t.quantity
            WHEN 'OUT'::public.stock_tx_type THEN (- t.quantity)
            WHEN 'CORRECTION'::public.stock_tx_type THEN t.quantity
            ELSE 0
        END) OVER (PARTITION BY t.stock_id ORDER BY t.id) AS total_after,
    sum(
        CASE t.type
            WHEN 'RESERVE'::public.stock_tx_type THEN t.quantity
            WHEN 'RELEASE'::public.stock_tx_type THEN (- t.quantity)
            WHEN 'OUT'::public.stock_tx_type THEN (- t.quantity)
            ELSE 0
        END) OVER (PARTITION BY t.stock_id ORDER BY t.id) AS reserved_after,
    t.delivery_id,
    t.note,
    t.created_by,
    u.full_name AS created_by_name
   FROM ((((public.stock_transactions t
     JOIN public.stocks s ON ((s.id = t.stock_id)))
     JOIN public.centers ac ON ((ac.id = s.center_id)))
     JOIN public.categories c ON ((c.id = s.category_id)))
     LEFT JOIN public.users u ON ((u.id = t.created_by)));


--
-- TOC entry 256 (class 1259 OID 25338)
-- Name: v_stock_utilization; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_stock_utilization AS
SELECT
    NULL::bigint AS center_id,
    NULL::character varying(150) AS center_name,
    NULL::character varying(30) AS category_code,
    NULL::bigint AS total_in,
    NULL::bigint AS total_out,
    NULL::integer AS current_total,
    NULL::integer AS current_reserved,
    NULL::numeric AS utilization_pct;


--
-- TOC entry 245 (class 1259 OID 25286)
-- Name: v_unmatched_requests; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_unmatched_requests AS
 SELECT r.id,
    r.urgency,
    r.created_at,
    (now() - r.created_at) AS waiting_for,
    ij.items
   FROM (public.requests r
     LEFT JOIN public.v_request_items_json ij ON ((ij.request_id = r.id)))
  WHERE (r.status = 'OPEN'::public.request_status)
  ORDER BY r.urgency DESC, r.created_at;


--
-- TOC entry 3882 (class 0 OID 16821)
-- Dependencies: 236
-- Data for Name: blocks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.blocks (block_index, delivery_id, delivery_hash, previous_hash, current_hash, block_timestamp) FROM stdin;
0	\N	901131d838b17aac0f7885b81e03cbdc9f5157a00343d30ab22083685ed1416a	0000000000000000000000000000000000000000000000000000000000000000	0bcc09671bca3908ead10be3caa546c6214d6b67625985892a83b4c57a98d480	2026-11-21 10:50:01+00
\.


--
-- TOC entry 3867 (class 0 OID 16553)
-- Dependencies: 221
-- Data for Name: categories; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.categories (id, code, name, unit, is_active, created_at) FROM stdin;
1	WATER	Su	şişe	t	2026-11-21 10:50:12.395083+00
2	FOOD	Gıda kolisi	koli	t	2026-11-21 10:50:12.395083+00
3	BLANKET	Battaniye	adet	t	2026-11-21 10:50:12.395083+00
4	HYGIENE	Hijyen paketi	paket	t	2026-11-21 10:50:12.395083+00
5	BABY_SUPPLY	Bebek bakım paketi	paket	t	2026-11-21 10:50:12.395083+00
6	MEDICAL	İlk yardım kiti	adet	t	2026-11-21 10:50:12.395083+00
7	CLOTHING	Giysi paketi	paket	t	2026-11-21 10:50:12.395083+00
8	SHELTER	Çadır	adet	t	2026-11-21 10:50:12.395083+00
\.


--
-- TOC entry 3863 (class 0 OID 16506)
-- Dependencies: 217
-- Data for Name: centers; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.centers (id, name, address, phone, latitude, longitude, is_active, created_at, updated_at) FROM stdin;
\.


--
-- TOC entry 3877 (class 0 OID 16655)
-- Dependencies: 231
-- Data for Name: deliveries; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.deliveries (id, match_id, request_id, center_id, volunteer_id, status, prepared_at, prepared_by, picked_up_at, picked_up_by, delivered_at, delivered_verified_by, cancelled_at, cancel_reason, created_at, updated_at) FROM stdin;
\.


--
-- TOC entry 3875 (class 0 OID 16632)
-- Dependencies: 229
-- Data for Name: matches; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.matches (id, request_id, center_id, distance_km, strategy, status, created_at, decided_at) FROM stdin;
\.


--
-- TOC entry 3887 (class 0 OID 16879)
-- Dependencies: 241
-- Data for Name: prediction_scores; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.prediction_scores (prediction_id, category_id, probability) FROM stdin;
\.


--
-- TOC entry 3886 (class 0 OID 16858)
-- Dependencies: 240
-- Data for Name: predictions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.predictions (id, request_id, input_text, model_name, model_version, threshold, latency_ms, created_by, created_at) FROM stdin;
\.


--
-- TOC entry 3881 (class 0 OID 16794)
-- Dependencies: 235
-- Data for Name: qr_tokens; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.qr_tokens (id, delivery_id, purpose, token_hash, expires_at, used_at, used_by, revoked_at, created_by, created_at) FROM stdin;
\.


--
-- TOC entry 3873 (class 0 OID 16613)
-- Dependencies: 227
-- Data for Name: request_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.request_items (id, request_id, category_id, quantity) FROM stdin;
\.


--
-- TOC entry 3884 (class 0 OID 16839)
-- Dependencies: 238
-- Data for Name: request_status_history; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.request_status_history (id, request_id, old_status, new_status, changed_by, changed_at, note) FROM stdin;
\.


--
-- TOC entry 3871 (class 0 OID 16591)
-- Dependencies: 225
-- Data for Name: requests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.requests (id, created_by, latitude, longitude, address, people_number, urgency, description, contact_name, contact_phone, status, cancel_reason, cancelled_at, created_at, updated_at) FROM stdin;
\.


--
-- TOC entry 3879 (class 0 OID 16709)
-- Dependencies: 233
-- Data for Name: stock_transactions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stock_transactions (id, stock_id, type, quantity, delivery_id, note, created_by, created_at) FROM stdin;
\.


--
-- TOC entry 3869 (class 0 OID 16564)
-- Dependencies: 223
-- Data for Name: stocks; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stocks (id, center_id, category_id, total, reserved, low_stock_alert, updated_at) FROM stdin;
\.


--
-- TOC entry 3865 (class 0 OID 16534)
-- Dependencies: 219
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.users (id, full_name, email, phone, password_hash, role, center_id, is_active, created_at, updated_at) FROM stdin;
\.


--
-- TOC entry 3894 (class 0 OID 0)
-- Dependencies: 220
-- Name: categories_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.categories_id_seq', 8, true);


--
-- TOC entry 3895 (class 0 OID 0)
-- Dependencies: 216
-- Name: centers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.centers_id_seq', 1, false);


--
-- TOC entry 3896 (class 0 OID 0)
-- Dependencies: 230
-- Name: deliveries_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.deliveries_id_seq', 1, false);


--
-- TOC entry 3897 (class 0 OID 0)
-- Dependencies: 228
-- Name: matches_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.matches_id_seq', 1, false);


--
-- TOC entry 3898 (class 0 OID 0)
-- Dependencies: 239
-- Name: predictions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.predictions_id_seq', 1, false);


--
-- TOC entry 3899 (class 0 OID 0)
-- Dependencies: 234
-- Name: qr_tokens_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.qr_tokens_id_seq', 1, false);


--
-- TOC entry 3900 (class 0 OID 0)
-- Dependencies: 226
-- Name: request_items_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.request_items_id_seq', 1, false);


--
-- TOC entry 3901 (class 0 OID 0)
-- Dependencies: 237
-- Name: request_status_history_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.request_status_history_id_seq', 1, false);


--
-- TOC entry 3902 (class 0 OID 0)
-- Dependencies: 224
-- Name: requests_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.requests_id_seq', 1, false);


--
-- TOC entry 3903 (class 0 OID 0)
-- Dependencies: 232
-- Name: stock_transactions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.stock_transactions_id_seq', 1, false);


--
-- TOC entry 3904 (class 0 OID 0)
-- Dependencies: 222
-- Name: stocks_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.stocks_id_seq', 1, false);


--
-- TOC entry 3905 (class 0 OID 0)
-- Dependencies: 218
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.users_id_seq', 1, false);


--
-- TOC entry 3637 (class 2606 OID 16828)
-- Name: blocks blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT blocks_pkey PRIMARY KEY (block_index);


--
-- TOC entry 3587 (class 2606 OID 16560)
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- TOC entry 3579 (class 2606 OID 16517)
-- Name: centers centers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.centers
    ADD CONSTRAINT centers_pkey PRIMARY KEY (id);


--
-- TOC entry 3613 (class 2606 OID 16668)
-- Name: deliveries deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (id);


--
-- TOC entry 3608 (class 2606 OID 16640)
-- Name: matches matches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_pkey PRIMARY KEY (id);


--
-- TOC entry 3653 (class 2606 OID 16884)
-- Name: prediction_scores prediction_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prediction_scores
    ADD CONSTRAINT prediction_scores_pkey PRIMARY KEY (prediction_id, category_id);


--
-- TOC entry 3650 (class 2606 OID 16868)
-- Name: predictions predictions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predictions
    ADD CONSTRAINT predictions_pkey PRIMARY KEY (id);


--
-- TOC entry 3632 (class 2606 OID 16802)
-- Name: qr_tokens qr_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qr_tokens
    ADD CONSTRAINT qr_tokens_pkey PRIMARY KEY (id);


--
-- TOC entry 3602 (class 2606 OID 16618)
-- Name: request_items request_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_items
    ADD CONSTRAINT request_items_pkey PRIMARY KEY (id);


--
-- TOC entry 3645 (class 2606 OID 16846)
-- Name: request_status_history request_status_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_status_history
    ADD CONSTRAINT request_status_history_pkey PRIMARY KEY (id);


--
-- TOC entry 3599 (class 2606 OID 16606)
-- Name: requests requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requests
    ADD CONSTRAINT requests_pkey PRIMARY KEY (id);


--
-- TOC entry 3627 (class 2606 OID 16718)
-- Name: stock_transactions stock_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transactions
    ADD CONSTRAINT stock_transactions_pkey PRIMARY KEY (id);


--
-- TOC entry 3593 (class 2606 OID 16577)
-- Name: stocks stocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocks
    ADD CONSTRAINT stocks_pkey PRIMARY KEY (id);


--
-- TOC entry 3639 (class 2606 OID 16832)
-- Name: blocks uq_blocks_current_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT uq_blocks_current_hash UNIQUE (current_hash);


--
-- TOC entry 3641 (class 2606 OID 16830)
-- Name: blocks uq_blocks_delivery; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT uq_blocks_delivery UNIQUE (delivery_id);


--
-- TOC entry 3589 (class 2606 OID 16562)
-- Name: categories uq_categories_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT uq_categories_code UNIQUE (code);


--
-- TOC entry 3581 (class 2606 OID 16519)
-- Name: centers uq_centers_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.centers
    ADD CONSTRAINT uq_centers_name UNIQUE (name);


--
-- TOC entry 3610 (class 2606 OID 16642)
-- Name: matches uq_matches_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT uq_matches_identity UNIQUE (id, request_id, center_id);


--
-- TOC entry 3634 (class 2606 OID 16804)
-- Name: qr_tokens uq_qr_tokens_hash; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qr_tokens
    ADD CONSTRAINT uq_qr_tokens_hash UNIQUE (token_hash);


--
-- TOC entry 3604 (class 2606 OID 16620)
-- Name: request_items uq_request_items_category; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_items
    ADD CONSTRAINT uq_request_items_category UNIQUE (request_id, category_id);


--
-- TOC entry 3595 (class 2606 OID 16579)
-- Name: stocks uq_stocks_center_category; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocks
    ADD CONSTRAINT uq_stocks_center_category UNIQUE (center_id, category_id);


--
-- TOC entry 3585 (class 2606 OID 16545)
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- TOC entry 3614 (class 1259 OID 16905)
-- Name: ix_deliveries_center; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_deliveries_center ON public.deliveries USING btree (center_id, status);


--
-- TOC entry 3615 (class 1259 OID 16912)
-- Name: ix_deliveries_match_fk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_deliveries_match_fk ON public.deliveries USING btree (match_id, request_id, center_id);


--
-- TOC entry 3616 (class 1259 OID 16914)
-- Name: ix_deliveries_picked_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_deliveries_picked_by ON public.deliveries USING btree (picked_up_by) WHERE (picked_up_by IS NOT NULL);


--
-- TOC entry 3617 (class 1259 OID 16913)
-- Name: ix_deliveries_prepared_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_deliveries_prepared_by ON public.deliveries USING btree (prepared_by) WHERE (prepared_by IS NOT NULL);


--
-- TOC entry 3618 (class 1259 OID 16915)
-- Name: ix_deliveries_verified_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_deliveries_verified_by ON public.deliveries USING btree (delivered_verified_by) WHERE (delivered_verified_by IS NOT NULL);


--
-- TOC entry 3619 (class 1259 OID 16906)
-- Name: ix_deliveries_volunteer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_deliveries_volunteer ON public.deliveries USING btree (volunteer_id, created_at DESC);


--
-- TOC entry 3605 (class 1259 OID 25260)
-- Name: ix_matches_center; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_matches_center ON public.matches USING btree (center_id, status);


--
-- TOC entry 3606 (class 1259 OID 25259)
-- Name: ix_matches_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_matches_request ON public.matches USING btree (request_id, status);


--
-- TOC entry 3646 (class 1259 OID 16919)
-- Name: ix_predictions_creator; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_predictions_creator ON public.predictions USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- TOC entry 3647 (class 1259 OID 16910)
-- Name: ix_predictions_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_predictions_model ON public.predictions USING btree (model_name, model_version);


--
-- TOC entry 3648 (class 1259 OID 16909)
-- Name: ix_predictions_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_predictions_request ON public.predictions USING btree (request_id);


--
-- TOC entry 3628 (class 1259 OID 16917)
-- Name: ix_qr_tokens_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_qr_tokens_created_by ON public.qr_tokens USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- TOC entry 3629 (class 1259 OID 16907)
-- Name: ix_qr_tokens_delivery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_qr_tokens_delivery ON public.qr_tokens USING btree (delivery_id);


--
-- TOC entry 3630 (class 1259 OID 16916)
-- Name: ix_qr_tokens_used_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_qr_tokens_used_by ON public.qr_tokens USING btree (used_by) WHERE (used_by IS NOT NULL);


--
-- TOC entry 3642 (class 1259 OID 16918)
-- Name: ix_req_hist_changed_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_req_hist_changed_by ON public.request_status_history USING btree (changed_by) WHERE (changed_by IS NOT NULL);


--
-- TOC entry 3643 (class 1259 OID 16908)
-- Name: ix_req_hist_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_req_hist_request ON public.request_status_history USING btree (request_id, changed_at);


--
-- TOC entry 3600 (class 1259 OID 16902)
-- Name: ix_request_items_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_request_items_category ON public.request_items USING btree (category_id);


--
-- TOC entry 3596 (class 1259 OID 16901)
-- Name: ix_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_requests_status ON public.requests USING btree (status, urgency DESC, created_at);


--
-- TOC entry 3651 (class 1259 OID 16911)
-- Name: ix_scores_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_scores_category ON public.prediction_scores USING btree (category_id);


--
-- TOC entry 3623 (class 1259 OID 16900)
-- Name: ix_stock_tx_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stock_tx_created_by ON public.stock_transactions USING btree (created_by);


--
-- TOC entry 3624 (class 1259 OID 16899)
-- Name: ix_stock_tx_delivery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stock_tx_delivery ON public.stock_transactions USING btree (delivery_id) WHERE (delivery_id IS NOT NULL);


--
-- TOC entry 3625 (class 1259 OID 16898)
-- Name: ix_stock_tx_stock_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stock_tx_stock_time ON public.stock_transactions USING btree (stock_id, id);


--
-- TOC entry 3590 (class 1259 OID 16896)
-- Name: ix_stocks_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stocks_category ON public.stocks USING btree (category_id);


--
-- TOC entry 3591 (class 1259 OID 16897)
-- Name: ix_stocks_low; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stocks_low ON public.stocks USING btree (center_id) WHERE (available <= low_stock_alert);


--
-- TOC entry 3582 (class 1259 OID 16895)
-- Name: ix_users_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_users_role ON public.users USING btree (role) WHERE is_active;


--
-- TOC entry 3597 (class 1259 OID 16920)
-- Name: ixrequests_creator; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ixrequests_creator ON public.requests USING btree (created_by, created_at DESC);


--
-- TOC entry 3620 (class 1259 OID 16706)
-- Name: uq_deliveries_one_active_per_volunteer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_deliveries_one_active_per_volunteer ON public.deliveries USING btree (volunteer_id) WHERE (status = ANY (ARRAY['ASSIGNED'::public.delivery_status, 'PREPARING'::public.delivery_status, 'IN_TRANSIT'::public.delivery_status]));


--
-- TOC entry 3621 (class 1259 OID 16705)
-- Name: uq_deliveries_one_live_per_request; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_deliveries_one_live_per_request ON public.deliveries USING btree (request_id) WHERE (status <> 'CANCELLED'::public.delivery_status);


--
-- TOC entry 3622 (class 1259 OID 16704)
-- Name: uq_deliveries_one_per_match; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_deliveries_one_per_match ON public.deliveries USING btree (match_id) WHERE (status <> 'CANCELLED'::public.delivery_status);


--
-- TOC entry 3611 (class 1259 OID 25269)
-- Name: uq_matches_one_accepted; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_matches_one_accepted ON public.matches USING btree (request_id) WHERE (status = 'ACCEPTED'::public.match_status);


--
-- TOC entry 3635 (class 1259 OID 16820)
-- Name: uq_qr_tokens_one_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_qr_tokens_one_live ON public.qr_tokens USING btree (delivery_id, purpose) WHERE ((used_at IS NULL) AND (revoked_at IS NULL));


--
-- TOC entry 3583 (class 1259 OID 16551)
-- Name: uq_users_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_users_email_lower ON public.users USING btree (lower((email)::text));


--
-- TOC entry 3859 (class 2618 OID 25346)
-- Name: v_ai_prediction_eval _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.v_ai_prediction_eval AS
 SELECT p.id AS prediction_id,
    p.request_id,
    p.model_name,
    p.model_version,
    p.threshold,
    count(*) FILTER (WHERE ((sc.probability >= p.threshold) AND (it.category_id IS NOT NULL))) AS tp,
    count(*) FILTER (WHERE ((sc.probability >= p.threshold) AND (it.category_id IS NULL))) AS fp,
    ( SELECT count(*) AS count
           FROM public.request_items i2
          WHERE ((i2.request_id = p.request_id) AND (NOT (EXISTS ( SELECT 1
                   FROM public.prediction_scores s2
                  WHERE ((s2.prediction_id = p.id) AND (s2.category_id = i2.category_id) AND (s2.probability >= p.threshold))))))) AS fn
   FROM ((public.predictions p
     JOIN public.prediction_scores sc ON ((sc.prediction_id = p.id)))
     LEFT JOIN public.request_items it ON (((it.request_id = p.request_id) AND (it.category_id = sc.category_id))))
  WHERE (p.request_id IS NOT NULL)
  GROUP BY p.id;


--
-- TOC entry 3856 (class 2618 OID 25331)
-- Name: v_request_timeline _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.v_request_timeline AS
 SELECT r.id AS request_id,
    r.urgency,
    r.status,
    r.created_at,
    min(h.changed_at) FILTER (WHERE (h.new_status = 'MATCHED'::public.request_status)) AS matched_at,
    min(h.changed_at) FILTER (WHERE (h.new_status = 'ASSIGNED'::public.request_status)) AS assigned_at,
    min(h.changed_at) FILTER (WHERE (h.new_status = 'IN_TRANSIT'::public.request_status)) AS in_transit_at,
    min(h.changed_at) FILTER (WHERE (h.new_status = 'DELIVERED'::public.request_status)) AS delivered_at,
    round((EXTRACT(epoch FROM (min(h.changed_at) FILTER (WHERE (h.new_status = 'MATCHED'::public.request_status)) - r.created_at)) / 60.0), 2) AS minutes_to_match,
    round((EXTRACT(epoch FROM (min(h.changed_at) FILTER (WHERE (h.new_status = 'ASSIGNED'::public.request_status)) - r.created_at)) / 60.0), 2) AS minutes_to_assign,
    round((EXTRACT(epoch FROM (min(h.changed_at) FILTER (WHERE (h.new_status = 'DELIVERED'::public.request_status)) - r.created_at)) / 60.0), 2) AS minutes_to_deliver
   FROM (public.requests r
     LEFT JOIN public.request_status_history h ON ((h.request_id = r.id)))
  GROUP BY r.id;


--
-- TOC entry 3858 (class 2618 OID 25341)
-- Name: v_stock_utilization _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.v_stock_utilization AS
 SELECT s.center_id,
    ac.name AS center_name,
    c.code AS category_code,
    COALESCE(sum(t.quantity) FILTER (WHERE (t.type = 'IN'::public.stock_tx_type)), (0)::bigint) AS total_in,
    COALESCE(sum(t.quantity) FILTER (WHERE (t.type = 'OUT'::public.stock_tx_type)), (0)::bigint) AS total_out,
    s.total AS current_total,
    s.reserved AS current_reserved,
    round(((100.0 * (COALESCE(sum(t.quantity) FILTER (WHERE (t.type = 'OUT'::public.stock_tx_type)), (0)::bigint))::numeric) / (NULLIF((COALESCE(sum(t.quantity) FILTER (WHERE (t.type = 'OUT'::public.stock_tx_type)), (0)::bigint) + s.total), 0))::numeric), 2) AS utilization_pct
   FROM (((public.stocks s
     JOIN public.centers ac ON ((ac.id = s.center_id)))
     JOIN public.categories c ON ((c.id = s.category_id)))
     LEFT JOIN public.stock_transactions t ON ((t.stock_id = s.id)))
  GROUP BY s.id, ac.name, c.code;


--
-- TOC entry 3698 (class 2620 OID 25118)
-- Name: blocks trg_blocks_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_blocks_append_only BEFORE DELETE OR UPDATE ON public.blocks FOR EACH ROW EXECUTE FUNCTION public.trg_fn_append_only();


--
-- TOC entry 3699 (class 2620 OID 25121)
-- Name: blocks trg_blocks_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_blocks_no_truncate BEFORE TRUNCATE ON public.blocks FOR EACH STATEMENT EXECUTE FUNCTION public.trg_fn_append_only();


--
-- TOC entry 3682 (class 2620 OID 25137)
-- Name: centers trg_centers_deactivate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_centers_deactivate BEFORE UPDATE OF is_active ON public.centers FOR EACH ROW EXECUTE FUNCTION public.trg_fn_centers_deactivate();


--
-- TOC entry 3683 (class 2620 OID 25112)
-- Name: centers trg_centers_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_centers_updated_at BEFORE UPDATE ON public.centers FOR EACH ROW EXECUTE FUNCTION public.trg_fn_set_updated_at();


--
-- TOC entry 3692 (class 2620 OID 25135)
-- Name: deliveries trg_deliveries_after; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_deliveries_after AFTER INSERT OR UPDATE OF status ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.trg_fn_deliveries_after();


--
-- TOC entry 3693 (class 2620 OID 25133)
-- Name: deliveries trg_deliveries_before; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_deliveries_before BEFORE INSERT OR UPDATE ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.trg_fn_deliveries_before();


--
-- TOC entry 3694 (class 2620 OID 25115)
-- Name: deliveries trg_deliveries_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_deliveries_updated_at BEFORE UPDATE ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.trg_fn_set_updated_at();


--
-- TOC entry 3700 (class 2620 OID 25119)
-- Name: request_status_history trg_req_hist_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_req_hist_append_only BEFORE DELETE OR UPDATE ON public.request_status_history FOR EACH ROW EXECUTE FUNCTION public.trg_fn_append_only();


--
-- TOC entry 3691 (class 2620 OID 25131)
-- Name: request_items trg_request_items_lock; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_request_items_lock BEFORE INSERT OR DELETE OR UPDATE ON public.request_items FOR EACH ROW EXECUTE FUNCTION public.trg_fn_request_items_lock();


--
-- TOC entry 3688 (class 2620 OID 25127)
-- Name: requests trg_requests_before; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_requests_before BEFORE INSERT OR UPDATE OF status ON public.requests FOR EACH ROW EXECUTE FUNCTION public.trg_fn_requests_before();


--
-- TOC entry 3689 (class 2620 OID 25129)
-- Name: requests trg_requests_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_requests_history AFTER INSERT OR UPDATE OF status ON public.requests FOR EACH ROW EXECUTE FUNCTION public.trg_fn_requests_history();


--
-- TOC entry 3690 (class 2620 OID 25114)
-- Name: requests trg_requests_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_requests_updated_at BEFORE UPDATE ON public.requests FOR EACH ROW EXECUTE FUNCTION public.trg_fn_set_updated_at();


--
-- TOC entry 3695 (class 2620 OID 25117)
-- Name: stock_transactions trg_stock_tx_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_stock_tx_append_only BEFORE DELETE OR UPDATE ON public.stock_transactions FOR EACH ROW EXECUTE FUNCTION public.trg_fn_append_only();


--
-- TOC entry 3696 (class 2620 OID 25125)
-- Name: stock_transactions trg_stock_tx_apply; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_stock_tx_apply BEFORE INSERT ON public.stock_transactions FOR EACH ROW EXECUTE FUNCTION public.trg_fn_stock_tx_apply();


--
-- TOC entry 3697 (class 2620 OID 25120)
-- Name: stock_transactions trg_stock_tx_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_stock_tx_no_truncate BEFORE TRUNCATE ON public.stock_transactions FOR EACH STATEMENT EXECUTE FUNCTION public.trg_fn_append_only();


--
-- TOC entry 3686 (class 2620 OID 25123)
-- Name: stocks trg_stocks_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_stocks_guard BEFORE INSERT OR UPDATE ON public.stocks FOR EACH ROW EXECUTE FUNCTION public.trg_fn_stocks_guard();


--
-- TOC entry 3687 (class 2620 OID 25113)
-- Name: stocks trg_stocks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_stocks_updated_at BEFORE UPDATE ON public.stocks FOR EACH ROW EXECUTE FUNCTION public.trg_fn_set_updated_at();


--
-- TOC entry 3684 (class 2620 OID 25139)
-- Name: users trg_users_protect; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_protect BEFORE DELETE OR UPDATE OF role, is_active, center_id ON public.users FOR EACH ROW EXECUTE FUNCTION public.trg_fn_users_protect();


--
-- TOC entry 3685 (class 2620 OID 25111)
-- Name: users trg_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.trg_fn_set_updated_at();


--
-- TOC entry 3675 (class 2606 OID 16833)
-- Name: blocks blocks_delivery_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT blocks_delivery_id_fkey FOREIGN KEY (delivery_id) REFERENCES public.deliveries(id) ON DELETE RESTRICT;


--
-- TOC entry 3662 (class 2606 OID 16674)
-- Name: deliveries deliveries_center_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_center_id_fkey FOREIGN KEY (center_id) REFERENCES public.centers(id) ON DELETE RESTRICT;


--
-- TOC entry 3663 (class 2606 OID 16694)
-- Name: deliveries deliveries_delivered_verified_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_delivered_verified_by_fkey FOREIGN KEY (delivered_verified_by) REFERENCES public.users(id);


--
-- TOC entry 3664 (class 2606 OID 16689)
-- Name: deliveries deliveries_picked_up_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_picked_up_by_fkey FOREIGN KEY (picked_up_by) REFERENCES public.users(id);


--
-- TOC entry 3665 (class 2606 OID 16684)
-- Name: deliveries deliveries_prepared_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_prepared_by_fkey FOREIGN KEY (prepared_by) REFERENCES public.users(id);


--
-- TOC entry 3666 (class 2606 OID 16669)
-- Name: deliveries deliveries_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE RESTRICT;


--
-- TOC entry 3667 (class 2606 OID 16679)
-- Name: deliveries deliveries_volunteer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_volunteer_id_fkey FOREIGN KEY (volunteer_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- TOC entry 3668 (class 2606 OID 16699)
-- Name: deliveries fk_deliveries_match; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT fk_deliveries_match FOREIGN KEY (match_id, request_id, center_id) REFERENCES public.matches(id, request_id, center_id) ON DELETE RESTRICT;


--
-- TOC entry 3660 (class 2606 OID 16648)
-- Name: matches matches_center_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_center_id_fkey FOREIGN KEY (center_id) REFERENCES public.centers(id) ON DELETE RESTRICT;


--
-- TOC entry 3661 (class 2606 OID 16643)
-- Name: matches matches_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE;


--
-- TOC entry 3680 (class 2606 OID 16890)
-- Name: prediction_scores prediction_scores_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prediction_scores
    ADD CONSTRAINT prediction_scores_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- TOC entry 3681 (class 2606 OID 16885)
-- Name: prediction_scores prediction_scores_prediction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prediction_scores
    ADD CONSTRAINT prediction_scores_prediction_id_fkey FOREIGN KEY (prediction_id) REFERENCES public.predictions(id) ON DELETE CASCADE;


--
-- TOC entry 3678 (class 2606 OID 16874)
-- Name: predictions predictions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predictions
    ADD CONSTRAINT predictions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- TOC entry 3679 (class 2606 OID 16869)
-- Name: predictions predictions_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predictions
    ADD CONSTRAINT predictions_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE;


--
-- TOC entry 3672 (class 2606 OID 16815)
-- Name: qr_tokens qr_tokens_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qr_tokens
    ADD CONSTRAINT qr_tokens_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- TOC entry 3673 (class 2606 OID 16805)
-- Name: qr_tokens qr_tokens_delivery_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qr_tokens
    ADD CONSTRAINT qr_tokens_delivery_id_fkey FOREIGN KEY (delivery_id) REFERENCES public.deliveries(id) ON DELETE RESTRICT;


--
-- TOC entry 3674 (class 2606 OID 16810)
-- Name: qr_tokens qr_tokens_used_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.qr_tokens
    ADD CONSTRAINT qr_tokens_used_by_fkey FOREIGN KEY (used_by) REFERENCES public.users(id);


--
-- TOC entry 3658 (class 2606 OID 16626)
-- Name: request_items request_items_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_items
    ADD CONSTRAINT request_items_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- TOC entry 3659 (class 2606 OID 16621)
-- Name: request_items request_items_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_items
    ADD CONSTRAINT request_items_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE;


--
-- TOC entry 3676 (class 2606 OID 16852)
-- Name: request_status_history request_status_history_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_status_history
    ADD CONSTRAINT request_status_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(id);


--
-- TOC entry 3677 (class 2606 OID 16847)
-- Name: request_status_history request_status_history_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_status_history
    ADD CONSTRAINT request_status_history_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE;


--
-- TOC entry 3657 (class 2606 OID 16607)
-- Name: requests requests_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requests
    ADD CONSTRAINT requests_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- TOC entry 3669 (class 2606 OID 16729)
-- Name: stock_transactions stock_transactions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transactions
    ADD CONSTRAINT stock_transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- TOC entry 3670 (class 2606 OID 16724)
-- Name: stock_transactions stock_transactions_delivery_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transactions
    ADD CONSTRAINT stock_transactions_delivery_id_fkey FOREIGN KEY (delivery_id) REFERENCES public.deliveries(id) ON DELETE RESTRICT;


--
-- TOC entry 3671 (class 2606 OID 16719)
-- Name: stock_transactions stock_transactions_stock_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transactions
    ADD CONSTRAINT stock_transactions_stock_id_fkey FOREIGN KEY (stock_id) REFERENCES public.stocks(id) ON DELETE RESTRICT;


--
-- TOC entry 3655 (class 2606 OID 16585)
-- Name: stocks stocks_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocks
    ADD CONSTRAINT stocks_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- TOC entry 3656 (class 2606 OID 16580)
-- Name: stocks stocks_center_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocks
    ADD CONSTRAINT stocks_center_id_fkey FOREIGN KEY (center_id) REFERENCES public.centers(id) ON DELETE RESTRICT;


--
-- TOC entry 3654 (class 2606 OID 16546)
-- Name: users users_center_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_center_id_fkey FOREIGN KEY (center_id) REFERENCES public.centers(id) ON DELETE RESTRICT;


-- Completed on 2026-11-21 14:36:49

--
-- PostgreSQL database dump complete
--

\unrestrict hbLVrdR8XiiGisTrd3tPFzdOA6CDvLUvggIdh0XA6gNevl1fw2wcvmBDJJmJxkt

