import os


BASE_DIR = os.path.abspath(os.path.dirname(__file__))

class Config:
    SECRET_KEY = os.getenv("SECRET_KEY")

    if not SECRET_KEY:
        raise ValueError("SECRET_KEY is not set in environment variables")

    SQLALCHEMY_DATABASE_URI = "sqlite:///"+ os.path.join(BASE_DIR, "instance","database.db")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
