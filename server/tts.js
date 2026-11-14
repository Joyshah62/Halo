// ElevenLabs TTS, one clip per step. Returns base64 mp3 or null when disabled/failing.
//
// What makes it sound human rather than like a list being read:
//  - one model for every step, so the voice never changes character mid-answer;
//  - full-quality audio (44.1 kHz / 128 kbps, not phone quality);
//  - request stitching: each step is told what was already said (`previous_text`),
//    so its intonation continues the sentence before instead of resetting.
import { log } from "./logging.js";

const KEY = process.env.ELEVENLABS_API_KEY;
// Hope: young, natural, clear and calm (shared library). Alexandra was kdmDKE6EkgrWrrykO9Qt;
// Hailey (VrUPKj92idNr4XrmO032) had audible background noise baked into the voice. Kleo was fZboLjcdZSF1lt1yyuXM.
const VOICE = process.env.ELEVENLABS_VOICE_ID || "OYTbf65OHHFELVut7v2H";
// v3 models drift in accent; an audio tag holds it. It steers delivery and is not read aloud. Set empty to turn off.
const ACCENT = (process.env.ELEVENLABS_ACCENT ?? "American").trim();
const SPEED = Math.min(1.2, Math.max(0.7, Number(process.env.ELEVENLABS_SPEED) || 0.92));
const MODEL = process.env.ELEVENLABS_MODEL_ID || "eleven_v3_conversational";
const FORMAT = process.env.ELEVENLABS_OUTPUT_FORMAT || "mp3_44100_128";

export const ttsEnabled = Boolean(KEY);
export const ttsVoice = { voice: VOICE, model: MODEL, format: FORMAT, accent: /_v3/.test(MODEL) ? ACCENT || null : null };

// ElevenLabs refuses requests beyond a plan's concurrency limit (2 to 5 at once) with a 429, and an answer asks
// for every step's voice in parallel, a lesson adds its fillers on top. A refused clip used to come back as no
// audio, and the iPad read that step in Apple's voice: Halo "suddenly changed its voice". So requests queue here
// (ELEVENLABS_CONCURRENCY, default 3) and a refused, failed or timed-out clip is tried again before giving up.
const LIMIT = Math.max(1, Number(process.env.ELEVENLABS_CONCURRENCY) || 3);
let running = 0;
const waiting = [];
async function slot() {
  if (running < LIMIT) { running++; return; }
  await new Promise((resolve) => waiting.push(resolve));
}
function done() {
  const next = waiting.shift();
  if (next) next(); else running--;
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** @param {string} text  @param {{ previous?: string, timeoutMs?: number }} [opts] */
export async function speak(text, opts = {}) {
  if (!KEY || !String(text ?? "").trim()) return null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    await slot();
    let outcome;
    try { outcome = await once(text, opts); } finally { done(); }
    if (outcome.audio) {
      if (attempt > 1) log("tts.recovered", { attempt, characters: text.length });
      return outcome.audio;
    }
    if (!outcome.retry || attempt === 3) {
      log("tts.failed", { attempt, status: outcome.status, reason: outcome.reason, characters: text.length }, "warn");
      return null;
    }
    log("tts.retry", { attempt, status: outcome.status, reason: outcome.reason }, "warn");
    await sleep(attempt * 600);
  }
  return null;
}

async function once(text, { previous = "", timeoutMs = 12000 } = {}) {
  const v3 = /_v3/.test(MODEL);
  const body = {
    text: v3 && ACCENT ? `[${ACCENT} accent] ${text}` : text,
    model_id: MODEL,
    language_code: "en",
    voice_settings: v3
      ? { stability: 0.5, similarity_boost: 0.8 }
      // Soothing: steadier than default so it never swings in pitch, almost no style exaggeration
      // (style makes it sound performed), and a touch slower than normal speech so it feels unhurried.
      : { stability: 0.6, similarity_boost: 0.8, style: 0.05, use_speaker_boost: true, speed: SPEED },
  };
  if (!v3 && previous) body.previous_text = previous.slice(-1000);
  try {
    const res = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE}?output_format=${FORMAT}`, {
      method: "POST",
      signal: AbortSignal.timeout(timeoutMs),
      headers: { "xi-api-key": KEY, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const reason = (await res.text()).slice(0, 200);
      console.warn("[tts]", MODEL, res.status, reason);
      // Too many at once, or ElevenLabs having a moment: worth another try. A bad key or an empty quota is not.
      return { status: res.status, reason, retry: res.status === 429 || res.status >= 500 };
    }
    return { audio: Buffer.from(await res.arrayBuffer()).toString("base64") };
  } catch (e) {
    console.warn("[tts] failed:", e.message);
    return { reason: e.message.slice(0, 200), retry: true };
  }
}
