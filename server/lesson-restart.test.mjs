import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const lessonURL = new URL("./lesson.js", import.meta.url).href;
async function run(directory, code) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--no-warnings", "--input-type=module", "-e", `import { startLesson, continueLesson } from ${JSON.stringify(lessonURL)}; const events = []; const send = (event, data) => events.push([event, data]); ${code}; console.log("RESULT:" + JSON.stringify({result, events}));`], {
      env: { ...process.env, HALO_MOCK: "1", ELEVENLABS_API_KEY: "", BACKBOARD_API_KEY: "", HALO_DB_PATH: ":memory:", HALO_LESSON_DB_PATH: path.join(directory, "lessons.sqlite"), HALO_MEMORY_DIR: path.join(directory, "memory") },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => { stdout += d; }); child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code !== 0) return reject(new Error(stderr));
      try { resolve(JSON.parse(stdout.split("\n").find((line) => line.startsWith("RESULT:")).slice(7))); } catch (error) { reject(error); }
    });
  });
}
test("lessons resume after a process restart and completed replies replay after another restart", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "halo-lesson-restart-"));
  try {
    const first = await run(directory, `const result = await startLesson({title:"Calculus",pages:[{page:1,text:"The power rule"},{page:2,text:"The chain rule"}]},send)`);
    assert.ok(first.result.waiting);
    const id = first.result.id;
    const reply = { answer: "three x", action: "answer", requestID: "restart-test-reply" };
    const code = `const result = await continueLesson(${JSON.stringify(id)},${JSON.stringify(reply)},send)`;
    const resumed = await run(directory, code);
    assert.ok(resumed.events.some(([event]) => event === "step"));
    assert.ok(resumed.events.some(([event]) => event === "question"));
    const replayed = await run(directory, code);
    assert.deepEqual(replayed, resumed);
    const next = await run(directory, `const result = await continueLesson(${JSON.stringify(id)},{answer:"bring the exponent down and subtract one",action:"answer",requestID:"next-reply"},send)`);
    assert.ok(next.events.some(([event, data]) => event === "grade" && data.verdict === "got_it"));
  } finally { await rm(directory, { recursive: true, force: true }); }
});
