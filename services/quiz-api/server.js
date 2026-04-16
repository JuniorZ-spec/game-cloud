const express = require("express");
const cors = require("cors");
const { createServer } = require("http");
const { Server } = require("socket.io");
const { createClient } = require("@supabase/supabase-js");

const app = express();
app.use(cors());
app.use(express.json());

const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: { origin: "*", methods: ["GET", "POST"] }
});

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_KEY;
const supabase = createClient(supabaseUrl, supabaseKey);

// --- Game State (In memory for TP, ideally in Redis) ---
const rooms = new Map(); // roomCode -> { players, question, status, clueIdx, timer }

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok", service: "quiz-api-qpuc-network" });
});

// Endpoint solo classique (compatible avec l'ancien frontend)
app.get("/question", async (_req, res) => {
  const { data } = await supabase.from("qpuc_questions").select("*");
  const question = data[Math.floor(Math.random() * data.length)];
  res.json(question);
});

app.post("/score", async (req, res) => {
  const { username, score } = req.body;
  await supabase.from("qpuc_scores").insert([{ username, score }]);
  res.json({ status: "saved" });
});

// --- Real-time Logic (Multiplayer) ---
io.on("connection", (socket) => {
  console.log("New student connected:", socket.id);

  socket.on("create_room", (username) => {
    const roomCode = Math.random().toString(36).substring(2, 7).toUpperCase();
    socket.join(roomCode);
    rooms.set(roomCode, { players: [{ id: socket.id, username, score: 0 }], status: "lobby" });
    socket.emit("room_created", roomCode);
  });

  socket.on("join_room", ({ roomCode, username }) => {
    const room = rooms.get(roomCode);
    if (room && room.status === "lobby") {
      socket.join(roomCode);
      room.players.push({ id: socket.id, username, score: 0 });
      io.to(roomCode).emit("players_update", room.players);
    } else {
      socket.emit("error", "Room not found or game started");
    }
  });

  socket.on("start_game", async (roomCode) => {
    const room = rooms.get(roomCode);
    if (!room) return;

    room.status = "playing";
    const { data } = await supabase.from("qpuc_questions").select("*");
    room.question = data[Math.floor(Math.random() * data.length)];
    room.clueIdx = 0;
    room.buzzedBy = null;

    io.to(roomCode).emit("game_started", { 
        theme: room.question.theme, 
        round: room.question.round,
        initialQuestion: room.question.round === 3 ? "Préparez vos buzzers..." : room.question.question
    });

    if (room.question.round === 3) {
      room.timer = setInterval(() => {
        if (room.buzzedBy) return; // Stop showing clues if someone buzzed
        if (room.clueIdx < room.question.clues.length) {
          io.to(roomCode).emit("clue", room.question.clues[room.clueIdx]);
          room.clueIdx++;
        } else {
          clearInterval(room.timer);
          io.to(roomCode).emit("timeout");
        }
      }, 3000);
    }
  });

  socket.on("buzz", (roomCode) => {
    const room = rooms.get(roomCode);
    if (room && !room.buzzedBy) {
      room.buzzedBy = socket.id;
      const player = room.players.find(p => p.id === socket.id);
      io.to(roomCode).emit("player_buzzed", { username: player.username, id: socket.id });
    }
  });

  socket.on("submit_answer", ({ roomCode, answer }) => {
    const room = rooms.get(roomCode);
    if (room && room.buzzedBy === socket.id) {
      const isCorrect = answer.toLowerCase().trim() === room.question.answer.toLowerCase();
      const points = isCorrect ? Math.max(2, 11 - room.clueIdx) : 0;
      
      const player = room.players.find(p => p.id === socket.id);
      if (isCorrect) player.score += points;

      io.to(roomCode).emit("answer_result", { 
        isCorrect, 
        correctAnswer: room.question.answer,
        player: player.username,
        points,
        players: room.players
      });
      
      room.buzzedBy = null; // Free buzzer for next question if needed
    }
  });

  socket.on("disconnect", () => {
    // Basic cleanup
    console.log("Student disconnected:", socket.id);
  });
});

const PORT = 3001;
httpServer.listen(PORT, () => {
  console.log(`quiz-api-qpuc (Socket.io) listening on :${PORT}`);
});
