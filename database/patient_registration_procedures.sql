-- patient_registration_procedures.sql
-- Run this AFTER patient_registration_schema.sql.

-- ============================================================
-- patient_result type
-- Shared return type used by sp_get_patients and sp_get_patient_by_id.
-- Defining it once here avoids duplicating the schema in every function
-- signature (DRY principle). Drop and recreate on schema changes.
-- ============================================================
DROP TYPE IF EXISTS patient_result CASCADE;
CREATE TYPE patient_result AS (
    id                  UUID,
    first_name          VARCHAR,
    last_name           VARCHAR,
    gender              VARCHAR,
    dob                 DATE,
    age                 INTEGER,
    phone_number        VARCHAR,
    photo_url           TEXT,
    address_line        VARCHAR,
    zip_code            VARCHAR,
    city_id             INTEGER,
    city_name           VARCHAR,
    state_id            INTEGER,
    state_name          VARCHAR,
    country_id          INTEGER,
    country_name        VARCHAR,
    camp_id             INTEGER,
    camp_name           VARCHAR,
    IsBlurredVision     SMALLINT,
    IsVisionDifficulty  SMALLINT,
    IsDoubleVision      SMALLINT,
    IsWearingCorrection SMALLINT,
    created_at          TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ,
    total_count         BIGINT
);


-- ============================================================
-- sp_create_patient
-- Inserts a new patient + their medical questionnaire row.
-- Returns the new patient UUID.
-- ============================================================
CREATE OR REPLACE FUNCTION sp_create_patient(
    p_first_name          VARCHAR,
    p_last_name           VARCHAR,
    p_gender              VARCHAR(20),
    p_dob                 DATE,
    p_phone_number        VARCHAR     DEFAULT NULL,
    p_photo_url           TEXT        DEFAULT NULL,
    p_address_line        VARCHAR     DEFAULT NULL,
    p_city_id             INTEGER     DEFAULT NULL,
    p_state_id            INTEGER     DEFAULT NULL,
    p_country_id          INTEGER     DEFAULT NULL,
    p_camp_id             INTEGER     DEFAULT NULL,
    p_zip_code            VARCHAR(20) DEFAULT NULL,
    p_IsBlurredVision     SMALLINT    DEFAULT 0,
    p_IsVisionDifficulty  SMALLINT    DEFAULT 0,
    p_IsDoubleVision      SMALLINT    DEFAULT 0,
    p_IsWearingCorrection SMALLINT    DEFAULT 0
)
RETURNS UUID AS $$
DECLARE
    v_patient_id UUID;
BEGIN
    INSERT INTO patients (
        first_name, last_name, gender, dob,
        phone_number, photo_url, address_line,
        city_id, state_id, country_id, camp_id, zip_code
    )
    VALUES (
        p_first_name, p_last_name, p_gender, p_dob,
        p_phone_number, p_photo_url, p_address_line,
        p_city_id, p_state_id, p_country_id, p_camp_id, p_zip_code
    )
    RETURNING id INTO v_patient_id;

    -- Every patient gets a questionnaire row, even if all boxes are unchecked
    INSERT INTO medical_questionnaire (
        patient_id,
        IsBlurredVision, IsVisionDifficulty, IsDoubleVision, IsWearingCorrection
    )
    VALUES (
        v_patient_id,
        p_IsBlurredVision, p_IsVisionDifficulty, p_IsDoubleVision, p_IsWearingCorrection
    );

    RETURN v_patient_id;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- sp_update_patient
-- Full field replace for an existing patient + questionnaire UPSERT.
-- Returns TRUE on success, FALSE if patient not found / already deleted.
-- ============================================================
CREATE OR REPLACE FUNCTION sp_update_patient(
    p_id                  UUID,
    p_first_name          VARCHAR,
    p_last_name           VARCHAR,
    p_gender              VARCHAR(20),
    p_dob                 DATE,
    p_phone_number        VARCHAR     DEFAULT NULL,
    p_photo_url           TEXT        DEFAULT NULL,
    p_address_line        VARCHAR     DEFAULT NULL,
    p_city_id             INTEGER     DEFAULT NULL,
    p_state_id            INTEGER     DEFAULT NULL,
    p_country_id          INTEGER     DEFAULT NULL,
    p_camp_id             INTEGER     DEFAULT NULL,
    p_zip_code            VARCHAR(20) DEFAULT NULL,
    p_IsBlurredVision     SMALLINT    DEFAULT 0,
    p_IsVisionDifficulty  SMALLINT    DEFAULT 0,
    p_IsDoubleVision      SMALLINT    DEFAULT 0,
    p_IsWearingCorrection SMALLINT    DEFAULT 0
)
RETURNS BOOLEAN AS $$
DECLARE
    v_rows_affected INTEGER;
