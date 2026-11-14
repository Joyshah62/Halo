// "Halo watches you work": a LangGraph agent that looks at a student's handwritten working and,
// when a line doesn't follow from the one before, says where to look without giving the answer.
//
//   read ──► verify ──► (every step checks out) ──────────────► respond   ✓
//                  └──► judge ──► (confirmed wrong) ──────────► respond   coral circle + hint
//                             └─► (not sure / fine) ──────────► respond   stay quiet
//
// read    Gemini vision transcribes each line, where it sits on the image, and how it should follow.
// verify  A math tool (mathjs, numeric) tests each step. The model never gets to "feel" that algebra is wrong.
// judge   Only runs when a step failed or couldn't be tested. It re-looks at the image with the tool's
//         evidence; a mistake is flagged only when it agrees. It also writes the hint.
//
// Correct work costs one model call. Set LANGSMITH_TRACING=true + LANGSMITH_API_KEY to see every run.
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";
import { ChatGoogleGenerativeAI } from "@langchain/google-genai";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { tool } from "@langchain/core/tools";
import { z } from "zod";
import { checkStep } from "./mathcheck.js";
import { describeLearner } from "./prompt.js";

const CHECK_MODEL = process.env.HALO_CHECK_MODEL || (/^gemini/i.test(process.env.HALO_MODEL || "") ? process.env.HALO_MODEL : "gemini-3.5-flash");
const isMock = () => process.env.HALO_MOCK === "1";

function gemini(thinkingLevel) {
  const options = { model: CHECK_MODEL, apiKey: process.env.GEMINI_API_KEY, temperature: 0.1, maxOutputTokens: 3000 };
  // Gemini 2.x takes a token budget; Gemini 3+ takes a level and rejects budget 0 (same rule as llm.js).
  options.thinkingConfig = /gemini-2\./i.test(CHECK_MODEL) ? { thinkingBudget: 0 } : { thinkingLevel };
  return new ChatGoogleGenerativeAI(options);
}

// ---------- tool ----------
const RELATIONS = ["same_solutions", "equal_value", "derivative_of_previous", "none"];

export const checkStepTool = tool(
  async ({ previous, current, relation, variable }) => checkStep(previous, current, relation, variable || "x"),
  {
    name: "check_step",
    description: "Numerically test whether one line of working follows from the line before it. Returns ok, mismatch (with evidence) or unknown.",
    schema: z.object({
      previous: z.string().describe("the earlier line, in calculator syntax"),
      current: z.string().describe("the line that should follow from it"),
      relation: z.enum(["same_solutions", "equal_value", "derivative_of_previous"]),
      variable: z.string().optional(),
    }),
  },
);

// ---------- read ----------
const Reading = z.object({
  problem: z.string().describe("What the student is trying to do, in a few words, e.g. 'solve 2x + 3 = 7 for x'. Empty if there is no working."),
  topic: z.string().describe("2-4 word topic, lowercase, e.g. 'chain rule', 'linear equations'"),
  variable: z.string().describe("The main variable, e.g. x"),
  lines: z.array(z.object({
    n: z.number().describe("1-based, top to bottom"),
    source: z.enum(["printed", "handwritten"]),
    text: z.string().describe("The line exactly as written, with Unicode math (x², √, ·)"),
    math: z.string().describe("The same line in calculator syntax, or empty if it isn't math"),
    follows: z.enum(RELATIONS).describe("How this line is meant to follow from the line before it"),
    box_2d: z.array(z.number()).describe("[ymin, xmin, ymax, xmax] of this line on the image, each 0-1000"),
  })),
});

