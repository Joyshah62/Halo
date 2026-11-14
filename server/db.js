import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const db = new DatabaseSync(process.env.HALO_DB_PATH || path.join(here, "halo.db"));

db.exec(`
  CREATE TABLE IF NOT EXISTS questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    url TEXT,
    title TEXT,
    question TEXT NOT NULL,
    mode TEXT NOT NULL,
    topic TEXT,
    circled_text TEXT,
    answer_text TEXT,
    parent_id INTEGER
  );
`);

const insertQ = db.prepare(
  `INSERT INTO questions (url, title, question, mode, parent_id) VALUES (?, ?, ?, ?, ?)`
);
const finishQ = db.prepare(
  `UPDATE questions SET topic = ?, circled_text = ?, answer_text = ? WHERE id = ?`
);

export function logQuestion({ url, title, question, mode, parentId }) {
  const r = insertQ.run(url ?? null, title ?? null, question, mode, parentId ?? null);
  return Number(r.lastInsertRowid);
}

export function finishQuestion(id, { topic, circledText, answerText }) {
  finishQ.run(topic ?? null, circledText ?? null, answerText ?? null, id);
}

export function history(limit = 50) {
  return db
    .prepare(`SELECT * FROM questions ORDER BY id DESC LIMIT ?`)
    .all(limit);
}

export function confusionMap() {
  return db
    .prepare(
      `SELECT topic, COUNT(*) AS count, MAX(created_at) AS last_asked
       FROM questions WHERE topic IS NOT NULL AND topic != ''
       GROUP BY topic ORDER BY count DESC, last_asked DESC`
    )
    .all();
}

export function flashcards(limit = 30) {
  return db
    .prepare(
      `SELECT id, topic, question, answer_text, circled_text, url, title
       FROM questions WHERE answer_text IS NOT NULL AND answer_text != ''
       ORDER BY id DESC LIMIT ?`
    )
    .all(limit);
}

export function clearAll() {
  db.exec(`DELETE FROM questions`);
}
