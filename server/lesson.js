// "Teach me this chapter": a LangGraph tutor that reads a chapter, draws up its own roadmap of the
// concepts in it, then teaches them one at a time the way a tutor does across a desk. It is a
// conversation, not a lecture followed by a quiz: before each idea Halo asks what the student
// thinks, builds the explanation on that guess, hands it back with a check, and follows up on
// what they actually said.
//
//   plan ─► open ─► guess ─► teach ─► ask ─► grade ──┬─► (got it / explicit skip) ─► open the next ─► … ─► wrap
//                                      ▲             ├─► (missed / asked something) ─► a smaller follow-up question
//                                      └─────────────┘
//
// plan   One model call over the whole chapter → 3 to 7 concepts in teaching order, each tied to a page and
//        each with a "hook": the question Halo asks before teaching it.
// open   Puts the concept on the desk and asks the hook. The teaching scene is already being prepared in the
//        background, so it is ready by the time the student has answered.
// guess  interrupt(): waits for the student's guess. Nothing is graded here; "show me" is a fine answer.
// teach  Streams spoken steps with handwriting (same NDJSON as /api/ask), opening on the student's guess, and
//        ends with a check question.
// ask    interrupt(): the graph stops here, checkpointed, until the student answers. Each HTTP request runs the
//        graph until the next interrupt (or the end), so the lesson survives between requests.
// grade  Judges the answer against what a right answer contains; re-explains differently after a miss, answers
//        the student's own question if that is what came back, then puts a smaller question to them.
// wrap   Writes the summary: what they nailed, what to revisit, the one thing to remember.
import { StateGraph, Annotation, START, END, interrupt, Command } from "@langchain/langgraph";
import { randomUUID } from "node:crypto";
import { lessonSaver, cachedLessonReply, saveLessonReply } from "./lesson-store.js";
import { streamText, generateJSON } from "./llm.js";
import { speak } from "./tts.js";
import { describeLearner } from "./prompt.js";
import { StepQueue, readLines, despeak } from "./steps.js";
import * as db from "./db.js";
import { startMaterial } from "./lesson-material.js";
import { learnerKey, recordTopics, coveredTopics } from "./learner-memory.js";

