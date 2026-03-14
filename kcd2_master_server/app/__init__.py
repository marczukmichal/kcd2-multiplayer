from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate

db = SQLAlchemy()
migrate = Migrate()

def create_app():
    app = Flask(__name__)
    app.config.from_object('config.Config')

    db.init_app(app)
    migrate.init_app(app, db)

    from .routes.servers import servers_bp
    from .routes.admin import admin_bp
    app.register_blueprint(servers_bp, url_prefix="/servers")
    app.register_blueprint(admin_bp, url_prefix="/admin")

    with app.app_context():
        from app import models
        db.create_all()
        from app.models import seed_tags
        seed_tags()

    return app


