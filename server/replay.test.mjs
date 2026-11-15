import test from "node:test";
import assert from "node:assert/strict";
import { similar, inScope, matchReply } from "./replay.js";

test("questions match loosely, but numbers must agree", () => {
  assert.equal(similar("What is BM25?", "what is bm25"), 1);
  assert.ok(similar("why does it normalize by document length", "why does it normalise by the document length") >= 0.75);
  assert.equal(similar("the answer is 4", "the answer is 5"), 0);
  assert.ok(similar("explain this", "what is a vector database") < 0.75);
});

test("only the demo document is recorded, unless told otherwise", () => {
  const before = process.env.HALO_REPLAY_MATCH;
  delete process.env.HALO_REPLAY_MATCH;
  assert.equal(inScope("AI Engineering (Chip Huyen)-354-397 · Page 3"), true);
  assert.equal(inScope("Lesson", "", "Imagine you work for an ecommerce site called Kitty Vogue"), true);
  assert.equal(inScope("A Little Calculus · Page 2", "the chain rule"), false);
  process.env.HALO_REPLAY_MATCH = "*";
  assert.equal(inScope("anything"), true);
  if (before === undefined) delete process.env.HALO_REPLAY_MATCH; else process.env.HALO_REPLAY_MATCH = before;
});

test("a lesson reply replays only the branch it matches", () => {
  const node = { children: [
    { reply: { action: "answer", answer: "you bring the power down and subtract one" }, id: "right" },
    { reply: { action: "answer", answer: "no idea" }, id: "lost" },
    { reply: { action: "jump", answer: "", concept: 3 }, id: "jump3" },
  ] };
  assert.equal(matchReply(node, { action: "answer", answer: "You bring the power down, and subtract one." })?.id, "right");
  assert.equal(matchReply(node, { action: "answer", answer: "No idea!" })?.id, "lost");
  assert.equal(matchReply(node, { action: "answer", answer: "it doubles" }), undefined);
  assert.equal(matchReply(node, { action: "jump", answer: "", concept: 3 })?.id, "jump3");
  assert.equal(matchReply(node, { action: "jump", answer: "", concept: 2 }), undefined);
});