BEGIN
    UPDATE patients SET
        first_name   = p_first_name,
        last_name    = p_last_name,
        gender       = p_gender,
        dob          = p_dob,
        phone_number = p_phone_number,
        photo_url    = p_photo_url,
        address_line = p_address_line,
        city_id      = p_city_id,
        state_id     = p_state_id,
        country_id   = p_country_id,
        camp_id      = p_camp_id,
        zip_code     = p_zip_code
    WHERE id = p_id
      AND deleted_at IS NULL;

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

    IF v_rows_affected = 0 THEN
        RETURN FALSE;  -- patient not found or already deleted
    END IF;

    -- UPSERT the questionnaire — update if exists, insert if somehow missing
    INSERT INTO medical_questionnaire (
        patient_id,
        IsBlurredVision, IsVisionDifficulty, IsDoubleVision, IsWearingCorrection
    )
    VALUES (
        p_id,
        p_IsBlurredVision, p_IsVisionDifficulty, p_IsDoubleVision, p_IsWearingCorrection
    )
    ON CONFLICT (patient_id) DO UPDATE SET
        IsBlurredVision     = EXCLUDED.IsBlurredVision,
        IsVisionDifficulty  = EXCLUDED.IsVisionDifficulty,
        IsDoubleVision      = EXCLUDED.IsDoubleVision,
        IsWearingCorrection = EXCLUDED.IsWearingCorrection;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- sp_get_patients
-- Paginated patient list with optional filters.
-- Pass NULL for any filter you don't want applied.
-- On initial page load: call with all NULLs → returns full paginated set.
-- Soft-deleted patients are always excluded.
--
-- Performance note: uses a CTE to paginate on IDs first, then joins.
-- This avoids building the full result set (with all joins) before limiting,
-- which is a significant bottleneck on large tables.
-- ============================================================
CREATE OR REPLACE FUNCTION sp_get_patients(
    p_first_name VARCHAR  DEFAULT NULL,
    p_last_name  VARCHAR  DEFAULT NULL,
    p_camp_id    INTEGER  DEFAULT NULL,
    p_limit      INTEGER  DEFAULT 50,
    p_offset     INTEGER  DEFAULT 0
)
RETURNS SETOF patient_result AS $$
BEGIN
    RETURN QUERY
    WITH paginated AS (
        -- Step 1: filter and paginate on the bare patients table — no joins, no subqueries.
        -- COUNT(*) OVER() here is cheap because we're only touching one table.
        SELECT
            p.id,
            COUNT(*) OVER () AS total_count
        FROM patients p
        WHERE p.deleted_at IS NULL
          AND (p_first_name IS NULL OR p.first_name ILIKE '%' || p_first_name || '%')
          AND (p_last_name  IS NULL OR p.last_name  ILIKE '%' || p_last_name  || '%')
          AND (p_camp_id    IS NULL OR p.camp_id = p_camp_id)
        ORDER BY p.last_name, p.first_name
        LIMIT  LEAST(p_limit, 200)  -- hard cap so nothing crazy slips through
        OFFSET p_offset
    )
    -- Step 2: now join only the rows we actually need (the paginated IDs).
    SELECT
        p.id,
        p.first_name,
        p.last_name,
        p.gender,
        p.dob,
        DATE_PART('year', AGE(CURRENT_DATE, p.dob))::INTEGER AS age,
        p.phone_number,
        p.photo_url,
        p.address_line,
        p.zip_code,
        p.city_id,
        ci.name       AS city_name,
        p.state_id,
        st.name       AS state_name,
        p.country_id,
        co.name       AS country_name,
        p.camp_id,
        ca.name       AS camp_name,
        mq.IsBlurredVision,
        mq.IsVisionDifficulty,
        mq.IsDoubleVision,
        mq.IsWearingCorrection,
        p.created_at,
        p.updated_at,
        pp.total_count
    FROM paginated pp
    JOIN patients p ON p.id = pp.id
    LEFT JOIN cities    ci ON ci.id = p.city_id
    LEFT JOIN states    st ON st.id = p.state_id
    LEFT JOIN countries co ON co.id = p.country_id
    LEFT JOIN camps     ca ON ca.id = p.camp_id
    LEFT JOIN medical_questionnaire mq ON mq.patient_id = p.id;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- sp_get_patient_by_id
