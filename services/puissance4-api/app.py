import json
import os
import uuid

from flask import Flask, jsonify, request
from flask_cors import CORS
from redis import Redis

app = Flask(__name__)
CORS(app)

ROWS = 6
COLUMNS = 7
redis_client = Redis(host=os.getenv("REDIS_HOST", "redis-service"), port=6379, decode_responses=True)


def game_key(game_id):
    return f"p4:{game_id}"


def empty_board():
    return [[0 for _ in range(COLUMNS)] for _ in range(ROWS)]


def winner(board, player):
    directions = [(1, 0), (0, 1), (1, 1), (1, -1)]
    for row in range(ROWS):
        for column in range(COLUMNS):
            if board[row][column] != player:
                continue
            for delta_row, delta_column in directions:
                cells = []
                for step in range(4):
                    next_row = row + delta_row * step
                    next_column = column + delta_column * step
                    if not (0 <= next_row < ROWS and 0 <= next_column < COLUMNS):
                        break
                    cells.append(board[next_row][next_column])
                if len(cells) == 4 and all(cell == player for cell in cells):
                    return True
    return False


@app.route("/healthz")
def health():
    return jsonify({"status": "ok", "service": "puissance4-api"})


@app.route("/game/start", methods=["POST"])
def start_game():
    state = {
        "id": str(uuid.uuid4()),
        "board": empty_board(),
        "current_player": 1,
        "winner": None,
    }
    redis_client.set(game_key(state["id"]), json.dumps(state), ex=3600)
    return jsonify(state), 201


@app.route("/game/<game_id>", methods=["GET"])
def get_game(game_id):
    payload = redis_client.get(game_key(game_id))
    if not payload:
        return jsonify({"error": "game not found"}), 404
    return jsonify(json.loads(payload))


@app.route("/game/<game_id>/move", methods=["POST"])
def play_move(game_id):
    payload = redis_client.get(game_key(game_id))
    if not payload:
        return jsonify({"error": "game not found"}), 404

    state = json.loads(payload)
    if state["winner"] is not None:
        return jsonify({"error": "game already finished", "state": state}), 409

    column = int((request.get_json() or {}).get("column", -1))
    if column < 0 or column >= COLUMNS:
        return jsonify({"error": "invalid column"}), 400

    played = False
    for row in range(ROWS - 1, -1, -1):
        if state["board"][row][column] == 0:
            state["board"][row][column] = state["current_player"]
            played = True
            break

    if not played:
        return jsonify({"error": "column is full"}), 409

    if winner(state["board"], state["current_player"]):
        state["winner"] = state["current_player"]
    else:
        state["current_player"] = 2 if state["current_player"] == 1 else 1

    redis_client.set(game_key(game_id), json.dumps(state), ex=3600)
    return jsonify(state)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5003)
