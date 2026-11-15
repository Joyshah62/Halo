import "dotenv/config";
import { installProcessLogging, requestLogging, log, errorDetails } from "./logging.js";
import express from "express";
import cors from "cors";
import { eventStream } from "./sse.js";
import { convertOffice, ImportError } from "./documents.js";
import { buildUserText, buildSystemPrompt, normalizeConversation, DIGEST_SYSTEM, buildDigestText, RECAP_SYSTEM, buildRecapText, ENHANCE_SYSTEM, buildEnhanceText, REFINE_SYSTEM, buildRefineText } from "./prompt.js";
import { streamText, generateImage, generateJSON, PROVIDER, MODEL } from "./llm.js";
import { speak, ttsEnabled, ttsVoice } from "./tts.js";
import * as db from "./db.js";
import { checkWork } from "./tutor.js";
import { whyStuck } from "./stuck.js";
import { learnerKey, recordTopics } from "./learner-memory.js";
import * as web from "./web.js";
import { cleanStep, despeak, prepareStep } from "./steps.js";
import { catalog as scenes, cleanExplorer } from "../shared/scene3d/schema.js";
import { startLesson, continueLesson } from "./lesson.js";
import * as replay from "./replay.js";
import { installNotesQuiz } from "./notes-quiz.js";
import { installInsights } from "./insights.js";
import { storeFile, tryStoreFile, listFiles, storageEnabled, StorageError, MAX_FILE_BYTES } from "./storage.js";

const PORT = Number(process.env.PORT || 8787);
installProcessLogging();
const app = express();
app.use(cors());
app.use(requestLogging);
app.use(express.json({ limit: "25mb" }));

app.get("/api/health", (_req, res) => res.json({ ok: true, provider: PROVIDER, model: MODEL, tts: ttsEnabled, voice: ttsEnabled ? ttsVoice : null, storage: storageEnabled }));
// Raw bytes avoid base64 overhead. Files and conversion profiles are removed after each request.
// With storage on, the converted PDF is also kept in S3; its public link comes back in X-Halo-File-Url.
app.post("/api/documents/convert", express.raw({ type: "application/octet-stream", limit: "25mb" }), async (req, res) => {
  try {
    const pdf = await convertOffice(req.body, req.query.extension);
    const name = typeof req.query.name === "string" ? req.query.name.replace(/\.[^.]+$/, "") + ".pdf" : undefined;
    const stored = await tryStoreFile({ data: pdf, mime: "application/pdf", kind: "document", name, meta: { convertedFrom: String(req.query.extension || "").toLowerCase() } });
    if (stored) res.set({ "X-Halo-File-Url": stored.url, "X-Halo-File-Id": stored.id });
    res.set({ "Content-Type": "application/pdf", "Cache-Control": "no-store" }).send(pdf);
  } catch (error) {
    res.status(error instanceof ImportError ? error.status : 500).json({ error: error instanceof ImportError ? error.message : "The document could not be imported. Please try again." });
  }
});

app.use("/api/documents/convert", (error, _req, res, next) => {
  if (error.type === "entity.too.large") return res.status(413).json({ error: "Choose a document smaller than 25 MB." });
  next(error);
});

// ---------- Files: bytes in S3, link + details in MongoDB Atlas (storage.js) ----------
// POST /api/files?kind=upload|document&name=notes.pdf  body: raw bytes, Content-Type = the file's type
//   → { file: { id, kind, bucket, key, url, mime, size, name, meta, createdAt } }
app.post("/api/files", express.raw({ type: () => true, limit: MAX_FILE_BYTES }), async (req, res) => {
  try {
    const kind = req.query.kind === "document" ? "document" : "upload";
    const meta = {};
    for (const field of ["title", "learner", "page"]) if (typeof req.query[field] === "string") meta[field] = req.query[field].slice(0, 200);
    const file = await storeFile({
      data: req.body, kind, meta,
      mime: String(req.headers["content-type"] || "application/octet-stream").split(";")[0].trim().toLowerCase(),
      name: typeof req.query.name === "string" ? req.query.name : undefined,
    });
    res.status(201).json({ file });
  } catch (error) {
    if (!(error instanceof StorageError)) log("files.error", { request: res.locals.requestID, ...errorDetails(error) }, "error");
    res.status(error instanceof StorageError ? error.status : 502).json({ error: error instanceof StorageError ? error.message : "The file could not be stored. Please try again." });
  }
});
app.use("/api/files", (error, _req, res, next) => {
  if (error.type === "entity.too.large") return res.status(413).json({ error: "Choose a file smaller than 25 MB." });
  next(error);
});
// GET /api/files?kind=&limit= → { files: [...] } newest first
app.get("/api/files", async (req, res) => {
  try { res.json({ files: await listFiles({ kind: typeof req.query.kind === "string" ? req.query.kind : undefined, limit: req.query.limit }) }); }
  catch (error) { res.status(error instanceof StorageError ? error.status : 502).json({ error: error instanceof StorageError ? error.message : "Files could not be listed." }); }
});

app.get("/api/history", (_req, res) => res.json(db.history()));
app.get("/api/confusion", (_req, res) => res.json(db.confusionMap()));
app.get("/api/flashcards", (_req, res) => res.json(db.flashcards()));
app.delete("/api/history", (_req, res) => { db.clearAll(); res.json({ ok: true }); });

// Step cleaning, speakable text and voice/picture preparation live in steps.js (shared with the lesson agent).

