import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const moduleURL = new URL("./logging.js", import.meta.url).href;
async function child(directory, body) {
  return new Promise((resolve, reject) => {
    const process = spawn(globalThis.process.execPath, ["--input-type=module", "-e", `import { log, errorDetails, installProcessLogging } from ${JSON.stringify(moduleURL)}; ${body}`], {
      env: { ...globalThis.process.env, HALO_LOG_DIR: directory }, stdio: "ignore",
    });
    process.on("error", reject); process.on("exit", (code) => resolve(code));
  });
}
test("diagnostic logs survive restarts and record crashes without exposing credentials", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "halo-log-test-"));
  try {
    assert.equal(await child(directory, 'installProcessLogging(); log("test.request", { request: "test-1" });'), 0);
    assert.equal(await child(directory, 'installProcessLogging(); throw new Error("Synthetic failure api_key=local-secret-value");'), 1);
    const text = await readFile(path.join(directory, "server.jsonl"), "utf8");
    const rows = text.trim().split("\n").map(JSON.parse);
    assert.equal(rows.filter((r) => r.event === "server.boot").length, 2);
    assert.ok(rows.some((r) => r.event === "test.request" && r.request === "test-1"));
    assert.ok(rows.some((r) => r.event === "process.crash"));
    assert.ok(rows.some((r) => r.event === "process.exit" && r.code === 1));
    assert.ok(!text.includes("local-secret-value"));
  } finally { await rm(directory, { recursive: true, force: true }); }
});
