// Provider abstraction: yields text deltas from the vision model.
// HALO_PROVIDER=gemini (default) | claude
import { SYSTEM_PROMPT, buildSystemPrompt } from "./prompt.js";

export const PROVIDER = (process.env.HALO_PROVIDER || "gemini").toLowerCase();
export const MODEL =
  process.env.HALO_MODEL || (PROVIDER === "claude" ? "claude-opus-5-5" : "gemini-3.5-flash");

/** @param {{images: {mime: string, data: string, label: string}[], text: string}} input */
export async function* streamText(input) {
  if (PROVIDER === "claude") yield* claudeStream(input);
  else yield* geminiStream(input);
}

async function* geminiStream({ images, text, conversation = [], system }) {
  const { GoogleGenAI } = await import("@google/genai");
  const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
  const parts = [];
  for (const im of images) {
    parts.push({ text: im.label });
    parts.push({ inlineData: { mimeType: im.mime, data: im.data } });
  }
  parts.push({ text });
  const config = {
    systemInstruction: system || SYSTEM_PROMPT,
    maxOutputTokens: 2000,
    temperature: 0.4,
    responseMimeType: "text/plain",
  };
  // Keep thinking minimal for speed (time to first step matters most).
  // Gemini 2.x takes a token budget; Gemini 3+ takes a level and rejects budget 0.
  if (/gemini-2\./i.test(MODEL)) {
    config.thinkingConfig = { thinkingBudget: Number(process.env.GEMINI_THINKING_BUDGET ?? 0) };
  } else {
    config.thinkingConfig = { thinkingLevel: process.env.GEMINI_THINKING_LEVEL || "minimal" };
  }

  const stream = await ai.models.generateContentStream({
    model: MODEL,
    contents: [...conversation.map((turn) => ({ role: turn.role === "assistant" ? "model" : "user", parts: [{ text: turn.text }] })), { role: "user", parts }],
    config,
  });
  for await (const chunk of stream) {
    const t = chunk.text;
    if (t) yield t;
  }
}

async function* claudeStream({ images, text, conversation = [], system }) {
  const { default: Anthropic } = await import("@anthropic-ai/sdk");
  const client = new Anthropic();
  const content = [];
  for (const im of images) {
    content.push({ type: "text", text: im.label });
    content.push({ type: "image", source: { type: "base64", media_type: im.mime, data: im.data } });
  }
  content.push({ type: "text", text });
  const stream = client.beta.messages.stream({
    model: MODEL,
    max_tokens: 2000,
    system: [{ type: "text", text: system || SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
    messages: [...conversation.map((turn) => ({ role: turn.role, content: turn.text })), { role: "user", content }],
    output_config: { effort: process.env.HALO_EFFORT || "low" },
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
  });
  for await (const ev of stream) {
    if (ev.type === "content_block_delta" && ev.delta.type === "text_delta") yield ev.delta.text;
  }
  const final = await stream.finalMessage();
  if (final.stop_reason === "refusal") throw new Error("The model declined to answer this one.");
}

// ---------- images for hard concepts ----------
const IMAGE_MODEL = process.env.GEMINI_IMAGE_MODEL || "gemini-2.5-flash-image";
const IMAGE_STYLE =
  "Draw this as a clean whiteboard-style educational diagram: blue marker on a plain white background, " +
  "simple hand-drawn shapes and arrows, minimal, no shading, no photo realism, only short labels if essential. Subject: ";

/** Returns { mime, data } (base64) or null. */
export async function generateImage(prompt) {
  if (!process.env.GEMINI_API_KEY) return null;
  try {
    const { GoogleGenAI } = await import("@google/genai");
    const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
    const t = Date.now();
    const r = await ai.models.generateContent({
      model: IMAGE_MODEL,
      contents: IMAGE_STYLE + prompt,
      config: { responseModalities: ["IMAGE", "TEXT"], httpOptions: { timeout: 20000 } },
    });
    const part = (r.candidates?.[0]?.content?.parts || []).find((p) => p.inlineData);
    if (!part) return null;
    console.log(`[image] ${IMAGE_MODEL} ${Date.now() - t}ms — ${prompt.slice(0, 60)}`);
    return { mime: part.inlineData.mimeType || "image/png", data: part.inlineData.data };
  } catch (e) {
    console.warn("[image] failed:", e.message.slice(0, 160));
    return null;
  }
}


/** The JSON object in a model reply, tolerating code fences and stray prose around it. Throws if there isn't one. */
export function parseJSON(raw) {
  const cleaned = String(raw ?? "").replace(/```[a-z]*|```/g, "").trim();
  const m = cleaned.match(/\{[\s\S]*\}/);
  return JSON.parse(m ? m[0] : cleaned);
}

async function rawJSON({ images, text, system, temperature }) {
  if (PROVIDER === "claude") {
    let raw = "";
    for await (const d of claudeStream({ images, text, system })) raw += d;
    return raw;
  }
  const { GoogleGenAI } = await import("@google/genai");
  const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
  const parts = [];
  for (const im of images) { parts.push({ text: im.label }); parts.push({ inlineData: { mimeType: im.mime, data: im.data } }); }
  parts.push({ text });
  const config = { systemInstruction: system, maxOutputTokens: 4000, temperature, responseMimeType: "application/json" };
  if (/gemini-2\./i.test(MODEL)) config.thinkingConfig = { thinkingBudget: Number(process.env.GEMINI_THINKING_BUDGET ?? 0) };
  else config.thinkingConfig = { thinkingLevel: process.env.GEMINI_THINKING_LEVEL || "minimal" };
  const r = await ai.models.generateContent({ model: MODEL, contents: [{ role: "user", parts }], config });
  return r.text || "";
}

/**
 * One-shot JSON answer (digest, recap, notes, lessons, web plans). Returns a parsed object or throws.
 * Now and then the model returns JSON that doesn't parse (an unescaped quote, a cut-off reply). That is a
 * one-off slip, so it gets one more try, a little cooler, before the caller sees an error.
 */
export async function generateJSON({ images = [], text, system }) {
  let raw = await rawJSON({ images, text, system, temperature: 0.5 });
  try { return parseJSON(raw); } catch (first) {
    console.warn(`[json] unreadable reply (${first.message}), trying again. It began: ${raw.slice(0, 160).replace(/\s+/g, " ")}`);
  }
  raw = await rawJSON({ images, text, system, temperature: 0.2 });
  try { return parseJSON(raw); } catch (second) {
    console.warn(`[json] unreadable again: ${raw.slice(0, 160).replace(/\s+/g, " ")}`);
    throw new Error("Halo got a garbled answer back from the model. Please try again.");
  }
}