// POST /api/ask  → text/event-stream
// body: { question, image (base64 png/jpeg, no prefix), imageMime, pageText, documentText?, circledText,
//         pageTitle, pageUrl, tutorMode, previousAnswer, parentId }
app.post("/api/ask", async (req, res) => {
  const b = req.body ?? {};
  const started = Date.now();
  const trace = (stage, details = {}) => {
    res.locals.stage = stage;
    log(stage, { request: res.locals.requestID, question: res.locals.questionID, ms: Date.now() - started, ...details });
  };
  if (typeof b.question !== "string" || !b.question.trim()) return res.status(400).json({ error: "question required" });

  const stream = eventStream(res, { onHeartbeat: () => log("ask.waiting", {
    request: res.locals.requestID, question: res.locals.questionID, stage: res.locals.stage, ms: Date.now() - started,
  }) });
  // Pages of the demo document are recorded once and replayed after that (replay.js).
  const replayable = replay.inScope(b.pageTitle, b.pageText);
  const recorded = [];
  const send = (event, data) => {
    if (replayable && (event === "meta" || event === "step")) recorded.push([event, data]);
    return stream.send(event, data);
  };

  const qid = db.logQuestion({
    url: b.pageUrl, title: b.pageTitle, question: b.question,
    mode: b.tutorMode ? "hint" : "answer", parentId: b.parentId,
  });
  res.locals.questionID = qid;
  trace("ask.started", { provider: PROVIDER, model: MODEL, image: Boolean(b.image), contextImage: Boolean(b.contextImage) });
  send("start", { id: qid });
  // Keep the screenshots in S3 alongside the question; runs beside the answer and never delays it.
  const shots = [[b.image, b.imageMime || "image/png", "crop"], [b.contextImage, "image/jpeg", "page"]].filter(([data]) => typeof data === "string" && data);
  for (const [data, mime, role] of shots) {
    tryStoreFile({ data: Buffer.from(data, "base64"), mime, kind: "screenshot", meta: { questionId: qid, role, pageUrl: b.pageUrl ?? null, pageTitle: b.pageTitle ?? null } })
      .then((file) => file && log("ask.screenshot.stored", { request: res.locals.requestID, question: qid, role, url: file.url }));
  }

  try {
  const recording = replayable && replay.findAnswer(b);
  if (recording) {
    trace("ask.replayed", { recordedAt: recording.at });
    for (const [event, data] of recording.events) if (!stream.closed) stream.send(event, data);
    const said = recording.events.filter(([event]) => event === "step").map(([, data]) => data.say);
    const topic = recording.events.find(([event]) => event === "meta")?.[1]?.topic;
    db.finishQuestion(qid, { topic, circledText: (b.circledText || "").slice(0, 500), answerText: said.join(" ") });
    send("done", { id: qid, steps: said.length, ms: Date.now() - started, replayed: true });
    console.log(`[ask] #${qid} replayed ${said.length} steps — ${b.question}`);
    return;
  }
  const images = [];
  if (b.contextImage) images.push({ mime: "image/jpeg", data: b.contextImage, label: "Screenshot of the whole visible page (for context):" });
  if (b.image) images.push({ mime: b.imageMime || "image/png", data: b.image, label: "Close-up of the rectangular section the student selected:" });
  const documentText = String(b.documentText || "").slice(0, 30000);
  // Asked from inside the 3D explorer: which model the student is holding and the part they touched.
  const explorer = cleanExplorer(b.explorer);
  // Nothing on this page to point at for a question about the whole document, or about a 3D model.
  const pointing = !explorer && b.pointing === true && Boolean(b.pageText) && !documentText;
  const system = buildSystemPrompt({ surface: b.surface === "panel" ? "panel" : "margin", pointing, supports3D: b.supports3D === true, explorer });
  const userText = buildUserText({
    pointing,
    question: b.question,
    pageTitle: b.pageTitle,
    pageUrl: b.pageUrl,
    circledText: (b.circledText || "").slice(0, 2000),
    pageText: (b.pageText || "").slice(0, 12000),
    documentText,
    previousAnswer: b.previousAnswer,
    tutorMode: Boolean(b.tutorMode),
    selectionMode: b.selectionMode,
    learner: b.learner,
  });


  let meta = null;
  const steps = [];
  const ttsJobs = [];       // promises in step order
  let emitted = 0;
  let buffer = "";
  // Emit steps strictly in order, each once its audio is ready.
  async function flush() {
    while (emitted < ttsJobs.length) {
      const audio = await ttsJobs[emitted];
      if (stream.closed) return;
      send("step", { index: emitted, ...steps[emitted], audio });
      emitted++;
      trace("ask.step.sent", { index: emitted - 1, audio: Boolean(audio) });
    }
  }
  let flushing = Promise.resolve(), preparationError;
  const queueFlush = () => {
    flushing = flushing.then(flush).catch((error) => { preparationError = error; });
  };

  function handleLine(line) {
    line = line.trim().replace(/^```[a-z]*$|^```$/i, "");
    if (!line) return;
    let obj;
    try { obj = JSON.parse(line); } catch {
      // Tolerate stray fences/prose: try to extract the first {...}
      const m = line.match(/\{.*\}/);
      if (!m) return;
      try { obj = JSON.parse(m[0]); } catch { return; }
    }
    if (!meta && obj.mode) {
      meta = { mode: obj.mode === "hint" ? "hint" : "answer", topic: String(obj.topic || "").toLowerCase().slice(0, 60) };
      send("meta", meta);
      return;
    }
    const step = cleanStep(obj);
    if (!step) return;
    steps.push(step);
    trace("ask.media.started", { index: steps.length - 1 });
    ttsJobs.push(prepareStep(step, steps.slice(0, -1).map((x) => x.say).join(" ")).catch((error) => {
      log("ask.media.error", { request: res.locals.requestID, ...errorDetails(error) }, "warn"); return null;
    }));
    queueFlush();
  }

  const t0 = Date.now();
  if (process.env.HALO_MOCK === "1") {
    // Offline demo fallback: canned steps, same wire format.
    const mock = b.tutorMode
      ? [{ mode: "hint", topic: "chain rule" },
         { say: "Look at this step: you differentiated the outside but what about the inside?", ink: [{ type: "arrow", to: "circled" }, { type: "text", value: "outside ✓   inside ?" }] },
         { say: "What is the derivative of the expression inside the parentheses?", ink: [{ type: "text", value: "d/dx (inside) = ?" }, { type: "underline", target: "previous" }] }]
      : [{ mode: "answer", topic: "chain rule" },
         { say: "This 2 comes from differentiating x squared.", ink: [{ type: "arrow", to: "circled" }, { type: "text", value: "d/dx (x²) = 2x" }] },
         { say: "The chain rule then multiplies by the derivative of the inside.", ink: [{ type: "text", value: "× inner derivative" }, { type: "underline", target: "previous" }, { type: "point", quote: "chain rule", style: "highlight" }] },
         { say: "So the 2 is just the power coming down in front.", ink: [{ type: "text", value: "power → coefficient" }, { type: "box", target: "previous" }] }];
    if (explorer) {
      // Offline, the explorer still answers from what Halo knows about each part, and still points at the model.
      const parts = scenes[explorer.model].parts, ids = Object.keys(parts);
      const first = explorer.focus || ids[0], next = ids[(ids.indexOf(first) + 1) % ids.length];
      const sentence = (text) => text.split(/(?<=[.!?])\s+/)[0];
      mock.length = 0;
      mock.push({ mode: "answer", topic: parts[first].label.toLowerCase() },
        { say: `This is the ${parts[first].label.toLowerCase()}. ${parts[first].detail}`, ink: [{ type: "scene3d", model: explorer.model, focus: first }, { type: "text", value: sentence(parts[first].detail) }] },
        { say: `It works closely with its neighbor, the ${parts[next].label.toLowerCase()}.`, ink: [{ type: "scene3d", model: explorer.model, focus: next }, { type: "text", value: `${parts[next].label}: ${sentence(parts[next].detail)}` }] },
        { say: `So when you think about the ${parts[first].label.toLowerCase()}, picture it as one part of a team.`, ink: [{ type: "scene3d", model: explorer.model, focus: first }, { type: "text", value: `${parts[first].label} never works alone` }] });
    }
    if (b.previousAnswer && !b.tutorMode && !explorer) mock[1] = { say: "This line is the inner derivative we multiplied by.", ink: [{ type: "arrow", to: "circled" }, { type: "text", value: "u = x² + 1 → u′ = 2x" }] };
    console.log(`[mock] #${qid} q="${b.question}" tutor=${!!b.tutorMode} followUp=${!!b.previousAnswer} crop=${b.image ? Math.round(b.image.length * 0.75 / 1024) + "KB" : "none"} circledText="${(b.circledText || "").slice(0, 60)}"`);
    if (b.selectionMode === "page") {
      for (const step of mock) if (step.ink) step.ink = step.ink.filter((item) => item.type !== "arrow" || item.to !== "circled");
    }
    for (const line of mock) handleLine(JSON.stringify(line));
    await new Promise((r) => setTimeout(r, 400));
    await flushing;
    db.finishQuestion(qid, { topic: meta?.topic, circledText: (b.circledText || "").slice(0, 500), answerText: steps.map((s) => s.say).join(" ") });
    if (replayable && !stream.closed) replay.saveAnswer(b, recorded);
    send("done", { id: qid, steps: steps.length, ms: Date.now() - t0 });
    return res.end();
  }
    trace("ask.provider.started");
    let fullText = "";
    for await (const delta of streamText({ images, text: userText, system, conversation: normalizeConversation(b.conversation) })) {
      if (stream.closed) break;
      if (!fullText) trace("ask.provider.first_delta");
      fullText += delta;
      buffer += delta;
      let nl;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        handleLine(buffer.slice(0, nl));
        buffer = buffer.slice(nl + 1);
      }
    }
    trace("ask.provider.finished", { characters: fullText.length, steps: steps.length });
    if (buffer.trim()) handleLine(buffer);
    await flushing;
    if (preparationError) throw preparationError;
    if (stream.closed) return;
    if (!meta) { meta = { mode: b.tutorMode ? "hint" : "answer", topic: "" }; send("meta", meta); }
    // Only a complete, real answer is kept: not the "couldn't read that" fallback, not one the student walked away from.
    if (replayable && steps.length && emitted === steps.length) replay.saveAnswer(b, recorded);
    if (steps.length === 0) {
      // Fallback: plain text next to the circle
      const text = fullText.replace(/```[a-z]*|```/g, "").trim();
      const step = { say: text || "I couldn't read that. Try cropping a wider section.", ink: [{ type: "arrow", to: "circled" }, { type: "text", value: "Try a wider crop" }] };
      steps.push(step);
      send("step", { index: 0, ...step, audio: await speak(step.say) });
    }
    db.finishQuestion(qid, {
      topic: meta.topic,
      circledText: (b.circledText || "").slice(0, 500),
      answerText: steps.map((s) => s.say).join(" "),
    });
    send("done", { id: qid, steps: steps.length, ms: Date.now() - t0 });
    trace("ask.completed", { steps: steps.length });
    console.log(`[ask] #${qid} ${meta.mode} "${meta.topic}" ${steps.length} steps in ${Date.now() - t0}ms — ${b.question}`);
  } catch (e) {
    log("ask.error", { request: res.locals.requestID, question: res.locals.questionID, stage: res.locals.stage, ...errorDetails(e) }, "error");
    console.error("[ask] error", e);
    if (!stream.closed) send("error", { message: e.message || String(e) });
  } finally {
    res.end();
  }
});

