// "Why am I stuck?": a LangChain Deep Agent that finds the idea a student is missing.
//
// The checker (tutor.js) is a fixed LangGraph pipeline: read → verify → judge. It answers "which line is wrong?"
// in one or two model calls. What it cannot do is answer "what does this student not know yet, and where in
// their own book is it taught?". That takes an open-ended search, so it is a deep agent rather than a graph:
//
//   plan      write_todos: the agent lays out its own steps; they stream to the app as a live checklist.
//   book      the student's book is loaded into the agent's filesystem, one file per page (/book/page-012.md).
//             The agent greps and reads it instead of having 100 pages stuffed into the prompt.
//   scout     a "book-scout" subagent does the page hunt in its own context window and hands back only
//             { page, quote }, so the tutor's context holds the diagnosis, not the search.
//   check     the same check_step calculator the checker uses, to test a suspicion about the rule that was misapplied.
//   memory    /memories/<learner>.md is loaded into the prompt on every run. It is rebuilt from Backboard before the
//             run and synced back after it (learner-memory.js); without a Backboard key it is just a file in server/memory/.
//             The agent writes each gap it finds there, so the second time a gap shows up Halo knows it's a pattern.
//   answer    a typed Diagnosis (responseFormat), which the route turns into spoken steps and page marks.
//
// Everything under /book is read-only to the agent; the only place it may write is /memories.
import { createDeepAgent, CompositeBackend, StateBackend, FilesystemBackend } from "deepagents";
import { todoListMiddleware } from "langchain";
import { ChatGoogle } from "@langchain/google";
import { z } from "zod";
import { checkStepTool } from "./tutor.js";
import { describeLearner } from "./prompt.js";
import { MEMORY_DIR, TOPICS_HEADING, learnerKey, pullMemory, pushMemory } from "./learner-memory.js";

const STUCK_MODEL = process.env.HALO_STUCK_MODEL || process.env.HALO_CHECK_MODEL || (/^gemini/i.test(process.env.HALO_MODEL || "") ? process.env.HALO_MODEL : "gemini-3.5-flash");
const isMock = () => process.env.HALO_MOCK === "1";
const clip = (value, n) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, n);

// ChatGoogle (@langchain/google) rather than the checker's ChatGoogleGenerativeAI: the deep agent's built-in tools
// have JSON-schema features (nullable types, exclusiveMinimum) that only the newer integration translates for Gemini.
function gemini(thinkingLevel) {
  const options = { model: STUCK_MODEL, apiKey: process.env.GEMINI_API_KEY, temperature: 0.2, maxOutputTokens: 4000 };
  // Gemini 2.x takes a token budget; Gemini 3+ takes a level and rejects budget 0 (same rule as tutor.js).
  if (/gemini-2\./i.test(STUCK_MODEL)) options.thinkingBudget = 0; else options.thinkingLevel = thinkingLevel;
  return new ChatGoogle(options);
}

// ---------- the answer ----------
const Diagnosis = z.object({
  gap: z.string().describe("The one idea the student is missing, 2 to 6 words, lowercase, e.g. 'derivative of the inside function'"),
  why: z.string().describe("How missing that idea produced this exact mistake. One sentence, at most 30 words, about their numbers and symbols."),
  page: z.number().describe("The page of their book that teaches the missing idea (from book-scout). 0 if the book does not cover it."),
  quote: z.string().describe("A short phrase copied EXACTLY from that page, 3 to 12 words, that Halo highlights for the student. Empty if page is 0."),
  seenBefore: z.boolean().describe("True if this same gap is already in the learner's memory file."),
  steps: z.array(z.object({
    say: z.string().describe("What Halo says out loud: 1 or 2 short sentences, at most 30 words, contractions, maths in words"),
    write: z.string().describe("What Halo jots down beside it: at most 28 characters, Unicode maths, no LaTeX"),
  })).describe("2 or 3 steps: name the gap, send them to the page, connect it back to their line. Never the corrected line or the final answer."),
  question: z.string().describe("One small question that checks the missing idea on a fresh, simpler case. At most 24 words."),
});

const Passage = z.object({
  page: z.number().describe("The page number that teaches the idea, or 0 if no page does"),
  quote: z.string().describe("A phrase copied exactly, character for character, from that page: 3 to 12 words from the sentence that states the idea"),
  reason: z.string().describe("One sentence: why this is the page to send the student back to"),
});

