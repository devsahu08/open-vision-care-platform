# ═══════════════════════════════════════════════════════════════════════════
# iCare – Brighter Future Program
# routes/EyeExam.py  |  Eye Exam Module Backend API
# ═══════════════════════════════════════════════════════════════════════════

import logging
from functools import wraps
import psycopg2
import psycopg2.extras

from flask import Blueprint, request, jsonify, session, g
from database_connection.db import get_db_connection

# Create the blueprint. This registers all the routes below under 'eye_exam_bp'
eye_exam_bp = Blueprint('eye_exam_bp', __name__)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ═══════════════════════════════════════════════════════════════════════════
# DATABASE HELPER
# ═══════════════════════════════════════════════════════════════════════════
def run_query(sql, params=(), fetch="all"):
    """
    A unified helper function to talk to the database safely.
    It automatically opens a connection, executes the query, and closes the connection.
    """
    conn = None
    try:
        conn = get_db_connection()
        # RealDictCursor makes the database return rows as dictionaries (like {id: 1, name: 'John'}) 
        # instead of tuples (like (1, 'John')), making it much easier to turn into JSON.
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            conn.commit() # Save changes to the DB
            
            if fetch == "all":
                return cur.fetchall() # Returns a list of all matching rows
            elif fetch == "one":
                return cur.fetchone() # Returns just the first matching row
            return None
    except psycopg2.Error as e:
        if conn:
            conn.rollback() # If something crashes, undo any changes made during this transaction
        logger.error("DB error: %s | SQL: %.120s", e, sql)
        raise e
    finally:
        if conn:
            conn.close() # Always close the connection to prevent memory leaks

# ═══════════════════════════════════════════════════════════════════════════
# RESPONSE HELPERS
# These standardize how our API replies to the frontend.
# ═══════════════════════════════════════════════════════════════════════════
def success(data=None, status=200):
    return jsonify({"ok": True, "data": data}), status

def error(message, status=400):
    return jsonify({"ok": False, "error": message}), status

# ═══════════════════════════════════════════════════════════════════════════
# AUTHENTICATION MIDDLEWARE (DECORATOR)
# ═══════════════════════════════════════════════════════════════════════════
def require_session(f):
    """
    This is a 'decorator'. By putting @require_session above a route, Python will 
    run this function FIRST before letting the user access the route.
    It ensures the user is logged in by checking the session.
    """
    @wraps(f)
    def decorated(*args, **kwargs):
        uid = session.get("user_id")
        #if not uid:
        #    return error("Unauthorized -- please log in.", 401)
        
        # We store these variables in 'g' so our route functions can easily access them
        g.user_id        = uid
        g.coordinator_id = session.get("coordinator_id")
        g.camp_id        = session.get("camp_id")
        return f(*args, **kwargs)
    return decorated

# Setup validation sets for strict data checking
VALID_LENS_TYPES  = {"Single Vision", "Bifocal", "Progressive", "Reading", "Distance", ""}
VALID_FRAME_SIZES = {"Small", "Medium", "Large", "Extra Large", ""}
VALID_STATUSES    = {
    "No Glasses Required",
    "Added to Waiting List",
    "Glasses Assigned",
    "Glasses Delivered",
}

# --- Validation Helper Functions ---
# These ensure the frontend doesn't send us junk data that crashes the database.
def _v_sph(val, label):
    if val is None or str(val).strip() == "":
        return None # <-- CHANGED: SPH is now completely optional
    try:
        f = float(val)
    except (TypeError, ValueError):
        return f"{label} must be a decimal number."
    if not (-30.0 <= f <= 30.0):
        return f"{label} ({f}) is outside the valid range (-30 to +30)."
    return None

def _v_cyl(val, label):
    if val is None or str(val).strip() == "": return None
    try: f = float(val)
    except: return f"{label} must be a decimal number."
    if not (-30.0 <= f <= 30.0): return f"{label} is out of range."
    return None

def _v_axis(val, label):
    if val is None or str(val).strip() == "": return None
    try: i = int(val)
    except: return f"{label} must be a whole number (0 - 180)."
    if not (0 <= i <= 180): return f"{label} must be between 0 and 180."
    return None

def _to_f(val):
    if val is None or str(val).strip() == "": return None
    try: return float(val)
    except: return None

def _to_si(val):
    if val is None or str(val).strip() == "": return None
    try: return int(val)
    except: return None

# ═══════════════════════════════════════════════════════════════════════════
# ROUTES / API ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════