const READ_SYSTEM = `You read a student's handwritten working so that each step can be checked by a calculator. You do not judge it. Transcribe exactly what is written, including mistakes: never correct anything, never fill in a step the student skipped.

The image shows part of a page. It may contain a printed problem and the student's handwriting below or beside it. List the printed problem statement first (source "printed") if it is visible and is what the working starts from, then each handwritten line of working, top to bottom, one entry per line. If one handwritten line contains a chain like "a = b = c", split it into separate entries. Ignore the student's doodles, page numbers and unrelated text. If there is no working at all, return an empty "lines" list.

"math" is the line in calculator syntax: + - * / ^, parentheses, sqrt(), sin(), cos(), tan(), log() for natural log, exp(), abs(), pi. Write multiplication between two letters explicitly (m*a, not ma). Equations keep their "=". Leave "math" empty for words, ±, inequalities, integrals, limits, vectors or anything that syntax can't express.
- When the left side is only a name for the thing being worked out (y =, f(x) =, f'(x) =, dy/dx =, or a line starting with "="), drop it and give just the expression.
- Write "the derivative of E with respect to x" as diff(E, x).

"follows" is how the line is MEANT to follow from the entry directly before it (the student's intent, whether or not they got it right):
- "same_solutions": both are equations and this one is the previous one rearranged or solved further.
- "equal_value": this expression should equal the previous one (simplifying, expanding, evaluating).
- "derivative_of_previous": this line is the result of differentiating the previous line.
- "none": the first entry, a new problem, a restated formula, a substitution of given numbers you can't relate, or anything else.

"box_2d" must tightly cover that one line of writing on the image.`;

const MOCK_READING = {
  problem: "differentiate (x² + 1)³", topic: "chain rule", variable: "x",
  lines: [
    { n: 1, source: "printed", text: "d/dx (x² + 1)³", math: "diff((x^2+1)^3, x)", follows: "none", box_2d: [120, 80, 200, 520] },
    { n: 2, source: "handwritten", text: "= 3(x² + 1)²", math: "3(x^2+1)^2", follows: "equal_value", box_2d: [300, 90, 390, 470] },
  ],
};

async function read(state) {
  if (isMock()) return { reading: MOCK_READING };
  const context = [];
  if (state.problem) context.push(`The problem being worked on (from the page): ${String(state.problem).slice(0, 600)}`);
  if (state.pageText) context.push(`Printed text near the working (for context only, do not list it unless it is the problem):\n${String(state.pageText).slice(0, 3000)}`);
  context.push("Transcribe the working in this image.");
  const reading = await gemini("MINIMAL").withStructuredOutput(Reading, { name: "reading" }).invoke([
    new SystemMessage(READ_SYSTEM),
    new HumanMessage({ content: [
      { type: "text", text: context.join("\n\n") },
      { type: "image_url", image_url: `data:${state.imageMime};base64,${state.image}` },
    ] }),
  ]);
  const lines = (Array.isArray(reading.lines) ? reading.lines : []).slice(0, 24).map((l, i) => ({ ...l, n: i + 1 }));
  return { reading: { ...reading, lines } };
}

// ---------- verify ----------
async function verify(state) {
  const { lines, variable } = state.reading;
  const checks = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.source !== "handwritten" || line.follows === "none") continue;
    const outcome = line.math && lines[i - 1].math
      ? await checkStepTool.invoke({ previous: lines[i - 1].math, current: line.math, relation: line.follows, variable })
      : { result: "unknown", evidence: "not written in a form the calculator can test" };
    checks.push({ line: line.n, ...outcome });
  }
  return { checks };
}

function afterVerify(state) {
  const { checks } = state;
  if (!checks.length) return "respond";                              // nothing to check yet
  if (checks.every((c) => c.result === "ok")) return "respond";      // all good: no second model call
  return "judge";
}

// ---------- judge ----------
const Judgement = z.object({
  verdict: z.enum(["wrong", "fine", "unsure"]),
  line: z.number().describe("The number of the first handwritten line that is wrong (0 if none)"),
  kind: z.enum(["slip", "concept"]).describe("slip = a careless error by someone who knows the method; concept = they don't seem to know the rule"),
  concept: z.string().describe("The rule or idea involved, 2-5 words, e.g. 'chain rule: inner derivative'"),
  say: z.string().describe("What you say out loud, 1-2 short sentences, at most 28 words"),
  write: z.string().describe("What you jot on the note, at most 28 characters, Unicode math, no LaTeX"),
  look: z.number().describe("Another line (printed or handwritten) your hint sends them back to, which Halo underlines while you speak; 0 if none"),
});