// ---------- prompts ----------
const STUCK_SYSTEM = `You are Halo: a warm, sharp human tutor. A student made a mistake while solving a problem by hand and asked "why am I stuck?". The line that went wrong is already circled. Your job is the thing behind it: the ONE idea they are missing, and where in their own book it is taught.

Work like this. Tools can be called together in one turn; do that wherever the steps don't depend on each other, because the student is waiting.
1. First turn, all at once:
   - write_todos: 3 or 4 short items in plain student-facing words ("Work out which rule slipped", "Find it in your book", "Note it for next time"), the first one in_progress. The student watches this list.
   - check_step, if you want to test a suspicion about the line that went wrong against the line before it. It is a calculator and it is never wrong; you can be.
   - task with the book-scout subagent: give it the idea you think is missing, in the words a textbook would use, plus one or two synonyms. Their book is in /book, one file per page. Never read the book yourself.
2. Diagnose from what came back: the rule they were applying and the exact piece of it that is missing.
3. Your memory of this learner is the file shown above (sections may still be empty). It has two sections:
   - "# Gaps Halo has seen": ideas they were missing before. If this gap, or one closely related, is listed, this is a pattern: say so gently in your first step ("this is the same thing that caught you before").
   - "# Topics they have covered": lessons they did with Halo and problems they practised, with how it went and when. If the missing idea was covered (for example a lesson concept marked "got it"), connect to it ("you got this in the lesson on the chain rule... it's the same move here"). If it was marked "still learning" or "skipped", that explains the gap: say it kindly.
4. Second turn, together: record the gap in the memory file and tick the list off with write_todos.
   One line per gap, under "# Gaps Halo has seen", in the form "- <gap> | <topic> | seen <n> time(s) | p.<page>". If the gap is already listed, raise its count with edit_file instead of adding a line; otherwise add a line directly under that heading with edit_file. Never change the "# Topics they have covered" section; Halo keeps it. Never store the problem's answer there.
5. Only after those calls have returned, in a turn of its own, reply with the diagnosis.

Rules for what you say to the student:
- A missing prerequisite is usually one level BELOW the topic of the problem (stuck on the chain rule → cannot yet see which function is inside; stuck solving 2x + 3 = 7 → inverse operations). Name that, not the topic itself.
- Hint, never the fix. Do NOT state the corrected line, the right value, the missing term or the final answer, in "steps", "why" or anywhere else: the student reads all of it. Say where the hole is, not what fills it.
- Talk like a person sitting next to them, about their actual symbols. Contractions. No "Great job", "Oops", "I noticed", "it seems".
- "quote" must be copied exactly from the page the scout found, because the app searches the page for it.
- No LaTeX or markdown in anything the student sees. In "say", speak maths in words ("x squared").`;

const SCOUT_SYSTEM = `You find where a student's book teaches one idea. The book is in /book, one file per page, named page-001.md, page-002.md and so on (the number is the page number).

In your first turn, call grep on /book two or three times at once, each with a different word or phrase a textbook would use for the idea. Then read_file the one or two most promising pages (together, in one turn) to confirm. Prefer the page that EXPLAINS or DEFINES the idea (a rule, a definition, a first worked example) over pages that merely use it or exercises that test it.

Return the page number and a quote copied character for character from that page, 3 to 12 words, taken from the sentence that states the idea. If no page teaches it, return page 0 and an empty quote. Do not write any files.`;

// ---------- the agent ----------
const agents = new Map();

/** One agent per learner: the memory file it loads into its prompt is theirs. */
function agentFor(who) {
  if (agents.has(who)) return agents.get(who);
  const agent = createDeepAgent({
    name: "halo-stuck",
    model: gemini(process.env.HALO_STUCK_THINKING || "MINIMAL"),
    systemPrompt: STUCK_SYSTEM,
    tools: [checkStepTool],
    // Planning is opt-in in deepagents 1.16: this adds write_todos and the `todos` state the app's checklist is drawn from.
    middleware: [todoListMiddleware()],
    subagents: [{
      name: "book-scout",
      description: "Searches the student's book (/book) for the page that teaches a given idea. Give it the idea in a few words, plus synonyms a textbook might use. Returns { page, quote, reason }.",
      systemPrompt: SCOUT_SYSTEM,
      model: gemini("MINIMAL"),
      responseFormat: Passage,
      permissions: [{ operations: ["write"], paths: ["/**"], mode: "deny" }],
    }],
    // The book lives in graph state for this run only; the learner's memory is a real folder that outlives the server.
    backend: new CompositeBackend(new StateBackend(), { "/memories/": new FilesystemBackend({ rootDir: MEMORY_DIR, virtualMode: true }) }),
    memory: [`/memories/${who}.md`],
    permissions: [
      { operations: ["write"], paths: ["/memories/**"] },
      { operations: ["write"], paths: ["/**"], mode: "deny" },
    ],
    responseFormat: Diagnosis,
  });
  agents.set(who, { agent, memoryFile: `/memories/${who}.md` });
  return agents.get(who);
}

