
# inventory_api.py
 
# ═══════════════════════════════════════════════════════════════════════════
# iCare – Brighter Future Program
# Inventory Module Backend API
# Blueprint Version (Integrated with app.py)
# Flask + PostgreSQL
# ═══════════════════════════════════════════════════════════════════════════
 
import os
import io
import csv
import json
import re
import logging
from functools import wraps
from datetime import date
 
import psycopg2
import psycopg2.extras
import psycopg2.errors
 
from flask import (
    Blueprint,
    request,
    jsonify,
    g,
    Response
)
 
from database_connection.db import get_db_connection
 
# Optional Excel support
try:
    import pandas as pd
    PANDAS_AVAILABLE = True
except ImportError:
    PANDAS_AVAILABLE = False
 
# ═══════════════════════════════════════════════════════════════════════════
# BLUEPRINT
# ═══════════════════════════════════════════════════════════════════════════
 
inventory_bp = Blueprint('inventory_bp', __name__)
 
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
 
# ═══════════════════════════════════════════════════════════════════════════
# DATABASE HELPERS
# ═══════════════════════════════════════════════════════════════════════════
 
def run_query(sql, params=(), fetch="all"):
    """
    Run a query and return results.
    fetch="all"  → list of rows
    fetch="one"  → single row (or None)
    fetch="none" → no result expected (INSERT/UPDATE without RETURNING)
    """
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            conn.commit()
            if fetch == "all":
                return cur.fetchall()
            elif fetch == "one":
                return cur.fetchone()
            else:
                return None
    except psycopg2.Error as e:
        if conn:
            conn.rollback()
        logger.error("DB error: %s | SQL: %.120s", e, sql)
        raise e
    finally:
        if conn:
            conn.close()
 
# ═══════════════════════════════════════════════════════════════════════════
# RESPONSE HELPERS
# ═══════════════════════════════════════════════════════════════════════════
 
def success(data=None, status=200):
    """Wrap a successful response."""
    return jsonify({"ok": True, "data": data}), status
 
 
def error(message, status=400):
    """Wrap an error response."""
    return jsonify({"ok": False, "error": message}), status
 
# ═══════════════════════════════════════════════════════════════════════════
# AUTH / CONTEXT HELPERS
# ═══════════════════════════════════════════════════════════════════════════
 
def require_session(f):
    """
    Reads coordinator_id from the request and populates g.coordinator_id.
 
    For GET requests        → query param:  ?coordinator_id=N
    For POST/PUT/DELETE     → JSON body:    { "coordinator_id": N, ... }
 
    coordinator_id is optional (omit or pass null for a global/SysAdmin scope).
    All stored procedures accept NULL coordinator_id to mean "no scope filter".
 
    Populates Flask g:
      g.coordinator_id  – INTEGER or None
    """
    @wraps(f)
    def decorated(*args, **kwargs):
        if request.method == "GET":
            raw_coord = request.args.get("coordinator_id")
        else:
            body      = request.get_json(force=True, silent=True) or {}
            raw_coord = body.get("coordinator_id")
 
        coordinator_id = None
        if raw_coord is not None:
            try:
                coordinator_id = int(raw_coord)
            except (TypeError, ValueError):
                return error("coordinator_id must be an integer.", 400)
 
        g.coordinator_id = coordinator_id
        return f(*args, **kwargs)
    return decorated
 
 
def scope():
    """
    DB scope selector used in every stored procedure call.
    None → no coordinator filter (global view, e.g. SysAdmin context)
    int  → strict per-coordinator data access
    """
    return g.coordinator_id
 
# ═══════════════════════════════════════════════════════════════════════════
# VALIDATION HELPERS
# ═══════════════════════════════════════════════════════════════════════════
 
VALID_LENS_TYPES   = {"Single Vision", "Bifocal", "Progressive"}
VALID_FRAME_SIZES  = {"Small", "Medium", "Large", "Extra Large", ""}
BULK_REQUIRED_COLS = {"sku", "quantity"}
VALID_CATEGORIES   = {
    "Glasses", "Single Vision", "Bifocal", "Progressive",
    "Sunglasses", "Contact Lens", "Frame"
}
 
 
def _v_sku(sku):
    """SKU: alphanumeric + hyphen + underscore, max 50 chars."""
    if not sku or not str(sku).strip():
        return "SKU is required."
    s = str(sku).strip()
    if len(s) > 50:
        return "SKU must be 50 characters or fewer."
    if not re.match(r'^[A-Za-z0-9_-]+$', s):
        return "SKU: only letters, numbers, hyphen and underscore allowed."
    return None
 
 
def _v_qty(val, label="Quantity", allow_zero=False):
    """Quantity: whole number, optionally allowing 0."""
    try:
        v = int(val)
    except (TypeError, ValueError):
        return f"{label} must be a whole number."
    if allow_zero and v < 0:
        return f"{label} cannot be negative."
    if not allow_zero and v <= 0:
        return f"{label} must be greater than 0."
    return None
 
 
