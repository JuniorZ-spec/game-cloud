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

// --- Supabase (optional - falls back to mock data if not configured) ---
const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_KEY;
const supabase = supabaseUrl && supabaseKey ? createClient(supabaseUrl, supabaseKey) : null;

// --- Mock questions for TP (when Supabase is not configured) ---
const mockQuestions = [
  { id: 1, question: "Quelle est la capitale de la France ?", answer: "Paris", clues: ["C'est une grande ville", "Tour Eiffel", "Seine"] },
  { id: 2, question: "Quel est le langage de programmation le plus utilisé ?", answer: "JavaScript", clues: ["Web", "Navigateur", "Node.js"] },
  { id: 3, question: "Quel est le plus grand océan ?", answer: "Pacifique", clues: ["Asie", "Amériques", "Le plus grand"] },
  { id: 4, question: "Qui a inventé Kubernetes ?", answer: "Google", clues: ["Google", "Conteneurs", "Orchestration"] },
  { id: 5, question: "Quel est le protocole de routage le plus utilisé sur Internet ?", answer: "BGP", clues: ["Border Gateway", "Protocole", "Routage"] }
];

// --- Game State (In memory for TP, ideally in Redis) ---
const rooms = new Map(); // roomCode -> { players, question, status, clueIdx, timer }
const mockScores = [];

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok", service: "quiz-api-questions-esgis-network", supabase: !!supabase });
});

// Endpoint solo classique (compatible avec l'ancien frontend)
app.get("/question", async (_req, res) => {
  try {
    if (supabase) {
      const { data } = await supabase.from("qpuc_questions").select("*");
      if (data && data.length > 0) {
        const question = data[Math.floor(Math.random() * data.length)];
        return res.json(question);
      }
    }
    // Fallback to mock data
    const question = mockQuestions[Math.floor(Math.random() * mockQuestions.length)];
    res.json(question);
  } catch (error) {
    console.error("Error fetching question:", error);
    const question = mockQuestions[Math.floor(Math.random() * mockQuestions.length)];
    res.json(question);
  }
});

app.post("/score", async (req, res) => {
  const { username, score } = req.body;
  try {
    if (supabase) {
      await supabase.from("qpuc_scores").insert([{ username, score }]);
    } else {
      mockScores.push({ username, score, date: new Date() });
    }
    res.json({ status: "saved" });
  } catch (error) {
    console.error("Error saving score:", error);
    mockScores.push({ username, score, date: new Date() });
    res.json({ status: "saved" });
  }
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
const HOST = "0.0.0.0";
httpServer.listen(PORT, HOST, () => {
  console.log(`quiz-api-questions-esgis (Socket.io) listening on ${HOST}:${PORT}`);
});
