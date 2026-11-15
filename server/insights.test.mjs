import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { readItems, cleanInsights, fallbackInsights, withWeakSpots } from "./insights.js";
import { MEMORY_DIR, learnerKey, recordInsights, weakSpots } from "./learner-memory.js";

const items = readItems([
  { ask: "What is the derivative of x cubed?", expected: "3x squared", answer: "3x^2", verdict: "right", source: "power rule" },
  { ask: "Why multiply by 2x?", expected: "the inside's derivative", answer: "no idea", verdict: "wrong", source: "outside' × inside'" },
  { ask: "", verdict: "right" },
]);

test("readItems drops empty questions and unknown verdicts become wrong", () => {
  assert.equal(items.length, 2);
  assert.equal(readItems([{ ask: "Q", verdict: "great" }])[0].verdict, "wrong");
});

test("cleanInsights keeps at most three, drops repeats, and only accepts improved spots from the earlier list", () => {
  const raw = {
    strengths: [{ point: "Power rule.", why: "You brought the 3 down." }, { point: "power rule", why: "dup" }, { point: "a" }, { point: "b" }, { point: "c" }],
    weaknesses: [{ point: "derivative of the inside function", next: "Write outside' × inside' first." }],
    improved: ["Spotting The Inside", "made up"],
  };
  const out = cleanInsights(raw, { earlier: ["spotting the inside"], items });
  assert.deepEqual(out.strengths.map((s) => s.point), ["power rule", "a", "b"]);
  assert.equal(out.weaknesses[0].next, "Write outside' × inside' first.");
  assert.deepEqual(out.improved, ["spotting the inside"]);
});

test("cleanInsights takes a weakness's next step even when the model filed it under why", () => {
  const out = cleanInsights({ weaknesses: [{ point: "inner derivatives", why: "Label inner and outer first." }] }, { items });
  assert.equal(out.weaknesses[0].next, "Label inner and outer first.");
});

test("cleanInsights drops strengths when nothing was right, and weaknesses when everything was", () => {
  const raw = { strengths: [{ point: "x" }], weaknesses: [{ point: "y" }] };
  assert.equal(cleanInsights(raw, { items: [{ verdict: "wrong" }] }).strengths.length, 0);
  assert.equal(cleanInsights(raw, { items: [{ verdict: "right" }] }).weaknesses.length, 0);
});

test("fallbackInsights turns right and missed questions into points", () => {
  const out = fallbackInsights(items);
  assert.deepEqual(out.strengths.map((s) => s.point), ["power rule"]);
  assert.deepEqual(out.weaknesses.map((w) => w.point), ["outside' × inside'"]);
  assert.match(out.weaknesses[0].next, /inside's derivative/);
});

test("recordInsights saves weak spots and strengths, and improved spots come off", async () => {
  const id = `insights-${Date.now()}`, key = learnerKey(id);
  await recordInsights(key, { how: "quiz", title: "Chain rule", strengths: [{ point: "power rule" }], weaknesses: [{ point: "derivative of the inside" }, { point: "product vs chain" }] });
  await recordInsights(key, { how: "lesson", title: "Chain rule", weaknesses: [{ point: "derivative of the inside" }], improved: ["product vs chain"] });
  const file = readFileSync(path.join(MEMORY_DIR, `${key}.md`), "utf8");
  assert.match(file, /- derivative of the inside \| chain rule \| seen 2 time\(s\) \| lesson/);
  assert.match(file, /- power rule \| quiz \| strength \| chain rule \|/);
  assert.doesNotMatch(file, /product vs chain/);
  assert.deepEqual(await weakSpots(key), ["derivative of the inside"]);
  const learner = await withWeakSpots({ name: "A" }, id);
  assert.deepEqual(learner, { name: "A", weaknesses: ["derivative of the inside"] });
});