def _v_sph_cyl(val, label):
    """SPH/CYL: decimal, multiple of 0.25, range -30 to +30."""
    if val is None or str(val).strip() == "":
        return None
    try:
        f = float(val)
    except (TypeError, ValueError):
        return f"{label} must be a decimal number (e.g. -1.25)."
    if not (-30.0 <= f <= 30.0):
        return f"{label} value {f} is outside the expected range (-30 to +30)."
    return None
 
 
def _v_axis(val, label):
    """Axis: integer 0 - 180."""
    if val is None or str(val).strip() == "":
        return None
    try:
        i = int(val)
    except (TypeError, ValueError):
        return f"{label} must be a whole number (0 - 180)."
    if not (0 <= i <= 180):
        return f"{label} must be between 0 and 180."
    return None
 
 
def _parse_rx(body, suffix):
    """
    Extract one eye's prescription fields from the request body.
    suffix = "od" (right/OD) or "os" (left/OS)
    """
    return (
        body.get(f"{suffix}_sph"),
        body.get(f"{suffix}_cyl"),
        body.get(f"{suffix}_axis"),
    )
 
# ═══════════════════════════════════════════════════════════════════════════
# HEALTH CHECK  GET /inventory/health
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/health", methods=["GET"])
def health():
    """Quick ping to confirm the API and DB are alive."""
    try:
        run_query("SELECT 1", fetch="one")
        return success({"status": "Inventory API is running. DB connected."})
    except Exception as e:
        return error(f"DB unreachable: {str(e)}", 503)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 0.5 — SEARCH INVENTORY BY RX
# GET /inventory/search
# ═══════════════════════════════════════════════════════════════════════════

@inventory_bp.route("/inventory/search", methods=["GET"])
@require_session
def search_inventory_rx():
    """
    Search and score coordinator inventory based on patient's RX.
    Returns ranked matches with details.
    """
    coord_id = g.coordinator_id or request.args.get("coordinator_id")
    
    od_sph = request.args.get("od_sph")
    od_cyl = request.args.get("od_cyl")
    od_axis = request.args.get("od_axis")
    od_add = request.args.get("od_add")
    
    os_sph = request.args.get("os_sph")
    os_cyl = request.args.get("os_cyl")
    os_axis = request.args.get("os_axis")
    os_add = request.args.get("os_add")
    
    frame_size = request.args.get("frame_size") or ""
    lens_type = request.args.get("lens_type") or ""

    if not coord_id:
        return error("coordinator_id is required.", 400)

    try:
        rows = run_query(
            """
            SELECT 
                r.sku,
                r.product_name,
                r.lens_type,
                r.frame_size,
                r.available_qty,
                r.match_percentage,
                i.sph_right,
                i.sph_left,
                i.cyl_right,
                i.axis_right,
                i.lens_gender
            FROM sp_search_inventory_rx(
                %s::INTEGER, %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::VARCHAR, %s::VARCHAR
            ) r
            JOIN inventory i ON i.sku = r.sku AND i.coordinator_id = %s
            """,
            (
                int(coord_id),
                _to_numeric(od_sph),
                _to_numeric(od_cyl),
                _to_smallint(od_axis),
                _to_numeric(od_add),
                _to_numeric(os_sph),
                _to_numeric(os_cyl),
                _to_smallint(os_axis),
                _to_numeric(os_add),
                frame_size,
                lens_type,
                int(coord_id)
            )
        )
        items = []
        for r in rows:
            items.append({
                "sku": r.get("sku"),
                "name": r.get("product_name"),
                "lens_type": r.get("lens_type"),
                "frame_size": r.get("frame_size"),
                "stock": r.get("available_qty"),
                "score": r.get("match_percentage"),
                "od_sph": float(r.get("sph_right")) if r.get("sph_right") is not None else 0.0,
                "os_sph": float(r.get("sph_left")) if r.get("sph_left") is not None else 0.0,
                "od_cyl": float(r.get("cyl_right")) if r.get("cyl_right") is not None else 0.0,
                "od_axis": int(r.get("axis_right")) if r.get("axis_right") is not None else 0,
                "gender": r.get("lens_gender") or ""
            })
        return success(items)
    except Exception as e:
        return error(str(e), 500)


# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 1 — INVENTORY STATS
# GET /inventory/stats?coordinator_id=N
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/stats", methods=["GET"])
@require_session
def inventory_stats():
    """
    Stat card counts scoped to the coordinator.
 
    Query params: coordinator_id (optional – omit for global view)
    SP: sp_inv_stats(coordinator_id)
    Returns: { total_skus, in_stock, low_stock, out_of_stock }
    """
    try:
        row = run_query(
            "SELECT * FROM sp_inv_stats(%s)",
            (scope(),),
            fetch="one"
        )
        return success(dict(row) if row else {})
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 2 — LIST INVENTORY
# GET /inventory?coordinator_id=N[&sku=...&name=...&...]
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory", methods=["GET"])
@require_session
def list_inventory():
    """
    Paginated, searchable, sortable inventory list scoped to coordinator.
 
    Query params:
      coordinator_id  → optional; omit for global view
      sku / name      → free-text search (SKU + product_name)
      sph             → numeric SPH search ±0.25 tolerance
      cyl             → numeric CYL search ±0.25 tolerance
      category        → exact category filter
      stock_level     → "in" | "low" | "out"
      sort_by         → sku | product_name | qty | category | lens_type
      sort_dir        → asc | desc
      limit           → page size max 200 (default 10)
      offset          → pagination offset (default 0)
 
    SP: sp_inv_list(coordinator_id, p_q, p_sph, p_cyl, p_category,
                    p_stock_level, p_sort_by, p_sort_dir, p_limit, p_offset)
    """
    sku_q  = (request.args.get("sku")  or "").strip()
    name_q = (request.args.get("name") or "").strip()
    q      = sku_q or name_q or None
 
    sph       = request.args.get("sph",  type=float) if request.args.get("sph")  else None
    cyl       = request.args.get("cyl",  type=float) if request.args.get("cyl")  else None
    category  = request.args.get("category")    or None
    stock_lvl = request.args.get("stock_level") or None
    sort_by   = request.args.get("sort_by",  "sku")
    sort_dir  = request.args.get("sort_dir", "asc")
    limit     = min(request.args.get("limit",  10, type=int), 200)
    offset    = request.args.get("offset",     0,  type=int)
 
    # Whitelist sort params — prevents SQL injection
    if sort_by  not in {"sku", "product_name", "qty", "category", "lens_type"}:
        sort_by  = "sku"
    if sort_dir not in {"asc", "desc"}:
        sort_dir = "asc"
 
    try:
        rows = run_query(
            "SELECT * FROM sp_inv_list(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (scope(), q, sph, cyl, category, stock_lvl,
             sort_by, sort_dir, limit, offset)
        )
        total = rows[0]["total_count"] if rows else 0
        items = [_row_to_item(dict(r)) for r in rows]
        return success({
            "items":      items,
            "pagination": {"total": total, "limit": limit, "offset": offset}
        })
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 3 — GET SINGLE ITEM  (View / Edit modal pre-fill)
# GET /inventory/sku/<sku>/detail?coordinator_id=N
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/sku/<path:sku>/detail", methods=["GET"])
@require_session
def get_inventory_item(sku):
    """
    Full item detail for the View or Edit modal.
 
    Query params: coordinator_id (optional)
    SP: sp_inv_get_by_sku(sku, coordinator_id)
    Returns 404 if SKU not found or belongs to another coordinator.
    """
    sku = sku.strip().upper()
    try:
        row = run_query(
            "SELECT * FROM sp_inv_get_by_sku(%s, %s)",
            (sku, scope()),
            fetch="one"
        )
        if not row:
            return error("Item not found or access denied.", 404)
        return success(_row_to_item(dict(row)))
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 4 — SKU LOOKUP
# GET /inventory/sku/<sku>?coordinator_id=N
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/sku/<path:sku>", methods=["GET"])
@require_session
def lookup_sku(sku):
    """
    Step 1 of the Add/Update flow — checks if SKU already exists.
 
    Query params: coordinator_id (optional)
    Returns:
      { found: true,  item: {...} }  → open Quick Update modal
      { found: false, sku: "..." }   → open Insert modal with blank form
 
    SP: sp_inv_lookup_sku(sku, coordinator_id)
    """
    sku = sku.strip().upper()
    e   = _v_sku(sku)
    if e:
        return error(e)
    try:
        row = run_query(
            "SELECT * FROM sp_inv_lookup_sku(%s, %s)",
            (sku, scope()),
            fetch="one"
        )
        if row:
            return success({"found": True, "item": _row_to_item(dict(row))})
        return success({"found": False, "sku": sku})
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 5 — CREATE INVENTORY ITEM
# POST /inventory
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory", methods=["POST"])
@require_session
def create_inventory_item():
    """
    Insert a new inventory item.
    coordinator_id is taken from the request body.
 
    Required body fields: coordinator_id*, sku*, description*, category*, quantity* (> 0)
    Optional: vendor, lensType, lensGender, frameSize, lensColor, lensMaterial,
              frameColor, frameMaterial, od_sph, od_cyl, od_axis,
              os_sph, os_cyl, os_axis, notes
 
    SP: sp_inv_create(sku, product_name, category, quantity,
                      vendor, lens_type, lens_gender, frame_size,
                      lens_color, lens_material, frame_material, frame_color,
                      sph_right, sph_left, cyl_right, cyl_left,
                      axis_right, axis_left, notes, coordinator_id)
 
    Returns: { sku: "SKU-0001" }
    409 if SKU already exists for this coordinator.
    """
    body = request.get_json(force=True, silent=True)
    if not body:
        return error("Request body is missing or not valid JSON.")
 
    if g.coordinator_id is None:
        return error("coordinator_id is required to create inventory.", 400)
 
    sku            = str(body.get("sku")          or "").strip().upper()
    product_name   = str(body.get("description")  or "").strip()
    category       = body.get("category")
    vendor         = body.get("vendor")
    lens_type      = body.get("lensType")
    lens_gender    = body.get("lensGender")
    frame_size     = body.get("frameSize")
    lens_color     = body.get("lensColor")     or body.get("color")
    lens_material  = body.get("lensMaterial")  or body.get("material")
    frame_material = body.get("frameMaterial")
    frame_color    = body.get("frameColor")
    quantity       = body.get("quantity", 0)
    notes          = body.get("notes")
 
    od_sph, od_cyl, od_axis = _parse_rx(body, "od")
    os_sph, os_cyl, os_axis = _parse_rx(body, "os")
 
    errs = []
    e = _v_sku(sku);                                          errs.append(e) if e else None
    if len(product_name) < 3:                                 errs.append("Description must be at least 3 characters.")
    if not category:                                          errs.append("Please select Category.")
    elif category not in VALID_CATEGORIES:                    errs.append("Invalid category selected.")
    if lens_type and lens_type not in VALID_LENS_TYPES:       errs.append("Invalid lens type selected.")
    if frame_size not in VALID_FRAME_SIZES:                   errs.append("Invalid frame size selected.")
    e = _v_qty(quantity, "Quantity");                         errs.append(e) if e else None
 
    for val, lbl in [(od_sph, "OD SPH"), (od_cyl, "OD CYL"),
                     (os_sph, "OS SPH"), (os_cyl, "OS CYL")]:
        e = _v_sph_cyl(val, lbl); errs.append(e) if e else None
 
    e = _v_axis(od_axis, "Right Eye Axis"); errs.append(e) if e else None
    e = _v_axis(os_axis, "Left Eye Axis");  errs.append(e) if e else None
 
    if errs:
        return error({"validation_errors": errs})
 
    try:
        run_query(
            """
            SELECT sp_inv_create(
                %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,  %s::INTEGER,
                %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,
                %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,
                %s::NUMERIC,  %s::NUMERIC,  %s::NUMERIC,  %s::NUMERIC,
                %s::SMALLINT, %s::SMALLINT,
                %s::TEXT,     %s::INTEGER
            )
            """,
            (
                sku,          product_name,          category,        int(quantity),
                vendor,       lens_type,              lens_gender,     frame_size,
                lens_color,   lens_material,          frame_material,  frame_color,
                _to_numeric(od_sph),  _to_numeric(os_sph),
                _to_numeric(od_cyl),  _to_numeric(os_cyl),
                _to_smallint(od_axis), _to_smallint(os_axis),
                notes,
                g.coordinator_id
            ),
            fetch="none"
        )
        return success({"sku": sku}, status=201)
 
    except psycopg2.errors.UniqueViolation:
        return error(
            f"SKU '{sku}' already exists in your inventory. "
            "Use Quick Update to add stock, or Edit to change details.",
            409
        )
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 6 — UPDATE INVENTORY ITEM
# PUT /inventory/sku/<sku>
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/sku/<path:sku>", methods=["PUT"])
@require_session
def update_inventory_item(sku):
    """
    Update item details and/or add stock.
    stock_to_add is a DELTA (0 = details-only update, positive = add stock).
 
    Required body fields: coordinator_id*
    SP: sp_inv_update(sku, coordinator_id, product_name, category,
                      stock_to_add, vendor, lens_type, lens_gender,
                      frame_size, lens_color, lens_material, frame_material,
                      frame_color, sph_right, sph_left, cyl_right, cyl_left,
                      axis_right, axis_left, notes)
    Returns: { updated: true } or 404.
    """
    sku  = sku.strip().upper()
    body = request.get_json(force=True, silent=True)
    if not body:
        return error("Request body is missing or not valid JSON.")
 
    product_name   = str(body.get("description")  or "").strip()
    category       = body.get("category")
    vendor         = body.get("vendor")
    lens_type      = body.get("lensType")
    lens_gender    = body.get("lensGender")
    frame_size     = body.get("frameSize")
    lens_color     = body.get("lensColor")     or body.get("color")
    lens_material  = body.get("lensMaterial")  or body.get("material")
    frame_material = body.get("frameMaterial")
    frame_color    = body.get("frameColor")
    stock_to_add   = body.get("stock_to_add", 0)
    notes          = body.get("notes")
 
    od_sph, od_cyl, od_axis = _parse_rx(body, "od")
    os_sph, os_cyl, os_axis = _parse_rx(body, "os")
 
    errs = []
    if len(product_name) < 3:                                errs.append("Description must be at least 3 characters.")
    if not category:                                         errs.append("Please select Category.")
    elif category not in VALID_CATEGORIES:                   errs.append("Invalid category selected.")
    if lens_type and lens_type not in VALID_LENS_TYPES:      errs.append("Invalid lens type selected.")
    if frame_size not in VALID_FRAME_SIZES:                  errs.append("Invalid frame size selected.")
    e = _v_qty(stock_to_add, "Stock to Add", allow_zero=True); errs.append(e) if e else None
 
    for val, lbl in [(od_sph, "OD SPH"), (od_cyl, "OD CYL"),
                     (os_sph, "OS SPH"), (os_cyl, "OS CYL")]:
        e = _v_sph_cyl(val, lbl); errs.append(e) if e else None
 
    e = _v_axis(od_axis, "Right Eye Axis"); errs.append(e) if e else None
    e = _v_axis(os_axis, "Left Eye Axis");  errs.append(e) if e else None
 
    if errs:
        return error({"validation_errors": errs})
 
    try:
        row = run_query(
            """
            SELECT * FROM sp_inv_update(
                %s::VARCHAR,  %s::INTEGER,
                %s::VARCHAR,  %s::VARCHAR,  %s::INTEGER,
                %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,
                %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,  %s::VARCHAR,
                %s::NUMERIC,  %s::NUMERIC,  %s::NUMERIC,  %s::NUMERIC,
                %s::SMALLINT, %s::SMALLINT,
                %s::TEXT
            )
            """,
            (
                sku,            scope(),
                product_name,   category,        int(stock_to_add),
                vendor,         lens_type,        lens_gender,      frame_size,
                lens_color,     lens_material,    frame_material,   frame_color,
                _to_numeric(od_sph),   _to_numeric(os_sph),
                _to_numeric(od_cyl),   _to_numeric(os_cyl),
                _to_smallint(od_axis), _to_smallint(os_axis),
                notes
            ),
            fetch="one"
        )
        if not row or not row.get("updated"):
            return error("Item not found or you do not have permission to edit it.", 404)
        return success({"message": "Item updated successfully.", "sku": sku})
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 7 — QUICK STOCK UPDATE  (Quick Update Grid modal)
# POST /inventory/sku/<sku>/quick-update
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/sku/<path:sku>/quick-update", methods=["POST"])
@require_session
def quick_update(sku):
    """
    Flowchart: Quick Update Grid → Click Save Icon → increases available_qty only.
    NEVER overwrites product details — stock replenishment only.
 
    Required body fields: coordinator_id*
    Body: { "coordinator_id": N, "stock_to_add": N }   (stock_to_add > 0)
    SP: sp_inv_quick_update(sku, coordinator_id, stock_to_add)
    Returns: { updated: true, new_qty: N }
    """
    sku  = sku.strip().upper()
    body = request.get_json(force=True, silent=True)
    if not body:
        return error("Request body is missing or not valid JSON.")
 
    if g.coordinator_id is None:
        return error("coordinator_id is required for quick update.", 400)
 
    stock_to_add = body.get("stock_to_add")
    e = _v_qty(stock_to_add, "Stock to Add")   # must be > 0
    if e:
        return error(e)
 
    try:
        row = run_query(
            "SELECT * FROM sp_inv_quick_update(%s, %s, %s)",
            (sku, g.coordinator_id, int(stock_to_add)),
            fetch="one"
        )
        if not row or not row.get("updated"):
            return error("SKU not found in your inventory.", 404)
        return success({
            "updated": True,
            "new_qty": row.get("new_qty"),
            "message": f"Stock adjusted. SKU: {sku} quantity increased by +{stock_to_add}."
        })
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 8 — REDUCE / DELETE STOCK not to delete the row, just reduce the quantity
# DELETE /inventory/sku/<sku>
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/sku/<path:sku>", methods=["DELETE"])
@require_session
def delete_inventory_stock(sku):
    """
    Flowchart: Delete Prompt → validates input ≤ available qty → reduces stock.
    The inventory row is NEVER physically deleted — only qty is reduced.
 
    Required body fields: coordinator_id (optional – omit for global scope)
    Body: { "coordinator_id": N, "quantity_to_remove": N }
    SP: sp_inv_delete_stock(sku, quantity_to_remove, coordinator_id)
    Returns: { before_qty: N, after_qty: N }
    """
    sku  = sku.strip().upper()
    body = request.get_json(force=True, silent=True)
    if not body:
        return error("Request body is missing or not valid JSON.")
 
    qty_remove = body.get("quantity_to_remove")
    e = _v_qty(qty_remove, "Quantity to remove")
    if e:
        return error(e)
 
    try:
        row = run_query(
            "SELECT * FROM sp_inv_delete_stock(%s, %s, %s)",
            (sku, int(qty_remove), scope()),
            fetch="one"
        )
        if not row:
            return error("Item not found or access denied.", 404)
 
        if not row.get("success"):
            return error(
                f"Cannot exceed available quantity ({row.get('before_qty', '?')}).",
                422
            )
        return success({
            "message":    "Stock reduced successfully.",
            "before_qty": row.get("before_qty"),
            "after_qty":  row.get("after_qty")
        })
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 9 — BULK UPLOAD VALIDATE  (file drop-zone → data preview)
# POST /inventory/bulk/validate
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/bulk/validate", methods=["POST"])
@require_session
def bulk_validate():
    """
    Flowchart: Step 1 Drag & Drop → Step 2 Show Data Preview.
    Parses CSV/Excel and returns row-by-row validation.
    Nothing is written to the DB here.
 
    Send as multipart/form-data:
      coordinator_id  – form field (optional)
      file            – .csv | .xlsx | .xls
 
    Mandatory columns: sku, quantity
    Optional columns:  description/product_name, vendor, od_sph, od_cyl,
                       od_axis, os_sph, os_cyl, os_axis, lens_type,
                       frame_size, color, material, notes
 
    Returns per row: row_num, sku, qty, isValid, errorMsg, dbIndex
      dbIndex = 1  → SKU exists (will UPDATE)
      dbIndex = -1 → new SKU   (will INSERT)
    """
    if "file" not in request.files:
        return error("No file part — expected multipart/form-data key 'file'.")
    f = request.files["file"]
    if not f.filename:
        return error("No file selected.")
 
    ext = f.filename.rsplit(".", 1)[-1].lower() if "." in f.filename else ""
    if ext not in {"csv", "xlsx", "xls"}:
        return error("Unsupported file type. Upload .csv, .xlsx, or .xls.")
 
    # Parse file
    try:
        if ext == "csv":
            content  = f.read().decode("utf-8-sig")
            raw_rows = list(csv.DictReader(io.StringIO(content)))
        else:
            if not PANDAS_AVAILABLE:
                return error(
                    "pandas and openpyxl are required for Excel uploads. "
                    "Run: pip install pandas openpyxl"
                )
            df = pd.read_excel(f, dtype=str)
            df.columns = [c.strip().lower().replace(" ", "_") for c in df.columns]
            raw_rows = df.where(pd.notna(df), None).to_dict(orient="records")
    except Exception as exc:
        return error(f"Could not parse file: {exc}")
 
    if not raw_rows:
        return error("The file contains no data rows.")
 
    def norm(row):
        return {
            k.strip().lower().replace(" ", "_"): (v.strip() if isinstance(v, str) else v)
            for k, v in row.items()
        }
 
    # Fetch existing SKUs for coordinator-scoped dbIndex feedback.
    # If coordinator_id is None (global scope) we skip — the SP handles upserts.
    try:
        if g.coordinator_id is not None:
            existing_rows = run_query(
                "SELECT sku FROM inventory WHERE coordinator_id = %s",
                (g.coordinator_id,)
            )
            existing_skus = {r["sku"].upper() for r in existing_rows} if existing_rows else set()
        else:
            existing_skus = set()
    except Exception:
        existing_skus = set()
 
    seen_skus = set()
    results   = []
    valid_n   = 0
 
    for i, raw in enumerate(raw_rows, 1):
        r         = norm(raw)
        error_msg = ""
 
        # Check mandatory columns present
        missing = BULK_REQUIRED_COLS - set(r.keys())
        if missing:
            results.append({
                "row_num":  i,
                "sku":      r.get("sku", ""),
                "qty":      r.get("quantity", ""),
                "isValid":  False,
                "errorMsg": f"Missing columns: {', '.join(sorted(missing))}",
                "dbIndex":  -1
            })
            continue
 
        raw_sku = str(r.get("sku") or "").strip().upper()
 
        # Duplicate SKU within the same upload
        if raw_sku in seen_skus:
            results.append({
                "row_num":  i,
                "sku":      raw_sku,
                "qty":      r.get("quantity", ""),
                "isValid":  False,
                "errorMsg": "Duplicate SKU found in upload file.",
                "dbIndex":  -1
            })
            continue
        seen_skus.add(raw_sku)
 
        e = _v_sku(raw_sku)
        if e:
            error_msg = e
 
        if not error_msg:
            e = _v_qty(r.get("quantity"), "Quantity")
            if e:
                error_msg = e
 
        if not error_msg:
            for fld, lbl in [("od_sph","OD SPH"),("od_cyl","OD CYL"),
                              ("os_sph","OS SPH"),("os_cyl","OS CYL")]:
                e = _v_sph_cyl(r.get(fld), lbl)
                if e:
                    error_msg = e
                    break
 
        if not error_msg:
            for fld, lbl in [("od_axis","Right Axis"),("os_axis","Left Axis")]:
                e = _v_axis(r.get(fld), lbl)
                if e:
                    error_msg = e
                    break
 
        is_valid = (error_msg == "")
        db_index = 1 if raw_sku in existing_skus else -1
        if is_valid:
            valid_n += 1
 
        try:
            qty_val = int(r.get("quantity", 0))
        except (TypeError, ValueError):
            qty_val = r.get("quantity", "")
 
        results.append({
            "row_num":  i,
            "sku":      raw_sku,
            "qty":      qty_val,
            "isValid":  is_valid,
            "errorMsg": error_msg if error_msg else "--",
            "dbIndex":  db_index,
            "_raw": {
                "description": r.get("description") or r.get("product_name") or "New Product",
                "vendor":      r.get("vendor",    "Default Vendor"),
                "od_sph":      r.get("od_sph",    ""),
                "od_cyl":      r.get("od_cyl",    ""),
                "od_axis":     r.get("od_axis",   ""),
                "os_sph":      r.get("os_sph",    ""),
                "os_cyl":      r.get("os_cyl",    ""),
                "os_axis":     r.get("os_axis",   ""),
                "lensType":    r.get("lens_type", "Single Vision"),
                "frameSize":   r.get("frame_size",""),
                "color":       r.get("color",     ""),
                "material":    r.get("material",  ""),
                "notes":       r.get("notes",     ""),
            }
        })
 
    return success({
        "rows": results,
        "summary": {
            "total":   len(results),
            "valid":   valid_n,
            "invalid": len(results) - valid_n
        }
    })
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 10 — BULK UPLOAD CONFIRM & IMPORT
# POST /inventory/bulk/import
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/bulk/import", methods=["POST"])
@require_session
def bulk_import():
    """
    Flowchart: Click 'Confirm & Import' → save good rows, skip bad, allow error report.
 
    Required body fields: coordinator_id*
    Body: { "coordinator_id": N, "rows": [ ...from /bulk/validate... ] }
    Only rows where isValid=true are processed.
 
    SP: sp_inv_bulk_import(rows_jsonb, coordinator_id)
    Returns: { inserted: N, updated: N, skipped: N, skipped_details: [...] }
    """
    body = request.get_json(force=True, silent=True)
    if not body or "rows" not in body:
        return error("Expected JSON body with a 'rows' array.")
 
    if g.coordinator_id is None:
        return error("coordinator_id is required for bulk import.", 400)
 
    rows = body["rows"]
    if not isinstance(rows, list) or not rows:
        return error("'rows' must be a non-empty array.")
 
    good = []
    for r in rows:
        if not r.get("isValid"):
            continue
        raw = r.get("_raw", {})
        good.append({
            "sku":            r["sku"],
            "product_name":   raw.get("description",  "New Product"),
            "category":       "Glasses",
            "quantity":       int(r["qty"]),
            "vendor":         raw.get("vendor",        "Default Vendor"),
            "lens_type":      raw.get("lensType",      "Single Vision"),
            "lens_gender":    None,
            "frame_size":     raw.get("frameSize",     ""),
            "lens_color":     raw.get("color",         ""),
            "lens_material":  raw.get("material",      ""),
            "frame_material": None,
            "frame_color":    None,
            "sph_right":      raw.get("od_sph",        ""),
            "sph_left":       raw.get("os_sph",        ""),
            "cyl_right":      raw.get("od_cyl",        ""),
            "cyl_left":       raw.get("os_cyl",        ""),
            "axis_right":     raw.get("od_axis",       ""),
            "axis_left":      raw.get("os_axis",       ""),
            "notes":          raw.get("notes",         ""),
        })
 
    if not good:
        return error("No valid rows to import.")
 
    try:
        row = run_query(
            "SELECT * FROM sp_inv_bulk_import(%s::jsonb, %s)",
            (json.dumps(good), g.coordinator_id),
            fetch="one"
        )
        return success({
            "inserted":        row.get("inserted", 0),
            "updated":         row.get("updated",  0),
            "skipped":         row.get("skipped",  0),
            "skipped_details": row.get("skipped_details", []),
        })
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 11 — EXPORT CSV
# GET /inventory/export?coordinator_id=N[&q=...&category=...&stock_level=...]
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/export", methods=["GET"])
@require_session
def export_inventory():
    """
    Download coordinator's inventory as a CSV file.
    Accepts same filter params as GET /inventory.
 
    Query params: coordinator_id (optional – omit for global export)
    SP: sp_inv_export(coordinator_id, q, category, stock_level)
    Filename: inventory_<coordinator_id>_<YYYY-MM-DD>.csv
    """
    q         = request.args.get("q")           or None
    category  = request.args.get("category")    or None
    stock_lvl = request.args.get("stock_level") or None
 
    try:
        rows = run_query(
            "SELECT * FROM sp_inv_export(%s, %s, %s, %s)",
            (scope(), q, category, stock_lvl)
        )
    except Exception as e:
        return error(str(e), 500)
 
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow([
        "SKU", "Lens Type", "Description/Name",
        "Right Eye SPH (OD)", "Right Eye CYL (OD)", "Right Eye Axis (OD)",
        "Left Eye SPH (OS)",  "Left Eye CYL (OS)",  "Left Eye Axis (OS)",
        "Vendor", "Frame Size", "Lens Color", "Lens Material",
        "Frame Color", "Frame Material", "Available Quantity", "Notes"
    ])
    for r in rows:
        writer.writerow([
            r.get("sku"),           r.get("lens_type"),     r.get("product_name"),
            r.get("sph_right"),     r.get("cyl_right"),     r.get("axis_right"),
            r.get("sph_left"),      r.get("cyl_left"),      r.get("axis_left"),
            r.get("vendor"),        r.get("frame_size"),
            r.get("lens_color"),    r.get("lens_material"),
            r.get("frame_color"),   r.get("frame_material"),
            r.get("available_qty"), r.get("notes")
        ])
 
    coord_id = g.coordinator_id or "all"
    fname    = f"inventory_{coord_id}_{date.today().isoformat()}.csv"
    return Response(
        output.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f"attachment; filename={fname}"}
    )
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 12 — TRANSFER STOCK
# POST /inventory/sku/<sku>/transfer
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/sku/<path:sku>/transfer", methods=["POST"])
@require_session
def transfer_item(sku):
    """
    Move N units of a SKU from one coordinator's stock to another.
 
    Body: { "from_coordinator_id": N, "to_coordinator_id": N, "quantity": N }
    SP: sp_inv_transfer(sku, from_coordinator, to_coordinator, quantity)
    """
    sku  = sku.strip().upper()
    body = request.get_json(force=True, silent=True)
    if not body:
        return error("Request body missing.")
 
    from_coord = body.get("from_coordinator_id")
    to_coord   = body.get("to_coordinator_id")
    quantity   = body.get("quantity")
 
    if not from_coord: return error("from_coordinator_id is required.")
    if not to_coord:   return error("to_coordinator_id is required.")
    e = _v_qty(quantity, "Quantity")
    if e: return error(e)
    
    # g.coordinator_id is used as performed_by (who initiated the transfer).
    # For the inventory API which reads coordinator_id from the request body,
    # we use from_coord as the performed_by since that is the acting coordinator.
    performed_by = int(from_coord)
    
    try:
        row = run_query(
            "SELECT * FROM sp_inv_transfer(%s, %s, %s, %s, %s)",
            (sku, int(from_coord), int(to_coord), int(quantity), performed_by),
            fetch="one"
        )
        if not row or not row.get("transferred"):
            return error(
                "Transfer failed — check SKU, coordinator IDs, and available stock.", 422
            )
        return success({"message": f"Transferred {quantity} unit(s) of {sku} successfully."})
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# ROUTE 13 — AUDIT LOG
# GET /inventory/sku/<sku>/audit?coordinator_id=N
# ═══════════════════════════════════════════════════════════════════════════
 
