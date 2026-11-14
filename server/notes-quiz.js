// Halo in the student's notebook: a quiz written from their own notes, marking for its short answers,
// and plain questions about the notes.
//
//   POST /api/notes/quiz   { notes: [{ title, text }], image?, document?, learner? }
//                          → { title, questions: [{ kind, ask, options, answer, expected, explain, source, audio }] }
//   POST /api/notes/grade  { ask, expected, source?, answer }  → { verdict: "right"|"almost"|"wrong", say, audio }
//   POST /api/notes/ask    { question, notes: [{ title, text }], document?, learner? }  → { say, audio }
//
// Multiple-choice questions are marked on the iPad (the right option is in the quiz); short answers come back here.
import { generateJSON } from "./llm.js";
import { speak } from "./tts.js";
import { despeak } from "./steps.js";
import { plain } from "./lesson.js";
import { QUIZ_SYSTEM, buildQuizText, QUIZ_GRADE_SYSTEM, buildQuizGradeText, NOTES_ASK_SYSTEM, buildNotesAskText } from "./prompt.js";

const isMock = () => process.env.HALO_MOCK === "1";
const clip = (value, n) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, n);
const VERDICTS = new Set(["right", "almost", "wrong"]);

/** The notes as sent: at most 12 notes and 14,000 characters in all, empty ones dropped. */
export function readNotes(list) {
  let room = 14000;
  const notes = [];
  for (const note of Array.isArray(list) ? list.slice(0, 12) : []) {
    const text = String(note?.text ?? "").trim().slice(0, Math.max(0, room));
    if (!text) continue;
    room -= text.length;
    notes.push({ title: clip(note?.title, 80), text });
  }
  return notes;
}

/** How many questions the notes can carry: 5 for a short note, up to 8 for a lot of notes. */
export function questionCount(notes, handwritten = false) {
  const words = notes.reduce((n, note) => n + note.text.split(/\s+/).filter(Boolean).length, 0) + (handwritten ? 120 : 0);
  return Math.max(5, Math.min(8, 4 + Math.round(words / 120)));
}

/** Shuffles a choice question's options, keeping track of the right one, so it is not always in the same place. */
export function shuffled(options, answer, random = Math.random) {
  const order = options.map((_, i) => i);
  for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(random() * (i + 1)); [order[i], order[j]] = [order[j], order[i]]; }
  return { options: order.map((i) => options[i]), answer: order.indexOf(answer) };
}

/** The model's quiz, checked: well-formed questions only, options shuffled, everything clipped to fit the screen. */
export function cleanQuiz(raw, { random = Math.random } = {}) {
  const questions = [];
  for (const q of Array.isArray(raw?.questions) ? raw.questions.slice(0, 10) : []) {
    const ask = clip(q?.ask, 240);
    if (!ask) continue;
    const explain = clip(q?.explain, 260), source = clip(q?.source, 200);
    const options = (Array.isArray(q?.options) ? q.options : []).map((o) => clip(o, 120)).filter(Boolean);
    const answer = Number.isInteger(q?.answer) ? q.answer : Number(q?.answer);
    if (q?.kind === "choice" && options.length >= 3 && options.length <= 5 && new Set(options).size === options.length
        && Number.isInteger(answer) && answer >= 0 && answer < options.length) {
      questions.push({ kind: "choice", ask, ...shuffled(options, answer, random), expected: "", explain, source });
    } else if (q?.kind === "short" || (q?.kind === "choice" && options[answer])) {
      // A choice question that came back broken still has a right answer worth asking for.
      const expected = clip(q?.expected, 240) || clip(options[answer], 120);
      if (expected) questions.push({ kind: "short", ask, options: [], answer: 0, expected, explain, source });
    }
  }
  if (questions.length < 3) throw new Error("Halo couldn't write a quiz from these notes. Add a little more to them and try again.");
  return { title: clip(raw?.title, 60) || "Quiz on your notes", questions: questions.slice(0, 8) };
}

export function cleanGrade(raw) {
  const verdict = VERDICTS.has(raw?.verdict) ? raw.verdict : "wrong";
  return { verdict, say: plain(clip(raw?.say, 220)) || (verdict === "right" ? "That's it." : "Not quite. Have a look at your notes on this.") };
}