const JUDGE_SYSTEM = `You are Halo: a warm, sharp human tutor sitting next to a student, watching them work a problem by hand. They paused. A calculator has tested each step of their working and found one that doesn't hold, or one it couldn't test. Look at the image yourself and decide.

The transcription was made by a machine and can be wrong. Decide from the image, not from the transcription.
- "wrong": you can see the mistake in the handwriting itself, on a specific line, and you would bet on it. If the calculator found a mismatch, check that the line really says what the transcription claims before agreeing.
- "fine": the working is correct as written (the calculator was fed a misreading, or the untested step is right).
- "unsure": the handwriting is ambiguous, the step is unfinished, or you can't tell. When in doubt choose this. Interrupting a student who is right is far worse than staying quiet.
"line" is the number of the first HANDWRITTEN line that fails to follow from the line above it. Never give the number of a printed line: if the student mis-copied or mis-expanded the printed problem, the wrong line is their first line.

If "wrong", give a hint, never the fix:
- "say": talk like a person, to the student, about their actual numbers and symbols. Point at where to look and why it's worth a second look, and stop there. Do NOT state the corrected line, the right value, or the final answer. Contractions. No "Great job", no "Oops", no "I noticed", no "it seems". A small "hold on" or "one sec" is fine.
  Slip → name the move they made ("check the sign when you moved that 3 over").
  Concept → ask the question that exposes the missing piece ("you took care of the outside... what about the inside?").
- "write": the nudge in a few characters, as a teacher would scribble it: "sign?", "inside′ = ?", "3 × (−2) = ?", "both sides ÷ 2".
- "look": when the hint sends them back to a different line ("look at the original problem", "compare with the line above"), its number, so Halo can underline it on the page while you speak. Make "say" refer to it ("this line up here"). Never the wrong line itself (that one is already circled). 0 if none.
- No LaTeX or markdown. In "say", speak math in words ("x squared").
If not "wrong", leave "say" and "write" empty and "line" and "look" 0.`;

async function judge(state) {
  const { reading, checks } = state;
  if (isMock()) {
    return { judgement: { verdict: "wrong", line: 2, kind: "concept", concept: "chain rule: inner derivative",
      say: "Hold on... you brought the 3 down and dropped the power, nice. But what's inside those parentheses up here?", write: "× inside′ = ?", look: 1 } };
  }
  const byLine = new Map(checks.map((c) => [c.line, c]));
  const listing = reading.lines.map((l) => {
    const c = byLine.get(l.n);
    const tested = c ? `   ← calculator: ${c.result.toUpperCase()}${c.evidence ? ` (${c.evidence})` : ""}` : "";
    return `${l.n}. [${l.source}] ${l.text}${tested}`;
  }).join("\n");
  const parts = [];
  const who = describeLearner(state.learner);
  if (who) parts.push(who);
  parts.push(`Problem: ${reading.problem || state.problem || "(see image)"}`);
  parts.push(`Machine transcription of the working, with the calculator's result for each step:\n${listing}`);
  parts.push("Look at the image and give your judgement.");
  const judgement = await gemini("LOW").withStructuredOutput(Judgement, { name: "judgement" }).invoke([
    new SystemMessage(JUDGE_SYSTEM),
    new HumanMessage({ content: [
      { type: "text", text: parts.join("\n\n") },
      { type: "image_url", image_url: `data:${state.imageMime};base64,${state.image}` },
    ] }),
  ]);
  return { judgement };
}

// ---------- respond ----------
/** Gemini's [ymin, xmin, ymax, xmax] in 0-1000 → { x, y, w, h } in 0-1 of the image, top-left origin. */
function toBox(b) {
  if (!Array.isArray(b) || b.length !== 4 || b.some((v) => !Number.isFinite(Number(v)))) return null;
  const [y0, x0, y1, x1] = b.map((v) => Math.min(1000, Math.max(0, Number(v))) / 1000);
  const x = Math.min(x0, x1), y = Math.min(y0, y1), w = Math.abs(x1 - x0), h = Math.abs(y1 - y0);
  const r = (v) => Math.round(v * 1000) / 1000;
  return w > 0.005 && h > 0.005 ? { x: r(x), y: r(y), w: r(w), h: r(h) } : null;
}

