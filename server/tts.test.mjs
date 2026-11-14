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

test("a clip refused for concurrency is tried again and still arrives", async (t) => {
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => {
    calls++;
    if (calls === 1) return new Response("too_many_concurrent_requests", { status: 429 });
    return new Response(Buffer.from("mp3-bytes"), { status: 200 });
  });
  assert.equal(await speak("Retry me"), Buffer.from("mp3-bytes").toString("base64"));
  assert.equal(calls, 2);
});

test("no more than three voice requests run at once, and all of them finish", async (t) => {
  let live = 0, most = 0;
  t.mock.method(globalThis, "fetch", async () => {
    live++; most = Math.max(most, live);
    await new Promise((resolve) => setTimeout(resolve, 20));
    live--;
    return new Response(Buffer.from("a"), { status: 200 });
  });
  const clips = await Promise.all(Array.from({ length: 8 }, (_, i) => speak(`step ${i}`)));
  assert.equal(clips.filter(Boolean).length, 8);
  assert.ok(most <= 3, `ran ${most} at once`);
});

test("a rejected key is not retried", async (t) => {
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => { calls++; return new Response("invalid_api_key", { status: 401 }); });
  assert.equal(await speak("No key"), null);
  assert.equal(calls, 1);
});