const isMock = () => process.env.HALO_MOCK === "1";
const clip = (value, n) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, n);
const KINDS = new Set(["idea", "definition", "method", "example", "pitfall"]);
const VERDICTS = new Set(["got_it", "almost", "missed", "question"]);
const STYLES = new Set(["explain", "predict", "next_move", "spot_the_slip", "choice"]);
// Models reach for a marker's verdict ("Spot on, Joy!") however they are asked not to. A tutor's first
// words are about what the student said, so a verdict opener is cut and the sentence starts at its substance.
const OPENER = /^\s*(?:(?:that(?:'s|’s| is)|you(?:'re|’re| are))\s+)?(?:spot on|exactly(?: right)?|absolutely|correct|precisely|bingo|nailed it|great (?:guess|job|question|thinking)|good (?:guess|question|thinking)|nice(?: one| guess)?|well done)\b[^.!?…—–-]{0,24}[.!?…—–-]+\s*/i;
export function plain(text) {
  const cut = String(text ?? "").replace(OPENER, "");
  // Only when something is left to say.
  return cut.split(/\s+/).filter(Boolean).length >= 3 ? cut[0].toUpperCase() + cut.slice(1) : String(text ?? "");
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// What a person says in the second after you answer them, before they have worked out their reply.
// The app plays one the moment the student answers, so there is no dead air while the model thinks.
// Rules: short and warm; no trailing "..." (the voice drags it into "okaaay"); no "let me think" (sounds like a
// machine stalling); and an "answer" line must not hint at right or wrong, because the grade isn't in yet.
const FILLERS = [
  { kind: "guess", say: "Ooh, interesting guess." }, { kind: "guess", say: "Nice, let's find out." }, { kind: "guess", say: "Good instinct. Let's see." },
  { kind: "guess", say: "I like where you're going." }, { kind: "guess", say: "Fair guess. Let's test it." },
  { kind: "answer", say: "Got it. Let's check." }, { kind: "answer", say: "Alright, let's look at that." }, { kind: "answer", say: "Okay, let's see how that holds up." },
  { kind: "answer", say: "Right, let's walk through it." }, { kind: "answer", say: "Good, let's check it together." },
];
let fillerVoices;
function fillers() {
  // One after another: a burst of parallel requests can run into the voice service's concurrency limit.
  fillerVoices ||= (async () => {
    const list = [];
    for (const f of FILLERS) list.push({ ...f, audio: await speak(f.say) });
    // A failed clip is retried by the next lesson instead of being remembered as silence.
    if (list.some((f) => !f.audio)) fillerVoices = null;
    return list;
  })();
  return fillerVoices;
}

/** Nodes stream to the client through LangGraph's custom stream writer. */
const emitter = (config) => (event, data) => config?.writer?.({ event, data });

// ---------- plan ----------
const PLAN_SYSTEM = `You are Halo, a brilliant, warm human tutor. A student has handed you one chapter of what they are studying and asked you to teach it to them, concept by concept, the way a great tutor would across a desk. First you draw up the roadmap.

Read the chapter and decide what it is really teaching. Choose between 3 and 7 concepts: the ideas a student has to actually get, in the order a good teacher would build them (prerequisites first, the payoff last). Each concept is one teachable thing, not a section heading: "why the inner derivative shows up", not "Section 4.2". Skip exercises, summaries, front matter and anything decorative. Merge small related points into one concept; split a big one.

Reply with JSON only:
{"title": "<the chapter's real topic as a short title, 2 to 5 words, like a name not a description: 'The chain rule', 'How cells make energy'>",
 "thread": "<the story the chapter tells, one sentence, at most 110 characters, plain words>",
 "say": "<what you say out loud to open the lesson, the way you'd say it to a friend who just sat down: what this chapter is really about, how many stops, where it ends up. 2 short sentences, at most 32 words, contractions, e.g. 'Okay, so this chapter is really one idea in three stops. We'll start with powers, and by the end you'll see exactly where that extra two x comes from.' No 'We'll explore', 'with ease', 'Great', 'Let's dive in', 'journey'. Don't ask anything here: your first question comes right after.>",
 "concepts": [{"name": "<2 to 6 words, lowercase except names>", "why": "<why it matters or what it unlocks, at most 90 characters>", "page": <the page number where the chapter introduces it>, "kind": "idea"|"definition"|"method"|"example"|"pitfall", "minutes": <1 to 4>,
   "hook": "<the question you ask BEFORE teaching this concept, to get them thinking first>"}]}

The hook is what separates a tutor from a lecture: you find out what they think before you tell them anything. For each concept write one spoken question, at most 26 words, that a student can answer with a guess in a few words WITHOUT having read the chapter: a prediction ("what do you reckon happens to…"), a tiny everyday puzzle the concept will resolve, a concrete case from the chapter to guess at, or "what do you already know about…". It must not need the concept's vocabulary, must not be a quiz on the chapter, and must not give the method or the answer away (never describe the rule inside the question). Make it specific and curious, never "What do you think X is?".

You may be told what this student has covered with Halo before (lessons and practice, with how it went). Use it: a concept they already got can be shorter, and its hook can build on it ("you've seen the power rule... so what happens when…"); one they were still learning or skipped deserves a gentler start; in "say", mention a connection to earlier work only if it is real. Never invent history that isn't listed. For the first concept, open with "So, before I show you anything..." or similar; for later ones, start with a two-to-four word bridge ("Okay, next thing." / "Now, here's a strange one."). Contractions, no LaTeX, maths in words.`;

function planText(state, covered = []) {
  const parts = [];
  const who = describeLearner(state.learner);
  if (who) parts.push(who);
  if (covered.length) parts.push(`What they have covered with Halo before (topic | how | result | where | last date | times):\n${covered.slice(-30).map((l) => `- ${l}`).join("\n")}`);
  parts.push(`Book or course: ${state.title || "(untitled)"}${state.chapter ? `\nChapter: ${state.chapter}` : ""}`);
  parts.push(`The chapter, page by page:\n${pagesText(state.pages, 48000)}`);
  parts.push("Draw up the roadmap as JSON.");
  return parts.join("\n\n");
}
function pagesText(pages, budget) {
  const per = Math.max(400, Math.floor(budget / Math.max(1, pages.length)));
  return pages.map((p) => `— Page ${p.page} —\n${String(p.text || "").slice(0, per)}`).join("\n\n");
}

const MOCK_PLAN = {
  title: "The chain rule", thread: "Derivatives of simple powers, then what changes when a function is nested inside another.",
  say: "Okay, this chapter is really one idea in three stops. We'll warm up with the power rule, then meet a function hiding inside another, and by the end you'll see exactly where that extra two x comes from.",
  concepts: [
    { name: "the power rule", why: "The one move every other derivative rule leans on", page: 1, kind: "method", minutes: 2, hook: "So, before I show you anything... x squared turns into two x. Take a guess: what does x cubed turn into?" },
    { name: "a function inside a function", why: "Spotting the outside and the inside is most of the chain rule", page: 2, kind: "idea", minutes: 3, hook: "Okay, next thing. If I cube x squared plus one, which happens first... the cubing, or the x squared plus one?" },
    { name: "why the inner derivative shows up", why: "The part students forget, and the reason it can't be skipped", page: 2, kind: "pitfall", minutes: 3, hook: "Now, here's a strange one. The book's answer has an extra two x on the end. Any guess where it comes from?" },
  ],
};

async function plan(state, config) {
  const emit = emitter(config);
  const voices = fillers();
  // What this learner has been through before, from Halo's memory (Backboard when configured). Never blocks the lesson.
  const covered = await Promise.race([coveredTopics(learnerKey(state.learnerId)).catch(() => []), sleep(1500).then(() => [])]);
  const raw = isMock() ? MOCK_PLAN : await generateJSON({ system: PLAN_SYSTEM, text: planText(state, covered) });
  const pageNumbers = state.pages.map((p) => p.page);
  const first = pageNumbers[0];
  const concepts = (Array.isArray(raw.concepts) ? raw.concepts : []).slice(0, 7).map((c, i) => ({
    n: i + 1, name: clip(c?.name, 60) || `concept ${i + 1}`, why: clip(c?.why, 110),
    page: pageNumbers.reduce((best, page) => Math.abs(page - Number(c?.page || first)) < Math.abs(best - Number(c?.page || first)) ? page : best, first), kind: KINDS.has(c?.kind) ? c.kind : "idea",
    minutes: Math.min(4, Math.max(1, Math.round(Number(c?.minutes) || 2))), hook: despeak(clip(c?.hook, 220)),
  })).filter((c) => c.name);
  if (concepts.length < 2) throw new Error("Halo couldn't find enough to teach in this chapter. Try a chapter with more text.");
  const say = despeak(clip(raw.say, 320) || `Let's take this in ${concepts.length} steps.`);
  const plan = { id: state.id, title: clip(raw.title, 60) || state.chapter || state.title || "Your lesson", thread: clip(raw.thread, 130), say, concepts };
  // The scene for the first concept is prepared while Halo is still saying hello.
  warm({ ...state, plan }, concepts[0]);
  // The clips are usually ready from an earlier lesson; a first lesson doesn't wait long for them.
  const [audio, voiced] = await Promise.all([speak(say), Promise.race([voices, sleep(2500).then(() => [])])]);
  emit("plan", { ...plan, audio, fillers: voiced.filter((f) => f.audio) });
  console.log(`[lesson] ${state.id.slice(0, 8)} plan "${plan.title}": ${concepts.map((c) => c.name).join(" → ")}`);
  return { plan, current: 0, attempts: 0, mastery: [], transcript: [], announced: 0, styles: [] };
}

// ---------- the teaching scene, prepared ahead of the conversation ----------
const scenes = new Map();
/** Starts (or returns) the scene for one concept. It keeps building while the student thinks about something else. */
function warm(state, concept) {
  const key = `${state.id}:${concept.n}`;
  if (!scenes.has(key)) {
    const index = Math.max(0, state.pages.findIndex((p) => p.page === concept.page));
    scenes.set(key, startMaterial({ concept, pages: state.pages.slice(Math.max(0, index - 1), index + 2), title: state.title, learner: state.learner, mock: isMock() }));
    while (scenes.size > 48) scenes.delete(scenes.keys().next().value);
  }
  return scenes.get(key);
}

// ---------- open: put the concept on the desk and ask what they think ----------
async function open(state, config) {
  const emit = emitter(config);
  const concept = state.plan.concepts[state.current];
  emit("concept", { n: concept.n });
  emit("material", warm(state, concept).first);
  if (!concept.hook) return { announced: concept.n, hooked: false, guess: "" };
  emit("question", { n: concept.n, kind: "hook", style: "guess", ask: concept.hook, options: [], hint: "", audio: await speak(concept.hook) });
  return { announced: concept.n, hooked: true, guess: "" };
}
// The graph waits here for the guess. A node restarts from its first line when it is resumed, so this one only waits.
function guess(state) {
  if (!state.hooked) return {};
  const reply = interrupt({ n: state.plan.concepts[state.current].n, ask: "hook" });
  if (reply?.action === "jump") {
    const index = state.plan.concepts.findIndex((c) => c.n === Number(reply.concept));
    return { current: index >= 0 ? index : state.current, announced: 0, hooked: false, guess: "" };
  }
  return { hooked: false, guess: reply?.action === "answer" ? clip(reply.answer, 400) : "" };
}

// ---------- teach ----------
const TEACH_SYSTEM = `You are Halo: a brilliant, warm human tutor sitting next to ONE student, working through a chapter of their book together. This is a conversation across a desk, not a lecture. You say a little, show a little, and hand it back to them. You speak out loud while writing by hand on the paper between you; what you write stays there for them to reread.

OUTPUT FORMAT — strict NDJSON. One JSON object per line, nothing else. No markdown, no code fences, no commentary.
Lines 1..N (2 to 4 of them):   {"focus":"source"|"visual"|"example","say":"<what you say for this beat>","ink":[<ink items>]}
Last line (handing it back):   {"ask":"<your question to them>","style":"explain"|"predict"|"next_move"|"spot_the_slip"|"choice","kind":"open"|"choice","options":["<a>","<b>","<c>"],"expected":"<what a right answer contains, for you alone>","hint":"<a nudge if they're stuck, at most 90 characters>"}

═══ HOW YOU TALK ("say") ═══
Spoken by a voice, so write exactly how a real person talks to one person they like. Contractions always. Short sentences. A comma or "..." where you'd pause.
- REACT FIRST. Right before this you asked them a question and they guessed. Your first words answer THEM, using a few of their own words: what's right in the guess, or the exact thing it's about to run into ("You said three x... hold onto that three, it's doing real work"). A wrong guess is useful: say why it was a sensible thing to think. Never grade it ("spot on", "exactly", "correct", "right", "not quite", "good guess"), never ignore it, and don't start with their name. If what they said was really a question or a comment, answer that in a sentence first. If they had no guess, skip this and just start, without mentioning it.
- Then teach THIS concept from THIS chapter in 2 to 4 beats: the book's own example, its real words, numbers and symbols, never a generic one. One idea per beat, 1 or 2 sentences, at most 28 words. Under 40 seconds in total. Stop before you'd lose them; the question is where the rest of the learning happens.
- Sound like you're thinking alongside them: "okay so", "here's the thing", "watch this", "right?", "see that?", "hang on". One or two of these across the whole turn, not in every sentence.
- Make it click: tie it to something they already know (an earlier concept in this lesson by name, or something they said), and give a quick way to remember it when there is one.
- Never: "Sure!", "Great question", "Certainly", "Let's dive in", "In this step", "As we can see", "I hope this helps", "Now, let's", bullet-speak, lecture-voice, summarising yourself, or reading the book aloud.
- No markdown. LaTeX only inside a "math" item's "tex" (no $ signs); everywhere else Unicode. Speak maths in words ("x squared plus one") and code in words ("the for loop").
- When the chapter has a formula or code, show the real thing with "math" or "code" (never code as handwriting), and explain it out loud.

═══ WHAT YOU WRITE (ink) ═══
What a tutor jots on the paper while saying that sentence: the point of the beat in a form worth rereading. 0–3 items per beat; almost every beat writes one "text".
  {"type":"text","value":"<one handwritten line, 40–90 chars, a complete thought; Unicode maths x², √, →, ≈>"}
  {"type":"math","tex":"<LaTeX for one formula, typeset like a textbook; for fractions, integrals, sums, matrices, subscripts>"}
  {"type":"code","lang":"<language>","value":"<the code, real newlines as \\n, at most 12 lines of up to 50 chars>"}
  {"type":"underline","target":"previous"}   underline the previous line
  {"type":"box","target":"previous"}         box the previous line (the punchline: do this once, on the takeaway)
  {"type":"check"}                           a small tick
  {"type":"sketch","w":200,"h":120,"paths":["<SVG path d>", ...],"labels":[{"x":10,"y":20,"text":"≤12 chars"}]}
        A quick hand-drawn diagram in a 200×120 (up to 240×160) box: axes, a curve, a number line, a triangle, boxes and arrows, a cell, a timeline.
        1–6 simple paths (M/L/Q/C commands, no fill), 0–5 short labels. Labels are handwriting: x,y is the LEFT end of the baseline, each character ~9 wide, 16 tall; a label for a line sits 8 above it. Use it whenever a picture explains it faster than words.
  {"type":"image","prompt":"<what to draw, one sentence>"}   only for something a hand sketch can't do (a 3-D structure, a mechanism, a map). At most one per concept.
  {"type":"point","quote":"<2–40 characters copied EXACTLY from the chapter text>","style":"highlight"|"underline"|"circle"}
        Points at the book: the student sees that line of the chapter lit up while you speak ("see where it says..."). Use it in one or two beats when the concept rests on a definition, formula or example printed in the chapter. Copy the quote character for character.

═══ HANDING IT BACK ("ask") ═══
End by giving them something to DO with the idea, the way a tutor slides the pencil across. One question that a student who got it answers easily and one who only nodded along cannot. Pick the style that fits, and don't use the style you used last time:
- "next_move": you stopped the worked example one move short; they make the move ("so what do we do with that two?").
- "predict": change one thing and ask what happens ("what if the power were five instead?").
- "spot_the_slip": show the answer a rushed student would write and ask what went wrong.
- "explain": they say it back in their own words ("how would you tell a friend why…").
- "choice": only for a definition or a natural set of 3 options, one right, the others being real mistakes people make. Then "kind":"choice" and fill "options"; for every other style "kind":"open" and "options": [].
Ask it the way you'd say it across a desk, at most 24 words, no "Question:", no "Can you tell me". Never say or write the answer to it in the beats before: whatever you are about to ask for (the last line of code, the final number, the missing word) must not appear in any "say" or ink above it. Stop one move short and let them make it. It must be answerable out loud in under 20 seconds from what you just taught, with no writing or long computation.`;

function teachText(state, concept) {
  const parts = [];
  const who = describeLearner(state.learner);
  if (who) parts.push(who);
  const { plan } = state;
  parts.push(`Book or course: ${state.title || "(untitled)"}${state.chapter ? `\nChapter: ${state.chapter}` : ""}\nLesson: "${plan.title}". The thread: ${plan.thread || "(see chapter)"}`);
  parts.push(`Roadmap:\n${plan.concepts.map((c) => `${c.n}. ${c.name}${c.n === concept.n ? "   ← teach this one now" : ""}`).join("\n")}`);
  const earlier = state.transcript.filter((t) => t.n < concept.n);
  if (earlier.length) {
    parts.push(`So far in this lesson:\n${earlier.map((t) => `- "${t.concept}": asked "${t.ask}"; they answered "${clip(t.answer, 160) || "(skipped)"}" → ${t.verdict.replace("_", " ")}`).join("\n")}\nBuild on what they got; if something went wrong earlier and it matters here, weave the repair in without making a thing of it.`);
  }
  parts.push(`Concept ${concept.n} of ${plan.concepts.length}: "${concept.name}" (${concept.kind}; why it matters: ${concept.why || "see chapter"}). It lives around page ${concept.page}.`);
  if (concept.hook && !state.review) parts.push(`Just now you asked them: "${concept.hook}"\n${state.guess ? `They answered: "${state.guess}"\nOpen by reacting to that, in their words.` : "They had no guess and asked you to show them. Just start; don't mention it."}`);
  else if (state.review) parts.push("They asked to go over this concept again. Come at it from a different angle than a first explanation would, and start straight in.");
  if (state.styles?.length) parts.push(`Your last hand-back was "${state.styles.at(-1)}". Choose a different style this time.`);
  parts.push(`Chapter text around it:\n${aroundPage(state.pages, concept.page, 7500)}`);
  if (state.material) parts.push(`The student sees this teaching scene, in three tabs (source, visual, example): ${JSON.stringify(state.material)}. Each of these is laid on the desk the first time a beat's "focus" names it, so use them as you talk: the book's line (source), the picture (visual), the worked example (example). You don't have to use all three, and the order is yours. If you use the example, it reveals one move per "example" beat; leaving its last move for them makes a natural "next_move" hand-back. A web perspective, if present, is supplementary: say it's from outside the book, and don't treat an analogy as a literal fact. Never ask something that depends only on optional web content.`);
  parts.push("Your turn to talk. Strict NDJSON, ending with the question you hand back.");
  return parts.join("\n\n");
}
function aroundPage(pages, page, budget) {
  const index = Math.max(0, pages.findIndex((p) => p.page === page));
  const near = pages.slice(Math.max(0, index - 1), index + 2);
  const per = Math.floor(budget / Math.max(1, near.length));
  return near.map((p) => `— Page ${p.page} —\n${String(p.text || "").slice(0, per)}`).join("\n\n");
}

const MOCK_TEACH = [
  { steps: [
      { say: "So, the power rule. Take x squared. The two comes down in front, and the power drops by one.", ink: [{ type: "point", quote: "f′(x) = 2x", style: "underline" }, { type: "text", value: "x² → 2x: the power comes down, then drops by one" }] },
      { say: "Same move every time... x to the five becomes five x to the four. Bring it down, knock one off.", ink: [{ type: "text", value: "xⁿ → n·xⁿ⁻¹  (bring it down, knock one off)" }, { type: "box", target: "previous" }] },
    ],
    ask: { ask: "In your own words: what are the two things you do to x cubed to get its derivative?", style: "explain", kind: "open", options: [], expected: "bring the 3 down in front, and reduce the power to 2 → 3x²", hint: "Think: where does the exponent go, and what happens to it?" } },
  { steps: [
      { say: "Now look at y equals x squared plus one, all cubed. There's a function hiding inside another one.", ink: [{ type: "point", quote: "y = (x² + 1)³", style: "underline" }, { type: "text", value: "(x² + 1)³: the outside is u³, the inside is u = x² + 1" }] },
      { say: "Picture it as two boxes. The inside box makes x squared plus one, then hands it to the outside box, which cubes it.", ink: [{ type: "sketch", w: 220, h: 90, paths: ["M 10 25 L 90 25 L 90 70 L 10 70 Z", "M 130 25 L 210 25 L 210 70 L 130 70 Z", "M 92 47 L 126 47", "M 118 41 L 126 47 L 118 53"], labels: [{ x: 22, y: 52, text: "x² + 1" }, { x: 150, y: 52, text: "( )³" }] }] },
      { say: "The chain rule says: differentiate the outside, keeping the inside as it is, then multiply by the derivative of the inside.", ink: [{ type: "text", value: "y′ = outside′(inside) × inside′" }, { type: "box", target: "previous" }] },
    ],
    ask: { ask: "For y = (x² + 1)³, which is the inside function?", style: "choice", kind: "choice", options: ["x² + 1", "u³", "3u²"], expected: "x² + 1", hint: "The inside is what gets computed first, before anything is cubed." } },
  { steps: [
      { say: "Here's the trap. People bring the three down, drop the power... and stop. Three times x squared plus one, squared. Looks done.", ink: [{ type: "text", value: "3(x² + 1)² alone is NOT the answer" }, { type: "cross" }] },
      { say: "But the inside is moving too. Its derivative is two x, and that's exactly the two x on the page.", ink: [{ type: "point", quote: "× 2x", style: "circle" }, { type: "text", value: "inside′ = 2x, so y′ = 3(x² + 1)² × 2x" }, { type: "box", target: "previous" }] },
    ],
    ask: { ask: "Say a friend writes three times x squared plus one, squared, and stops. What did they leave out?", style: "spot_the_slip", kind: "open", options: [], expected: "the inside function x² + 1 also changes with x, so you multiply by its derivative 2x", hint: "What's inside the brackets, and does it change when x changes?" } },
];

async function teach(state, config) {
  const emit = emitter(config);
  const concept = state.plan.concepts[state.current];
  // A review (a jump from the roadmap) arrives here without passing through "open".
  if (state.announced !== concept.n) emit("concept", { n: concept.n });
  const t0 = Date.now();
  const scene = warm(state, concept);
  if (state.announced !== concept.n) emit("material", scene.first);
  // The book's line, the picture and the example are needed to teach; the web reading can arrive while Halo talks.
  let material = await scene.scene;
  const early = await Promise.race([scene.full, sleep(isMock() ? 0 : 150).then(() => null)]);
  if (early) material = early;
  emit("material", early || { ...material, status: "searching" });
  const queue = new StepQueue((step) => emit("step", step));
  let asked = null;
  if (isMock()) {
    const canned = MOCK_TEACH[(concept.n - 1) % MOCK_TEACH.length];
    const steps = canned.steps.map((step, i) => i === 0 && state.guess ? { ...step, say: `You said "${state.guess}"... hold onto that. ${step.say}` } : step);
    for (const step of steps) { queue.push(step); await sleep(150); }
    asked = canned.ask;
  } else {
    await readLines(streamText({ images: [], system: TEACH_SYSTEM, text: teachText({ ...state, material }, concept) }), (obj) => {
      if (typeof obj.ask === "string") asked = obj;
      else queue.push(queue.steps.length || typeof obj.say !== "string" ? obj : { ...obj, say: plain(obj.say) });
    });
  }
  await queue.drain();
  if (!queue.steps.length) {
    queue.push({ say: `Let's look at ${concept.name}. Open page ${concept.page} and read the first paragraph with me.`, ink: [{ type: "text", value: `${concept.name} — page ${concept.page}` }] });
    await queue.drain();
  }
  if (!early) {
    // Whatever the search found is added to the desk; a search still running after this is dropped.
    material = await Promise.race([scene.full, sleep(8000).then(() => ({ ...material, status: "unavailable" }))]);
    emit("material", material);
  }
  const question = cleanQuestion(asked, concept);
  const spoken = { ...question, audio: await speak(question.ask, { previous: queue.said }) };
  const { expected, ...sent } = spoken;
  emit("question", sent);
  // While they think about this one, get the next concept's scene ready.
  const next = state.plan.concepts[state.current + 1];
  if (next) warm(state, next);
  console.log(`[lesson] ${state.id.slice(0, 8)} taught ${concept.n} "${concept.name}" in ${queue.steps.length} steps, ${Date.now() - t0}ms${state.guess ? ` (guess: "${state.guess.slice(0, 40)}")` : ""} — asks: ${question.ask}`);
  const exchanges = concept.hook && !state.review ? [{ role: "tutor", text: concept.hook }, { role: "student", text: state.guess || "(no guess: asked to be shown)" }] : [];
  return { material, question: spoken, attempts: 0, teaching: queue.said, exchanges, announced: concept.n, review: false, styles: [...(state.styles || []), question.style].slice(-6) };
}
function cleanQuestion(raw, concept) {
  const options = (Array.isArray(raw?.options) ? raw.options : []).map((o) => clip(o, 80)).filter(Boolean).slice(0, 4);
  const kind = raw?.kind === "choice" && options.length >= 2 ? "choice" : "open";
  return {
    n: concept.n, kind, style: kind === "choice" ? "choice" : STYLES.has(raw?.style) && raw.style !== "choice" ? raw.style : "explain",
    ask: despeak(clip(raw?.ask, 240)) || `In your own words, what is ${concept.name} and why does it matter here?`,
    options: kind === "choice" ? options : [],
    expected: clip(raw?.expected, 300) || `a clear description of ${concept.name}`,
    hint: clip(raw?.hint, 110),
  };
}

// ---------- ask: the graph waits here for the student ----------
function ask(state) {
  const concept = state.plan.concepts[state.current];
  const reply = interrupt({ n: concept.n, ask: state.question.ask });
  return { reply };
}

// ---------- grade ----------
const GRADE_SYSTEM = `You are Halo, a warm, sharp human tutor in the middle of working through a chapter with ONE student, across a desk. You just explained a concept and handed them a question; they answered out loud (so the words may be a little garbled by speech recognition, and informal). This is a conversation: respond to what THEY said, then keep it moving.

Reply with JSON only:
{"verdict": "got_it" | "almost" | "missed" | "question",
 "say": "<what you say first, 1 or 2 short sentences, at most 28 words, spoken>",
 "steps": [{"focus": "source"|"visual"|"example", "say": "...", "ink": [...]}],
 "follow": {"ask": "<the next thing you ask them, at most 22 words>", "expected": "<what a right answer contains>", "hint": "<a nudge, at most 90 characters>"},
 "note": "<for missed or almost: the specific misunderstanding in at most 10 words, lowercase; else empty>"}

"say" always starts from their words. Quote or paraphrase a piece of what they said and respond to that piece ("'Bring it down'... yes, and then?" / "You said the cube happens first. I get why..."). Sound like a person reacting, not a marker returning a paper. Never open with praise or a verdict word ("Correct", "Exactly", "Exactly right", "Spot on", "Great job", "Good try", "Not quite", "Close", "Oops", "Unfortunately"), and no exclamation marks. When they've got it, say what it is they've got, plainly, the way you'd nod and carry on.

Verdicts:
- "got_it": the answer shows they have the idea, even if clumsy, incomplete in wording, or in different words from the book. Be generous about phrasing, strict about the idea. "say" names the specific thing they got and, when natural, adds the one detail that makes it stick or links it to what's coming. "steps": [] and "follow": null.
- "almost": the core is there but one part is off or missing. "say" credits the part that's right and points at the gap without filling it. "steps": at most one beat that shows where to look, and "follow" asks ONLY for the missing piece.
- "missed": the idea isn't there, or they said they don't know. "say" is kind and short and takes the blame for the explanation ("that's on me, let me try it differently"). "steps": 1 or 2 beats that come at it from a DIFFERENT angle than before (an everyday analogy, a tiny case with small numbers, or the mistake made visible). Never repeat the first explanation. "follow" is a smaller, easier stepping-stone question that walks them halfway there, not the original question again.
- "question": they asked something, or asked you to repeat, slow down, give an example or say it another way. "say" answers the heart of it straight away, without commenting on the question itself (no "great question", "good question", "that's a great thing to ask"). "steps": 1 or 2 beats that finish the answer, grounded in the chapter. "follow" hands the original question back in fresh, shorter words ("so, with that... what's the inside one?").

Never say or write the answer to the question in "follow": the beats show them where to look, they take the last step. Keep every turn short: you talk for under 20 seconds, then it's theirs again. Each beat sets "focus" to "source", "visual" or "example" to bring that part of the desk back into view. The cited web perspective may supply a different analogy; say it's from outside the book. Beats use the same ink as your teaching: {"type":"text","value":"<40–90 chars, a complete thought>"}, {"type":"underline"|"box","target":"previous"}, {"type":"check"}, {"type":"cross"}, {"type":"sketch",...}, {"type":"point","quote":"<copied exactly from the chapter text>","style":"highlight"|"underline"|"circle"}.
Voice rules: contractions, short sentences, specific to the chapter's example, no LaTeX or markdown, maths spoken in words. Leave their name out unless this is a real breakthrough after a struggle.`;

function gradeText(state, concept, answer) {
  const parts = [];
  const who = describeLearner(state.learner);
  if (who) parts.push(who);
  parts.push(`Lesson "${state.plan.title}", concept ${concept.n} of ${state.plan.concepts.length}: "${concept.name}" (${concept.kind}).`);
  parts.push(`The check question: "${state.question.ask}"${state.question.options.length ? `\nOptions offered: ${state.question.options.join(" | ")}` : ""}\nWhat a right answer contains: ${state.question.expected}${state.question.hint ? `\nYour prepared hint: ${state.question.hint}` : ""}`);
  if (state.question.goal && state.question.goal !== state.question.ask) parts.push(`That was a stepping-stone towards your original question: "${state.question.goal}". If this answer shows they now have the whole idea, that's "got_it"; if it only gets the stepping stone, credit it and let "follow" take the next step towards the original.`);
  if (state.attempts > 0) parts.push(`This is attempt ${state.attempts + 1} on this concept. If they still don't have it, go smaller and more concrete, and make "follow" easier still. Keep checking the idea; only the student decides to skip it.`);
  if (state.material) parts.push(`Teaching scene and cited supplementary evidence: ${JSON.stringify(state.material)}`);
  parts.push(`What you actually taught: ${state.teaching || "(see chapter)"}`);
  if (state.exchanges?.length) parts.push(`Recent conversation on this concept:\n${state.exchanges.slice(-8).map((x) => `${x.role}: ${x.text}`).join("\n")}`);
  parts.push(`The student's answer: "${answer}"`);
  parts.push(`Chapter text around the concept:\n${aroundPage(state.pages, concept.page, 4000)}`);
  parts.push("Judge it and reply as JSON.");
  return parts.join("\n\n");
}

function mockGrade(state, concept, answer) {
  const a = answer.toLowerCase();
  if (/\?|^why|^how|^what do you mean|again|slower|don't get/.test(a)) {
    return { verdict: "question", say: "Good question... let me put it another way.", steps: [{ say: "Think of the inside as a machine that's always running. Change x a little, and the inside moves too, so its speed has to be in the answer.", ink: [{ type: "text", value: "inside moves with x → its speed (2x) multiplies in" }] }], follow: { ask: "So, with that... how would you put it?", expected: state.question.expected, hint: state.question.hint }, note: "" };
  }
  const right = [/bring.*down|down.*front|exponent|power.*(one|1|drop|minus)|3x/, /x.*2.*\+.*1|x squared plus one|inside is x/, /inside|2x|two x|chang|moving|also/][(concept.n - 1) % 3].test(a);
  if (right) return { verdict: "got_it", say: "Yes... that's exactly it. You've got the shape of it.", steps: [], note: "" };
  if (/don't know|not sure|no idea|skip/.test(a) || !a) return { verdict: "missed", say: "No stress, that one trips everyone up at first.", steps: [{ say: "Try it like a speedometer. The outside tells you how fast the cube grows... but the thing being cubed is itself speeding up.", ink: [{ type: "text", value: "two speeds stacked: outside′ × inside′" }] }, { say: "So the answer has to carry both speeds. That's the whole chain rule.", ink: [{ type: "text", value: "miss the inside speed → wrong answer" }, { type: "underline", target: "previous" }] }], follow: { ask: "Smaller question, then: does the inside change when x changes?", expected: "yes, the inside changes with x", hint: "Try x = 1, then x = 2." }, note: "forgets the inner derivative" };
  return { verdict: "almost", say: "You're close... you've got the first half.", steps: [{ say: "Just add the second half: whatever is inside the brackets gets differentiated too, and multiplied on.", ink: [{ type: "text", value: "… × inside′  (don't stop early)" }] }], follow: { ask: "So what's the one piece still missing from your answer?", expected: state.question.expected, hint: state.question.hint }, note: "stops after the outside derivative" };
}

/** Each concept goes into the learner's memory as it is checked; later checks update the result, not the count. */
function remember(state, concept, result, first) {
  recordTopics(learnerKey(state.learnerId), [{ topic: concept.name, how: "lesson", result, book: state.title, page: concept.page, again: !first }]);
}

async function grade(state, config) {
  const emit = emitter(config);
  const { plan } = state;
  const concept = plan.concepts[state.current];
  const reply = state.reply || {};
  const transcript = [...state.transcript];
  const mastery = [...state.mastery];
  const label = `halo-lesson://${state.id}`;

  if (reply.action === "jump") {
    const index = plan.concepts.findIndex((c) => c.n === Number(reply.concept));
    return { outcome: "review", current: index >= 0 ? index : state.current, attempts: 0, announced: 0, review: true, guess: "" };
  }
  if (reply.action === "skip") {
    const say = state.current + 1 < plan.concepts.length ? "No problem, we'll leave that one for now." : "No problem, let's wrap up.";
    emit("grade", { n: concept.n, verdict: "skipped", say, audio: await speak(say), note: "" });
    remember(state, concept, "skipped", !transcript.some((x) => x.n === concept.n));
    transcript.push({ n: concept.n, concept: concept.name, ask: state.question.ask, answer: "", verdict: "skipped" });
    const old = mastery.findIndex((m) => m.n === concept.n);
    if (old >= 0) mastery.splice(old, 1);
    mastery.push({ n: concept.n, verdict: "skipped" });
    return { outcome: "advance", current: state.current + 1, attempts: 0, transcript, mastery };
  }

  const answer = clip(reply.answer, 1500);
  const t0 = Date.now();
  const raw = isMock() ? mockGrade(state, concept, answer) : await generateJSON({ system: GRADE_SYSTEM, text: gradeText(state, concept, answer) });
  if (!VERDICTS.has(raw?.verdict)) throw new Error("Halo couldn’t assess that answer. Please try again.");
  const verdict = raw.verdict;
  const say = plain(despeak(clip(raw?.say, 260))) || { got_it: "That's it.", almost: "Close, nearly there.", missed: "Let's look at it another way.", question: "Good question." }[verdict];
  const note = clip(raw?.note, 80);
  emit("grade", { n: concept.n, verdict, say, audio: await speak(say), note });
  const queue = new StepQueue((step) => emit("step", step));
  for (const step of (Array.isArray(raw?.steps) ? raw.steps : []).slice(0, 3)) queue.push(step);
  await queue.drain();

  const attempts = state.attempts + (verdict === "question" ? 0 : 1);
  const outcome = verdict === "got_it" ? "advance" : "again";
  if (verdict !== "question") {
    const tries = transcript.filter((x) => x.n === concept.n).length + 1;
    const result = verdict === "got_it" ? (tries > 1 ? `got it after ${tries} tries` : "got it") : verdict === "almost" ? "nearly there" : "still learning";
    remember(state, concept, result, tries === 1);
    transcript.push({ n: concept.n, concept: concept.name, ask: state.question.ask, answer, verdict });
    // A miss is a confusion signal: it joins the history the learner profile's weak spots are built from.
    if (verdict !== "got_it") {
      const qid = db.logQuestion({ url: label, title: `${state.title}${state.chapter ? ` · ${state.chapter}` : ""}`, question: `(lesson) ${state.question.ask}`, mode: "lesson" });
      db.finishQuestion(qid, { topic: concept.name.toLowerCase(), circledText: answer.slice(0, 500), answerText: note || say });
    }
  }
  if (outcome === "advance") {
    const old = mastery.findIndex((m) => m.n === concept.n);
    if (old >= 0) mastery.splice(old, 1);
    mastery.push({ n: concept.n, verdict });
  }
  // Not there yet: the conversation continues with a smaller question (or the same one, handed back in new words).
  let question = state.question;
  if (outcome === "again") {
    const ask = despeak(clip(raw?.follow?.ask, 220));
    if (ask) {
      const goal = state.question.goal || state.question.ask;
      question = { n: concept.n, kind: "open", style: verdict === "question" ? state.question.style : "explain", ask, options: [], goal,
        expected: clip(raw.follow.expected, 300) || state.question.expected, hint: clip(raw.follow.hint, 110) || state.question.hint,
        audio: await speak(ask, { previous: [say, queue.said].filter(Boolean).join(" ") }) };
      // A choice question keeps its options when it is only being handed back after the student's own question.
      if (verdict === "question" && state.question.kind === "choice") Object.assign(question, { kind: "choice", options: state.question.options });
    }
    const { expected, goal, ...sent } = question;
    emit("question", { ...sent, again: true });
  }
  console.log(`[lesson] ${state.id.slice(0, 8)} concept ${concept.n}: "${answer.slice(0, 60)}" → ${verdict} (${outcome}) in ${Date.now() - t0}ms`);
  const told = [say, queue.said, outcome === "again" ? question.ask : ""].filter(Boolean).join(" ");
  return { outcome, attempts, transcript, mastery, question, exchanges: [...(state.exchanges || []), { role: "student", text: answer }, { role: "tutor", text: told }].slice(-12), current: outcome === "advance" ? state.current + 1 : state.current };
}

function afterGrade(state) {
  if (state.outcome === "again") return "ask";
  if (state.outcome === "review") return "teach";
  return state.current < state.plan.concepts.length ? "open" : "wrap";
}

// ---------- wrap ----------
const WRAP_SYSTEM = `You are Halo, a warm human tutor, finishing a lesson you just taught a student concept by concept. You have the roadmap and how each check went. Write the send-off.
Reply with JSON only:
{"say": "<spoken, 2 or 3 short sentences, at most 45 words: specific to what THEY did today, warm, honest about what to revisit, no 'Great job', no 'Congratulations'>",
 "nailed": ["<concept names they clearly got>"],
 "revisit": ["<concept names worth another look, with a 3 to 8 word reason after a colon>"],
 "takeaway": "<the one sentence from this chapter to remember, at most 110 characters, plain words, no LaTeX>"}`;

async function wrap(state, config) {
  const emit = emitter(config);
  const { plan, transcript, mastery } = state;
  const got = mastery.filter((m) => m.verdict === "got_it").map((m) => plan.concepts[m.n - 1]?.name).filter(Boolean);
  const shaky = plan.concepts.filter((c) => !got.includes(c.name)).map((c) => c.name);
  let raw;
  if (isMock()) {
    raw = { say: `That's the chapter. ${got.length ? `You showed you understand ${got.join(" and ")}.` : "We have a starting point for your next practice."}${shaky.length ? ` Give ${shaky[0]} another look.` : " Keep those connections in mind."}`,
      nailed: got, revisit: shaky.map((s) => `${s}: try one more example`), takeaway: "Outside derivative times inside derivative. Always ask: what's inside?" };
  } else {
    raw = await generateJSON({ system: WRAP_SYSTEM, text: [
      describeLearner(state.learner),
      `Lesson "${plan.title}" (${state.title}${state.chapter ? `, ${state.chapter}` : ""}). Thread: ${plan.thread}`,
      `Roadmap and how each check went:\n${plan.concepts.map((c) => { const t = transcript.filter((x) => x.n === c.n); return `${c.n}. ${c.name} — ${t.length ? t.map((x) => `asked "${x.ask}" → "${clip(x.answer, 120) || "(skipped)"}" (${x.verdict.replace("_", " ")})`).join("; ") : "not reached"}`; }).join("\n")}`,
      "Write the send-off as JSON.",
    ].filter(Boolean).join("\n\n") });
  }
  const say = despeak(clip(raw?.say, 320)) || "That's the chapter. Nice work today.";
  const summary = {
    say, audio: await speak(say),
    // Mastery comes from the actual checks, never from a generated send-off.
    nailed: got,
    revisit: shaky.map((name) => {
      const reason = Array.isArray(raw?.revisit) && raw.revisit.find((s) => typeof s === "string" && s.startsWith(name + ":"));
      return clip(reason || `${name}: try another example`, 110);
    }),
    takeaway: clip(raw?.takeaway, 130).replace(/\$/g, ""),
    mastery: plan.concepts.map((c) => mastery.find((m) => m.n === c.n) || { n: c.n, verdict: "not_reached" }),
  };
  if (!summary.nailed.length && got.length) summary.nailed = got;
  emit("finish", summary);
  console.log(`[lesson] ${state.id.slice(0, 8)} done: ${got.length} nailed, ${shaky.length} to revisit — ${say.slice(0, 70)}`);
  return { summary };
}

// ---------- graph ----------
const LessonState = Annotation.Root({
  id: Annotation(), title: Annotation(), chapter: Annotation(), pages: Annotation(), learner: Annotation(), learnerId: Annotation(),
  plan: Annotation(), current: Annotation(), attempts: Annotation(), question: Annotation(), reply: Annotation(),
  teaching: Annotation(), exchanges: Annotation(), material: Annotation(), outcome: Annotation(), mastery: Annotation(), transcript: Annotation(), summary: Annotation(),
  announced: Annotation(), hooked: Annotation(), guess: Annotation(), review: Annotation(), styles: Annotation(),
});

export const lessonGraph = new StateGraph(LessonState)
  .addNode("build_plan", plan)
  .addNode("open_concept", open)
  .addNode("hear_guess", guess)
  .addNode("teach", teach)
  .addNode("ask", ask)
  .addNode("grade", grade)
  .addNode("wrap", wrap)
  .addEdge(START, "build_plan")
  .addEdge("build_plan", "open_concept")
  .addEdge("open_concept", "hear_guess")
  .addEdge("hear_guess", "teach")
  .addEdge("teach", "ask")
  .addEdge("ask", "grade")
  .addConditionalEdges("grade", afterGrade, { ask: "ask", open: "open_concept", teach: "teach", wrap: "wrap" })
  .addEdge("wrap", END)
  .compile({ checkpointer: lessonSaver });

const settings = (id) => ({ configurable: { thread_id: id }, streamMode: "custom", runName: "halo-lesson", tags: ["halo", "lesson"] });

async function run(id, input, send) {
  for await (const chunk of await lessonGraph.stream(input, settings(id))) {
    if (chunk && typeof chunk.event === "string") send(chunk.event, chunk.data);
  }
  const snapshot = await lessonGraph.getState(settings(id));
  return { id, waiting: (snapshot.next || []).length > 0 };
}

/**
 * Starts a lesson over a chapter and streams it until Halo asks its first question.
 * @param {{ title: string, chapter: string, pages: { page: number, text: string }[], learner?: object }} input
 * @param {(event: string, data: object) => void} send
 * @returns {Promise<{ id: string, waiting: boolean }>}
 */
export async function startLesson(input, send) {
  if (!Array.isArray(input.pages) || !input.pages.length || input.pages.length > 120) throw new Error("Choose a chapter with 1 to 120 pages.");
  const pages = input.pages.map((p) => ({ page: Number(p?.page), text: String(p?.text || "").slice(0, 12000) }));
  if (pages.some((p) => !Number.isInteger(p.page) || p.page < 1) || new Set(pages.map((p) => p.page)).size !== pages.length) throw new Error("Chapter page numbers must be unique positive integers.");
  if (!pages.some((p) => p.text.trim())) throw new Error("This chapter has no readable text. Choose a PDF with a text layer.");
  pages.sort((a, b) => a.page - b.page);
  input = { ...input, pages };
  const id = randomUUID();
  return run(id, { ...input, id }, send);
}

/** Hands the student's reply to the paused lesson and streams what Halo does next. */
// Serialize resumes. A retry with the same request ID replays the completed response, so a
// dropped connection cannot accidentally answer the next question or teach two concepts at once.
const active = new Map();
const replies = new Map();
export async function continueLesson(id, reply, send) {
  const key = `${id}:${reply.requestID || ""}`;
  const cached = reply.requestID ? replies.get(key) || cachedLessonReply(key) : undefined;
  if (cached) {
    for (const [event, data] of cached.events) send(event, data);
    return cached.result;
  }
  if (active.has(id)) {
    const prior = active.get(id);
    if (!reply.requestID || prior.key !== key) throw new Error("Halo is still responding to your last answer.");
    await prior.promise;
    return continueLesson(id, reply, send);
  }
  const events = [];
  const promise = (async () => {
    const snapshot = await lessonGraph.getState(settings(id));
    if (!snapshot?.values?.plan || !(snapshot.next || []).length) throw new Error("That lesson has ended or the server was restarted. Start it again.");
    const action = reply.action || "answer";
    if (!["answer", "skip", "jump"].includes(action)) throw new Error("Unknown lesson action.");
    if (action === "answer" && !clip(reply.answer, 1500)) throw new Error("Say or type an answer, ask a question, or leave this concept for later.");
    if (action === "jump" && !snapshot.values.plan.concepts.some((c) => c.n === Number(reply.concept))) throw new Error("Choose a concept from this lesson's roadmap.");
    const paused = snapshot.tasks?.some((t) => t.interrupts?.length);
    const result = await run(id, paused ? new Command({ resume: reply }) : null, (event, data) => { events.push([event, data]); send(event, data); });
    if (reply.requestID) {
      const completed = { events, result };
      saveLessonReply(key, completed);
      replies.set(key, completed);
      // Audio is large; retain only recent retries.
      while (replies.size > 64) replies.delete(replies.keys().next().value);
    }
    return result;
  })();
  active.set(id, { key, promise });
  try { return await promise; } finally { active.delete(id); }
}