@inventory_bp.route("/inventory/sku/<path:sku>/audit", methods=["GET"])
@require_session
def get_audit_log(sku):
    """
    Returns the full stock-change history for a SKU.
    Pass coordinator_id to scope to one coordinator; omit for all coordinators.
 
    Query params: coordinator_id (optional)
    Reads from: inventory_stock_audit table
    """
    sku = sku.strip().upper()
    try:
        rows = run_query(
            """
            SELECT
                a.audit_id,
                a.action_type,
                a.qty_changed,
                a.old_qty,
                a.new_qty,
                a.remarks,
                a.performed_at,
                u.first_name || ' ' || u.last_name AS performed_by_name
            FROM inventory_stock_audit a
            LEFT JOIN users u ON u.id = a.performed_by
            WHERE a.sku = %s
              AND (%s IS NULL OR a.coordinator_id = %s)
            ORDER BY a.performed_at DESC
            LIMIT 100
            """,
            (sku, scope(), scope())
        )
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)
 
 
# ═══════════════════════════════════════════════════════════════════════════
# PRIVATE HELPERS
# ═══════════════════════════════════════════════════════════════════════════
 
def _row_to_item(r):
    """
    Convert a DB row to the field names the HTML frontend JS uses.
    Ensures the API always speaks the frontend's language.
    """
    return {
        "sku":           r.get("sku"),
        "coordinator_id": r.get("coordinator_id"),
        "category":      r.get("category"),
        "description":   r.get("product_name"),       # HTML: productName / description
        "lensType":      r.get("lens_type"),           # HTML: lensType
        "lensGender":    r.get("lens_gender"),
        "od_sph":        _fmt_rx(r.get("sph_right")),
        "od_cyl":        _fmt_rx(r.get("cyl_right")),
        "od_axis":       str(r.get("axis_right")) if r.get("axis_right") is not None else "",
        "os_sph":        _fmt_rx(r.get("sph_left")),
        "os_cyl":        _fmt_rx(r.get("cyl_left")),
        "os_axis":       str(r.get("axis_left"))  if r.get("axis_left")  is not None else "",
        "frameSize":     r.get("frame_size"),          # HTML: frameSize
        "lensColor":     r.get("lens_color"),
        "lensMaterial":  r.get("lens_material"),
        "frameColor":    r.get("frame_color"),
        "frameMaterial": r.get("frame_material"),
        "vendor":        r.get("vendor"),
        "notes":         r.get("notes"),
        "quantity":      r.get("available_qty"),       # HTML: quantity
    }
 
 
def _fmt_rx(val):
    """Format a NUMERIC prescription value e.g. '-1.50', or '' if None."""
    if val is None:
        return ""
    return f"{float(val):.2f}"
 
 
def _to_numeric(val):
    """Convert a string prescription value to float, or None if empty."""
    if val is None or str(val).strip() == "":
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
 
 
def _to_smallint(val):
    """Convert an axis string to int, or None if empty."""
    if val is None or str(val).strip() == "":
        return None
    try:
        return int(val)
    except (TypeError, ValueError):
        return None
 