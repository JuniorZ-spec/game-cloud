const express = require("express");
const cors = require("cors");
const { createClient } = require("@supabase/supabase-js");

const app = express();
app.use(cors());
app.use(express.json());

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_KEY;
const supabase = createClient(supabaseUrl, supabaseKey);

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok", service: "quiz-api-qpuc" });
});

app.get("/question", async (_req, res) => {
  try {
    const { data, error } = await supabase
      .from("qpuc_questions")
      .select("*");

    if (error) throw error;

    const question = data[Math.floor(Math.random() * data.length)];
    res.json(question);
  } catch (error) {
    console.error("Supabase Error:", error);
    res.status(500).json({ error: "Failed to fetch question" });
  }
});

app.get("/questions", async (_req, res) => {
  try {
    const { data, error } = await supabase
      .from("qpuc_questions")
      .select("*");

    if (error) throw error;
    res.json({ items: data });
  } catch (error) {
    console.error("Supabase Error:", error);
    res.status(500).json({ error: "Failed to fetch questions" });
  }
});

// Enregistrer les scores QPUC spécifiquement dans Supabase
app.post("/score", async (req, res) => {
  const { username, score } = req.body;
  try {
    const { data, error } = await supabase
      .from("qpuc_scores")
      .insert([{ username, score }]);

    if (error) throw error;
    res.json({ status: "saved", data });
  } catch (error) {
    console.error("Supabase Error:", error);
    res.status(500).json({ error: "Failed to save score" });
  }
});

const PORT = 3001;
app.listen(PORT, () => {
  console.log(`quiz-api (QPUC version) listening on :${PORT}`);
});
