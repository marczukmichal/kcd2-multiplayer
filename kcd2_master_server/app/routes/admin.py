from flask import Blueprint

admin_bp = Blueprint("admin", __name__)


@admin_bp.route("/stats", methods=["GET"])
def get_stats():
    ##TODO
    return "TODO "
