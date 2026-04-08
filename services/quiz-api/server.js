const express = require("express");
const cors = require("cors");

const app = express();
app.use(cors());
app.use(express.json());

const questions = [
  { id: 1, question: "Quel composant route le trafic HTTP vers les services Kubernetes ?", answer: "Ingress" },
  { id: 2, question: "Quel outil cree un cluster Kubernetes local multi-noeuds ?", answer: "Kind" },
  { id: 3, question: "Quel service GameCloud stocke les scores ?", answer: "score-api" },
  { id: 4, question: "Quel moteur cle/valeur utilise pendu-api et memory-api ?", answer: "Redis" }
];

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok", service: "quiz-api" });
});

app.get("/question", (_req, res) => {
  const question = questions[Math.floor(Math.random() * questions.length)];
  res.json(question);
});

app.get("/questions", (_req, res) => {
  res.json({ items: questions });
});

app.listen(3001, () => {
  console.log("quiz-api listening on :3001");
});