/** [{ page, text }] → the files the agent sees under /book. */
function bookFiles(pages) {
  const now = new Date().toISOString();
  const files = {};
  for (const p of pages) {
    const n = Math.round(Number(p?.page));
    const text = String(p?.text || "").trim();
    if (!Number.isFinite(n) || n < 1 || !text) continue;
    files[`/book/page-${String(n).padStart(3, "0")}.md`] = { content: `Page ${n}\n\n${text.slice(0, 6000)}`, mimeType: "text/markdown", created_at: now, modified_at: now };
  }
  return files;
}

function describeWork(input) {
  const parts = [];
  const who = describeLearner(input.learner);
  if (who) parts.push(who);
  if (input.title) parts.push(`Their book: ${clip(input.title, 120)}${input.chapter ? `, chapter "${clip(input.chapter, 120)}"` : ""}`);
  parts.push(`Problem: ${clip(input.problem, 300) || "(not given)"}`);
  const lines = (Array.isArray(input.lines) ? input.lines : []).slice(0, 24);
  if (lines.length) parts.push(`Their working (a machine transcription):\n${lines.map((l) => `${l.n}. [${l.source === "printed" ? "printed" : "handwritten"}] ${clip(l.text, 160)}${Number(l.n) === Number(input.line) ? "   ← the line that went wrong" : ""}`).join("\n")}`);
  if (input.concept) parts.push(`The checker's guess at the rule involved: ${clip(input.concept, 80)}`);
  if (input.hint) parts.push(`The hint Halo already gave (don't repeat it): "${clip(input.hint, 240)}"`);
  parts.push(`Your memory file for this learner is ${input.memoryFile}.`);
  if (input.covered?.length) parts.push(`What they have already covered with Halo (from that file; topic | how | result | where | last date | times):\n${input.covered.slice(-20).map((l) => `- ${l}`).join("\n")}\nIf one of these is the missing idea or the step just before it, your FIRST spoken step must connect to it by name ("remember the lesson on…", "you practised this on page…"). That is what makes this feel like a tutor who knows them.`);
  parts.push(`Find what they are missing and where their book teaches it.`);
  return parts.join("\n\n");
}

// ---------- progress ----------
/** What the agent is doing, in words a student would use. Tool calls are read off the model's messages as they stream. */
function describeCall(call, scout) {
  const a = call.args || {};
  switch (call.name) {
    case "task": return { name: "scout", say: "Looking through your book" };
    case "grep": return { name: "search", say: `Searching your book for “${clip(a.pattern, 40)}”` };
    case "glob": case "ls": return scout ? { name: "search", say: "Scanning the pages" } : null;
    case "read_file": {
      const page = String(a.file_path || "").match(/page-0*(\d+)/)?.[1];
      return page ? { name: "read", say: `Reading page ${page}`, page: Number(page) } : null;
    }
    case "check_step": return { name: "check", say: "Testing the step with a calculator" };
    case "write_file": case "edit_file": return /\/memories\//.test(String(a.file_path || "")) ? { name: "remember", say: "Remembering this for next time" } : null;
    default: return null;
  }
}