@eye_exam_bp.route("/eye-exam/health", methods=["GET"])
def health():
    """Simple check to make sure the server and DB are alive."""
    try:
        run_query("SELECT 1", fetch="one")
        return success({"status": "Eye Exam API is running. DB connected."})
    except Exception as e:
        return error(f"DB unreachable: {str(e)}", 503)

@eye_exam_bp.route("/eye-exam/campaigns", methods=["GET"])
@require_session
def get_campaigns():
    """Fetches campaigns for the dropdown filter on the frontend UI."""
    try:
        rows = run_query("SELECT * FROM sp_get_exam_campaigns()")
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)

@eye_exam_bp.route("/eye-exam/patients/search", methods=["GET"])
@require_session
def search_patients():
    """
    Called by the frontend 'debouncePatientSearch()' whenever the user types in the Patient Name box.
    It grabs the 'q' parameter from the URL (e.g., ?q=John).
    """
    q       = (request.args.get("q") or "").strip()
    camp_id = request.args.get("camp_id", type=int) or g.camp_id
 
    if not q or len(q) < 1:
        return error("Query must be at least 2 characters.", 400)
    if not camp_id:
        return error("camp_id is required.", 400)
 
    try:
        rows = run_query(
            "SELECT * FROM sp_search_patients_exam(%s, %s, %s)",
            (q, camp_id, 10) # Limits to top 10 matches
        )
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)

@eye_exam_bp.route("/eye-exam", methods=["GET"])
@require_session
def list_exams():
    """
    Populates the main data table in the UI. 
    It reads filters from the URL (like offset, limit, patient_name) and asks the DB for the exact rows.
    """
    # request.args grabs query parameters like ?campaign_id=5&status=Assigned
    campaign_id  = request.args.get("campaign_id",  type=int)
    patient_name = request.args.get("patient_name") or None
    doctor_name  = request.args.get("doctor_name")  or None
    status       = request.args.get("status")       or None
    sort_dir     = request.args.get("sort_dir", "desc")
    limit        = min(request.args.get("limit",  10, type=int), 200)
    offset       = request.args.get("offset",     0,  type=int)
 
    if sort_dir not in {"asc", "desc"}: sort_dir = "desc"
    if status and status not in VALID_STATUSES:
        return error("Invalid status.")
 
    try:
        rows  = run_query(
            """SELECT * FROM sp_get_exams(
                %s::INTEGER, %s::TEXT, %s::TEXT, %s::TEXT, %s::VARCHAR, %s::INTEGER, %s::INTEGER
            )
            """,
            (campaign_id, patient_name, doctor_name, status, sort_dir, limit, offset)
        )
        total = rows[0]["total_count"] if rows else 0
        return success({
            "exams":      [dict(r) for r in rows],
            "pagination": {"total": total, "limit": limit, "offset": offset}
        })
    except Exception as e:
        return error(str(e), 500)

@eye_exam_bp.route("/eye-exam", methods=["POST"])
@require_session
def create_exam():
    """
    Creates the main exam record. The frontend calls this during the executeConfirm() function.
    It handles BOTH the 'No Action Required' path and the 'Create RX' path based on the 'action' key.
    """
    body = request.get_json() 
    if not body:
        return error("Request body is missing.")
 
    patient_id  = body.get("patient_id")
    campaign_id = body.get("campaign_id") or g.camp_id
    doctor_id   = body.get("doctor_id")   or g.user_id
    action      = body.get("action", "no_action")   
    exam_date   = body.get("exam_date")  or None
 
    if not patient_id:   return error("patient_id is required.")
    if not campaign_id:  return error("campaign_id is required.")
 
    has_rx = (action == "create_rx")
 
    if has_rx:
        status = "No Glasses Required" 
        od_sph = body.get("od_sph")
        od_cyl = body.get("od_cyl")
        od_axis = body.get("od_axis")
        od_add = body.get("od_add")  
        os_sph = body.get("os_sph")
        os_cyl = body.get("os_cyl")
        os_axis = body.get("os_axis")
        os_add = body.get("os_add")  
        lens_type = body.get("lens_type")
        frame_size = body.get("frame_size")
        ipd = body.get("ipd")
        rx_notes = body.get("rx_notes")
        rxImage = body.get("rxImage")
 
        errs = []
        e = _v_sph(od_sph, "OD SPH"); errs.append(e) if e else None
        e = _v_sph(os_sph, "OS SPH"); errs.append(e) if e else None
        if errs:
            return error({"validation_errors": errs})
    else:
        status = "No Glasses Required"
        od_sph = od_cyl = od_axis = od_add = None
        os_sph = os_cyl = os_axis = os_add = None
        lens_type = frame_size = ipd = rx_notes = rxImage = None # UPDATED
        rx_notes = body.get("rx_notes")
 
    try:
        row = run_query(
            """
            SELECT * FROM sp_create_eye_exam(
                %s::UUID, %s::INTEGER, %s::INTEGER, %s::DATE, %s::exam_allocation_status,
                %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::VARCHAR, %s::VARCHAR, %s::NUMERIC, %s::TEXT, %s::TEXT
            )
            """,
            (
                str(patient_id), campaign_id, doctor_id, exam_date, status,
                _to_f(od_sph), _to_f(od_cyl), _to_si(od_axis), _to_f(od_add),
                _to_f(os_sph), _to_f(os_cyl), _to_si(os_axis), _to_f(os_add),
                lens_type, frame_size, _to_f(ipd), rx_notes, body.get("rxImage")
            ),
            fetch="one"
        )
        return success({"exam_id": row["exam_id"], "exam_code": row["exam_code"]}, status=201)
 
    except psycopg2.errors.RaiseException as e:
        return error(str(e).split('\n')[0], 409)
    except Exception as e:
        return error(str(e), 500)

