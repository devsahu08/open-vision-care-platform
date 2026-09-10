-- ═══════════════════════════════════════════════════════════════════════════
-- iCare – Brighter Future Program
-- eye_exam_procedures.sql  |  Eye Exam Module – Database Schema + Stored Procedures
-- PostgreSQL 14+
-- ═══════════════════════════════════════════════════════════════════════════

DO $$ BEGIN
    CREATE TYPE exam_allocation_status AS ENUM (
        'No Glasses Required',
        'Added to Waiting List',
        'Glasses Assigned',
        'Glasses Delivered'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END; $$;

CREATE TABLE IF NOT EXISTS eye_exams (
    id               SERIAL          PRIMARY KEY,
    exam_code        VARCHAR(20)     NOT NULL UNIQUE, 
    patient_id       UUID            NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
    campaign_id      INTEGER         REFERENCES campaigns(id) ON DELETE SET NULL,
    doctor_id        INTEGER         REFERENCES users(id) ON DELETE SET NULL,
    exam_date        DATE            NOT NULL DEFAULT CURRENT_DATE,
    allocation_status exam_allocation_status NOT NULL DEFAULT 'No Glasses Required',
    assigned_sku     VARCHAR(50),
    is_deleted       BOOLEAN         NOT NULL DEFAULT FALSE,
    deleted_at       TIMESTAMPTZ,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_exam_patient    ON eye_exams(patient_id)    WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_exam_campaign   ON eye_exams(campaign_id)   WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_exam_doctor     ON eye_exams(doctor_id)     WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_exam_date       ON eye_exams(exam_date DESC)WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_exam_status     ON eye_exams(allocation_status) WHERE NOT is_deleted;
CREATE UNIQUE INDEX IF NOT EXISTS idx_exam_code ON eye_exams(exam_code);

CREATE TABLE IF NOT EXISTS exam_prescriptions (
    id          SERIAL      PRIMARY KEY,
    exam_id     INTEGER     NOT NULL UNIQUE REFERENCES eye_exams(id) ON DELETE CASCADE,
    od_sph      NUMERIC(5,2) NOT NULL,
    od_cyl      NUMERIC(5,2) NOT NULL DEFAULT 0.00,
    od_axis     SMALLINT               CHECK (od_axis BETWEEN 0 AND 180),
    od_add      NUMERIC(5,2)           DEFAULT 0.00,  
    os_sph      NUMERIC(5,2) NOT NULL,
    os_cyl      NUMERIC(5,2) NOT NULL DEFAULT 0.00,
    os_axis     SMALLINT               CHECK (os_axis BETWEEN 0 AND 180),
    os_add      NUMERIC(5,2)           DEFAULT 0.00,  
    lens_type   VARCHAR(50),   
    frame_size  VARCHAR(20),   
    ipd         NUMERIC(5,2),  
    rx_notes    TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION _trg_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_exam_updated_at ON eye_exams;
CREATE TRIGGER trg_exam_updated_at
    BEFORE UPDATE ON eye_exams
    FOR EACH ROW EXECUTE FUNCTION _trg_set_updated_at();

DROP TRIGGER IF EXISTS trg_rx_updated_at ON exam_prescriptions;
CREATE TRIGGER trg_rx_updated_at
    BEFORE UPDATE ON exam_prescriptions
    FOR EACH ROW EXECUTE FUNCTION _trg_set_updated_at();

CREATE SEQUENCE IF NOT EXISTS exam_code_seq START 10000 INCREMENT 1;

CREATE OR REPLACE FUNCTION generate_exam_code()
RETURNS VARCHAR AS $$
BEGIN
    RETURN 'EXM-' || LPAD(nextval('exam_code_seq')::TEXT, 5, '0');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sp_search_patients_exam(
    p_query     TEXT,
    p_camp_id   INTEGER,
    p_limit     INTEGER DEFAULT 10
)
RETURNS TABLE (
    patient_id            UUID,
    full_name             TEXT,
    age                   INTEGER,
    gender                VARCHAR,
    wears_glasses         SMALLINT,
    blurred_vision        SMALLINT,
    vision_difficulty     SMALLINT,
    double_vision         SMALLINT,
    has_exam_this_camp    BOOLEAN
)
LANGUAGE sql STABLE AS $$
    SELECT
        p.id,
        p.first_name || ' ' || p.last_name,
        DATE_PART('year', AGE(p.dob))::INTEGER,
        p.gender::VARCHAR                       AS gender, -- Changed from g.name to p.gender
        COALESCE(mq.IsWearingCorrection, 0)     AS wears_glasses,
        COALESCE(mq.IsBlurredVision,     0)     AS blurred_vision,
        COALESCE(mq.IsVisionDifficulty,  0)     AS vision_difficulty,
        COALESCE(mq.IsDoubleVision,      0)     AS double_vision,
        EXISTS (
            SELECT 1
            FROM eye_exams e
            WHERE e.patient_id  = p.id
              AND e.campaign_id = p_camp_id
              AND NOT e.is_deleted
        ) AS has_exam_this_camp
    FROM patients p
    -- Removed: LEFT JOIN genders g ON g.id = p.gender_id
    LEFT JOIN medical_questionnaire mq ON mq.patient_id = p.id
    WHERE
        p.camp_id    = p_camp_id
        AND p.deleted_at IS NULL
        AND (
            p_query IS NULL
            OR p.first_name ILIKE '%' || p_query || '%'
            OR p.last_name  ILIKE '%' || p_query || '%'
            OR (p.first_name || ' ' || p.last_name) ILIKE '%' || p_query || '%'
        )
    ORDER BY p.first_name, p.last_name
    LIMIT p_limit;
$$;


CREATE OR REPLACE FUNCTION sp_create_eye_exam(
    p_patient_id    UUID,
    p_campaign_id   INTEGER,
    p_doctor_id     INTEGER,
    p_exam_date     DATE        DEFAULT CURRENT_DATE,
    p_status        exam_allocation_status DEFAULT 'No Glasses Required',
    p_od_sph        NUMERIC(5,2) DEFAULT NULL,
    p_od_cyl        NUMERIC(5,2) DEFAULT 0.00,
    p_od_axis       SMALLINT     DEFAULT NULL,
    p_od_add        NUMERIC(5,2) DEFAULT 0.00,
    p_os_sph        NUMERIC(5,2) DEFAULT NULL,
    p_os_cyl        NUMERIC(5,2) DEFAULT 0.00,
    p_os_axis       SMALLINT     DEFAULT NULL,
    p_os_add        NUMERIC(5,2) DEFAULT 0.00,
    p_lens_type     VARCHAR(50)  DEFAULT NULL,
    p_frame_size    VARCHAR(20)  DEFAULT NULL,
    p_ipd           NUMERIC(5,2) DEFAULT NULL,
    p_rx_notes      TEXT         DEFAULT NULL
)
RETURNS TABLE (
    exam_id     INTEGER,
    exam_code   VARCHAR
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code  VARCHAR(20);
    v_id    INTEGER;
    v_has_rx BOOLEAN;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM patients
        WHERE id = p_patient_id AND camp_id = p_campaign_id AND deleted_at is NULL
    ) THEN
        RAISE EXCEPTION 'Patient not found or does not belong to this campaign.';
    END IF;
 
    IF EXISTS (
        SELECT 1 FROM eye_exams
        WHERE patient_id  = p_patient_id
          AND campaign_id = p_campaign_id
          AND NOT is_deleted
    ) THEN
        RAISE EXCEPTION 'An exam already exists for this patient in this campaign.';
    END IF;
 
    v_code := generate_exam_code();
 
    INSERT INTO eye_exams (
        exam_code, patient_id, campaign_id, doctor_id,
        exam_date, allocation_status
    ) VALUES (
        v_code, p_patient_id, p_campaign_id, p_doctor_id,
        p_exam_date, p_status
    )
    RETURNING id INTO v_id;
 
    v_has_rx := (p_od_sph IS NOT NULL AND p_os_sph IS NOT NULL);
 
    IF v_has_rx THEN
        INSERT INTO exam_prescriptions (
            exam_id,
            od_sph, od_cyl, od_axis, od_add,
            os_sph, os_cyl, os_axis, os_add,
            lens_type, frame_size, ipd, rx_notes
        ) VALUES (
            v_id,
            p_od_sph, COALESCE(p_od_cyl, 0.00), p_od_axis, COALESCE(p_od_add, 0.00),
            p_os_sph, COALESCE(p_os_cyl, 0.00), p_os_axis, COALESCE(p_os_add, 0.00),
            p_lens_type, p_frame_size, p_ipd, p_rx_notes
        );
    END IF;
 
    RETURN QUERY SELECT v_id, v_code;
END;
$$;
 

CREATE OR REPLACE FUNCTION sp_get_exams(
    p_campaign_id   INTEGER  DEFAULT NULL,
    p_patient_name  TEXT     DEFAULT NULL,
    p_doctor_name   TEXT     DEFAULT NULL,
    p_status        TEXT     DEFAULT NULL,
    p_sort_dir      VARCHAR  DEFAULT 'desc',   
    p_limit         INTEGER  DEFAULT 10,
    p_offset        INTEGER  DEFAULT 0
)
RETURNS TABLE (
    id                  INTEGER,
    exam_code           VARCHAR,
    patient_id          UUID,
    patient_name        TEXT,
    patient_age         INTEGER,
    patient_gender      VARCHAR,
    campaign_id         INTEGER,
    campaign_name       VARCHAR,
    doctor_id           INTEGER,
    doctor_name         TEXT,
    allocation_status   exam_allocation_status,
    assigned_sku        VARCHAR,
    exam_date           DATE,
    has_rx              BOOLEAN,
    od_sph              NUMERIC,
    od_cyl              NUMERIC,
    od_axis             SMALLINT,
    od_add              NUMERIC,
    os_sph              NUMERIC,
    os_cyl              NUMERIC,
    os_axis             SMALLINT,
    os_add              NUMERIC,
    lens_type           VARCHAR,
    frame_size          VARCHAR,
    ipd                 NUMERIC,
    rx_notes            TEXT,
    total_count         BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sort_dir VARCHAR := p_sort_dir;
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT
            e.id,
            e.exam_code,
            e.patient_id,
            (p.first_name || ' ' || p.last_name)::TEXT          AS patient_name,
            DATE_PART('year', AGE(p.dob))::INTEGER               AS patient_age,
            p.gender::VARCHAR                                    AS patient_gender,
            e.campaign_id,
            c.camp_name::VARCHAR                                 AS campaign_name,
            e.doctor_id,
            (u.first_name || ' ' || u.last_name)::TEXT          AS doctor_name,
            e.allocation_status,
            e.assigned_sku,
            e.exam_date                                          AS exam_date,
            (rx.id IS NOT NULL)                                  AS has_rx,
            rx.od_sph, rx.od_cyl, rx.od_axis, rx.od_add,
            rx.os_sph, rx.os_cyl, rx.os_axis, rx.os_add,
            rx.lens_type, rx.frame_size, rx.ipd, rx.rx_notes
        FROM eye_exams e
        JOIN patients  p ON p.id = e.patient_id
        LEFT JOIN campaigns           c  ON c.id  = e.campaign_id
        LEFT JOIN users                u  ON u.id  = e.doctor_id
        LEFT JOIN exam_prescriptions   rx ON rx.exam_id = e.id
        WHERE
            e.is_deleted = FALSE
            AND (p_campaign_id  IS NULL OR e.campaign_id = p_campaign_id)
            AND (p_patient_name IS NULL OR (p.first_name || ' ' || p.last_name) ILIKE '%' || p_patient_name || '%')
            AND (p_doctor_name  IS NULL OR (u.first_name || ' ' || u.last_name) ILIKE '%' || p_doctor_name  || '%')
            AND (p_status       IS NULL OR e.allocation_status::TEXT = p_status)
    ),
    counted AS (SELECT *, COUNT(*) OVER() AS total_count FROM base)
    SELECT *
    FROM counted
    ORDER BY
        CASE WHEN v_sort_dir = 'desc' THEN exam_date END DESC NULLS LAST,
        CASE WHEN v_sort_dir = 'asc'  THEN exam_date END ASC  NULLS LAST,
        id DESC
    LIMIT  p_limit
    OFFSET p_offset;
END;
$$;
 
-- Fix the Single Exam detail procedure by removing the GENDERS join
CREATE OR REPLACE FUNCTION sp_get_exam_by_id(
    p_exam_id   INTEGER
)
RETURNS TABLE (
    id                  INTEGER,
    exam_code           VARCHAR,
    patient_id          UUID,
    patient_name        TEXT,
    patient_age         INTEGER,
    patient_gender      VARCHAR,
    campaign_id         INTEGER,
    campaign_name       VARCHAR,
    doctor_id           INTEGER,
    doctor_name         TEXT,
    allocation_status   exam_allocation_status,
    assigned_sku        VARCHAR,
    exam_date           DATE,
    has_rx              BOOLEAN,
    od_sph              NUMERIC,
    od_cyl              NUMERIC,
    od_axis             SMALLINT,
    od_add              NUMERIC,
    os_sph              NUMERIC,
    os_cyl              NUMERIC,
    os_axis             SMALLINT,
    os_add              NUMERIC,
    lens_type           VARCHAR,
    frame_size          VARCHAR,
    ipd                 NUMERIC,
    rx_notes            TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        e.id,
        e.exam_code,
        e.patient_id,
        (p.first_name || ' ' || p.last_name)::TEXT     AS patient_name,
        DATE_PART('year', AGE(p.dob))::INTEGER         AS patient_age,
        p.gender::VARCHAR                              AS patient_gender, -- Changed from g.name to p.gender
        e.campaign_id,
        c.camp_name::VARCHAR                           AS campaign_name,
        e.doctor_id,
        (u.first_name || ' ' || u.last_name)::TEXT    AS doctor_name,
        e.allocation_status,
        e.assigned_sku,
        e.exam_date,
        (rx.id IS NOT NULL)                            AS has_rx,
        rx.od_sph, rx.od_cyl, rx.od_axis, rx.od_add,
        rx.os_sph, rx.os_cyl, rx.os_axis, rx.os_add,
        rx.lens_type, rx.frame_size, rx.ipd, rx.rx_notes
    FROM eye_exams e
    JOIN patients  p ON p.id = e.patient_id
    LEFT JOIN campaigns          c  ON c.id  = e.campaign_id
    LEFT JOIN users              u  ON u.id  = e.doctor_id
    LEFT JOIN exam_prescriptions rx ON rx.exam_id = e.id
    WHERE e.id = p_exam_id AND NOT e.is_deleted;
$$;
 
CREATE OR REPLACE FUNCTION sp_update_eye_exam(
    p_exam_id       INTEGER,
    p_doctor_id     INTEGER     DEFAULT NULL,
    p_exam_date     DATE        DEFAULT NULL,
    p_od_sph        NUMERIC(5,2) DEFAULT NULL,
    p_od_cyl        NUMERIC(5,2) DEFAULT NULL,
    p_od_axis       SMALLINT     DEFAULT NULL,
    p_od_add        NUMERIC(5,2) DEFAULT NULL,
    p_os_sph        NUMERIC(5,2) DEFAULT NULL,
    p_os_cyl        NUMERIC(5,2) DEFAULT NULL,
    p_os_axis       SMALLINT     DEFAULT NULL,
    p_os_add        NUMERIC(5,2) DEFAULT NULL,
    p_lens_type     VARCHAR(50)  DEFAULT NULL,
    p_frame_size    VARCHAR(20)  DEFAULT NULL,
    p_ipd           NUMERIC(5,2) DEFAULT NULL,
    p_rx_notes      TEXT         DEFAULT NULL
)
RETURNS TABLE (updated BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows  INTEGER;
BEGIN
    -- 1. Update the main exam record
    UPDATE eye_exams
    SET
        doctor_id  = COALESCE(p_doctor_id, doctor_id),
        exam_date  = COALESCE(p_exam_date, exam_date)
    WHERE id = p_exam_id AND NOT is_deleted;
 
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RETURN QUERY SELECT FALSE;
        RETURN;
    END IF;
 
    -- 2. Upsert the prescription record (Always try to update if data is provided)
    -- We remove the IF v_has_rx check so that we can clear values if needed
    INSERT INTO exam_prescriptions (
        exam_id, od_sph, od_cyl, od_axis, od_add, os_sph, os_cyl, os_axis, os_add, lens_type, frame_size, ipd, rx_notes
    ) VALUES (
        p_exam_id, p_od_sph, p_od_cyl, p_od_axis, p_od_add, p_os_sph, p_os_cyl, p_os_axis, p_os_add, p_lens_type, p_frame_size, p_ipd, p_rx_notes
    )
    ON CONFLICT (exam_id) DO UPDATE
    SET
        od_sph     = COALESCE(EXCLUDED.od_sph, exam_prescriptions.od_sph),
        od_cyl     = COALESCE(EXCLUDED.od_cyl, exam_prescriptions.od_cyl),
        od_axis    = COALESCE(EXCLUDED.od_axis, exam_prescriptions.od_axis),
        od_add     = COALESCE(EXCLUDED.od_add, exam_prescriptions.od_add),
        os_sph     = COALESCE(EXCLUDED.os_sph, exam_prescriptions.os_sph),
        os_cyl     = COALESCE(EXCLUDED.os_cyl, exam_prescriptions.os_cyl),
        os_axis    = COALESCE(EXCLUDED.os_axis, exam_prescriptions.os_axis),
        os_add     = COALESCE(EXCLUDED.os_add, exam_prescriptions.os_add),
        lens_type  = COALESCE(EXCLUDED.lens_type, exam_prescriptions.lens_type),
        frame_size = COALESCE(EXCLUDED.frame_size, exam_prescriptions.frame_size),
        ipd        = COALESCE(EXCLUDED.ipd, exam_prescriptions.ipd),
        rx_notes   = COALESCE(EXCLUDED.rx_notes, exam_prescriptions.rx_notes);
 
    RETURN QUERY SELECT TRUE;
END;
$$; 
CREATE OR REPLACE FUNCTION sp_delete_eye_exam(
    p_exam_id   INTEGER
)
RETURNS TABLE (deleted BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows INTEGER;
BEGIN
    IF EXISTS (
        SELECT 1 FROM eye_exams
        WHERE id = p_exam_id
          AND allocation_status = 'Glasses Assigned'
          AND NOT is_deleted
    ) THEN
        RAISE EXCEPTION 'Cannot delete an exam where glasses have already been assigned.';
    END IF;
 
    UPDATE eye_exams
    SET is_deleted = TRUE, deleted_at = NOW()
    WHERE id = p_exam_id AND NOT is_deleted;
 
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN QUERY SELECT (v_rows > 0);
END;
$$;
 
-- ═══════════════════════════════════════════════════════════════════════════
-- sp_search_inventory_rx  (UNCOMMENTED & ACTIVE)
-- Scored inventory matching algorithm based on RX differences
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION sp_search_inventory_rx(
    p_coordinator_id    INTEGER,
    p_od_sph            NUMERIC,
    p_od_cyl            NUMERIC,
    p_od_axis           SMALLINT,
    p_od_add            NUMERIC,
    p_os_sph            NUMERIC,
    p_os_cyl            NUMERIC,
    p_os_axis           SMALLINT,
    p_os_add            NUMERIC,
    p_frame_size        VARCHAR,
    p_lens_type         VARCHAR
)
RETURNS TABLE (
    sku              VARCHAR,
    product_name     VARCHAR,
    lens_type        VARCHAR,
    frame_size       VARCHAR,
    available_qty    INTEGER,
    match_percentage INTEGER
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    WITH scored_inventory AS (
        SELECT 
            i.sku, 
            i.product_name, 
            i.lens_type, 
            i.frame_size, 
            i.available_qty,
            -- Computes absolute cumulative prescription variance across both optical channels
            (
                ABS(COALESCE(i.sph_right, 0) - COALESCE(p_od_sph, 0)) +
                ABS(COALESCE(i.sph_left, 0) - COALESCE(p_os_sph, 0)) +
                ABS(COALESCE(i.cyl_right, 0) - COALESCE(p_od_cyl, 0)) +
                ABS(COALESCE(i.cyl_left, 0) - COALESCE(p_os_cyl, 0))
            ) AS power_diff
        FROM inventory i
        WHERE i.coordinator_id = p_coordinator_id
          AND i.available_qty > 0
          AND (p_frame_size IS NULL OR p_frame_size = '' OR i.frame_size = p_frame_size)
          AND (p_lens_type IS NULL OR p_lens_type = '' OR i.lens_type = p_lens_type)
    )
    SELECT 
        si.sku, 
        si.product_name, 
        si.lens_type, 
        si.frame_size, 
        si.available_qty,
        -- Standardizes deviance into an intuitive 0-100% value score for UI cards
        GREATEST(10, LEAST(100, ROUND(100 - (si.power_diff * 18))))::INTEGER AS match_percentage
    FROM scored_inventory si
    ORDER BY power_diff ASC
    LIMIT 3;
END;
$$;


CREATE OR REPLACE FUNCTION sp_assign_glasses(
    p_exam_id        INTEGER,
    p_sku            VARCHAR,
    p_coordinator_id INTEGER
)
RETURNS TABLE (assigned BOOLEAN, reason TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_current_qty INTEGER;
    v_exam_status exam_allocation_status;
BEGIN
    -- Verify exam state boundaries
    SELECT allocation_status INTO v_exam_status FROM eye_exams WHERE id = p_exam_id AND NOT is_deleted;
    IF v_exam_status = 'Glasses Assigned' THEN
        RETURN QUERY SELECT FALSE, 'Glasses are already assigned to this examination record.'::TEXT;
        RETURN;
    END IF;

    -- Lock and read current inventory level
    SELECT available_qty INTO v_current_qty 
    FROM inventory 
    WHERE sku = UPPER(TRIM(p_sku)) AND coordinator_id = p_coordinator_id
    FOR UPDATE;

    IF v_current_qty IS NULL OR v_current_qty <= 0 THEN
        RETURN QUERY SELECT FALSE, 'Insufficient stock allocation available.'::TEXT;
        RETURN;
    END IF;

    -- FIX: Explicitly deduct stock from the inventory records
    UPDATE inventory 
    SET available_qty = available_qty - 1 
    WHERE sku = UPPER(TRIM(p_sku)) AND coordinator_id = p_coordinator_id;

    -- Create target ledger audit trail
    INSERT INTO inventory_stock_audit (
        sku, coordinator_id, action_type,
        qty_changed, old_qty, new_qty,
        performed_by, remarks
    ) VALUES (
        UPPER(TRIM(p_sku)), p_coordinator_id, 'ASSIGN_GLASSES',
        1, v_current_qty, v_current_qty - 1,
        p_coordinator_id,
        'Glasses assigned automatically to exam ID ' || p_exam_id
    );

    -- Lock down medical status mapping
    UPDATE eye_exams
    SET allocation_status = 'Glasses Assigned',
        assigned_sku      = UPPER(TRIM(p_sku))
    WHERE id = p_exam_id;

    RETURN QUERY SELECT TRUE, 'Success'::TEXT;
END;
$$;


CREATE OR REPLACE FUNCTION sp_add_to_waiting_list(
    p_exam_id   INTEGER
)
RETURNS TABLE (updated BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows  INTEGER;
BEGIN
    IF EXISTS (
        SELECT 1 FROM eye_exams
        WHERE id = p_exam_id
          AND allocation_status = 'Glasses Assigned'
          AND NOT is_deleted
    ) THEN
        RAISE EXCEPTION 'Cannot change status — glasses have already been assigned.';
    END IF;
 
    UPDATE eye_exams
    SET allocation_status = 'Added to Waiting List'
    WHERE id = p_exam_id AND NOT is_deleted;
 
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN QUERY SELECT (v_rows > 0);
END;
$$;
 
CREATE OR REPLACE FUNCTION sp_get_exam_campaigns()
RETURNS TABLE (id INTEGER, name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT id, camp_name AS name
    FROM campaigns
    WHERE is_deleted = FALSE
    ORDER BY camp_name;
$$;

-----------------------------------------------------------------------
--demo run--
SELECT * FROM exam_prescriptions
SELECT sku, available_qty, coordinator_id 
FROM inventory
WHERE sku = 'GLS-1001';