// POST /api/check → text/event-stream. "Halo watches you work": the student paused while solving by hand.
// body: { image (base64 of the working, with the printed problem if it fits), imageMime, problem, pageText,
//         pageTitle, pageUrl, learner, learnerId (a correct or wrong result is recorded as practice on that topic) }
// events: start {} → stage {name} … → verdict { status: correct|wrong|unsure|nothing, line, box {x,y,w,h in 0-1 of
//         the image}, kind, concept, topic, lines, checks } → meta + step (same shape as /api/ask; only when wrong) → done
const practising = new Map();   // learner → the problem they were last checked on
app.post("/api/check", async (req, res) => {
  const b = req.body ?? {};
  if (typeof b.image !== "string" || !b.image) return res.status(400).json({ error: "image required" });

  const stream = eventStream(res);
  const send = (event, data) => stream.send(event, data);
  const t0 = Date.now();
  send("start", {});
  try {
    const { verdict, steps: raw } = await checkWork(
      { image: b.image, imageMime: b.imageMime, problem: b.problem, pageText: b.pageText, learner: b.learner },
      (name) => send("stage", { name, ms: Date.now() - t0 }),
    );
    let qid = null;
    const steps = raw.map(cleanStep).filter(Boolean);
    if (verdict.status === "wrong" && steps.length) {
      // A caught mistake is a confusion signal: it joins the same history the confusion map is built from.
      qid = db.logQuestion({ url: b.pageUrl, title: b.pageTitle, question: `(working) ${verdict.problem || "checked a step"}`, mode: "check" });
      db.finishQuestion(qid, { topic: verdict.topic, circledText: (verdict.lines.find((l) => l.n === verdict.line)?.text || "").slice(0, 500), answerText: steps.map((s) => s.say).join(" ") });
    }
    send("verdict", { id: qid, ...verdict });
    // Solved or slipped, it was practice on this topic: it goes into what the learner has covered.
    if ((verdict.status === "correct" || verdict.status === "wrong") && verdict.topic) {
      const page = Number(String(b.pageUrl || "").match(/\/page\/(\d+)/)?.[1]) || 0;
      // Halo checks after every pause, so one problem counts once; later checks of it only update the result.
      const who = learnerKey(b.learnerId), again = practising.get(who) === verdict.problem;
      practising.set(who, verdict.problem);
      recordTopics(who, [{ topic: verdict.topic, how: "practice", result: verdict.status === "correct" ? "solved it" : "made a mistake", book: String(b.pageTitle || "").split(" · ")[0], page, again }]);
    }
    if (steps.length) {
      send("meta", { mode: "hint", topic: verdict.topic });
      let said = "";
      for (const [index, step] of steps.entries()) {
        const audio = await prepareStep(step, said);
        send("step", { index, ...step, audio });
        said += ` ${step.say}`;
      }
    }
    send("done", { id: qid, steps: steps.length, ms: Date.now() - t0 });
    const flagged = verdict.status === "wrong" ? ` line ${verdict.line} (${verdict.kind}: ${verdict.concept}) — ${steps[0]?.say ?? ""}` : "";
    console.log(`[check] ${verdict.status} "${verdict.topic || ""}" ${verdict.lines.length} lines, ${verdict.checks.map((c) => c.result).join(",") || "no checks"} in ${Date.now() - t0}ms${flagged}`);
  } catch (e) {
    console.error("[check] error", e);
    send("error", { message: e.message || String(e) });
  } finally {
    res.end();
  }
});

