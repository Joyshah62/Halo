// What Halo remembers about each learner, in two sections of one markdown file (/memories/<key>.md):
//
//   # Gaps Halo has seen                 written by the "Why am I stuck?" agent (stuck.js)
//   - derivative of the inside function | chain rule | seen 2 time(s) | p.3
//
//   # Topics they have covered           written by the server from real results, never by a model
//   - the power rule | lesson | got it | Calculus Workbook p.1 | 2026-11-14 | 1 time(s)
//   - chain rule | practice | solved it | Calculus Workbook p.3 | 2026-11-14 | 3 time(s)
//
// With BACKBOARD_API_KEY set, Backboard (backboard.io) holds the real copy: one Backboard assistant per learner,
// one Backboard memory per line (metadata.kind = "gap" | "topic"). Before a run the file is rebuilt from Backboard;
// changes go back in the background. Without a key (or when Backboard can't be reached) the local file is the memory.
//
// Learners are keyed by an anonymous device ID the iPad generates (no login; demo only), never by name.
import path from "node:path";
import { fileURLToPath } from "node:url";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";

const here = path.dirname(fileURLToPath(import.meta.url));
export const MEMORY_DIR = process.env.HALO_MEMORY_DIR || path.join(here, "memory");
export const GAPS_HEADING = "# Gaps Halo has seen";
export const TOPICS_HEADING = "# Topics they have covered";
const BASE = "https://app.backboard.io/api";
const PREFIX = "halo-learner-";
const MAX_TOPICS = 80;
const enabled = () => Boolean(process.env.BACKBOARD_API_KEY) && process.env.HALO_MOCK !== "1";
const clip = (value, n) => String(value ?? "").replace(/[|\n]+/g, " ").replace(/\s+/g, " ").trim().slice(0, n);

/** The file name (and Backboard assistant suffix) for a learner: their device ID, or "learner" when there is none. */
export function learnerKey(learnerId) {
  const id = String(learnerId || "").trim().toLowerCase();
  return /^[a-z0-9-]{8,64}$/.test(id) ? `id-${id}` : "learner";
}

// ---------- the file ----------
const fields = (line) => line.replace(/^-\s*/, "").split("|").map((f) => f.trim());
const gapKey = (line) => fields(line)[0].toLowerCase();
const topicKey = (line) => { const [topic, how] = fields(line); return `${(how || "").toLowerCase()}:${topic.toLowerCase()}`; };

/** markdown → { gaps: Map<key, line>, topics: Map<key, line> }. Lines before any heading count as gaps. */
function parse(markdown) {
  const gaps = new Map(), topics = new Map();
  let section = "gaps";
  for (const raw of String(markdown || "").split("\n")) {
    const line = raw.trim();
    if (line.startsWith("# ")) { section = line.toLowerCase().startsWith(TOPICS_HEADING.toLowerCase()) ? "topics" : "gaps"; continue; }
    if (!line.startsWith("- ") || !fields(line)[0]) continue;
    if (section === "topics") topics.set(topicKey(line), line); else gaps.set(gapKey(line), line);
  }
  return { gaps, topics };
}
function render({ gaps, topics }) {
  return `${GAPS_HEADING}\n${[...gaps.values()].map((l) => `${l}\n`).join("")}\n${TOPICS_HEADING}\n${[...topics.values()].map((l) => `${l}\n`).join("")}`;
}
const fileFor = (key) => path.join(MEMORY_DIR, `${key}.md`);
function readLocal(key) {
  try { return readFileSync(fileFor(key), "utf8"); } catch { return ""; }
}
function writeLocal(key, memory) {
  mkdirSync(MEMORY_DIR, { recursive: true });
  writeFileSync(fileFor(key), render(memory));
}

// ---------- Backboard ----------
async function backboard(method, route, body) {
  const r = await fetch(BASE + route, {
    method, body: body && JSON.stringify(body), signal: AbortSignal.timeout(8000),
    headers: { "X-API-Key": process.env.BACKBOARD_API_KEY, "Content-Type": "application/json" },
  });
  if (!r.ok) throw new Error(`Backboard ${method} ${route.split("/").slice(0, 2).join("/")} → ${r.status}`);
  return r.json();
}

const assistants = new Map();   // key → Promise<assistant_id>
/** The learner's Backboard assistant, created the first time Halo has something to remember. */
function assistantFor(key) {
  if (!assistants.has(key)) {
    const found = (async () => {
      const name = PREFIX + key;
      const list = await backboard("GET", "/assistants");
      const existing = (Array.isArray(list) ? list : list?.assistants || []).find((a) => a?.name === name);
      if (existing) return existing.assistant_id;
      const made = await backboard("POST", "/assistants", { name, description: "Halo: what this learner has been stuck on and has covered" });
      return made.assistant_id;
    })();
    assistants.set(key, found);
    found.catch(() => assistants.delete(key));   // try again next time
  }
  return assistants.get(key);
}

