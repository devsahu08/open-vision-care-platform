import psycopg2
import psycopg2.extras
from flask import Blueprint, request, jsonify
from database_connection.db import get_db_connection

campaign_bp = Blueprint('campaign_bp', __name__)

@campaign_bp.route('/campaigns', methods=['POST'])
def create_campaign():
    data = request.get_json()
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        # Added %s for street_address
        cur.execute("""
            SELECT * FROM create_campaign(%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            data.get('camp_name'),
            data.get('city_id'),
            data.get('zip_code'),
            data.get('street_address'), # <-- NEW PARAMETER
            data.get('camp_date'),
            data.get('status', 'Scheduled'),
            data.get('coordinator_id'),
            data.get('volunteer_ids', []),
            data.get('optometrist_ids', [])
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

@campaign_bp.route('/campaigns', methods=['GET'])
def get_campaigns():
    camp_name  = request.args.get('camp_name')
    status     = request.args.get('status')
    date_from  = request.args.get('date_from')
    date_to    = request.args.get('date_to')
    city_id    = request.args.get('city_id')
    coordinator_id = request.args.get('coordinator_id') 
    
    # Capture pagination params (default to 10 and 0)
    limit  = request.args.get('limit', default=10, type=int)
    offset = request.args.get('offset', default=0, type=int)
    
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        # Pass limit and offset to the SQL function (8 parameters total)
        cur.execute("""
            SELECT * FROM get_campaigns(%s, %s, %s, %s, %s, %s, %s, %s)
        """, (camp_name, status, date_from, date_to, city_id, coordinator_id, limit, offset)) 
        
        results = cur.fetchall()
        
        # Extract total count from the first row if results exist
        total_count = results[0]['total_count'] if results else 0
        
        # Clean up the total_count field from the individual row objects 
        # so it doesn't get rendered in the table data accidentally
        data = []
        for row in results:
            row_dict = dict(row)
            row_dict.pop('total_count', None) 
            data.append(row_dict)

        # Return structured response expected by the frontend pagination
        return jsonify({
            "data": data,
            "total": total_count
        }), 200
        
    except Exception as e:
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()

@campaign_bp.route('/campaigns/<int:campaign_id>', methods=['GET'])
def get_campaign_by_id(campaign_id):
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        cur.execute("SELECT * FROM get_campaign_by_id(%s)", (campaign_id,))
        result = cur.fetchone()
        if result is None:
            return jsonify({"error": "Campaign not found"}), 404
        return jsonify(dict(result)), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close() 

@campaign_bp.route('/campaigns/<int:campaign_id>', methods=['PUT'])
def update_campaign(campaign_id):
    data = request.get_json()
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        # Added %s for street_address
        cur.execute("""
            SELECT update_campaign(%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            campaign_id,
            data.get('camp_name'),
            data.get('city_id'),
            data.get('zip_code'),
            data.get('street_address'), # <-- NEW PARAMETER
            data.get('camp_date'),
            data.get('status'),
            data.get('volunteer_ids'),
            data.get('optometrist_ids')
        ))
        conn.commit()
        return jsonify({"message": "Campaign updated successfully"}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()

@campaign_bp.route('/campaigns/<int:campaign_id>', methods=['DELETE'])
def delete_campaign(campaign_id):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT delete_campaign(%s)", (campaign_id,))
        conn.commit()
        return jsonify({"message": "Campaign deleted successfully"}), 200
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 400
    finally:
        cur.close()
        conn.close()