// POST /api/stuck → text/event-stream. "Why am I stuck?": after a caught mistake, a deep agent (stuck.js) finds the idea
// the student is missing and the page of their own book that teaches it, and remembers the gap for next time.
// body: { problem, lines: [{ n, source, text }], line, concept, hint, title, chapter, pages: [{ page, text }], learner,
//         learnerId (the iPad's anonymous device ID; memory is kept per ID, in Backboard when BACKBOARD_API_KEY is set) }
//         (problem, lines, line and concept are the /api/check verdict's; pages is the chapter or book, as for a lesson)
// events: start {} → todos { todos: [{ content, status }] } (the agent's own plan, as it changes) and stage { name, say, page? }
//         (what it is doing right now) → diagnosis { gap, why, page, quote, seenBefore, question }
//         → meta + step (same shape as /api/ask; the step that sends them to the book carries a `point` with `page`) → done
app.post("/api/stuck", async (req, res) => {
  const b = req.body ?? {};
  const pages = (Array.isArray(b.pages) ? b.pages : []).slice(0, 400).map((p) => ({ page: Number(p?.page) || 0, text: String(p?.text || "").slice(0, 6000) })).filter((p) => p.page > 0 && p.text.trim());
  const lines = (Array.isArray(b.lines) ? b.lines : []).slice(0, 24).map((l) => ({ n: Number(l?.n) || 0, source: l?.source === "printed" ? "printed" : "handwritten", text: String(l?.text || "").slice(0, 160) }));
  if (!lines.length && !(typeof b.problem === "string" && b.problem.trim())) return res.status(400).json({ error: "problem or lines required" });

  const stream = eventStream(res);
  const send = (event, data) => stream.send(event, data);
  const t0 = Date.now();
  send("start", {});
  try {
    const { steps: raw, ...diagnosis } = await whyStuck(
      { problem: String(b.problem || "").slice(0, 300), lines, line: Number(b.line) || 0, concept: String(b.concept || "").slice(0, 80), hint: String(b.hint || "").slice(0, 240),
        title: String(b.title || "").slice(0, 120), chapter: String(b.chapter || "").slice(0, 120), pages, learner: b.learner,
        learnerId: typeof b.learnerId === "string" ? b.learnerId.slice(0, 64) : "" },
      (event, data) => send(event, { ...data, ms: Date.now() - t0 }),
    );
    send("diagnosis", diagnosis);
    const steps = raw.map(cleanStep).filter(Boolean);
    if (steps.length) {
      send("meta", { mode: "hint", topic: diagnosis.gap });
      let said = "";
      for (const [index, step] of steps.entries()) {
        const audio = await prepareStep(step, said);
        send("step", { index, ...step, audio });
        said += ` ${step.say}`;
      }
    }
    send("done", { steps: steps.length, ms: Date.now() - t0 });
    console.log(`[stuck] "${diagnosis.gap}" → p.${diagnosis.page || "?"}${diagnosis.seenBefore ? " (seen before)" : ""}, ${pages.length} pages searched in ${Date.now() - t0}ms`);
  } catch (e) {
    console.error("[stuck] error", e);
    send("error", { message: e.message || String(e) });
  } finally {
    res.end();
  }
});

