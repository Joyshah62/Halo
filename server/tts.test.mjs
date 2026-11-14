import { test } from "node:test";
import assert from "node:assert/strict";
process.env.ELEVENLABS_API_KEY = "local-test-key";
const { speak } = await import("./tts.js");

test("a hung voice service times out and lets the answer continue without audio", async (t) => {
  // No request leaves this process. The fake service only responds to cancellation.
  t.mock.method(globalThis, "fetch", async (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  }));
  const keepAlive = setTimeout(() => {}, 1000);
  try { assert.equal(await speak("Local test speech", { timeoutMs: 30 }), null); }
  finally { clearTimeout(keepAlive); }
});
