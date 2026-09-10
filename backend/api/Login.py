import psycopg2
import bcrypt

from flask import Blueprint, request, jsonify
from database_connection.db import get_db_connection

login_bp = Blueprint('login_bp', __name__)

@login_bp.route('/login', methods=['POST'])
def login():
    conn = None
    try:
        # Get request JSON data
        data = request.get_json()
        email = data.get("email")
        password = data.get("password")

        # Validation
        if not email or not password:
            return jsonify({
                "status": "error",
                "message": "Email and password are required"
            }), 400

        # Database connection
        conn = get_db_connection()
        cursor = conn.cursor()

        # Fetch user (Added usr.is_active)
        cursor.execute(
            """
            SELECT 
                usr.id,
                usr.first_name,
                usr.last_name,
                usr.email,
                rl.role_name,
                usr.coordinator_id,
                usr.is_active,
                usr.password_hash
            FROM users usr
            Inner join roles rl on rl.id = usr.role_id 
            WHERE email = %s
              AND is_deleted = FALSE
            """,
            (email,)
        )

        row = cursor.fetchone()

        # User not found
        if row is None:
            return jsonify({
                "status": "error",
                "message": "Invalid email or password"
            }), 401

        # Restrict inactive users
        if not row["is_active"]:
            return jsonify({
                "status": "error",
                "message": "This account has been deactivated. Please contact your administrator."
            }), 403

        stored_hash = row["password_hash"]

        # Password validation
        password_matches = bcrypt.checkpw(
            password.encode("utf-8"),
            stored_hash.encode("utf-8")
        )

        # Login success
        if password_matches:
            return jsonify({
                "status": "success",
                "message": "Login successful",
                "data": {
                    "id": row["id"],
                    "first_name": row["first_name"],
                    "last_name": row["last_name"],
                    "email": row["email"],
                    "role_name": row["role_name"],
                    "coordinator_id": row["coordinator_id"]
                }
            }), 200

        # Wrong password
        return jsonify({
            "status": "error",
            "message": "Invalid email or password"
        }), 401

    except Exception as e:
        return jsonify({
            "status": "error",
            "message": f"Server error: {str(e)}"
        }), 500

    finally:
        if conn:
            conn.close()