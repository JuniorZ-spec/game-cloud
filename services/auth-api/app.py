import hashlib
import os
import time

import jwt
import psycopg2
from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

JWT_SECRET = os.getenv("JWT_SECRET", "gamecloud-secret")


def get_db():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "postgres-service"),
        database=os.getenv("DB_NAME", "gamecloud"),
        user=os.getenv("DB_USER", "gameuser"),
        password=os.getenv("DB_PASSWORD"),
    )


def init_db():
    try:
        connection = get_db()
        cursor = connection.cursor()
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                username VARCHAR(50) UNIQUE NOT NULL,
                password_hash VARCHAR(64) NOT NULL,
                created_at TIMESTAMP DEFAULT NOW()
            )
            """
        )
        connection.commit()
        cursor.close()
        connection.close()
    except Exception as error:
        print(f"auth-api init_db warning: {error}")


def make_token(user_id, username):
    payload = {
        "user_id": user_id,
        "username": username,
        "exp": time.time() + 86400,
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


def current_user(req):
    header = req.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None

    try:
        return jwt.decode(header[7:], JWT_SECRET, algorithms=["HS256"])
    except Exception:
        return None


@app.route("/healthz")
def health():
    return jsonify({"status": "ok", "service": "auth-api"})


@app.route("/register", methods=["POST"])
def register():
    data = request.get_json() or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""

    if not username or not password:
        return jsonify({"error": "username and password are required"}), 400

    connection = None
    try:
        connection = get_db()
        cursor = connection.cursor()
        cursor.execute(
            "INSERT INTO users(username, password_hash) VALUES(%s, %s) RETURNING id",
            (username, hashlib.sha256(password.encode()).hexdigest()),
        )
        user_id = cursor.fetchone()[0]
        connection.commit()
        cursor.close()
        return jsonify({
            "token": make_token(user_id, username),
            "user": {"id": user_id, "username": username},
        }), 201
    except psycopg2.IntegrityError:
        if connection:
            connection.rollback()
        return jsonify({"error": "username already exists"}), 409
    except Exception as error:
        if connection:
            connection.rollback()
        return jsonify({"error": str(error)}), 500
    finally:
        if connection:
            connection.close()


@app.route("/login", methods=["POST"])
def login():
    data = request.get_json() or {}
    username = data.get("username") or ""
    password = data.get("password") or ""

    try:
        connection = get_db()
        cursor = connection.cursor()
        cursor.execute(
            "SELECT id, username FROM users WHERE username=%s AND password_hash=%s",
            (username, hashlib.sha256(password.encode()).hexdigest()),
        )
        row = cursor.fetchone()
        cursor.close()
        connection.close()

        if not row:
            return jsonify({"error": "invalid credentials"}), 401

        return jsonify({
            "token": make_token(row[0], row[1]),
            "user": {"id": row[0], "username": row[1]},
        })
    except Exception as error:
        return jsonify({"error": str(error)}), 500


@app.route("/me")
def me():
    user = current_user(request)
    if not user:
        return jsonify({"error": "unauthorized"}), 401

    return jsonify({"user": {"id": user["user_id"], "username": user["username"]}})


init_db()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