const ids = new Map();     // key → Map<"gap:<k>" | "topic:<k>", Backboard memory id>
const queues = new Map();  // key → the last write for that learner; writes run one after another

function enqueue(key, job) {
  const next = (queues.get(key) || Promise.resolve()).then(job).catch((e) => console.warn(`[memory] Backboard sync failed (kept locally): ${e.message}`));
  queues.set(key, next);
  next.finally(() => { if (queues.get(key) === next) queues.delete(key); });
  return next;
}

/** Reads the learner's memory from Backboard into the local file. False when Backboard is off or unreachable. */
async function fromBackboard(key) {
  if (!enabled()) return false;
  try {
    const assistant = await assistantFor(key);
    const memories = [];
    for (let page = 1; page <= 5; page++) {
      const r = await backboard("GET", `/assistants/${assistant}/memories?page=${page}&page_size=100`);
      memories.push(...(r.memories || []));
      if (!r.total_pages || page >= r.total_pages) break;
    }
    const memory = { gaps: new Map(), topics: new Map() }, known = new Map();
    // Oldest first, so the newest version of a line wins.
    memories.sort((a, b) => String(a.created_at || "").localeCompare(String(b.created_at || "")));
    for (const m of memories) {
      const line = `- ${String(m.content || "").replace(/^-\s*/, "").trim()}`;
      if (!fields(line)[0]) continue;
      if (m.metadata?.kind === "topic") { memory.topics.set(topicKey(line), line); known.set(`topic:${topicKey(line)}`, m.id); }
      else { memory.gaps.set(gapKey(line), line); known.set(`gap:${gapKey(line)}`, m.id); }
    }
    ids.set(key, known);
    writeLocal(key, memory);
    return true;
  } catch (e) {
    console.warn(`[memory] Backboard unavailable, using the local copy: ${e.message}`);
    return false;
  }
}

/** Sends the lines that changed between two versions of the memory to Backboard. */
async function toBackboard(key, before, after) {
  if (!enabled() || !ids.has(key)) return;
  const assistant = await assistantFor(key);
  const known = ids.get(key);
  for (const kind of ["gaps", "topics"]) {
    const was = before[kind], now = after[kind], tag = kind === "gaps" ? "gap" : "topic";
    for (const [k, line] of now) {
      if (was.get(k) === line) continue;
      const content = line.replace(/^-\s*/, "");
      const metadata = tag === "gap" ? { kind: "gap", gap: k, source: "halo" } : { kind: "topic", topic: fields(line)[0], how: fields(line)[1] || "", source: "halo" };
      const id = known.get(`${tag}:${k}`);
      if (id) await backboard("PUT", `/assistants/${assistant}/memories/${id}`, { content, metadata });
      else {
        const made = await backboard("POST", `/assistants/${assistant}/memories`, { content, metadata });
        if (made?.memory_id || made?.id) known.set(`${tag}:${k}`, made.memory_id || made.id);
      }
      console.log(`[memory] Backboard ← ${tag}: ${content}`);
    }
    for (const k of was.keys()) {
      const id = known.get(`${tag}:${k}`);
      if (now.has(k) || !id) continue;
      await backboard("DELETE", `/assistants/${assistant}/memories/${id}`);
      known.delete(`${tag}:${k}`);
    }
  }
}

// ---------- what the rest of the server uses ----------
/**
 * Before a run: the learner's memory as markdown, also written to the file the agent reads.
 * @returns {Promise<{ markdown: string, source: "backboard" | "local" }>}
 */
export async function pullMemory(key) {
  await queues.get(key);
  const source = (await fromBackboard(key)) ? "backboard" : "local";
  const memory = parse(readLocal(key));
  writeLocal(key, memory);   // always has both headings, so the agent only ever edits it
  return { markdown: readLocal(key), source };
}

/** After an agent run: sends what the agent changed in the gaps section to Backboard, in the background. Never throws. */
export function pushMemory(key, before) {
  const was = parse(before), now = parse(readLocal(key));
  // The agent only writes gaps; topics are the server's, so the agent's copy of them is ignored.
  return enqueue(key, () => toBackboard(key, { gaps: was.gaps, topics: new Map() }, { gaps: now.gaps, topics: new Map() }));
}

/**
 * Records topics the learner has been through. Runs in the background; never throws.
 * @param {string} key  from learnerKey()
 * @param {{ topic: string, how: "lesson" | "practice", result: string, book?: string, page?: number, again?: boolean }[]} items
 *        again: the same session is updating its result (a lesson concept checked a second time), so the count stays.
 */
