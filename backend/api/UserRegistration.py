import psycopg2
import psycopg2.extras
from flask import Blueprint, request, jsonify
import requests
from database_connection.db import get_db_connection

user_bp = Blueprint('user_bp', __name__)

import requests

@user_bp.route('/zip-search', methods=['GET'])
def zip_search():
    q = request.args.get('q', '')
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        cur.execute("""
            SELECT z.zip_code,
                   c.id as city_id, c.name as city_name,
                   s.id as state_id, s.name as state_name,
                   co.id as country_id, co.name as country_name
            FROM zip_code_mappings z
            JOIN cities c ON z.city_id = c.id
            JOIN states s ON z.state_id = s.id
            JOIN countries co ON z.country_id = co.id
            WHERE z.zip_code LIKE %s
            ORDER BY z.zip_code ASC
            LIMIT 15
        """, (f"{q}%",)) # <-- ADDED THE COMMA HERE
        results = cur.fetchall()
        return jsonify({"data": [dict(row) for row in results]}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()
    

@user_bp.route('/users', methods=['POST'])
def create_user():
    data = request.get_json()
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        def clean_int(val):
            try: return int(val)
            except: return None

        cur.execute("""
            SELECT * FROM create_user(
                %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
            )
        """, (
            data.get('first_name'),
            data.get('last_name'),
            data.get('dob'),
            data.get('phone'),
            data.get('email'),
            data.get('gender'),
            data.get('address'),
            clean_int(data.get('city_id')),
            data.get('zip_code'),
            clean_int(data.get('role_id')),
            data.get('password'),
            data.get('npi') if data.get('role_id') == 4 else None,
            clean_int(data.get('coordinator_id')),
            data.get('is_active', True) # Added IsActive
        ))
        conn.commit()
        result = cur.fetchone()
        return jsonify(dict(result)), 201
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()


@user_bp.route('/users', methods=['GET'])
def get_users():
    first_name = request.args.get('first_name')
    last_name  = request.args.get('last_name')
    city_id    = request.args.get('city_id')
    role_id    = request.args.get('role_id')
    is_active  = request.args.get('is_active')

    # Convert is_active to boolean if provided
    if is_active is not None and is_active != '':
        is_active = is_active.lower() == 'true'
    else:
        is_active = None

    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        cur.execute("""
            SELECT * FROM get_users(%s, %s, %s, %s, %s)
        """, (first_name, last_name, city_id, role_id, is_active))
        results = cur.fetchall()
        return jsonify([dict(row) for row in results]), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()


@user_bp.route('/users/<int:user_id>', methods=['PUT'])
def update_user(user_id):
    data = request.get_json()
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        def clean_int(val):
            try: return int(val)
            except: return None

        cur.execute("""
            SELECT update_user(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            user_id,
            data.get('first_name'),
            data.get('last_name'),
            data.get('dob'),
            data.get('phone'),
            data.get('email'),
            data.get('gender'),
            data.get('address'),
            clean_int(data.get('city_id')), 
            data.get('zip_code'),
            clean_int(data.get('role_id')), 
            data.get('password'),
            data.get('npi'),
            clean_int(data.get('coordinator_id')), 
            data.get('is_active', True) # Added IsActive
        ))
        conn.commit()
        return jsonify({"message": "User updated successfully"}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()


@user_bp.route('/users/<int:user_id>', methods=['DELETE'])
def delete_user(user_id):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT delete_user(%s)", (user_id,))
        conn.commit()
        return jsonify({"message": "User deleted successfully"}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()