// POST /api/digest → JSON document map + spoken welcome (the upload "wow" moment)
// body: { title, pages: [{ page, text, image? (base64 jpeg thumbnail) }], learner }
app.post("/api/digest", async (req, res) => {
  const b = req.body ?? {};
  const pages = (Array.isArray(b.pages) ? b.pages : []).slice(0, 80).map((p, i) => ({
    page: Number(p.page) || i + 1, text: String(p.text || "").slice(0, 2500), image: typeof p.image === "string" ? p.image : null,
  }));
  if (!pages.length) return res.status(400).json({ error: "pages required" });
  const t0 = Date.now();
  try {
    let map;
    if (process.env.HALO_MOCK === "1") {
      map = { title: b.title || "Sample lesson", subject: "calculus", say: "Okay, this is a short chain rule lesson, three pages. Page two is where it gets interesting... that's where the inside and outside derivatives meet. Want to start there?",
        keyIdeas: ["power rule: xⁿ → n·xⁿ⁻¹", "chain rule = outside′ × inside′", "always ask: what's inside?"], startHere: 2,
        pages: pages.map((p) => ({ page: p.page, topic: ["power rule", "chain rule", "practice"][(p.page - 1) % 3], difficulty: p.page === 2 ? 3 : 1, note: p.page === 2 ? "students forget the inner derivative" : "" })) };
    } else {
      const images = pages.filter((p) => p.image && p.text.length < 200).slice(0, 8)
        .map((p) => ({ mime: "image/jpeg", data: p.image, label: `Thumbnail of page ${p.page}:` }));
      map = await generateJSON({ images, text: buildDigestText({ title: b.title, pages, learner: b.learner, chapter: b.chapter }), system: DIGEST_SYSTEM });
    }
    // sanitize
    const byPage = new Map((Array.isArray(map.pages) ? map.pages : []).map((p) => [Number(p.page), p]));
    const out = {
      title: String(map.title || b.title || "Document").slice(0, 60),
      subject: String(map.subject || "").slice(0, 40),
      say: String(map.say || "").slice(0, 400),
      keyIdeas: (Array.isArray(map.keyIdeas) ? map.keyIdeas : []).slice(0, 3).map((k) => String(k).slice(0, 44)),
      // Pages keep the numbers the client sent, so a chapter of a book starts mid-document.
      startHere: Math.min(pages[pages.length - 1].page, Math.max(pages[0].page, Number(map.startHere) || pages[0].page)),
      pages: pages.map((p) => {
        const m = byPage.get(p.page) || {};
        return { page: p.page, topic: String(m.topic || "").slice(0, 40), difficulty: [1, 2, 3].includes(Number(m.difficulty)) ? Number(m.difficulty) : 1, note: String(m.note || "").slice(0, 80) };
      }),
      audio: null,
    };
    if (out.say) out.audio = await speak(out.say);
    console.log(`[digest] "${out.title}" ${pages.length} pages in ${Date.now() - t0}ms — ${out.say.slice(0, 80)}`);
    res.json(out);
  } catch (e) {
    console.error("[digest] error", e);
    res.status(500).json({ error: e.message || String(e) });
  }
});