export function recordTopics(key, items) {
  const clean = (Array.isArray(items) ? items : []).map((t) => ({
    topic: clip(t?.topic, 60).toLowerCase(), how: t?.how === "practice" ? "practice" : "lesson", result: clip(t?.result, 30),
    where: [clip(t?.book, 80), Number(t?.page) > 0 ? `p.${Math.round(Number(t.page))}` : ""].filter(Boolean).join(" "),
    again: Boolean(t?.again),
  })).filter((t) => t.topic && t.result);
  if (!clean.length) return Promise.resolve();
  return enqueue(key, async () => {
    if (!ids.has(key)) await fromBackboard(key);
    const before = parse(readLocal(key));
    const after = { gaps: before.gaps, topics: new Map(before.topics) };
    const today = new Date().toISOString().slice(0, 10);
    for (const t of clean) {
      const k = `${t.how}:${t.topic}`;
      const old = after.topics.get(k);
      const times = (old ? Number(fields(old).at(-1)?.match(/(\d+)/)?.[1]) || 1 : 0) + (old && t.again ? 0 : 1);
      after.topics.delete(k);   // re-inserted at the end: the list stays in the order things were last done
      after.topics.set(k, `- ${t.topic} | ${t.how} | ${t.result} | ${t.where} | ${today} | ${times} time(s)`);
    }
    while (after.topics.size > MAX_TOPICS) after.topics.delete(after.topics.keys().next().value);
    writeLocal(key, after);
    console.log(`[memory] covered: ${clean.map((t) => `${t.topic} (${t.how}, ${t.result})`).join("; ")}`);
    await toBackboard(key, before, after);
  });
}

/**
 * Saves what a quiz or lesson showed: weaknesses become gap lines (the same section the "Why am I stuck?" agent
 * reads and writes), strengths become topic lines, and weak spots the student has now got are taken off.
 * Runs in the background; never throws.
 * @param {string} key  from learnerKey()
 * @param {{ how: "quiz" | "lesson", title?: string, strengths?: { point: string }[], weaknesses?: { point: string }[], improved?: string[] }} insight
 */
export function recordInsights(key, { how, title, strengths = [], weaknesses = [], improved = [] }) {
  const source = how === "lesson" ? "lesson" : "quiz";
  const topic = clip(title, 60).toLowerCase() || source;
  const weak = weaknesses.map((w) => clip(w?.point, 60).toLowerCase()).filter(Boolean);
  const strong = strengths.map((s) => clip(s?.point, 60).toLowerCase()).filter(Boolean);
  const fixed = new Set(improved.map((g) => clip(g, 60).toLowerCase()).filter(Boolean));
  if (!weak.length && !strong.length && !fixed.size) return Promise.resolve();
  return enqueue(key, async () => {
    if (!ids.has(key)) await fromBackboard(key);
    const before = parse(readLocal(key));
    const after = { gaps: new Map(before.gaps), topics: new Map(before.topics) };
    const today = new Date().toISOString().slice(0, 10);
    for (const gap of fixed) after.gaps.delete(gap);
    for (const gap of weak) {
      const old = after.gaps.get(gap);
      const times = (old ? Number(old.match(/seen (\d+) time/)?.[1]) || 1 : 0) + 1;
      after.gaps.delete(gap);   // re-inserted at the end: newest weak spots last
      after.gaps.set(gap, `- ${gap} | ${topic} | seen ${times} time(s) | ${source}`);
    }
    for (const point of strong) {
      const k = `${source}:${point}`, old = after.topics.get(k);
      const times = (old ? Number(fields(old).at(-1)?.match(/(\d+)/)?.[1]) || 1 : 0) + 1;
      after.topics.delete(k);
      after.topics.set(k, `- ${point} | ${source} | strength | ${topic} | ${today} | ${times} time(s)`);
    }
    while (after.topics.size > MAX_TOPICS) after.topics.delete(after.topics.keys().next().value);
    while (after.gaps.size > MAX_TOPICS) after.gaps.delete(after.gaps.keys().next().value);
    writeLocal(key, after);
    console.log(`[memory] ${source} "${topic}": ${strong.length} strength(s), ${weak.length} weak spot(s), ${fixed.size} improved`);
    await toBackboard(key, before, after);
  });
}

/** The learner's weak spots, newest first (gap names only), for prompts. */
export async function weakSpots(key, limit = 8) {
  const { markdown } = await pullMemory(key);
  return [...parse(markdown).gaps.keys()].reverse().slice(0, limit);
}

/** The topics section as plain lines, for prompts that only need to know what was covered. */
export async function coveredTopics(key) {
  const { markdown } = await pullMemory(key);
  return [...parse(markdown).topics.values()].map((l) => l.replace(/^-\s*/, ""));
}
