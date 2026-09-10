-- ============================================================
-- PATIENT REGISTRATION SYSTEM - PostgreSQL Schema
-- Version: 1.0
-- Description: Full schema for patient registration including
--              camps, address lookup, and medical questionnaires
-- ============================================================

-- ─────────────────────────────────────────────
-- EXTENSIONS
-- ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- for ILIKE index support


-- ─────────────────────────────────────────────
-- LOOKUP / REFERENCE TABLES
-- ─────────────────────────────────────────────

-- Gender options
CREATE TABLE genders (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(20) NOT NULL UNIQUE   -- e.g. Male, Female, Non-binary, Prefer not to say
);

INSERT INTO genders (name) VALUES
    ('Male'),
    ('Female'),
    ('Non-binary'),
    ('Prefer not to say');


-- US States
CREATE TABLE states (
    id           SERIAL PRIMARY KEY,
    code         CHAR(2)     NOT NULL UNIQUE,  -- e.g. CA, TX
    name         VARCHAR(50) NOT NULL UNIQUE
);

INSERT INTO states (code, name) VALUES
    ('AL','Alabama'), ('AK','Alaska'), ('AZ','Arizona'), ('AR','Arkansas'),
    ('CA','California'), ('CO','Colorado'), ('CT','Connecticut'), ('DE','Delaware'),
    ('FL','Florida'), ('GA','Georgia'), ('HI','Hawaii'), ('ID','Idaho'),
    ('IL','Illinois'), ('IN','Indiana'), ('IA','Iowa'), ('KS','Kansas'),
    ('KY','Kentucky'), ('LA','Louisiana'), ('ME','Maine'), ('MD','Maryland'),
    ('MA','Massachusetts'), ('MI','Michigan'), ('MN','Minnesota'), ('MS','Mississippi'),
    ('MO','Missouri'), ('MT','Montana'), ('NE','Nebraska'), ('NV','Nevada'),
    ('NH','New Hampshire'), ('NJ','New Jersey'), ('NM','New Mexico'), ('NY','New York'),
    ('NC','North Carolina'), ('ND','North Dakota'), ('OH','Ohio'), ('OK','Oklahoma'),
    ('OR','Oregon'), ('PA','Pennsylvania'), ('RI','Rhode Island'), ('SC','South Carolina'),
    ('SD','South Dakota'), ('TN','Tennessee'), ('TX','Texas'), ('UT','Utah'),
    ('VT','Vermont'), ('VA','Virginia'), ('WA','Washington'), ('WV','West Virginia'),
    ('WI','Wisconsin'), ('WY','Wyoming'), ('DC','District of Columbia');


-- Cities (linked to states for cascading dropdowns)
CREATE TABLE cities (
    id       SERIAL PRIMARY KEY,
    state_id INTEGER     NOT NULL REFERENCES states(id) ON DELETE CASCADE,
    name     VARCHAR(100) NOT NULL,
    UNIQUE (state_id, name)
);

-- Sample cities (extend as needed)
INSERT INTO cities (state_id, name)
SELECT s.id, c.name
FROM states s
JOIN (VALUES
    ('CA', 'Los Angeles'), ('CA', 'San Francisco'), ('CA', 'San Diego'),
    ('CA', 'Sacramento'), ('CA', 'San Jose'), ('CA', 'Fresno'),
    ('TX', 'Houston'), ('TX', 'Austin'), ('TX', 'Dallas'), ('TX', 'San Antonio'),
    ('NY', 'New York City'), ('NY', 'Buffalo'), ('NY', 'Albany'),
    ('FL', 'Miami'), ('FL', 'Orlando'), ('FL', 'Tampa'),
    ('IL', 'Chicago'), ('IL', 'Springfield'),
    ('WA', 'Seattle'), ('WA', 'Spokane'),
    ('CO', 'Denver'), ('CO', 'Boulder')
) AS c(state_code, name) ON s.code = c.state_code;


-- Camps (health / eye care camp events)
CREATE TABLE camps (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100)  NOT NULL UNIQUE,
    location    VARCHAR(200),
    camp_date   DATE,
    is_active   BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

INSERT INTO camps (name, location, camp_date) VALUES
    ('Camp Alpha', 'Downtown Community Center', '2025-06-01'),
    ('Camp Beta',  'Riverside Health Clinic',   '2025-07-15'),
    ('Camp Gamma', 'East Side School',           '2025-08-20');


-- ─────────────────────────────────────────────
-- MEDICAL QUESTIONNAIRE OPTIONS
-- ─────────────────────────────────────────────

CREATE TABLE medical_conditions (
    id          SERIAL PRIMARY KEY,
    code        VARCHAR(50)  NOT NULL UNIQUE,  -- machine-readable key
    description TEXT         NOT NULL,         -- UI label
    sort_order  SMALLINT     NOT NULL DEFAULT 0
);

INSERT INTO medical_conditions (code, description, sort_order) VALUES
    ('BLURRED_VISION_ETC',    'Blurred vision / headaches / eye strain / dryness',      1),
    ('NEAR_FAR_DIFFICULTY',   'Difficulty seeing near or far',                           2),
    ('DOUBLE_VISION_ETC',     'Double vision / light sensitivity',                       3),
    ('GLASSES_CONTACTS',      'Wearing glasses / contact lenses',                        4);


-- ─────────────────────────────────────────────
-- CORE: PATIENTS
-- ─────────────────────────────────────────────

CREATE TABLE patients (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Name
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,

    -- Demographics
    gender_id       INTEGER      REFERENCES genders(id),
    dob             DATE         NOT NULL,
    -- age is intentionally NOT stored; it is derived from dob at query time
    -- (stored age goes stale; computed age is always accurate)

    -- Contact
    phone_number    VARCHAR(20),

    -- Photo
    photo_url       TEXT,        -- path or object-storage key

    -- Address
    address_line    VARCHAR(255),
    city_id         INTEGER      REFERENCES cities(id),
    state_id        INTEGER      REFERENCES states(id),
    zip_code        VARCHAR(10),

    -- Camp assignment
    camp_id         INTEGER      REFERENCES camps(id),

    -- Audit
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ             -- soft-delete; NULL = active
);

-- Indexes for filter/search performance
CREATE INDEX idx_patients_first_name  ON patients USING gin (first_name gin_trgm_ops);
CREATE INDEX idx_patients_last_name   ON patients USING gin (last_name  gin_trgm_ops);
CREATE INDEX idx_patients_camp_id     ON patients (camp_id);
CREATE INDEX idx_patients_deleted_at  ON patients (deleted_at) WHERE deleted_at IS NULL;


-- ─────────────────────────────────────────────
-- PATIENT ↔ MEDICAL CONDITIONS  (many-to-many)
-- ─────────────────────────────────────────────

CREATE TABLE patient_medical_conditions (
    patient_id   UUID    NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    condition_id INTEGER NOT NULL REFERENCES medical_conditions(id) ON DELETE CASCADE,
    PRIMARY KEY (patient_id, condition_id)
);


-- ─────────────────────────────────────────────
-- AUTO-UPDATE updated_at TRIGGER
-- ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_patients_updated_at
    BEFORE UPDATE ON patients
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