// POST /api/recap → written summary of a study session: each question asked and how it was explained (no audio)
// body: { title, learner, notes: [{ n, page, chapter, topic, questions: [], written: [], said }] }
app.post("/api/recap", async (req, res) => {
  const b = req.body ?? {};
  const notes = (Array.isArray(b.notes) ? b.notes : []).slice(0, 60).map((n, i) => ({
    n: Number(n.n) || i + 1, page: Number(n.page) || 1, chapter: String(n.chapter || "").slice(0, 80), topic: String(n.topic || "").slice(0, 40),
    questions: (Array.isArray(n.questions) ? n.questions : []).slice(0, 8).map((q) => String(q).slice(0, 300)),
    written: (Array.isArray(n.written) ? n.written : []).slice(0, 14).map((w) => String(w).slice(0, 120)),
    said: String(n.said || "").slice(0, 900),
  }));
  if (!notes.length) return res.status(400).json({ error: "notes required" });
  const t0 = Date.now();
  try {
    const topics = [...new Set(notes.map((n) => n.topic).filter(Boolean))];
    const raw = process.env.HALO_MOCK === "1"
      ? { headline: topics.slice(0, 2).join(" and ") || "Your session", overview: `Covered ${topics.slice(0, 3).join(", ") || "a few questions"}.`,
          items: notes.map((n) => ({ note: n.n, question: n.questions.join(" Then: "), points: n.written.slice(0, 4) })) }
      : await generateJSON({ text: buildRecapText({ title: b.title, notes, learner: b.learner }), system: RECAP_SYSTEM });
    // One item per note, in the student's order, whatever the model returned.
    const byNote = new Map((Array.isArray(raw.items) ? raw.items : []).map((i) => [Number(i?.note), i]));
    const out = {
      headline: String(raw.headline || "Your session").slice(0, 60),
      overview: String(raw.overview || "").slice(0, 260),
      items: notes.map((n) => {
        const item = byNote.get(n.n) || {};
        const points = (Array.isArray(item.points) ? item.points : []).map((p) => String(p).slice(0, 200)).filter(Boolean).slice(0, 5);
        return { note: n.n, question: String(item.question || n.questions.join(" Then: ")).slice(0, 200), points: points.length ? points : n.written.slice(0, 4) };
      }),
    };
    console.log(`[recap] ${notes.length} notes in ${Date.now() - t0}ms — ${out.headline}`);
    res.json(out);
  } catch (e) {
    console.error("[recap] error", e);
    res.status(500).json({ error: e.message || String(e) });
  }
});

// POST /api/notes/enhance → the student's own notes, organized and filled out (no audio)
// body: { text and/or image (base64 picture of handwritten notes), imageMime?, title?, document?, chapter?, page?, pageText?, learner? }
// → { title, summary, sections: [{ heading, points: [{ text, added }], image (a diagram to draw, or "") }], terms, corrections }
// Diagrams are drawn separately (POST /api/notes/image), so the written notes appear first.
app.post("/api/notes/enhance", async (req, res) => {
  const b = req.body ?? {};
  const text = typeof b.text === "string" ? b.text.trim().slice(0, 12000) : "";
  // Notes written by hand arrive as a picture of the page; typed and handwritten parts can come together.
  const images = typeof b.image === "string" && b.image ? [{ mime: b.imageMime || "image/jpeg", data: b.image, label: "The student's handwritten notes:" }] : [];
  if (text.length < 3 && !images.length) return res.status(400).json({ error: "text or image required" });
  const title = String(b.title || "").trim().slice(0, 80);
  const t0 = Date.now();
  try {
    const raw = process.env.HALO_MOCK === "1"
      ? mockEnhanced(text || "Handwritten notes\n(read on the live server)", title)
      : await generateJSON({ images, system: ENHANCE_SYSTEM, text: buildEnhanceText({
          text, title, handwritten: images.length > 0, document: String(b.document || "").slice(0, 120), chapter: String(b.chapter || "").slice(0, 120),
          page: Number(b.page) || null, pageText: String(b.pageText || "").slice(0, 6000), learner: b.learner }) });
    let diagrams = 0;
    const sections = (Array.isArray(raw.sections) ? raw.sections : []).slice(0, 6).map((s) => {
      const points = (Array.isArray(s?.points) ? s.points : []).slice(0, 8)
        .map((p) => (typeof p === "string" ? { text: p, added: false } : { text: String(p?.text || ""), added: p?.added === true }))
        .map((p) => ({ text: p.text.trim().slice(0, 320), added: p.added })).filter((p) => p.text);
      const image = typeof s?.image === "string" && s.image.trim().length > 8 && diagrams < 2 ? s.image.trim().slice(0, 300) : "";
      if (image) diagrams++;
      return { heading: String(s?.heading || "").trim().slice(0, 60), points, image };
    }).filter((s) => s.points.length);
    if (!sections.length) throw new Error("Halo couldn't make sense of these notes. Add a little more and try again.");
    const out = {
      title: String(raw.title || title || "My notes").trim().slice(0, 70),
      summary: String(raw.summary || "").trim().slice(0, 320),
      sections,
      terms: (Array.isArray(raw.terms) ? raw.terms : []).filter((t) => t?.term && t?.meaning).slice(0, 5)
        .map((t) => ({ term: String(t.term).slice(0, 40), meaning: String(t.meaning).slice(0, 160) })),
      corrections: (Array.isArray(raw.corrections) ? raw.corrections : []).filter((c) => c?.wrote && c?.correct).slice(0, 4)
        .map((c) => ({ wrote: String(c.wrote).slice(0, 160), correct: String(c.correct).slice(0, 260) })),
    };
    console.log(`[notes] "${out.title}" ${sections.length} sections, ${sections.reduce((n, s) => n + s.points.filter((p) => p.added).length, 0)} added points, ${diagrams} diagrams in ${Date.now() - t0}ms`);
    res.json(out);
  } catch (e) {
    console.error("[notes] error", e);
    res.status(500).json({ error: e.message || String(e) });
  }
});

