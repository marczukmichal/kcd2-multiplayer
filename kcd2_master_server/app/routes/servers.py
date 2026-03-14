from flask import Blueprint, request, jsonify
from app import db
from app.models import Server

servers_bp = Blueprint("servers", __name__)

@servers_bp.route("/servers_list", methods=["GET"])
def get_servers():
    servers = Server.query.all()
    return jsonify([s.to_dict() for s in servers])

@servers_bp.route("/get_server/<string:ip_address>", methods=["GET"])
def get_server(ip_address):
    server = Server.query.filter_by(ip_address=ip_address).first()

    if not server:
        return jsonify({
            "error": "Server not found"
            }),404
    
    return jsonify(server.detailed_dict())

@servers_bp.route("/register", methods=["POST"])
def register_servers():
    data = request.get_json()

    server = Server(
            name = data["name"],
            ip_address = data["ip_address"],
            port = data["port"],
            map_name = data["map_name"],
            description = data["description"],
            tag = data["tag"]
            )

    db.session.add(server)
    db.session.commit()

    return jsonify({
        "message": "Server registered",
        "id": server.id,
        "token": server.token
        }), 201
