-- inventory_procedures.sql
-- iCare – Brighter Future Program
-- ─────────────────────────────────────────────────────────────────────────
-- TABLE: inventory
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE TABLE IF NOT EXISTS inventory (
    sku              VARCHAR(50)   NOT NULL,
    coordinator_id   INTEGER       NOT NULL
                                   REFERENCES users(id) ON DELETE RESTRICT,
 
    product_name     VARCHAR(200)  NOT NULL,
    category         VARCHAR(50)   NOT NULL
                                   CHECK (category IN (
                                       'Glasses','Single Vision','Bifocal','Progressive',
                                       'Sunglasses','Contact Lens','Frame'
                                   )),
 
    lens_type        VARCHAR(50),
    lens_gender      VARCHAR(20),
 
    sph_right        NUMERIC(5,2),
    sph_left         NUMERIC(5,2),
    cyl_right        NUMERIC(5,2),
    cyl_left         NUMERIC(5,2),
    axis_right       SMALLINT      CHECK (axis_right BETWEEN 0 AND 180),
    axis_left        SMALLINT      CHECK (axis_left  BETWEEN 0 AND 180),
 
    frame_size       VARCHAR(20),
 
    -- [CH1] Replaced single colour + material with 4 dedicated columns
    --       matching the UI Insert Modal Section C dropdowns exactly.
    --       lens_color      = "Lens Color"      dropdown
    --       lens_material   = "Lens Material"   dropdown
    --       frame_material  = "Frame Material"  dropdown
    --       frame_color     = "Frame Color"     dropdown
    lens_color       VARCHAR(50),
    lens_material    VARCHAR(50),
    frame_material   VARCHAR(50),
    frame_color      VARCHAR(50),
 
    vendor           VARCHAR(100),
    notes            TEXT,
 
    available_qty    INTEGER       NOT NULL DEFAULT 0
                                   CHECK (available_qty >= 0),
 
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
 
    PRIMARY KEY (sku, coordinator_id)
);
 
-- [CH1] Migration: if table already exists from v1/v2 with colour+material,
-- add the 4 new columns and drop the old ones safely.
ALTER TABLE inventory ADD COLUMN IF NOT EXISTS lens_color      VARCHAR(50);
ALTER TABLE inventory ADD COLUMN IF NOT EXISTS lens_material   VARCHAR(50);
ALTER TABLE inventory ADD COLUMN IF NOT EXISTS frame_material  VARCHAR(50);
ALTER TABLE inventory ADD COLUMN IF NOT EXISTS frame_color     VARCHAR(50);
ALTER TABLE inventory ADD COLUMN IF NOT EXISTS lens_gender     VARCHAR(20);
 
-- Only drop old columns if they exist (safe migration)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'inventory' AND column_name = 'colour'
    ) THEN
        -- Migrate existing data before dropping
        UPDATE inventory SET lens_color = colour WHERE lens_color IS NULL AND colour IS NOT NULL;
        UPDATE inventory SET frame_color = colour WHERE frame_color IS NULL AND colour IS NOT NULL;
        ALTER TABLE inventory DROP COLUMN colour;
    END IF;
 
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'inventory' AND column_name = 'material'
    ) THEN
        UPDATE inventory SET lens_material  = material WHERE lens_material  IS NULL AND material IS NOT NULL;
        UPDATE inventory SET frame_material = material WHERE frame_material IS NULL AND material IS NOT NULL;
        ALTER TABLE inventory DROP COLUMN material;
    END IF;
