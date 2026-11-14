// Halo's answers are steps: what to say, paired with what to write. This is the shared plumbing for them:
// cleaning what the model produced, making it safe to speak, and attaching voice and pictures in order.
import { generateImage } from "./llm.js";
import { speak } from "./tts.js";

const INK_TYPES = new Set(["text", "arrow", "underline", "box", "check", "cross", "sketch", "image", "point"]);
const POINT_STYLES = new Set(["highlight", "underline", "circle"]);

/** One raw model object → a clean step, or null when it isn't one. */
export function cleanStep(obj) {
  if (!obj || typeof obj.say !== "string") return null;
  const ink = Array.isArray(obj.ink)
    ? obj.ink.filter((i) => i && INK_TYPES.has(i.type)).filter((i) => i.type !== "point" || typeof i.quote === "string" || Number.isInteger(i.line)).slice(0, 5).map((i) => {
        if (i.type === "point") {
          // A mark on the printed page: found by its exact text (asks) or by a line of the checked working (checks).
          const style = POINT_STYLES.has(i.style) ? i.style : "highlight";
          return Number.isInteger(i.line) ? { type: "point", line: i.line, style } : { type: "point", quote: String(i.quote).trim().slice(0, 60), style };
        }
        if (i.type === "sketch") {
          return {
            type: "sketch",
            w: Math.min(320, Math.max(80, Number(i.w) || 200)),
            h: Math.min(240, Math.max(60, Number(i.h) || 120)),
            paths: (Array.isArray(i.paths) ? i.paths : []).filter((d) => typeof d === "string" && /^[MmLlHhVvCcSsQqTtAaZz0-9\s,.\-+eE]+$/.test(d)).slice(0, 8),
            labels: (Array.isArray(i.labels) ? i.labels : []).filter((l) => l && typeof l.text === "string").slice(0, 6)
              .map((l) => ({ x: Number(l.x) || 0, y: Number(l.y) || 0, text: String(l.text).slice(0, 16) })),
          };
        }
        if (i.type === "image") return { type: "image", prompt: String(i.prompt || "").slice(0, 300) };
        return i;
      })
    : [];
  return { say: despeak(obj.say), ink, ...(["source", "visual", "example"].includes(obj.focus) ? { focus: obj.focus } : {}) };
}

/** Make model text safe to speak: strip LaTeX/markdown leftovers. */
export function despeak(t) {
  return String(t)
    .replace(/\$+/g, "")
    .replace(/\\(frac|cdot|times|sqrt|left|right|text)\b/g, " ")
    .replace(/[\\*_`#]/g, "")
    .replace(/\^2\b/g, " squared").replace(/\^3\b/g, " cubed").replace(/\^/g, " to the power ")
    .replace(/\s+/g, " ").trim();
}

/** Resolve a step's async assets: TTS audio and any generated images. */
export async function prepareStep(step, previous) {
  const [audio] = await Promise.all([
    speak(step.say, { previous }),
    ...step.ink.filter((i) => i.type === "image").map(async (i) => {
      const img = await generateImage(i.prompt);
      if (img) { i.mime = img.mime; i.data = img.data; }
    }),
  ]);
  return audio;
}

/** A line of model output → the JSON object on it, tolerating fences and stray prose. Null when there isn't one. */
export function parseLine(line) {
  line = line.trim().replace(/^```[a-z]*$|^```$/i, "");
  if (!line) return null;
  try { return JSON.parse(line); } catch {
    const m = line.match(/\{.*\}/);
    if (!m) return null;
    try { return JSON.parse(m[0]); } catch { return null; }
  }
}

/**
 * Steps come out of the model one line at a time. Each gets its voice prepared as soon as it lands, in parallel,
 * and is emitted strictly in order once its voice is ready, so the first step is spoken while the rest are still being written.
 */
export class StepQueue {
  /** @param {(step: object) => void} emit */
  constructor(emit) { this.emit = emit; this.steps = []; this.jobs = []; this.emitted = 0; this.flushing = Promise.resolve(); }
  push(raw) {
    const step = cleanStep(raw);
    if (!step) return null;
    const said = this.steps.map((s) => s.say).join(" ");
    this.steps.push(step);
    this.jobs.push(prepareStep(step, said));
    this.flushing = this.flushing.then(() => this.flush());
    return step;
  }
  async flush() {
    while (this.emitted < this.jobs.length) {
      const audio = await this.jobs[this.emitted];
      const index = this.emitted++;
      this.emit({ index, ...this.steps[index], audio });
    }
  }
  /** Resolves once every pushed step has been emitted. */
  async drain() { await this.flushing; }
  get said() { return this.steps.map((s) => s.say).join(" "); }
}

/**
 * Reads NDJSON from a text stream, handing each complete line's object to `onObject`. Partial lines are buffered.
 * @param {AsyncIterable<string>} deltas  @param {(obj: object, line: string) => void} onObject  @returns the full text
 */
export async function readLines(deltas, onObject) {
  let buffer = "", full = "";
  const take = (line) => { const obj = parseLine(line); if (obj) onObject(obj, line); };
  for await (const delta of deltas) {
    full += delta; buffer += delta;
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) { take(buffer.slice(0, nl)); buffer = buffer.slice(nl + 1); }
  }
  if (buffer.trim()) take(buffer);
  return full;
}
