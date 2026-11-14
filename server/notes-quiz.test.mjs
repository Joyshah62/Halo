import { test } from "node:test";
import assert from "node:assert/strict";
import { readNotes, questionCount, shuffled, cleanQuiz, cleanGrade } from "./notes-quiz.js";

const choice = (over = {}) => ({ kind: "choice", ask: "Why multiply by the inside derivative?", options: ["Chain rule", "Power rule", "Product rule", "Quotient rule"], answer: 0, explain: "Outside' times inside'.", source: "outside' x inside'", ...over });
const short = (over = {}) => ({ kind: "short", ask: "What does the power rule do?", expected: "Brings the exponent down and reduces it by one", explain: "", source: "", ...over });

test("notes: empty ones dropped, total length capped", () => {
  const notes = readNotes([{ title: "A", text: "  " }, { title: "B", text: "x".repeat(10000) }, { title: "C", text: "y".repeat(10000) }, { text: "late" }]);
  assert.equal(notes.length, 2);
  assert.equal(notes.reduce((n, x) => n + x.text.length, 0), 14000);
  assert.deepEqual(readNotes("nope"), []);
});

test("question count grows with the notes, from 5 to 8", () => {
  assert.equal(questionCount([{ text: "a few words" }]), 5);
  assert.equal(questionCount([{ text: "word ".repeat(2000) }]), 8);
});

test("shuffling keeps track of the right option", () => {
  const options = ["right", "b", "c", "d"];
  for (let seed = 0; seed < 20; seed++) {
    let s = seed; const random = () => ((s = (s * 9301 + 49297) % 233280) / 233280);
    const out = shuffled(options, 0, random);
    assert.equal(out.options[out.answer], "right");
    assert.deepEqual([...out.options].sort(), [...options].sort());
  }
});

test("quiz: good questions kept, broken ones dropped or turned into short answers", () => {
  const quiz = cleanQuiz({ title: "Chain rule", questions: [
    choice(), short(),
    choice({ options: ["same", "same", "x", "y"] }),            // duplicate options → short answer from the right option
    choice({ answer: 9 }),                                        // no right option → dropped
    { kind: "short", ask: "", expected: "x" },                    // no question → dropped
    short({ expected: "" }),                                      // nothing to mark against → dropped
  ] }, { random: () => 0.5 });
  assert.equal(quiz.title, "Chain rule");
  assert.deepEqual(quiz.questions.map((q) => q.kind), ["choice", "short", "short"]);
  assert.equal(quiz.questions[0].options[quiz.questions[0].answer], "Chain rule");
  assert.equal(quiz.questions[2].expected, "same");
});

test("quiz: too few usable questions is an error the student can act on", () => {
  assert.throws(() => cleanQuiz({ questions: [short()] }), /Add a little more/);
  assert.throws(() => cleanQuiz(null), /couldn't write a quiz/);
});

test("grade: unknown verdicts count as wrong, and a verdict opener is cut", () => {
  assert.equal(cleanGrade({ verdict: "maybe", say: "Hmm" }).verdict, "wrong");
  assert.equal(cleanGrade({ verdict: "right", say: "Spot on! The exponent comes down and drops by one." }).say, "The exponent comes down and drops by one.");
  assert.ok(cleanGrade({ verdict: "right" }).say.length > 0);
});