END;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- TABLE: inventory_stock_audit  (unchanged from uploaded file)
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE TABLE IF NOT EXISTS inventory_stock_audit (
    audit_id         SERIAL        PRIMARY KEY,
    sku              VARCHAR(50)   NOT NULL,
    coordinator_id   INTEGER       NOT NULL
                                   REFERENCES users(id) ON DELETE RESTRICT,
    action_type      VARCHAR(30)   NOT NULL,
    -- action_type values:
    --   'INSERT'       — new item created
    --   'UPDATE'       — item details or stock edited via full modal
    --   'QUICK_UPDATE' — stock added via quick update grid
    --   'DELETE_STOCK' — stock reduced via delete prompt
    --   'BULK_IMPORT'  — stock added/inserted via Excel upload
    --   'TRANSFER'     — stock moved between coordinators (SysAdmin)
    --   'ASSIGN_GLASSES'  — 1 unit deducted when glasses assigned to a patient exam
    --                       (written by eye_exam_procedures.sql sp_assign_glasses)
    qty_changed      INTEGER       NOT NULL,
    old_qty          INTEGER       NOT NULL,
    new_qty          INTEGER       NOT NULL,
    performed_by     INTEGER
                                   REFERENCES users(id) ON DELETE SET NULL,
    remarks          TEXT,
    performed_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
 
CREATE INDEX IF NOT EXISTS idx_inv_audit_sku   ON inventory_stock_audit(sku);
CREATE INDEX IF NOT EXISTS idx_inv_audit_coord ON inventory_stock_audit(coordinator_id);
CREATE INDEX IF NOT EXISTS idx_inv_audit_date  ON inventory_stock_audit(performed_at);
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- INDEXES
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE INDEX IF NOT EXISTS idx_inv_coord    ON inventory (coordinator_id);
CREATE INDEX IF NOT EXISTS idx_inv_category ON inventory (category);
CREATE INDEX IF NOT EXISTS idx_inv_qty      ON inventory (available_qty);
-- [CH2] Indexes for the new dedicated SPH/CYL prescription search
CREATE INDEX IF NOT EXISTS idx_inv_sph_right ON inventory (sph_right);
CREATE INDEX IF NOT EXISTS idx_inv_sph_left  ON inventory (sph_left);
CREATE INDEX IF NOT EXISTS idx_inv_cyl_right ON inventory (cyl_right);
CREATE INDEX IF NOT EXISTS idx_inv_cyl_left  ON inventory (cyl_left);
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER: updated_at (unchanged)
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION _trg_inv_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;
 
DROP TRIGGER IF EXISTS trg_inv_updated_at ON inventory;
CREATE TRIGGER trg_inv_updated_at
    BEFORE UPDATE ON inventory
    FOR EACH ROW EXECUTE FUNCTION _trg_inv_updated_at();

-- ═══════════════════════════════════════════════════════════════════════════
-- STORED PROCEDURES
-- ═══════════════════════════════════════════════════════════════════════════
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_stats  (UNCHANGED)
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_stats(
    p_coordinator_id  INTEGER
)
RETURNS TABLE (
    total_skus    BIGINT,
    in_stock      BIGINT,
    low_stock     BIGINT,
    out_of_stock  BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT
        COUNT(*)                                                           AS total_skus,
        COUNT(*) FILTER (WHERE available_qty  > 5)                       AS in_stock,
        COUNT(*) FILTER (WHERE available_qty >= 1 AND available_qty <= 5) AS low_stock,
        COUNT(*) FILTER (WHERE available_qty  = 0)                       AS out_of_stock
    FROM  inventory
    WHERE (p_coordinator_id IS NULL OR coordinator_id = p_coordinator_id);
$$;
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_list  [CH1] [CH2]
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_list(
    p_coordinator_id  INTEGER,
    p_q               TEXT,         -- free-text: searches SKU + product_name
    p_sph             NUMERIC,      -- [CH2] dedicated SPH search box (NULL = ignore)
    p_cyl             NUMERIC,      -- [CH2] dedicated CYL search box (NULL = ignore)
    p_category        VARCHAR,
    p_stock_level     VARCHAR,
    p_sort_by         VARCHAR,
    p_sort_dir        VARCHAR,
    p_limit           INTEGER,
    p_offset          INTEGER
)
RETURNS TABLE (
    sku             VARCHAR,
    coordinator_id  INTEGER,
    product_name    VARCHAR,
    category        VARCHAR,
    lens_type       VARCHAR,
    lens_gender     VARCHAR,
    sph_right       NUMERIC,
    sph_left        NUMERIC,
    cyl_right       NUMERIC,
    cyl_left        NUMERIC,
    axis_right      SMALLINT,
    axis_left       SMALLINT,
    frame_size      VARCHAR,
    -- [CH1] four columns instead of old colour + material
    lens_color      VARCHAR,
    lens_material   VARCHAR,
    frame_material  VARCHAR,
    frame_color     VARCHAR,
    vendor          VARCHAR,
    notes           TEXT,
    available_qty   INTEGER,
    updated_at      TIMESTAMPTZ,
    total_count     BIGINT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT i.*
        FROM   inventory i
        WHERE
            (p_coordinator_id IS NULL OR i.coordinator_id = p_coordinator_id)
        -- free-text searches SKU and product name only
        AND (
            p_q IS NULL
            OR i.sku          ILIKE '%' || p_q || '%'
            OR i.product_name ILIKE '%' || p_q || '%'
        )
        -- [CH2] Dedicated SPH numeric search: match either eye within ±0.25
        AND (
            p_sph IS NULL
            OR ABS(COALESCE(i.sph_right, 0) - p_sph) <= 0.25
            OR ABS(COALESCE(i.sph_left,  0) - p_sph) <= 0.25
        )
        -- [CH2] Dedicated CYL numeric search: match either eye within ±0.25
        AND (
            p_cyl IS NULL
            OR ABS(COALESCE(i.cyl_right, 0) - p_cyl) <= 0.25
            OR ABS(COALESCE(i.cyl_left,  0) - p_cyl) <= 0.25
        )
        AND (p_category IS NULL OR i.category = p_category)
        AND (
            p_stock_level IS NULL
            OR (p_stock_level = 'in'  AND i.available_qty > 5)
            OR (p_stock_level = 'low' AND i.available_qty >= 1 AND i.available_qty <= 5)
            OR (p_stock_level = 'out' AND i.available_qty = 0)
        )
    ),
    counted AS (
        SELECT *, COUNT(*) OVER() AS total_count FROM base
    )
    SELECT
        c.sku, c.coordinator_id, c.product_name, c.category,
        c.lens_type, c.lens_gender,
        c.sph_right, c.sph_left, c.cyl_right, c.cyl_left,
        c.axis_right, c.axis_left, c.frame_size,
        -- [CH1]
        c.lens_color, c.lens_material, c.frame_material, c.frame_color,
        c.vendor, c.notes, c.available_qty, c.updated_at, c.total_count
    FROM counted c
    ORDER BY
        CASE WHEN p_sort_by='sku'          AND p_sort_dir='asc'  THEN c.sku           END ASC,
        CASE WHEN p_sort_by='sku'          AND p_sort_dir='desc' THEN c.sku           END DESC,
        CASE WHEN p_sort_by='product_name' AND p_sort_dir='asc'  THEN c.product_name  END ASC,
        CASE WHEN p_sort_by='product_name' AND p_sort_dir='desc' THEN c.product_name  END DESC,
        CASE WHEN p_sort_by='category'     AND p_sort_dir='asc'  THEN c.category      END ASC,
        CASE WHEN p_sort_by='category'     AND p_sort_dir='desc' THEN c.category      END DESC,
        CASE WHEN p_sort_by='qty'          AND p_sort_dir='asc'  THEN c.available_qty END ASC,
        CASE WHEN p_sort_by='qty'          AND p_sort_dir='desc' THEN c.available_qty END DESC,
        c.sku ASC
    LIMIT  p_limit
    OFFSET p_offset;
END;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_lookup_sku  (UNCHANGED)
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_lookup_sku(
    p_sku             VARCHAR,
    p_coordinator_id  INTEGER
)
RETURNS SETOF inventory
LANGUAGE sql STABLE AS $$
    SELECT *
    FROM   inventory
    WHERE  sku            = UPPER(TRIM(p_sku))
      AND  (p_coordinator_id IS NULL OR coordinator_id = p_coordinator_id);
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_get_by_sku  (UNCHANGED)
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_get_by_sku(
    p_sku             VARCHAR,
    p_coordinator_id  INTEGER
)
RETURNS SETOF inventory
LANGUAGE sql STABLE AS $$
    SELECT *
    FROM   inventory
    WHERE  sku = UPPER(TRIM(p_sku))
      AND  (p_coordinator_id IS NULL OR coordinator_id = p_coordinator_id);
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_create  [CH1] [CH6]
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_create(
    p_sku             VARCHAR,
    p_product_name    VARCHAR,
    p_category        VARCHAR,
    p_quantity        INTEGER,
    p_vendor          VARCHAR,
    p_lens_type       VARCHAR,
    p_lens_gender     VARCHAR,
    p_frame_size      VARCHAR,
    -- [CH1] four separate parameters replace the old p_colour + p_material
    p_lens_color      VARCHAR,
    p_lens_material   VARCHAR,
    p_frame_material  VARCHAR,
    p_frame_color     VARCHAR,
    p_sph_right       NUMERIC,
    p_sph_left        NUMERIC,
    p_cyl_right       NUMERIC,
    p_cyl_left        NUMERIC,
    p_axis_right      SMALLINT,
    p_axis_left       SMALLINT,
    p_notes           TEXT,
    p_coordinator_id  INTEGER
)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO inventory (
        sku, coordinator_id,
        product_name, category, available_qty,
        vendor, lens_type, lens_gender, frame_size,
        lens_color, lens_material, frame_material, frame_color,  -- [CH1]
        sph_right, sph_left, cyl_right, cyl_left,
        axis_right, axis_left, notes
    ) VALUES (
        UPPER(TRIM(p_sku)), p_coordinator_id,
        p_product_name, p_category, p_quantity,
        p_vendor, p_lens_type, p_lens_gender, p_frame_size,
        p_lens_color, p_lens_material, p_frame_material, p_frame_color,  -- [CH1]
        p_sph_right, p_sph_left, p_cyl_right, p_cyl_left,
        p_axis_right, p_axis_left, p_notes
    );
 
    -- [CH6] Audit: record the initial stock creation
    INSERT INTO inventory_stock_audit (
        sku, coordinator_id, action_type,
        qty_changed, old_qty, new_qty,
        performed_by, remarks
    ) VALUES (
        UPPER(TRIM(p_sku)), p_coordinator_id, 'INSERT',
        p_quantity, 0, p_quantity,
        p_coordinator_id, 'New inventory item created'
    );
END;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_update  [CH1] [CH6]
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_update(
    p_sku             VARCHAR,
    p_coordinator_id  INTEGER,
    p_product_name    VARCHAR,
    p_category        VARCHAR,
    p_stock_to_add    INTEGER,
    p_vendor          VARCHAR,
    p_lens_type       VARCHAR,
    p_lens_gender     VARCHAR,
    p_frame_size      VARCHAR,
    -- [CH1] four parameters replace old p_colour + p_material
    p_lens_color      VARCHAR,
    p_lens_material   VARCHAR,
    p_frame_material  VARCHAR,
    p_frame_color     VARCHAR,
    p_sph_right       NUMERIC,
    p_sph_left        NUMERIC,
    p_cyl_right       NUMERIC,
    p_cyl_left        NUMERIC,
    p_axis_right      SMALLINT,
    p_axis_left       SMALLINT,
    p_notes           TEXT
)
RETURNS TABLE (updated BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows     INTEGER;
    v_old_qty  INTEGER;  -- [CH6] capture before value for audit
BEGIN
    -- Validation: kept exactly from uploaded file
    IF LENGTH(TRIM(p_sku)) = 0 THEN
        RAISE EXCEPTION 'SKU cannot be empty';
    END IF;
 
    IF COALESCE(p_stock_to_add, 0) < 0 THEN
        RAISE EXCEPTION 'Stock to add cannot be negative';
    END IF;
 
    IF p_category IS NULL OR TRIM(p_category) = '' THEN
        RAISE EXCEPTION 'Category cannot be empty';
    END IF;
 
    IF NOT EXISTS (
        SELECT 1 FROM inventory
        WHERE sku = UPPER(TRIM(p_sku))
          AND (p_coordinator_id IS NULL OR coordinator_id = p_coordinator_id)
    ) THEN
        RAISE EXCEPTION 'SKU not found or access denied';
    END IF;
 
    -- [CH6] Read current qty before update so the audit log is accurate
    SELECT available_qty INTO v_old_qty
    FROM   inventory
    WHERE  sku = UPPER(TRIM(p_sku))
      AND  (p_coordinator_id IS NULL OR coordinator_id = p_coordinator_id);
 
    UPDATE inventory
    SET
        product_name   = p_product_name,
        category       = p_category,
        available_qty  = available_qty + COALESCE(p_stock_to_add, 0),
        vendor         = p_vendor,
        lens_type      = p_lens_type,
        lens_gender    = p_lens_gender,
        frame_size     = p_frame_size,
        -- [CH1]
        lens_color     = p_lens_color,
        lens_material  = p_lens_material,
        frame_material = p_frame_material,
        frame_color    = p_frame_color,
        sph_right      = p_sph_right,
        sph_left       = p_sph_left,
        cyl_right      = p_cyl_right,
        cyl_left       = p_cyl_left,
        axis_right     = p_axis_right,
        axis_left      = p_axis_left,
        notes          = p_notes
    WHERE sku = UPPER(TRIM(p_sku))
      AND (p_coordinator_id IS NULL OR coordinator_id = p_coordinator_id);
 
    GET DIAGNOSTICS v_rows = ROW_COUNT;
 
    -- [CH6] Audit: only write if stock actually changed
    IF v_rows > 0 AND COALESCE(p_stock_to_add, 0) > 0 THEN
        INSERT INTO inventory_stock_audit (
            sku, coordinator_id, action_type,
            qty_changed, old_qty, new_qty,
            performed_by, remarks
        ) VALUES (
            UPPER(TRIM(p_sku)), p_coordinator_id, 'UPDATE',
            p_stock_to_add, v_old_qty, v_old_qty + p_stock_to_add,
            p_coordinator_id, 'Stock added via edit modal'
        );
    END IF;
 
    RETURN QUERY SELECT (v_rows > 0);
END;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_quick_update  [CH5] — NEW
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_quick_update(
    p_sku             VARCHAR,
    p_coordinator_id  INTEGER,
    p_stock_to_add    INTEGER    -- must be > 0; quick add only, not subtract
)
RETURNS TABLE (
    updated   BOOLEAN,
    new_qty   INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- Validate: quick update must add stock, not subtract
    IF COALESCE(p_stock_to_add, 0) <= 0 THEN
        RAISE EXCEPTION 'stock_to_add must be greater than 0 for quick update';
    END IF;
 
    -- Lock row for this coordinator only (quick update is never SysAdmin-scoped)
    SELECT available_qty
    INTO   v_current
    FROM   inventory
    WHERE  sku            = UPPER(TRIM(p_sku))
      AND  coordinator_id = p_coordinator_id
    FOR UPDATE;
 
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SKU % not found in your inventory', p_sku;
    END IF;
 
    UPDATE inventory
    SET    available_qty = available_qty + p_stock_to_add
    WHERE  sku            = UPPER(TRIM(p_sku))
      AND  coordinator_id = p_coordinator_id;
 
    -- Audit trail for quick update
    INSERT INTO inventory_stock_audit (
        sku, coordinator_id, action_type,
        qty_changed, old_qty, new_qty,
        performed_by, remarks
    ) VALUES (
        UPPER(TRIM(p_sku)), p_coordinator_id, 'QUICK_UPDATE',
        p_stock_to_add, v_current, v_current + p_stock_to_add,
        p_coordinator_id, 'Stock added via quick update grid'
    );
 
    RETURN QUERY SELECT TRUE, (v_current + p_stock_to_add);
END;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_delete_stock  [CH3]
-- (Audit INSERT + FOR UPDATE lock kept from uploaded file — already correct.)
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_delete_stock(
    p_sku                VARCHAR,
    p_quantity_to_remove INTEGER,
    p_coordinator_id     INTEGER
)
RETURNS TABLE (
    success     BOOLEAN,
    before_qty  INTEGER,   -- [CH3b] qty BEFORE removal — shown in UI delete dialog
    after_qty   INTEGER    -- [CH3a] renamed from remaining_qty, no collision with table col
)
LANGUAGE plpgsql AS $$
DECLARE
    v_current      INTEGER;
    v_remaining    INTEGER;
    v_coord_id     INTEGER;  -- resolved coordinator_id for audit (never NULL)
BEGIN
    -- FOR UPDATE lock: prevents two requests from simultaneously over-drawing
    SELECT inv.available_qty, inv.coordinator_id
    INTO   v_current, v_coord_id
    FROM   inventory inv
    WHERE  inv.sku = UPPER(TRIM(p_sku))
      AND  (p_coordinator_id IS NULL OR inv.coordinator_id = p_coordinator_id)
    FOR UPDATE;
 
    IF NOT FOUND THEN
        -- [CH3a] Return NULLs with no collision — column names are now distinct
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER;
        RETURN;
    END IF;
 
    -- Guard: cannot remove more than available
    IF p_quantity_to_remove > v_current THEN
        -- [CH3b] Return before_qty so the UI can still display "Current: 120"
        RETURN QUERY SELECT FALSE, v_current, v_current;
        RETURN;
    END IF;
 
    v_remaining := v_current - p_quantity_to_remove;
 
    UPDATE inventory
    SET    available_qty = v_remaining
    WHERE  sku = UPPER(TRIM(p_sku))
      AND  (p_coordinator_id IS NULL OR coordinator_id = p_coordinator_id);
 
    -- Audit trail (kept from uploaded file, already correct)
    INSERT INTO inventory_stock_audit (
        sku, coordinator_id, action_type,
        qty_changed, old_qty, new_qty,
        performed_by, remarks
    ) VALUES (
        UPPER(TRIM(p_sku)),
        v_coord_id,          -- resolved from table row, never NULL
        'DELETE_STOCK',
        p_quantity_to_remove,
        v_current,
        v_remaining,
        COALESCE(p_coordinator_id, v_coord_id),
        'Stock reduced from inventory'
    );
 
    -- [CH3b] Return both before and after — UI dialog gets everything it needs
    RETURN QUERY SELECT TRUE, v_current, v_remaining;
END;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_bulk_import  [CH1] [CH4]
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_bulk_import(
    p_rows            JSONB,
    p_coordinator_id  INTEGER
)
RETURNS TABLE (
    inserted         INTEGER,
    updated          INTEGER,
    skipped          INTEGER,
    skipped_details  JSONB    -- [CH4] [{row_num, sku, reason}] for error report download
)
LANGUAGE plpgsql AS $$
DECLARE
    v_row         JSONB;
    v_sku         VARCHAR;
    v_exists      BOOLEAN;
    v_inserted    INTEGER := 0;
    v_updated     INTEGER := 0;
    v_skipped     INTEGER := 0;
    v_skip_detail JSONB   := '[]'::JSONB;  -- [CH4]
    v_row_num     INTEGER := 0;
BEGIN
    FOR v_row IN SELECT jsonb_array_elements(p_rows)
    LOOP
        v_row_num := v_row_num + 1;
        v_sku     := UPPER(TRIM(v_row->>'sku'));
 
        SELECT EXISTS (
            SELECT 1 FROM inventory
            WHERE  sku            = v_sku
              AND  coordinator_id = p_coordinator_id
        ) INTO v_exists;
 
        IF v_exists THEN
            UPDATE inventory
            SET    available_qty = available_qty + (v_row->>'quantity')::INTEGER
            WHERE  sku            = v_sku
              AND  coordinator_id = p_coordinator_id;
            v_updated := v_updated + 1;
 
            -- [BUG FIX] Audit: record bulk stock increase for existing SKU
            INSERT INTO inventory_stock_audit (
                sku, coordinator_id, action_type,
                qty_changed, old_qty, new_qty,
                performed_by, remarks
            )
            SELECT
                v_sku, p_coordinator_id, 'BULK_IMPORT',
                (v_row->>'quantity')::INTEGER,
                available_qty - (v_row->>'quantity')::INTEGER,
                available_qty,
                p_coordinator_id,
                'Stock increased via bulk Excel upload'
            FROM inventory
            WHERE sku = v_sku AND coordinator_id = p_coordinator_id;
        ELSE
            BEGIN
                INSERT INTO inventory (
                    sku, coordinator_id,
                    product_name, category, available_qty,
                    vendor, lens_type, lens_gender, frame_size,
                    -- [CH1] four columns
                    lens_color, lens_material, frame_material, frame_color,
                    sph_right, sph_left, cyl_right, cyl_left,
                    axis_right, axis_left, notes
                ) VALUES (
                    v_sku, p_coordinator_id,
                    v_row->>'product_name',
                    v_row->>'category',
                    (v_row->>'quantity')::INTEGER,
                    v_row->>'vendor',
                    v_row->>'lens_type',
                    v_row->>'lens_gender',
                    v_row->>'frame_size',
                    -- [CH1]
                    v_row->>'lens_color',
                    v_row->>'lens_material',
                    v_row->>'frame_material',
                    v_row->>'frame_color',
                    NULLIF(v_row->>'sph_right','')::NUMERIC,
                    NULLIF(v_row->>'sph_left', '')::NUMERIC,
                    NULLIF(v_row->>'cyl_right','')::NUMERIC,
                    NULLIF(v_row->>'cyl_left', '')::NUMERIC,
                    NULLIF(v_row->>'axis_right','')::SMALLINT,
                    NULLIF(v_row->>'axis_left', '')::SMALLINT,
                    v_row->>'notes'
                );
                v_inserted := v_inserted + 1;
 
                -- [BUG FIX] Audit: record new item created via bulk import
                INSERT INTO inventory_stock_audit (
                    sku, coordinator_id, action_type,
                    qty_changed, old_qty, new_qty,
                    performed_by, remarks
                ) VALUES (
                    v_sku, p_coordinator_id, 'BULK_IMPORT',
                    (v_row->>'quantity')::INTEGER, 0, (v_row->>'quantity')::INTEGER,
                    p_coordinator_id, 'New item created via bulk Excel upload'
                );
            EXCEPTION WHEN OTHERS THEN
                -- [CH4] Record which row failed and why
                v_skipped     := v_skipped + 1;
                v_skip_detail := v_skip_detail || jsonb_build_object(
                    'row_num', v_row_num,
                    'sku',     v_sku,
                    'reason',  SQLERRM
                );
            END;
        END IF;
    END LOOP;
 
    -- [CH4] Return skipped_details so frontend can build the error report CSV
    RETURN QUERY SELECT v_inserted, v_updated, v_skipped, v_skip_detail;
END;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_export  [CH1] [CH7]
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_export(
    p_coordinator_id  INTEGER,
    p_q               TEXT,
    p_category        VARCHAR,
    p_stock_level     VARCHAR
)
RETURNS TABLE (
    sku             VARCHAR,
    product_name    VARCHAR,
    category        VARCHAR,
    lens_type       VARCHAR,
    lens_gender     VARCHAR,
    sph_right       NUMERIC,
    sph_left        NUMERIC,
    cyl_right       NUMERIC,
    cyl_left        NUMERIC,
    axis_right      SMALLINT,
    axis_left       SMALLINT,
    frame_size      VARCHAR,
    -- [CH1] four columns in explicit export list
    lens_color      VARCHAR,
    lens_material   VARCHAR,
    frame_material  VARCHAR,
    frame_color     VARCHAR,
    vendor          VARCHAR,
    notes           TEXT,
    available_qty   INTEGER,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
)
LANGUAGE sql STABLE AS $$
    SELECT
        i.sku, i.product_name, i.category,
        i.lens_type, i.lens_gender,
        i.sph_right, i.sph_left,
        i.cyl_right, i.cyl_left,
        i.axis_right, i.axis_left,
        i.frame_size,
        -- [CH1]
        i.lens_color, i.lens_material, i.frame_material, i.frame_color,
        i.vendor, i.notes,
        i.available_qty,
        i.created_at, i.updated_at
    FROM inventory i
    WHERE
        (p_coordinator_id IS NULL OR i.coordinator_id = p_coordinator_id)
    AND (
        p_q IS NULL
        OR i.sku          ILIKE '%' || p_q || '%'
        OR i.product_name ILIKE '%' || p_q || '%'
    )
    AND (p_category IS NULL OR i.category = p_category)
    AND (
        p_stock_level IS NULL
        OR (p_stock_level = 'in'  AND i.available_qty >  5)
        OR (p_stock_level = 'low' AND i.available_qty >= 1 AND i.available_qty <= 5)
        OR (p_stock_level = 'out' AND i.available_qty  = 0)
    )
    ORDER BY i.sku;
$$;
 
 
-- ─────────────────────────────────────────────────────────────────────────
-- sp_inv_transfer  [CH1]  (rest unchanged)
--
-- CH1: INSERT and SELECT in the clone branch now use the 4 new column names.
-- ─────────────────────────────────────────────────────────────────────────
 
CREATE OR REPLACE FUNCTION sp_inv_transfer(
    p_sku              VARCHAR,
    p_from_coordinator INTEGER,
    p_to_coordinator   INTEGER,
    p_quantity         INTEGER,
    p_performed_by     INTEGER
)
RETURNS TABLE (transferred BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
    v_current   INTEGER;
    v_to_exists BOOLEAN;
BEGIN
    SELECT available_qty
    INTO   v_current
    FROM   inventory
    WHERE  sku            = UPPER(TRIM(p_sku))
      AND  coordinator_id = p_from_coordinator
    FOR UPDATE;
 
    IF NOT FOUND OR v_current < p_quantity THEN
        RETURN QUERY SELECT FALSE;
        RETURN;
    END IF;
 
    UPDATE inventory
    SET    available_qty = available_qty - p_quantity
    WHERE  sku            = UPPER(TRIM(p_sku))
      AND  coordinator_id = p_from_coordinator;
 
    SELECT EXISTS (
        SELECT 1 FROM inventory
        WHERE  sku            = UPPER(TRIM(p_sku))
          AND  coordinator_id = p_to_coordinator
    ) INTO v_to_exists;
 
    IF v_to_exists THEN
        UPDATE inventory
        SET    available_qty = available_qty + p_quantity
        WHERE  sku            = UPPER(TRIM(p_sku))
          AND  coordinator_id = p_to_coordinator;
    ELSE
        INSERT INTO inventory (
            sku, coordinator_id,
            product_name, category, available_qty,
            vendor, lens_type, lens_gender, frame_size,
            lens_color, lens_material, frame_material, frame_color,  -- [CH1]
            sph_right, sph_left, cyl_right, cyl_left,
            axis_right, axis_left, notes
        )
        SELECT
            UPPER(TRIM(p_sku)), p_to_coordinator,
            product_name, category, p_quantity,
            vendor, lens_type, lens_gender, frame_size,
            lens_color, lens_material, frame_material, frame_color,  -- [CH1]
            sph_right, sph_left, cyl_right, cyl_left,
            axis_right, axis_left, notes
        FROM inventory
        WHERE  sku            = UPPER(TRIM(p_sku))
          AND  coordinator_id = p_from_coordinator;
    END IF;
 
    -- [BUG FIX] Audit: record deduction from source coordinator
    INSERT INTO inventory_stock_audit (
        sku, coordinator_id, action_type,
        qty_changed, old_qty, new_qty,
        performed_by, remarks
    ) VALUES (
        UPPER(TRIM(p_sku)), p_from_coordinator, 'TRANSFER',
        p_quantity, v_current, v_current - p_quantity,
        p_performed_by,
        FORMAT('Transferred %s units to coordinator %s', p_quantity, p_to_coordinator)
    );
 
    -- [BUG FIX] Audit: record addition to destination coordinator
    INSERT INTO inventory_stock_audit (
        sku, coordinator_id, action_type,
        qty_changed, old_qty, new_qty,
        performed_by, remarks
    )
    SELECT
        UPPER(TRIM(p_sku)), p_to_coordinator, 'TRANSFER',
        p_quantity, available_qty - p_quantity, available_qty,
        p_performed_by,
        FORMAT('Received %s units from coordinator %s', p_quantity, p_from_coordinator)
    FROM inventory
    WHERE sku = UPPER(TRIM(p_sku)) AND coordinator_id = p_to_coordinator;
 
    RETURN QUERY SELECT TRUE;
END;
$$;
