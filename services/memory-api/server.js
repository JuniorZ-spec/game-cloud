const express = require("express");
const cors = require("cors");
const { createClient } = require("redis");
const crypto = require("crypto");

const app = express();
app.use(cors());
app.use(express.json());

const symbols = ["A", "B", "C", "D", "E", "F", "G", "H"];
const redis = createClient({
  url: `redis://${process.env.REDIS_HOST || "redis-service"}:6379`
});

redis.on("error", (error) => {
  console.error("memory-api redis error:", error);
});

const ensureRedis = async () => {
  if (!redis.isOpen) {
    await redis.connect();
  }
};

const shuffledDeck = () => {
  const cards = [...symbols, ...symbols].map((value, index) => ({ id: index + 1, value }));
  for (let index = cards.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(Math.random() * (index + 1));
    [cards[index], cards[swapIndex]] = [cards[swapIndex], cards[index]];
  }
  return cards;
};

app.get("/healthz", async (_req, res) => {
  res.json({ status: "ok", service: "memory-api" });
});

app.post("/session/start", async (_req, res) => {
  await ensureRedis();
  const sessionId = crypto.randomUUID();
  const session = {
    id: sessionId,
    cards: shuffledDeck(),
    opened: [],
    found: []
  };

  await redis.set(`memory:${sessionId}`, JSON.stringify(session), { EX: 3600 });
  res.status(201).json({
    id: sessionId,
    total_cards: session.cards.length,
    found: session.found
  });
});

app.get("/session/:sessionId", async (req, res) => {
  await ensureRedis();
  const payload = await redis.get(`memory:${req.params.sessionId}`);
  if (!payload) {
    return res.status(404).json({ error: "session not found" });
  }
  return res.json(JSON.parse(payload));
});

app.post("/session/:sessionId/flip", async (req, res) => {
  await ensureRedis();
  const payload = await redis.get(`memory:${req.params.sessionId}`);
  if (!payload) {
    return res.status(404).json({ error: "session not found" });
  }

  const session = JSON.parse(payload);
  const cardId = Number((req.body || {}).card_id);
  const card = session.cards.find((item) => item.id === cardId);

  if (!card) {
    return res.status(400).json({ error: "card not found" });
  }

  if (!session.opened.includes(cardId)) {
    session.opened.push(cardId);
  }

  if (session.opened.length >= 2) {
    const openedCards = session.cards.filter((item) => session.opened.includes(item.id));
    const [first, second] = openedCards.slice(-2);
    if (first && second && first.value === second.value) {
      session.found.push(first.id, second.id);
    }
  }

  await redis.set(`memory:${req.params.sessionId}`, JSON.stringify(session), { EX: 3600 });
  return res.json(session);
});

app.listen(3002, "0.0.0.0", () => {
  console.log("memory-api listening on 0.0.0.0:3002");
});
