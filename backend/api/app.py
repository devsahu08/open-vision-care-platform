from flask import Flask
from flask_cors import CORS

from routes.UserRegistration import user_bp
from routes.PatientRegistration import patient_bp
from routes.CampaignManagement import campaign_bp
from routes.Login import login_bp
from routes.inventory_api import inventory_bp
from routes.EyeExam import eye_exam_bp

app = Flask(__name__)
import os
app.secret_key = os.getenv("FLASK_SECRET_KEY")
# Enable CORS
#CORS(app)
CORS(app, supports_credentials=True)

# Register APIs
app.register_blueprint(user_bp)
app.register_blueprint(patient_bp)
app.register_blueprint(campaign_bp)
app.register_blueprint(login_bp)
app.register_blueprint(inventory_bp)
app.register_blueprint(eye_exam_bp)

print(app.url_map)
# app.register_blueprint(inventory_bp, url_prefix="/api")
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024  # Limit upload size to 10 MB

if __name__ == "__main__":
    app.run(debug=True)