from app import db
from datetime import datetime
import secrets

class Server(db.Model):
    __tablename__ = "servers"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    ip_address = db.Column(db.String(45), nullable=False)
    port = db.Column(db.Integer, nullable=False)
    map_name = db.Column(db.String(100), nullable=False)
    token = db.Column(db.String(64), unique=True, default=lambda: secrets.token_hex(32))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    description = db.Column(db.Text, nullable=True)
    tag = db.Column(db.String(200), nullable=True)
    
    def to_dict(self):
        return {
                "id": self.id,
                "name": self.name,
                "ip_address": self.ip_address,
                "port": self.port,
                "map_name": self.map_name,
                "created_at": self.created_at.isoformat(),
                }

    def detailed_dict(self):
        return {
                "id": self.id,
                "name": self.name,
                "ip_address": self.ip_address,
                "port": self.port,
                "map_name": self.map_name,
                "created_at": self.created_at.isoformat(),
                "description": self.description,
                "tag": self.tag,
                }