// POST /api/notes/refine → one circled or selected part of the student's notes, refined as they asked
// body: { ask, image? (base64 crop of circled handwriting), overview? (whole handwritten page), selected? (typed text),
//         text?, title?, document?, pageText?, learner? }  → { title, points: [{ text, added }], replacement, image }
app.post("/api/notes/refine", async (req, res) => {
  const b = req.body ?? {};
  const selected = typeof b.selected === "string" ? b.selected.trim().slice(0, 4000) : "";
  const pictures = [];
  if (typeof b.image === "string" && b.image) pictures.push({ mime: "image/jpeg", data: b.image, label: "The part of their handwritten notes they circled:" });
  if (typeof b.overview === "string" && b.overview) pictures.push({ mime: "image/jpeg", data: b.overview, label: "Their whole handwritten page, for context:" });
  if (!selected && !pictures.length) return res.status(400).json({ error: "image or selected text required" });
  const ask = String(b.ask || "").trim().slice(0, 300);
  const t0 = Date.now();
  try {
    const raw = process.env.HALO_MOCK === "1"
      ? { title: "Refined", points: (selected || "Your circled notes").split("\n").filter(Boolean).map((t) => ({ text: t.trim(), added: false })), replacement: selected, image: "" }
      : await generateJSON({ images: pictures, system: REFINE_SYSTEM, text: buildRefineText({
          ask, selected, handwritten: pictures.length > 0, text: String(b.text || "").slice(0, 6000), title: String(b.title || "").slice(0, 80),
          document: String(b.document || "").slice(0, 120), pageText: String(b.pageText || "").slice(0, 4000), learner: b.learner }) });
    const points = (Array.isArray(raw.points) ? raw.points : []).slice(0, 6)
      .map((p) => (typeof p === "string" ? { text: p, added: false } : { text: String(p?.text || ""), added: p?.added === true }))
      .map((p) => ({ text: p.text.trim().slice(0, 240), added: p.added })).filter((p) => p.text);
    if (!points.length) throw new Error("Halo couldn't read that part. Try circling a little more.");
    const out = {
      title: String(raw.title || "").trim().slice(0, 60),
      points,
      replacement: selected ? String(raw.replacement || "").trim().slice(0, 4000) : "",
      image: typeof raw.image === "string" && raw.image.trim().length > 8 ? raw.image.trim().slice(0, 300) : "",
    };
    console.log(`[refine] "${ask || "clean it up"}" → "${out.title}" ${points.length} points${out.image ? " + diagram" : ""} in ${Date.now() - t0}ms`);
    res.json(out);
  } catch (e) {
    console.error("[refine] error", e);
    res.status(500).json({ error: e.message || String(e) });
  }
});

// Quiz me on my notes, mark a short answer, ask about my notes (notes-quiz.js).
installNotesQuiz(app);
// Strengths and weaknesses after a quiz, saved to the learner's memory (insights.js).
installInsights(app);
// POST /api/notes/image → { image: { mime, data (base64), url? } | null }: one diagram for a section of enhanced notes.
// url is the image's public S3 link when storage is on.
app.post("/api/notes/image", async (req, res) => {
  const prompt = typeof req.body?.prompt === "string" ? req.body.prompt.trim().slice(0, 300) : "";
  if (!prompt) return res.status(400).json({ error: "prompt required" });
  const image = process.env.HALO_MOCK === "1" ? null : await generateImage(prompt);
  if (image?.data) {
    const file = await tryStoreFile({ data: Buffer.from(image.data, "base64"), mime: image.mime || "image/png", kind: "note-image", meta: { prompt } });
    if (file) image.url = file.url;
  }
  res.json({ image });
});

// ---------- Go deeper: Halo looks it up on the web (see web.js) ----------
const webRoute = (name, run) => async (req, res) => {
  try { res.json(await run(req.body ?? {})); }
  catch (e) { console.error(`[dive] ${name} error`, e); res.status(500).json({ error: e.message || String(e) }); }
};
// POST /api/dive/plan { question, context?, document?, learner? } → { title, say, web, video, wiki, image }
app.post("/api/dive/plan", webRoute("plan", (b) => web.plan(b)));
// POST /api/dive/answer { question, topic?, context?, learner? } → { sections: [{ heading, text, cites: [n] }], takeaway, say, next: [question], audio, sources: [{ title, url, site }], searches }
app.post("/api/dive/answer", webRoute("answer", (b) => web.answer(b)));
// POST /api/dive/videos { query } → { videos: [{ id, title, channel, length, views }] }
app.post("/api/dive/videos", webRoute("videos", async (b) => ({ videos: await web.videos(b.query) })));
// POST /api/dive/moment { videoId, question, title? } → { moment: { start, why } | null }: Halo watches the video for the student
app.post("/api/dive/moment", webRoute("moment", async (b) => ({ moment: await web.moment(b) })));
// POST /api/dive/images { wiki?, query?, question? } → { images: [{ thumb, title, credit, license, page, width, height }] }
app.post("/api/dive/images", webRoute("images", async (b) => ({ images: await web.images(b) })));
// GET /api/dive/picture?u=<address> → the picture itself, fetched by the server. A fallback for when the iPad can't reach
// a picture host directly (school Wi-Fi, the simulator). Only the hosts the board uses are allowed.
const PICTURE_HOSTS = /^(i\.ytimg\.com|(?:upload|thumb)\.wikimedia\.org|www\.google\.com)$/;
app.get("/api/dive/picture", async (req, res) => {
  try {
    const url = new URL(String(req.query.u || ""));
    if (url.protocol !== "https:" || !PICTURE_HOSTS.test(url.hostname) || (url.hostname === "www.google.com" && url.pathname !== "/s2/favicons")) return res.status(400).end();
    const r = await fetch(url, { headers: { "User-Agent": "HaloStudyApp/1.0 (student project)" }, signal: AbortSignal.timeout(10000) });
    const type = r.headers.get("content-type") || "";
    if (!r.ok || !type.startsWith("image/")) return res.status(502).end();
    res.set("Content-Type", type).set("Cache-Control", "public, max-age=86400").send(Buffer.from(await r.arrayBuffer()));
  } catch { res.status(502).end(); }
});
// POST /api/speak { text } → { audio: base64 | null }
app.post("/api/speak", webRoute("speak", async (b) => ({ audio: typeof b.text === "string" && b.text.trim() ? await speak(despeak(b.text).slice(0, 400)) : null })));

