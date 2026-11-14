// ElevenLabs TTS, one clip per step. Returns base64 mp3 or null when disabled/failing.
//
// What makes it sound human rather than like a list being read:
//  - one model for every step, so the voice never changes character mid-answer;
//  - full-quality audio (44.1 kHz / 128 kbps, not phone quality);
//  - request stitching: each step is told what was already said (`previous_text`),
//    so its intonation continues the sentence before instead of resetting.
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

/** @param {string} text  @param {{ previous?: string }} [opts] */
export async function speak(text, { previous = "", timeoutMs = 12000 } = {}) {
  if (!KEY) return null;
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
      console.warn("[tts]", MODEL, res.status, (await res.text()).slice(0, 200));
      return null;
    }
    return Buffer.from(await res.arrayBuffer()).toString("base64");
  } catch (e) {
    console.warn("[tts] failed:", e.message);
    return null;
  }
}
