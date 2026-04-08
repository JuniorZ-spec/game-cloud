const express = require("express");
const cors = require("cors");
const jwt = require("jsonwebtoken");
const { Pool } = require("pg");

const app = express();
app.use(cors());
app.use(express.json());

const pool = new Pool({
  host: process.env.DB_HOST || "postgres-service",
  port: 5432,
  database: process.env.DB_NAME || "gamecloud",
  user: process.env.DB_USER || "gameuser",
  password: process.env.DB_PASSWORD
});

const JWT_SECRET = process.env.JWT_SECRET || "gamecloud-secret";

const currentUser = (req) => {
  const header = (req.headers.authorization || "").replace("Bearer ", "");
  if (!header) {
    return null;
  }

  try {
    return jwt.verify(header, JWT_SECRET);
  } catch (_error) {
    return null;
  }
};

const initDb = async () => {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS scores (
      id SERIAL PRIMARY KEY,
      user_id INT,
      username VARCHAR(50),
      game VARCHAR(50),
      score INT NOT NULL,
      duration_sec INT,
      played_at TIMESTAMP DEFAULT NOW()
    )
  `);
};

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok", service: "score-api" });
});

app.post("/score", async (req, res) => {
  const user = currentUser(req);
  if (!user) {
    return res.status(401).json({ error: "unauthorized" });
  }

  const { game, score, duration_sec } = req.body || {};
  if (!game || score === undefined) {
    return res.status(400).json({ error: "game and score are required" });
  }

  const result = await pool.query(
    `
      INSERT INTO scores(user_id, username, game, score, duration_sec)
      VALUES($1, $2, $3, $4, $5)
      RETURNING id
    `,
    [user.user_id, user.username, game, score, duration_sec || null]
  );

  return res.status(201).json({ id: result.rows[0].id, message: "score saved" });
});

app.get("/leaderboard", async (_req, res) => {
  const result = await pool.query(`
    SELECT username, game, MAX(score) AS best_score, COUNT(*) AS games_played
    FROM scores
    GROUP BY username, game
    ORDER BY best_score DESC
    LIMIT 20
  `);

  res.json({ leaderboard: result.rows });
});

app.get("/leaderboard/:game", async (req, res) => {
  const result = await pool.query(
    `
      SELECT username, MAX(score) AS best_score, COUNT(*) AS games_played
      FROM scores
      WHERE game = $1
      GROUP BY username
      ORDER BY best_score DESC
      LIMIT 10
    `,
    [req.params.game]
  );

  res.json({ game: req.params.game, leaderboard: result.rows });
});

initDb()
  .then(() => {
    app.listen(3003, () => {
      console.log("score-api listening on :3003");
    });
  })
  .catch((error) => {
    console.error("score-api init error:", error);
    process.exit(1);
  });
