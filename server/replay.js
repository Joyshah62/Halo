// Demo replay cache for Circle & Ask and the lesson agent.
//
// The first time a question is asked about a page (or a lesson is taught over a chapter), the full response is
// recorded: every SSE event, voice audio included. Asking the same thing again replays it instantly, so a rehearsed
// demo never waits on the model or the voice and never comes out differently. Only documents that match
// HALO_REPLAY_MATCH are recorded (by default the "AI Engineering" chapter used in the demo).
//
// Keys are built from what is on the page, not from the document's name or ID, so re-importing the PDF still hits.
// Questions, circled text and lesson answers match loosely (voice transcripts vary), but numbers must agree.
//
//   HALO_REPLAY=0               turn it off            HALO_REPLAY=1   also on with HALO_MOCK=1 (tests)
//   HALO_REPLAY_MATCH=<regex>   which documents (tested against the title and page text); "*" for every document
//   HALO_REPLAY_DIR=<dir>       where recordings live (default server/replay); delete a file to re-record it
//   HALO_REPLAY_SIMILARITY=0.75 how close a question or answer must be to a recorded one
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const DIR = process.env.HALO_REPLAY_DIR || path.join(here, "replay");
// Phrases from the demo PDF ("AI Engineering", chapter 6: RAG and Agents), so any page or chapter of it is recognised.
const DEFAULT_MATCH = "AI Engineering|Chip Huyen|RAG and Agents|retrieve-then-generate|retrieval-augmented|Kitty Vogue|Fruity Fedora|EADDRNOTAVAIL|reciprocal rank fusion|BM25|HNSW|vector database|SWE-agent|Chameleon|Kambhampati|planning should be decoupled";
const SIMILARITY = Math.min(1, Math.max(0.3, Number(process.env.HALO_REPLAY_SIMILARITY) || 0.75));
const ASKS_PER_PAGE = 40;

export const replayEnabled = () => process.env.HALO_REPLAY !== "0" && (process.env.HALO_MOCK !== "1" || process.env.HALO_REPLAY === "1");

/** True when this document is one whose responses are recorded and replayed. */
export function inScope(...texts) {
  if (!replayEnabled()) return false;
  const match = process.env.HALO_REPLAY_MATCH ?? DEFAULT_MATCH;
  if (match.trim() === "*") return true;
  let pattern;
  try { pattern = new RegExp(match, "i"); } catch { return false; }
  return texts.some((text) => pattern.test(String(text ?? "")));
}

export const norm = (text) => String(text ?? "").normalize("NFKC").toLowerCase().replace(/[’‘]/g, "'").replace(/[^\p{L}\p{N}]+/gu, " ").trim();
const hash = (value) => createHash("sha256").update(typeof value === "string" ? value : JSON.stringify(value)).digest("hex").slice(0, 20);

/** 0..1: how alike two questions or answers are (shared words). Numbers must agree, or they are different questions. */
export function similar(a, b) {
  const x = norm(a), y = norm(b);
  if (x === y) return 1;
  if (!x || !y) return 0;
  const left = new Set(x.split(" ")), right = new Set(y.split(" "));
  const numbers = (set) => [...set].filter((t) => /\d/.test(t)).sort().join(",");
  if (numbers(left) !== numbers(right)) return 0;
  let shared = 0;
  for (const token of left) if (right.has(token)) shared++;
  return (2 * shared) / (left.size + right.size);
}

// ---------- files ----------
const loaded = new Map();
function read(name) {
  if (loaded.has(name)) return loaded.get(name);
  let data;
  try { data = JSON.parse(fs.readFileSync(path.join(DIR, name), "utf8")); } catch { data = undefined; }
  loaded.set(name, data);
  return data;
}
function write(name, data) {
  loaded.set(name, data);
  try {
    fs.mkdirSync(DIR, { recursive: true });
    const file = path.join(DIR, name), temp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temp, JSON.stringify(data));
    fs.renameSync(temp, file);
  } catch (error) {
    console.warn("[replay] could not save", name, error.message);
  }
}

// ---------- Circle & Ask ----------
// One file per page (and kind of question); inside it, every recorded question about that page.
function askFile(b) {
  const page = Number(String(b.pageUrl || "").match(/\/page\/(\d+)/)?.[1] || String(b.pageTitle || "").match(/Page (\d+)\s*$/)?.[1]) || 0;
  const explorer = b.explorer && typeof b.explorer === "object" ? `${b.explorer.model || ""}:${b.explorer.focus || ""}` : "";
  const turns = Array.isArray(b.conversation) ? b.conversation.length : 0;
  return `ask-${hash([page, norm(b.pageText).slice(0, 4000), Boolean(b.tutorMode), b.selectionMode || "", b.surface || "", explorer, turns, Boolean(b.previousAnswer), Boolean(b.documentText)])}.json`;
}

/** The recorded answer to this question, or undefined. */
export function findAnswer(b) {
  const entries = read(askFile(b))?.entries || [];
  let best, score = 0;
  for (const entry of entries) {
    const question = similar(entry.question, b.question);
    const circled = !norm(entry.circledText) && !norm(b.circledText) ? 1 : similar(entry.circledText, b.circledText);
    if (question < SIMILARITY || circled < Math.min(SIMILARITY, 0.6)) continue;
    if (question + circled > score) { best = entry; score = question + circled; }
  }
  return best;
}

/** Keeps a finished answer: events are [name, data] pairs ("meta" and "step"). */
export function saveAnswer(b, events) {
  if (!events.some(([event]) => event === "step")) return;
  const name = askFile(b);
  const entries = (read(name)?.entries || []).filter((e) => !(norm(e.question) === norm(b.question) && norm(e.circledText) === norm(b.circledText)));
  entries.push({ question: String(b.question || ""), circledText: String(b.circledText || "").slice(0, 2000), page: b.pageTitle || "", at: new Date().toISOString(), events });
  write(name, { kind: "ask", entries: entries.slice(-ASKS_PER_PAGE) });
}

// ---------- lessons ----------
// One file per chapter: a tree of the conversation. Each node is one response from Halo, with the LangGraph thread
// and checkpoint it left the lesson paused at, so an answer nobody has given before continues live from there.
export const lessonFile = (pages) => `lesson-${hash(pages.map((p) => `${p.page}:${norm(p.text)}`).join("\n"))}.json`;
export const loadLesson = (name) => read(name);
export const saveLesson = (name, tree) => write(name, tree);

/** The recorded response to this reply at this point of the lesson, if someone has given it before. */
export function matchReply(node, reply) {
  let best, score = 0;
  for (const child of node.children || []) {
    const said = child.reply;
    if (said.action !== reply.action) continue;
    if (reply.action === "jump") { if (Number(said.concept) === Number(reply.concept)) return child; continue; }
    if (reply.action === "skip") return child;
    const s = similar(said.answer, reply.answer);
    if (s >= SIMILARITY && s > score) { best = child; score = s; }
  }
  return best;
}
