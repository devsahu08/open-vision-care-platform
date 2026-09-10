import psycopg2
import psycopg2.extras
from flask import Blueprint, request, jsonify
from database_connection.db import get_db_connection

patient_bp = Blueprint('patient_bp', __name__)


# ---------------------------------------------------------------------------
# Small helper utilities
# ---------------------------------------------------------------------------

def success(data=None, status=200):
    """Wrap a successful response."""
    return jsonify({"ok": True, "data": data}), status


def error(message, status=400):
    """Wrap an error response."""
    return jsonify({"ok": False, "error": message}), status


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
        raise e
    finally:
        if conn:
            conn.close()


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@patient_bp.route("/health", methods=["GET"])
def health():
    """Quick ping to confirm the API and DB are alive."""
    try:
        run_query("SELECT 1", fetch="one")
        return success({"status": "all good"})
    except Exception as e:
        return error(f"database unreachable: {str(e)}", 503)


# ---------------------------------------------------------------------------
# PATIENTS
# ---------------------------------------------------------------------------

@patient_bp.route("/patients", methods=["GET"])
def list_patients():
    """
    List patients with optional filters.
    """
    first_name = request.args.get("first_name") or None
    last_name  = request.args.get("last_name")  or None
    camp_id    = request.args.get("camp_id",    type=int)
    limit      = request.args.get("limit",  50, type=int)
    offset     = request.args.get("offset",  0, type=int)

    # Clamp limit so nobody accidentally asks for 10,000 rows
    limit = min(limit, 200)

    try:
        rows = run_query(
            "SELECT * FROM sp_get_patients(%s, %s, %s, %s, %s)",
            (first_name, last_name, camp_id, limit, offset)
        )

        # total_count comes back on every row — grab it from the first one
        total = rows[0]["total_count"] if rows else 0

        return success({
            "patients": [dict(r) for r in rows],
            "pagination": {
                "total":  total,
                "limit":  limit,
                "offset": offset,
            }
        })

    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/patients/<uuid:patient_id>", methods=["GET"])
def get_patient(patient_id):
    """
    Get a single patient's full record.
    """
    try:
        row = run_query(
            "SELECT * FROM sp_get_patient_by_id(%s)",
            (str(patient_id),),
            fetch="one"
        )

        if not row:
            return error("patient not found", 404)

        return success(dict(row))

    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/patients", methods=["POST"])
def create_patient():
    """
    Register a new patient.
    """
    # 1. READ THE INCOMING JSON
    body = request.get_json()
    if not body:
        return error("request body is missing or not valid JSON")

    # Validate the fields we actually care about
    #required = ["first_name", "last_name", "dob"]
    #missing  = [f for f in required if not body.get(f)]
    #if missing:
    #    return error(f"missing required fields: {', '.join(missing)}")

    try:
        # 2. EXPLICITLY CAST ALL TYPES SO POSTGRES DOESN'T COMPLAIN
        row = run_query(
            """
            SELECT sp_create_patient(
                %s::varchar, %s::varchar, %s::varchar, %s::date,
                %s::varchar, %s::text,    %s::varchar,
                %s::int,     %s::int,     %s::int,     %s::int,
                %s::varchar, %s::smallint,%s::smallint,%s::smallint,%s::smallint
            ) AS new_id
            """,
            (
                body.get("first_name"),
                body.get("last_name"),
                body.get("gender"),
                body.get("dob"),
                body.get("phone_number"),
                body.get("photo_base64"), 
                body.get("address_line"),
                body.get("city_id"),
                body.get("state_id"),
                body.get("country_id"),
                body.get("camp_id"),
                body.get("zip_code"),
                int(body.get("IsBlurredVision",     0)),
                int(body.get("IsVisionDifficulty",  0)),
                int(body.get("IsDoubleVision",      0)),
                int(body.get("IsWearingCorrection", 0)),
            ),
            fetch="one"
        )

        return success({"id": str(row["new_id"])}, status=201)

    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/patients/<uuid:patient_id>", methods=["PUT"])