function mockQuiz(notes) {
  const lines = notes.flatMap((n) => n.text.split("\n")).map((l) => l.replace(/^[•\-*\s]+/, "").trim()).filter((l) => l.length > 6);
  const pick = (i) => lines[i % lines.length] || "your notes";
  return {
    title: notes[0]?.title || "Quiz on your notes",
    questions: [0, 1, 2, 3, 4].map((i) => i % 2 === 0
      ? { kind: "choice", ask: `Which of these is in your notes?`, options: [pick(i), "Something you didn't write", "A different idea", "None of it"], answer: 0, explain: `You wrote: ${pick(i)}.`, source: pick(i) }
      : { kind: "short", ask: `In your own words, what did you note about "${pick(i).split(" ").slice(0, 4).join(" ")}"?`, expected: pick(i), explain: `Your note says: ${pick(i)}.`, source: pick(i) }),
  };
}

/** Speaks each question (all at once, so the first is ready as soon as the rest). */
async function voiced(questions) {
  const audio = await Promise.all(questions.map((q) => speak(despeak(q.ask)).catch(() => null)));
  return questions.map((q, i) => ({ ...q, audio: audio[i] }));
}

export function installNotesQuiz(app) {
  app.post("/api/notes/quiz", async (req, res) => {
    const b = req.body ?? {};
    const notes = readNotes(b.notes);
    const images = typeof b.image === "string" && b.image ? [{ mime: "image/jpeg", data: b.image, label: "The student's handwritten notes:" }] : [];
    if (!notes.length && !images.length) return res.status(400).json({ error: "notes required" });
    const t0 = Date.now();
    try {
      const count = questionCount(notes, images.length > 0);
      const raw = isMock() ? mockQuiz(notes) : await generateJSON({ images, system: QUIZ_SYSTEM,
        text: buildQuizText({ notes, document: clip(b.document, 120), count, learner: b.learner, handwritten: images.length > 0 }) });
      const quiz = cleanQuiz(raw);
      quiz.questions = await voiced(quiz.questions);
      console.log(`[quiz] "${quiz.title}" ${quiz.questions.length} questions (${quiz.questions.filter((q) => q.kind === "choice").length} choice) from ${notes.length} notes in ${Date.now() - t0}ms`);
      res.json(quiz);
    } catch (e) {
      console.error("[quiz] error", e);
      res.status(500).json({ error: e.message || String(e) });
    }
  });

  app.post("/api/notes/grade", async (req, res) => {
    const b = req.body ?? {};
    const ask = clip(b.ask, 240), expected = clip(b.expected, 240), answer = clip(b.answer, 600);
    if (!ask || !expected) return res.status(400).json({ error: "ask and expected required" });
    try {
      const raw = isMock()
        ? { verdict: answer.length > 3 ? "right" : "wrong", say: answer.length > 3 ? "That matches your notes." : `Your notes say: ${expected}` }
        : await generateJSON({ system: QUIZ_GRADE_SYSTEM, text: buildQuizGradeText({ ask, expected, source: clip(b.source, 200), answer }) });
      const grade = cleanGrade(raw);
      res.json({ ...grade, audio: await speak(despeak(grade.say)).catch(() => null) });
    } catch (e) {
      console.error("[quiz grade] error", e);
      res.status(500).json({ error: e.message || String(e) });
    }
  });

  app.post("/api/notes/ask", async (req, res) => {
    const b = req.body ?? {};
    const question = clip(b.question, 300), notes = readNotes(b.notes);
    if (!question) return res.status(400).json({ error: "question required" });
    try {
      const raw = isMock() ? { say: notes.length ? `From your notes: ${clip(notes[0].text, 160)}` : "You haven't written any notes yet." }
        : await generateJSON({ system: NOTES_ASK_SYSTEM, text: buildNotesAskText({ question, notes, document: clip(b.document, 120), learner: b.learner }) });
      const say = clip(raw?.say, 420) || "I couldn't find that in your notes.";
      res.json({ say, audio: await speak(despeak(say)).catch(() => null) });
    } catch (e) {
      console.error("[notes ask] error", e);
      res.status(500).json({ error: e.message || String(e) });
    }
  });
}
