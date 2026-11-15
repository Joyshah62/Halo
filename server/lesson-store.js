// Durable LangGraph checkpoints and completed-response replay survive development/server restarts.
import { SqliteSaver } from "@langchain/langgraph-checkpoint-sqlite";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { mkdirSync } from "node:fs";

const here = path.dirname(fileURLToPath(import.meta.url));
export const lessonDatabase = process.env.HALO_LESSON_DB_PATH || (process.env.HALO_DB_PATH === ":memory:" ? ":memory:" : path.join(here, "lessons.sqlite"));
if (lessonDatabase !== ":memory:") mkdirSync(path.dirname(lessonDatabase), { recursive: true });
export const lessonSaver = SqliteSaver.fromConnString(lessonDatabase);
const db = lessonSaver.db;
db.exec("CREATE TABLE IF NOT EXISTS halo_lesson_replies (key TEXT PRIMARY KEY, data TEXT NOT NULL)");
const read = db.prepare("SELECT data FROM halo_lesson_replies WHERE key = ?");
const write = db.prepare("INSERT OR REPLACE INTO halo_lesson_replies (key, data) VALUES (?, ?)");
const trim = db.prepare("DELETE FROM halo_lesson_replies WHERE key NOT IN (SELECT key FROM halo_lesson_replies ORDER BY rowid DESC LIMIT 64)");
export function cachedLessonReply(key) {
  const row = read.get(key);
  return row ? JSON.parse(row.data) : undefined;
}
export function saveLessonReply(key, response) {
  db.transaction(() => { write.run(key, JSON.stringify(response)); trim.run(); })();
}

// Replayed lessons (replay.js): which recording a client's lesson ID walks, and how far along it is.
db.exec("CREATE TABLE IF NOT EXISTS halo_replay_sessions (id TEXT PRIMARY KEY, data TEXT NOT NULL)");
const readSession = db.prepare("SELECT data FROM halo_replay_sessions WHERE id = ?");
const writeSession = db.prepare("INSERT OR REPLACE INTO halo_replay_sessions (id, data) VALUES (?, ?)");
const trimSessions = db.prepare("DELETE FROM halo_replay_sessions WHERE id NOT IN (SELECT id FROM halo_replay_sessions ORDER BY rowid DESC LIMIT 200)");
export function replaySession(id) {
  const row = readSession.get(id);
  return row ? JSON.parse(row.data) : undefined;
}
export function saveReplaySession(id, session) {
  db.transaction(() => { writeSession.run(id, JSON.stringify(session)); trimSessions.run(); })();
}