-- Full single-patient record for the View / Update modal.
-- Returns nothing (0 rows) if the patient doesn't exist or is deleted.
-- ============================================================
CREATE OR REPLACE FUNCTION sp_get_patient_by_id(p_id UUID)
RETURNS SETOF patient_result AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.id,
        p.first_name,
        p.last_name,
        p.gender,
        p.dob,
        DATE_PART('year', AGE(CURRENT_DATE, p.dob))::INTEGER AS age,
        p.phone_number,
        p.photo_url,
        p.address_line,
        p.zip_code,
        p.city_id,
        ci.name       AS city_name,
        p.state_id,
        st.name       AS state_name,
        p.country_id,
        co.name       AS country_name,
        p.camp_id,
        ca.name       AS camp_name,
        mq.IsBlurredVision,
        mq.IsVisionDifficulty,
        mq.IsDoubleVision,
        mq.IsWearingCorrection,
        p.created_at,
        p.updated_at,
        1::BIGINT     AS total_count  -- always 1 for single record lookup
    FROM patients p
    LEFT JOIN cities    ci ON ci.id = p.city_id
    LEFT JOIN states    st ON st.id = p.state_id
    LEFT JOIN countries co ON co.id = p.country_id
    LEFT JOIN camps     ca ON ca.id = p.camp_id
    LEFT JOIN medical_questionnaire mq ON mq.patient_id = p.id
    WHERE p.id = p_id
      AND p.deleted_at IS NULL;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- sp_delete_patient
-- Soft delete — sets deleted_at to NOW().
-- Returns TRUE if deleted, FALSE if not found or already deleted.
-- ============================================================
CREATE OR REPLACE FUNCTION sp_delete_patient(p_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_rows_affected INTEGER;
BEGIN
    UPDATE patients
    SET deleted_at = NOW()
    WHERE id = p_id
      AND deleted_at IS NULL;

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    RETURN v_rows_affected > 0;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- sp_lookup_zip
-- Given a zip/postal code string, return the matched geography.
-- Used by the API for ZIP autofill — UI calls this on ZIP input.
-- Returns 0 rows if the ZIP isn't in our master table.
-- ============================================================
CREATE OR REPLACE FUNCTION sp_lookup_zip(p_zip_code VARCHAR)
RETURNS TABLE (
    city_id      INTEGER,
    city_name    VARCHAR,
    state_id     INTEGER,
    state_name   VARCHAR,
    country_id   INTEGER,
    country_name VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        zm.city_id,
        ci.name  AS city_name,
        zm.state_id,
        st.name  AS state_name,
        zm.country_id,
        co.name  AS country_name
    FROM zip_code_mappings zm
    JOIN cities    ci ON ci.id = zm.city_id
    JOIN states    st ON st.id = zm.state_id
    JOIN countries co ON co.id = zm.country_id
    WHERE zm.zip_code = p_zip_code
    LIMIT 1;  -- return the primary/canonical match if there are multiple
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- LOOKUP HELPERS
-- ============================================================

-- Active camps for the Camp dropdown
CREATE OR REPLACE FUNCTION sp_get_camps()
RETURNS TABLE (id INTEGER, name VARCHAR, location VARCHAR, camp_date DATE) AS $$
BEGIN
    RETURN QUERY
    SELECT c.id, c.name, c.location, c.camp_date
    FROM camps c
    WHERE c.is_active = TRUE
    ORDER BY c.camp_date DESC;
END;
$$ LANGUAGE plpgsql;


-- All countries for the Country dropdown
CREATE OR REPLACE FUNCTION sp_get_countries()
RETURNS TABLE (id INTEGER, name VARCHAR) AS $$
BEGIN
    RETURN QUERY
    SELECT c.id, c.name
    FROM countries c
    ORDER BY c.name;
END;
$$ LANGUAGE plpgsql;


-- States for a given country (called after user picks country)
CREATE OR REPLACE FUNCTION sp_get_states_by_country(p_country_id INTEGER)
RETURNS TABLE (id INTEGER, name VARCHAR) AS $$
BEGIN
    RETURN QUERY
    SELECT s.id, s.name
    FROM states s
    WHERE s.country_id = p_country_id
    ORDER BY s.name;
END;
$$ LANGUAGE plpgsql;


-- Cities for a given state (called after user picks state)
CREATE OR REPLACE FUNCTION sp_get_cities_by_state(p_state_id INTEGER)
RETURNS TABLE (id INTEGER, name VARCHAR) AS $$
BEGIN
    RETURN QUERY
    SELECT c.id, c.name
    FROM cities c
    WHERE c.state_id = p_state_id
    ORDER BY c.name;
END;
$$ LANGUAGE plpgsql;


-- Medical conditions reference list (checkbox labels)
CREATE OR REPLACE FUNCTION sp_get_medical_conditions()
RETURNS TABLE (id INTEGER, code VARCHAR, description TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT mc.id, mc.code, mc.description
    FROM medical_conditions mc
    ORDER BY mc.sort_order;
END;
$$ LANGUAGE plpgsql;
