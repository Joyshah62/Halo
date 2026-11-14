import { test, after } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
const directory = await mkdtemp(join(tmpdir(), "halo-runtime-"));
const target = join(directory, "runtime.mjs");
await build({ entryPoints: [fileURLToPath(new URL("../src/shared/runtime.ts", import.meta.url))], outfile: target, bundle: true, platform: "node", format: "esm" });
after(() => rm(directory, { recursive: true, force: true }));
let counter = 0;
const fresh = () => import(`${pathToFileURL(target).href}?test=${counter++}`);
test("synchronous invalidation is caught and recovery runs once", async () => {
  globalThis.chrome = { runtime: { id: "halo", sendMessage() { throw new Error("Extension context invalidated."); } } };
  const runtime = await fresh(); let recoveries = 0;
  runtime.onRuntimeInvalidated(() => recoveries++);
  assert.equal(await runtime.sendRuntimeMessage({ type: "CAPTURE" }), null);
  assert.equal(await runtime.sendRuntimeMessage({ type: "LISTEN_STOP" }), null);
  assert.equal(recoveries, 1);
});
test("asynchronous invalidation also triggers recovery", async () => {
  globalThis.chrome = { runtime: { id: "halo", sendMessage: async () => { throw new Error("Extension context invalidated."); } } };
  const runtime = await fresh(); let recovered = false;
  runtime.onRuntimeInvalidated(() => { recovered = true; });
  assert.equal(await runtime.sendRuntimeMessage({ type: "CAPTURE" }), null);
  assert.equal(recovered, true);
});
test("a removed runtime is detected without making another API call", async () => {
  let calls = 0;
  globalThis.chrome = { runtime: { id: undefined, sendMessage: () => { calls++; } } };
  const runtime = await fresh();
  assert.equal(await runtime.sendRuntimeMessage({ type: "CAPTURE" }), null);
  assert.equal(calls, 0);
});
test("ordinary connection failures do not invalidate the extension", async () => {
  globalThis.chrome = { runtime: { id: "halo", sendMessage: async () => { throw new Error("Could not establish connection. Receiving end does not exist."); } } };
  const runtime = await fresh(); let recoveries = 0;
  runtime.onRuntimeInvalidated(() => recoveries++);
  assert.equal(await runtime.sendRuntimeMessage({ type: "CAPTURE" }), null);
  assert.equal(runtime.runtimeAvailable(), true);
  assert.equal(recoveries, 0);
});