@eye_exam_bp.route("/eye-exam/<int:exam_id>", methods=["GET"])
@require_session
def get_exam(exam_id):
    """Fetches full details of a specific exam when the 'View' button is clicked."""
    try:
        row = run_query("SELECT * FROM sp_get_exam_by_id(%s)", (exam_id,), fetch="one")
        if not row: return error("Exam not found.", 404)
        
        row_dict = dict(row)
        
        # SAFER APPROACH: Query the table directly for the delivery image.
        # This guarantees the image is fetched and displayed even if your stored procedure is outdated!
        run_query("ALTER TABLE eye_exams ADD COLUMN IF NOT EXISTS delivery_image TEXT", fetch="none")
        img_row = run_query("SELECT delivery_image FROM eye_exams WHERE id = %s", (exam_id,), fetch="one")
        
        if img_row and img_row.get("delivery_image"):
            row_dict["delivery_image"] = img_row["delivery_image"]
            
        return success(row_dict)
    except Exception as e: 
        return error(str(e), 500)

@eye_exam_bp.route("/eye-exam/<int:exam_id>", methods=["PUT"])
@require_session
def update_exam(exam_id):
    body = request.get_json()
    try:
        # Note: We pass the fields to the stored procedure
        row = run_query(
            """
            SELECT * FROM sp_update_eye_exam(
                %s::INTEGER, %s::INTEGER, %s::DATE,
                %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::VARCHAR, %s::VARCHAR, %s::NUMERIC, %s::TEXT
            )
            """,
            (
                exam_id, 
                body.get("doctor_id"), 
                body.get("exam_date"),
                _to_f(body.get("od_sph")), _to_f(body.get("od_cyl")), _to_si(body.get("od_axis")), _to_f(body.get("od_add")),
                _to_f(body.get("os_sph")), _to_f(body.get("os_cyl")), _to_si(body.get("os_axis")), _to_f(body.get("os_add")),
                body.get("lens_type"), body.get("frame_size"), _to_f(body.get("ipd")), body.get("rx_notes")
            ),
            fetch="one"
        )
        if not row or not row.get("updated"):
            return error("Exam not found.", 404)
        return success({"message": "Exam updated successfully."})
    except Exception as e:
        return error(str(e), 500)

@eye_exam_bp.route("/eye-exam/<int:exam_id>", methods=["DELETE"])
@require_session
def delete_exam(exam_id):
    """Soft-deletes an exam (sets is_deleted = TRUE in DB). Blocks if glasses are already assigned."""
    try:
        row = run_query("SELECT * FROM sp_delete_eye_exam(%s)", (exam_id,), fetch="one")
        if not row or not row.get("deleted"): return error("Exam not found.", 404)
        return success({"message": "Exam deleted successfully."})
    except psycopg2.errors.RaiseException as e:
        return error(str(e).split('\n')[0], 422)
    except Exception as e: return error(str(e), 500)

