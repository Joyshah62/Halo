import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const runtime = fileURLToPath(new URL("./http-runtime.js", import.meta.url));
const fixture = fileURLToPath(new URL("./test-fixtures/http-peer-close.mjs", import.meta.url));

for (const mode of ["length", "eof", "length-truncated", "chunked-truncated"]) {
  test(`HTTP peer close with paused ${mode} body does not crash or hang`, async () => {
    const result = await run(process.execPath, ["--import", runtime, fixture, mode], { timeout: 5000 });
    assert.equal(result.stderr, "");
  });
}
