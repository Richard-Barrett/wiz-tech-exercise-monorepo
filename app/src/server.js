const express = require("express");
const { MongoClient, ObjectId } = require("mongodb");
const path = require("path");

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "..", "public")));

const mongoUri = process.env.MONGODB_URI;
if (!mongoUri) {
  console.error("MONGODB_URI is not set");
  process.exit(1);
}

const client = new MongoClient(mongoUri, { serverSelectionTimeoutMS: 5000 });
let todos;

async function init() {
  await client.connect();
  const db = client.db("wizdb");
  todos = db.collection("todos");
  await todos.createIndex({ createdAt: -1 });
  console.log("Connected to MongoDB and ready.");
}

app.get("/api/health", async (req, res) => {
  try {
    await client.db("admin").command({ ping: 1 });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.get("/api/todos", async (req, res) => {
  const items = await todos.find({}).sort({ createdAt: -1 }).limit(50).toArray();
  res.json(items);
});

app.post("/api/todos", async (req, res) => {
  const text = (req.body && req.body.text) ? String(req.body.text).slice(0, 200) : "";
  if (!text) return res.status(400).json({ error: "text is required" });
  const doc = { text, createdAt: new Date() };
  const result = await todos.insertOne(doc);
  res.json({ _id: result.insertedId, ...doc });
});

app.delete("/api/todos/:id", async (req, res) => {
  const id = req.params.id;
  await todos.deleteOne({ _id: new ObjectId(id) });
  res.json({ ok: true });
});

const port = process.env.PORT || 3000;
init()
  .then(() => app.listen(port, () => console.log(`Listening on ${port}`)))
  .catch(err => {
    console.error("Failed to start:", err);
    process.exit(1);
  });
