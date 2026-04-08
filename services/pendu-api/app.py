import json
import os
import random
import uuid

from flask import Flask, jsonify, request
from flask_cors import CORS
from redis import Redis

app = Flask(__name__)
CORS(app)

WORDS = ["kubernetes", "ingress", "cluster", "virtualisation", "datacenter", "serverless"]
redis_client = Redis(host=os.getenv("REDIS_HOST", "redis-service"), port=6379, decode_responses=True)


def game_key(game_id):
    return f"pendu:{game_id}"


def serialize_game(state):
    masked = "".join(letter if letter in state["guesses"] else "_" for letter in state["word"])
    won = "_" not in masked
    lost = state["attempts_left"] <= 0 and not won
    return {
        "id": state["id"],
        "masked_word": masked,
        "attempts_left": state["attempts_left"],
        "guesses": state["guesses"],
        "won": won,
        "lost": lost,
    }


@app.route("/healthz")
def health():
    return jsonify({"status": "ok", "service": "pendu-api"})


@app.route("/game/start", methods=["POST"])
def start_game():
    word = random.choice(WORDS)
    state = {
        "id": str(uuid.uuid4()),
        "word": word,
        "attempts_left": 6,
        "guesses": [],
    }
    redis_client.set(game_key(state["id"]), json.dumps(state), ex=3600)
    return jsonify(serialize_game(state)), 201


@app.route("/game/<game_id>", methods=["GET"])
def get_game(game_id):
    payload = redis_client.get(game_key(game_id))
    if not payload:
        return jsonify({"error": "game not found"}), 404
    return jsonify(serialize_game(json.loads(payload)))


@app.route("/game/<game_id>/guess", methods=["POST"])
def guess_letter(game_id):
    payload = redis_client.get(game_key(game_id))
    if not payload:
        return jsonify({"error": "game not found"}), 404

    letter = ((request.get_json() or {}).get("letter") or "").lower().strip()
    if len(letter) != 1 or not letter.isalpha():
        return jsonify({"error": "a single letter is required"}), 400

    state = json.loads(payload)
    if letter not in state["guesses"]:
        state["guesses"].append(letter)
        if letter not in state["word"]:
            state["attempts_left"] -= 1

    redis_client.set(game_key(game_id), json.dumps(state), ex=3600)
    return jsonify(serialize_game(state))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5002)