/** A quote the model "copied" is only used if it is really on a page; the page number follows the quote. */
function locate(pages, page, quote) {
  const squash = (s) => String(s || "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
  const want = squash(quote);
  const known = pages.find((p) => Number(p.page) === Number(page));
  if (want.length >= 8) {
    if (known && squash(known.text).includes(want)) return { page: Number(page), quote };
    const elsewhere = pages.find((p) => squash(p.text).includes(want));
    if (elsewhere) return { page: Number(elsewhere.page), quote };
  }
  return { page: known ? Number(page) : 0, quote: "" };
}

const MOCK = {
  todos: [
    { content: "Work out which rule slipped", status: "completed" },
    { content: "Find where your book teaches it", status: "completed" },
    { content: "Remember this for next time", status: "completed" },
  ],
  diagnosis: {
    gap: "derivative of the inside function", why: "You differentiated the cube but treated x² + 1 as if it were a plain x, so its own derivative never showed up.",
    page: 2, quote: "", seenBefore: false,
    steps: [
      { say: "Okay, here's what's underneath this. You're fine with the power rule... the missing piece is that the thing inside the brackets changes too.", write: "inside changes too" },
      { say: "Your book builds exactly this on page two. Have a look at how it treats the inside as its own function.", write: "p.2: inside = u" },
      { say: "So on your line... you've handled the outside. What does the inside do when x moves?", write: "u′ = ?" },
    ],
    question: "If u is x squared plus one, what's the derivative of u on its own?",
  },
};

/**
 * Finds the idea behind a mistake and where the student's book teaches it.
 * @param {{ problem?: string, lines?: { n: number, source: string, text: string }[], line?: number, concept?: string, hint?: string,
 *           title?: string, chapter?: string, pages: { page: number, text: string }[], learner?: object }} input
 * @param {(event: "todos"|"stage", data: object) => void} [emit]
 * @returns {Promise<{ gap: string, why: string, page: number, quote: string, seenBefore: boolean, question: string, steps: { say: string, ink: object[] }[] }>}
 */
export async function whyStuck(input, emit = () => {}) {
  const pages = (Array.isArray(input.pages) ? input.pages : []).filter((p) => p && Number.isFinite(Number(p.page)) && String(p.text || "").trim());
  let diagnosis;
  if (isMock()) {
    emit("todos", { todos: MOCK.todos });
    diagnosis = MOCK.diagnosis;
  } else {
    const who = learnerKey(input.learnerId);
    const memory = await pullMemory(who);
    const covered = memory.markdown.split(TOPICS_HEADING)[1]?.split("\n").filter((l) => l.startsWith("- ")).map((l) => l.slice(2)) || [];
    const { agent, memoryFile } = agentFor(who);
    const stream = await agent.stream(
      { messages: [{ role: "user", content: describeWork({ ...input, memoryFile, covered }) }], files: bookFiles(pages) },
      { streamMode: "updates", subgraphs: true, recursionLimit: 60, runName: "halo-why-stuck", tags: ["halo", "stuck", "deepagents"] },
    );
    const seen = new Set();
    for await (const [namespace, update] of stream) {
      const scout = namespace.length > 0;   // an update from inside the book-scout subagent
      for (const [node, value] of Object.entries(update || {})) {
        if (process.env.HALO_STUCK_DEBUG) console.log("[stuck]", namespace.join("/") || "main", node, value && typeof value === "object" ? Object.keys(value).join(",") : value);
        if (!value || typeof value !== "object") continue;
        if (!scout && Array.isArray(value.todos)) emit("todos", { todos: value.todos.map((t) => ({ content: clip(t.content, 80), status: t.status })) });
        for (const message of Array.isArray(value.messages) ? value.messages : []) {
          for (const call of message?.tool_calls || []) {
            // A subagent's messages come round again when it hands back to the tutor; each call is reported once.
            if (seen.has(call.id)) continue;
            seen.add(call.id);
            if (process.env.HALO_STUCK_DEBUG) console.log("[stuck]   call", call.name, JSON.stringify(call.args).slice(0, 200));
            const stage = describeCall(call, scout);
            if (stage) emit("stage", stage);
          }
        }
        if (!scout && value.structuredResponse) diagnosis = value.structuredResponse;
      }
    }
    // The student hears the answer now; their memory goes up to Backboard behind it.
    pushMemory(who, memory.markdown);
    if (!diagnosis) throw new Error("Halo couldn't work out what was missing. Try again.");
  }

  const found = locate(pages, diagnosis.page, diagnosis.quote);
  const steps = (Array.isArray(diagnosis.steps) ? diagnosis.steps : []).slice(0, 3).map((s, i) => {
    const write = clip(s?.write, 32);
    const ink = write ? [{ type: "text", value: write }] : [];
    // The page mark goes with the step that sends them to the book (the second one, or the only one).
    if (found.quote && i === Math.min(1, diagnosis.steps.length - 1)) ink.push({ type: "point", quote: found.quote, page: found.page, style: "highlight" });
    return { say: clip(s?.say, 320), ink };
  }).filter((s) => s.say);
  return {
    gap: clip(diagnosis.gap, 60).toLowerCase(), why: clip(diagnosis.why, 240), page: found.page, quote: found.quote,
    seenBefore: Boolean(diagnosis.seenBefore), question: clip(diagnosis.question, 200), steps,
  };
}