def update_patient(patient_id):
    """
    Update an existing patient's record.
    """
    body = request.get_json()
    if not body:
        return error("request body is missing or not valid JSON")

    #required = ["first_name", "last_name", "dob"]
    #missing  = [f for f in required if not body.get(f)]
    #if missing:
    #    return error(f"missing required fields: {', '.join(missing)}")

    try:
        # SAME FIX HERE: EXPLICIT TYPE CASTING
        row = run_query(
            """
            SELECT sp_update_patient(
                %s::uuid,
                %s::varchar, %s::varchar, %s::varchar, %s::date,
                %s::varchar, %s::text,    %s::varchar,
                %s::int,     %s::int,     %s::int,     %s::int,
                %s::varchar, %s::smallint,%s::smallint,%s::smallint,%s::smallint
            ) AS updated
            """,
            (
                str(patient_id),
                body.get("first_name"),
                body.get("last_name"),
                body.get("gender"),
                body.get("dob"),
                body.get("phone_number"),
                body.get("photo_base64"), 
                body.get("address_line"),
                body.get("city_id"),
                body.get("state_id"),
                body.get("country_id"),
                body.get("camp_id"),
                body.get("zip_code"),
                int(body.get("IsBlurredVision",     0)),
                int(body.get("IsVisionDifficulty",  0)),
                int(body.get("IsDoubleVision",      0)),
                int(body.get("IsWearingCorrection", 0)),
            ),
            fetch="one"
        )

        if not row["updated"]:
            return error("patient not found or already deleted", 404)

        return success({"id": str(patient_id)})

    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/patients/<uuid:patient_id>", methods=["DELETE"])
def delete_patient(patient_id):
    """
    Soft-delete a patient.
    """
    try:
        row = run_query(
            "SELECT sp_delete_patient(%s) AS deleted",
            (str(patient_id),),
            fetch="one"
        )

        if not row["deleted"]:
            return error("patient not found or already deleted", 404)

        return success({"message": "patient deleted successfully"})

    except Exception as e:
        return error(str(e), 500)


# ---------------------------------------------------------------------------
# ZIP CODE AUTOFILL
# ---------------------------------------------------------------------------

@patient_bp.route("/zip-lookup/<zip_code>", methods=["GET"])
def zip_lookup(zip_code):
    """
    Given a ZIP / postal code, return the matching city, state, and country.
    """
    try:
        row = run_query(
            "SELECT * FROM sp_lookup_zip(%s)",
            (zip_code,),
            fetch="one"
        )

        if not row:
            return error(f"no match found for zip code '{zip_code}'", 404)

        return success(dict(row))

    except Exception as e:
        return error(str(e), 500)


# ---------------------------------------------------------------------------
# LOOKUP / DROPDOWN HELPERS
# ---------------------------------------------------------------------------

@patient_bp.route("/lookups/camps", methods=["GET"])
def get_camps():
    """Active camps for the Camp dropdown."""
    try:
        rows = run_query("SELECT * FROM sp_get_camps()")
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/lookups/countries", methods=["GET"])
def get_countries():
    """All countries for the Country dropdown."""
    try:
        rows = run_query("SELECT * FROM sp_get_countries()")
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/lookups/states/<int:country_id>", methods=["GET"])
def get_states(country_id):
    """States / provinces for a given country."""
    try:
        rows = run_query(
            "SELECT * FROM sp_get_states_by_country(%s)",
            (country_id,)
        )
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/lookups/cities/<int:state_id>", methods=["GET"])
def get_cities(state_id):
    """Cities for a given state."""
    try:
        rows = run_query(
            "SELECT * FROM sp_get_cities_by_state(%s)",
            (state_id,)
        )
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)


@patient_bp.route("/lookups/medical-conditions", methods=["GET"])
def get_medical_conditions():
    """Reference list of medical conditions."""
    try:
        rows = run_query("SELECT * FROM sp_get_medical_conditions()")
        return success([dict(r) for r in rows])
    except Exception as e:
        return error(str(e), 500)