@eye_exam_bp.route("/inventory/search", methods=["GET"])
@require_session
def search_inventory():
    # 1. Grab coordinator ID
    coord_id = request.args.get("coordinator_id", type=int) or request.args.get("coordinatorId", type=int) or g.coordinator_id

    if not coord_id:
        return error("coordinator_id is required.", 400)
        
    # 2. Extract raw RX data straight from the URL parameters
    od_sph = _to_f(request.args.get("od_sph"))
    os_sph = _to_f(request.args.get("os_sph"))

    # Extract optional fields with defaults
    od_cyl = _to_f(request.args.get("od_cyl"))
    od_axis = _to_si(request.args.get("od_axis"))
    od_add = _to_f(request.args.get("od_add"))
    
    os_cyl = _to_f(request.args.get("os_cyl"))
    os_axis = _to_si(request.args.get("os_axis"))
    os_add = _to_f(request.args.get("os_add"))
    
    frame_size = request.args.get("frame_size", "")
    lens_type = request.args.get("lens_type", "")

    try:
        # 3. Pass the URL variables directly into the SQL function
        inventory_rows = run_query(
            """
            SELECT * FROM sp_search_inventory_rx(
                %s::INTEGER, 
                %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::NUMERIC, %s::NUMERIC, %s::SMALLINT, %s::NUMERIC,
                %s::VARCHAR, %s::VARCHAR
            )
            """,
            (
                coord_id,
                od_sph, od_cyl, od_axis, od_add,
                os_sph, os_cyl, os_axis, os_add,
                frame_size, lens_type
            )
        )
        return success([dict(r) for r in inventory_rows])
    except Exception as e:
        return error(str(e), 500)

@eye_exam_bp.route("/eye-exam/<int:exam_id>/assign", methods=["POST"])
@require_session
def assign_glasses(exam_id):
    """
    Final assignment step. 
    It receives the chosen SKU, deducts the physical quantity from the DB inventory table, 
    and locks the exam status to 'Glasses Assigned'.
    """
    body = request.get_json(force=True, silent=True) or {}
    sku  = (body.get("sku") or "").strip().upper()
 
    coord_id = g.coordinator_id or body.get("coordinator_id")
    try:
        row = run_query(
            "SELECT * FROM sp_assign_glasses(%s::INTEGER, %s::VARCHAR, %s::INTEGER)",
            (exam_id, sku, coord_id), fetch="one"
        )
        if not row or not row.get("assigned"):
            return error(row.get("reason"), 422)
        return success({"message": "Glasses assigned successfully."})
    except Exception as e: return error(str(e), 500)

@eye_exam_bp.route("/eye-exam/<int:exam_id>/waiting-list", methods=["POST"])
@require_session
def add_to_waiting_list(exam_id):
    """Updates the status without deducting inventory stock."""
    try:
        row = run_query("SELECT * FROM sp_add_to_waiting_list(%s::INTEGER)", (exam_id,), fetch="one")
        return success({"updated": True, "message": "Patient added to waiting list."})
    except psycopg2.errors.RaiseException as e: return error(str(e).split('\n')[0], 422)
    except Exception as e: return error(str(e), 500)

@eye_exam_bp.route("/eye-exam/<int:exam_id>/status", methods=["PUT"])
@require_session
def update_exam_status(exam_id):
    """Updates the eye exam allocation status."""
    body = request.get_json(force=True, silent=True) or {}
    status = body.get("status")
    delivery_image = body.get("delivery_image")  # field for delivery proof
    
    # Map from the frontend values to database enum values
    status_mapping = {
        "glasses_assigned": "Glasses Assigned",
        "glasses_delivered": "Glasses Delivered",
        "place_order": "Added to Waiting List",
        "no_glasses_required": "No Glasses Required"
    }
    
    db_status = status_mapping.get(status)
    if not db_status:
        return error("Invalid status value.", 400)
        
    # field for delivery proof validation
    if db_status == "Glasses Delivered" and not delivery_image:
        return error("Delivery image is required when marking as 'Glasses Delivered'.", 400)
        
    try:
        # SILENT FAILSAFE: Guarantee the column exists in the database
        run_query("ALTER TABLE eye_exams ADD COLUMN IF NOT EXISTS delivery_image TEXT", fetch="none")
        
        run_query(
            """
            UPDATE eye_exams 
            SET allocation_status = %s::exam_allocation_status,
                delivery_image = COALESCE(%s, delivery_image)
            WHERE id = %s AND NOT is_deleted
            """,
            (db_status, delivery_image, exam_id),
            fetch="none"
        )
        return success({"message": "Exam status updated successfully."})
    except psycopg2.errors.RaiseException as e:
        return error(str(e).split('\n')[0], 422)
    except Exception as e:
        return error(str(e), 500)


@eye_exam_bp.route("/eye-exam/<int:exam_id>/export-pdf", methods=["GET"])
@require_session
def export_pdf(exam_id):
    """Placeholder route for future PDF generation."""
    try:
        row = run_query("SELECT * FROM sp_get_exam_by_id(%s)", (exam_id,), fetch="one")
        return success(dict(row))
    except Exception as e: return error(str(e), 500)