// ---------- Teach me this chapter: a LangGraph lesson that pauses for the student's answers (see lesson.js) ----------
// Both routes stream text/event-stream:
//   plan { id, title, say, audio, concepts: [{ n, name, why, page, kind, minutes, hook }], fillers: [{ kind, say, audio }] }   (start only)
//   concept { n }  →  material { … }  →  question { n, kind: "hook", ask, audio }          Halo asks what they think first
//   (their guess)  →  material …  →  step { index, say, ink, audio, focus } …  →  question { n, kind, style, ask, options, hint, audio }
//   grade { n, verdict, say, audio, note }  →  (steps …)  →  question { …, again: true } | concept … | finish { say, audio, nailed, revisit, takeaway }
//   done { id, waiting }      waiting = true while the lesson is paused on a question
const lessonRoute = (run) => async (req, res) => {
  const b = req.body ?? {};
  const stream = eventStream(res);
  const send = (event, data) => stream.send(event, data);
  const t0 = Date.now();
  try {
    const out = await run(b, send, () => closed);
    send("done", { ...out, ms: Date.now() - t0 });
  } catch (e) {
    log("lesson.error", { request: res.locals.requestID, ...errorDetails(e) }, "error");
    console.error("[lesson] error", e);
    send("error", { message: e.message || String(e) });
  } finally { res.end(); }
};
// POST /api/lesson/start { title, chapter, pages: [{ page, text }], learner }
app.post("/api/lesson/start", lessonRoute((b, send) => {
  const pages = (Array.isArray(b.pages) ? b.pages : []).map((p) => ({ page: Number(p?.page), text: String(p?.text || "").slice(0, 12000) }));
  if (!pages.length) throw new Error("pages required");
  return startLesson({ title: String(b.title || "").slice(0, 120), chapter: String(b.chapter || "").slice(0, 120), pages, learner: b.learner,
        learnerId: typeof b.learnerId === "string" ? b.learnerId.slice(0, 64) : "" }, send);
}));
// POST /api/lesson/answer { id, answer, action: "answer" | "skip" | "jump", concept }
app.post("/api/lesson/answer", lessonRoute((b, send) => {
  if (typeof b.id !== "string" || !b.id) throw new Error("lesson id required");
  return continueLesson(b.id, { answer: String(b.answer || "").slice(0, 1500), action: ["answer", "skip", "jump"].includes(b.action) ? b.action : "answer", concept: Number(b.concept) || 0, requestID: String(b.requestID || "").slice(0, 100) }, send);
}));

/** Offline stand-in: paragraphs become sections, lines become points. Nothing is added. */
function mockEnhanced(text, title) {
  const blocks = text.split(/\n\s*\n/).map((b) => b.split("\n").map((l) => l.replace(/^\s*[-•*·]+\s*/, "").trim()).filter(Boolean)).filter((b) => b.length);
  return {
    title: title || blocks[0][0].slice(0, 50),
    summary: "",
    sections: blocks.map((lines, i) => {
      const headed = lines.length > 1 && lines[0].length <= 40;
      return { heading: headed ? lines[0].replace(/:$/, "") : blocks.length > 1 ? `Part ${i + 1}` : "Notes", points: (headed ? lines.slice(1) : lines).map((l) => ({ text: l, added: false })), image: "" };
    }),
  };
}

app.use((error, req, res, _next) => {
  log("request.error", { request: res.locals.requestID, path: req.path, ...errorDetails(error) }, "error");
  if (res.headersSent) {
    if (!res.writableEnded && !res.destroyed) res.end(`event: error\ndata: ${JSON.stringify({ message: "The server couldn’t finish this answer. Please retry." })}\n\n`);
    return;
  }
  res.status(error.status || 500).json({ error: "The request could not be completed. Check the server log for its request ID." });
});

const httpServer = app.listen(PORT, () => {
  log("server.listening", { port: PORT, provider: PROVIDER, model: MODEL });
  // Library voices can take several seconds on first use; warm it so the first real answer isn't the slow one.
  if (ttsEnabled) { const t = Date.now(); speak("Hi.").then((a) => console.log(`[tts] voice warmed in ${Date.now() - t}ms${a ? "" : " (failed)"}`)); }
  console.log(`Halo server on http://localhost:${PORT}  ${PROVIDER}/${MODEL}  tts=${ttsEnabled ? "elevenlabs" : "off (browser fallback)"}`);
});