function respond(state) {
  const { reading, checks = [], judgement } = state;
  const lines = reading.lines.map((l) => ({ n: l.n, source: l.source, text: String(l.text).slice(0, 120), box: toBox(l.box_2d) }));
  const handwritten = lines.filter((l) => l.source === "handwritten");
  const base = { topic: String(reading.topic || "").toLowerCase().slice(0, 60), problem: String(reading.problem || "").slice(0, 160), lines, checks };

  if (!handwritten.length || !checks.length) return { verdict: { status: "nothing", ...base }, steps: [] };

  if (!judgement) {
    // Every step passed the calculator. The ✓ goes on the last line they wrote.
    const last = handwritten[handwritten.length - 1];
    return { verdict: { status: "correct", line: last.n, box: last.box, ...base }, steps: [] };
  }

  // Where the circle goes: the calculator's first failing line when it found one (the tutor sometimes names
  // the printed line the mistake came from instead). The tutor's own line only counts for steps the calculator couldn't test.
  const failed = checks.find((c) => c.result === "mismatch")?.line;
  const flagged = lines.find((l) => l.n === (failed ?? Number(judgement.line)) && l.source === "handwritten");
  const say = String(judgement.say || "").trim();
  if (judgement.verdict === "wrong" && flagged && say) {
    const write = String(judgement.write || "").trim().slice(0, 32);
    const ink = write ? [{ type: "text", value: write }, { type: "underline", target: "previous" }] : [];
    // The line the hint sends them back to gets underlined on the page while it is spoken.
    const look = lines.find((l) => l.n === Number(judgement.look) && l.n !== flagged.n && l.box);
    if (look) ink.push({ type: "point", line: look.n, style: "underline" });
    return {
      verdict: { status: "wrong", line: flagged.n, box: flagged.box, kind: judgement.kind === "concept" ? "concept" : "slip",
        concept: String(judgement.concept || "").slice(0, 60), ...base },
      steps: [{ say, ink }],
    };
  }
  // The calculator objected but the tutor didn't see it in the handwriting: likely a misread. Stay quiet.
  const disputed = checks.some((c) => c.result === "mismatch");
  if (judgement.verdict === "fine" && !disputed) {
    const last = handwritten[handwritten.length - 1];
    return { verdict: { status: "correct", line: last.n, box: last.box, ...base }, steps: [] };
  }
  return { verdict: { status: "unsure", ...base }, steps: [] };
}

// ---------- graph ----------
const TutorState = Annotation.Root({
  image: Annotation(), imageMime: Annotation(), pageText: Annotation(), problem: Annotation(), learner: Annotation(),
  reading: Annotation(), checks: Annotation(), judgement: Annotation(), verdict: Annotation(), steps: Annotation(),
});

export const tutorGraph = new StateGraph(TutorState)
  .addNode("read", read)
  .addNode("verify", verify)
  .addNode("judge", judge)
  .addNode("respond", respond)
  .addEdge(START, "read")
  .addEdge("read", "verify")
  .addConditionalEdges("verify", afterVerify, { judge: "judge", respond: "respond" })
  .addEdge("judge", "respond")
  .addEdge("respond", END)
  .compile();

/**
 * Run the check, reporting each node as it finishes.
 * @param {{ image: string, imageMime?: string, pageText?: string, problem?: string, learner?: object }} input
 * @param {(stage: "read"|"verify"|"judge"|"respond") => void} [onStage]
 * @returns {Promise<{ verdict: object, steps: { say: string, ink: object[] }[] }>}
 */
export async function checkWork(input, onStage) {
  let out = { verdict: { status: "unsure", lines: [], checks: [] }, steps: [] };
  const stream = await tutorGraph.stream(
    { image: input.image, imageMime: input.imageMime || "image/jpeg", pageText: input.pageText, problem: input.problem, learner: input.learner },
    { streamMode: "updates", runName: "halo-check-work", tags: ["halo", "check"] },
  );
  for await (const update of stream) {
    for (const [node, value] of Object.entries(update)) {
      onStage?.(node);
      if (node === "respond") out = value;
    }
  }
  return out;
}
