// Strengths and weaknesses after a quiz or a lesson, written from the student's actual answers, and saved to
// their memory so later quizzes and lessons give the weak spots more care.
//
//   POST /api/insights { kind: "quiz", title, items: [{ ask, expected, answer, verdict, source }], learnerId }
//                      → { strengths: [{ point, why }], weaknesses: [{ point, next }], improved: [string] }
//
// The lesson writes its own in wrap() (lesson.js), from the same rules, in the call that already writes its send-off.
import * as replay from "./replay.js";
import { generateJSON } from "./llm.js";
import { learnerKey, recordInsights, weakSpots } from "./learner-memory.js";

const isMock = () => process.env.HALO_MOCK === "1";
const clip = (value, n) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, n);
const VERDICTS = new Set(["right", "almost", "wrong", "skipped"]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const INSIGHTS_RULES = `"strengths": 1 to 3 skills or ideas their RIGHT answers show they have, each {"point": "<2 to 6 words, lowercase, a skill or idea, not a question>", "why": "<what in their answer showed it, at most 18 words, speaking to them as 'you'>"}. Empty list when nothing was right.
"weaknesses": 1 to 3 ideas their wrong, almost or skipped answers show they are missing, each {"point": "<2 to 6 words, lowercase, the missing idea itself, e.g. 'derivative of the inside function'>", "next": "<one concrete thing to do next, at most 18 words, e.g. 'Write outside' times inside' before you start each problem'>"}. Group related misses into one point. Empty list when everything was right.
"improved": the weak spots from the "Earlier weak spots" list (copy each exactly) that a right answer here clearly shows they now have. Empty list when none.
Ground every point in their actual answers; never invent skills that weren't tested. Plain words, no LaTeX.`;

const SYSTEM = `You are Halo, a warm, honest tutor. A student just finished a quiz on their own notes. From each question, the right answer and what they said, name their strengths and weaknesses.
Reply with JSON only, in exactly this shape (strengths have "why", weaknesses have "next"):
{"strengths": [{"point": "...", "why": "..."}], "weaknesses": [{"point": "...", "next": "..."}], "improved": ["..."]}
${INSIGHTS_RULES}`;

/** The answers as sent: at most 12, everything clipped. */
export function readItems(list) {
  return (Array.isArray(list) ? list.slice(0, 12) : []).map((x) => ({
    ask: clip(x?.ask, 240), expected: clip(x?.expected, 240), answer: clip(x?.answer, 300),
    verdict: VERDICTS.has(x?.verdict) ? x.verdict : "wrong", source: clip(x?.source, 200),
  })).filter((x) => x.ask);
}

/** The model's reply, checked: at most 3 of each, no repeats, improved only from the earlier list. */
export function cleanInsights(raw, { earlier = [], items = [] } = {}) {
  const seen = new Set();
  // Models sometimes put a weakness's next step under "why" (or "step"), so any of them is taken.
  const list = (value, detail) => (Array.isArray(value) ? value : []).map((x) => ({
    point: clip(typeof x === "string" ? x : x?.point, 60).toLowerCase().replace(/[.!]+$/, ""),
    [detail]: clip(x?.[detail] || x?.why || x?.next || x?.step, 140),
  })).filter((x) => x.point && !seen.has(x.point) && seen.add(x.point)).slice(0, 3);
  const anyRight = items.some((x) => x.verdict === "right"), anyMissed = items.some((x) => x.verdict !== "right");
  const known = new Map(earlier.map((g) => [String(g).toLowerCase(), g]));
  return {
    // A list the answers can't support is dropped, whatever the model wrote.
    strengths: anyRight || !items.length ? list(raw?.strengths, "why") : [],
    weaknesses: anyMissed || !items.length ? list(raw?.weaknesses, "next") : [],
    improved: [...new Set((Array.isArray(raw?.improved) ? raw.improved : []).map((g) => known.get(String(g).toLowerCase().trim())).filter(Boolean))].slice(0, 5),
  };
}

/** Offline, or when the model fails: the questions themselves become the points. */
export function fallbackInsights(items) {
  const short = (x) => clip((x.source || x.ask).replace(/[?.!]+$/, ""), 60).toLowerCase();
  return {
    strengths: items.filter((x) => x.verdict === "right").slice(0, 3).map((x) => ({ point: short(x), why: "You answered this one correctly." })),
    weaknesses: items.filter((x) => x.verdict !== "right").slice(0, 3).map((x) => ({ point: short(x), next: x.expected ? `Go back to it in your notes: ${clip(x.expected, 90)}` : "Go back to this part of your notes." })),
    improved: [],
  };
}

/** The learner with their saved weak spots added, for any prompt. Never waits more than 1.5 s for memory. */
export async function withWeakSpots(learner, learnerId) {
  const spots = await Promise.race([weakSpots(learnerKey(learnerId)).catch(() => []), sleep(1500).then(() => [])]);
  if (!spots.length) return learner;
  return { ...(learner && typeof learner === "object" ? learner : {}), weaknesses: spots };
}

export function installInsights(app) {
  app.post("/api/insights", async (req, res) => {
    const b = req.body ?? {};
    const items = readItems(b.items);
    if (!items.length) return res.status(400).json({ error: "items required" });
    const title = clip(b.title, 60);
    const who = learnerKey(b.learnerId);
    const t0 = Date.now();
    // The end of a recorded quiz about the demo document replays too (replay.js); memory is still updated.
    const scoped = items.some((x) => replay.webAllowed(x.ask));
    const recorded = scoped && replay.webCached("insights", b);
    const earlier = recorded ? [] : await Promise.race([weakSpots(who).catch(() => []), sleep(1500).then(() => [])]);
    let insights;
    let failed = false;
    try {
      if (recorded) insights = recorded;
      else if (isMock()) insights = fallbackInsights(items);
      else {
        const raw = await generateJSON({ system: SYSTEM, text: [
          title && `Quiz: "${title}"`,
          earlier.length ? `Earlier weak spots: ${earlier.join("; ")}` : "Earlier weak spots: none",
          items.map((x, i) => `${i + 1}. Q: ${x.ask}\n   Right answer: ${x.expected || "(see their notes)"}${x.source ? `\n   From their notes: "${x.source}"` : ""}\n   They said: ${x.answer || "(nothing: asked to be shown)"}\n   Marked: ${x.verdict}`).join("\n"),
          "Respond with the JSON object only.",
        ].filter(Boolean).join("\n\n") });
        insights = cleanInsights(raw, { earlier, items });
        if (!insights.strengths.length && !insights.weaknesses.length) insights = fallbackInsights(items);
      }
    } catch (e) {
      console.error("[insights] error, using the questions instead", e.message || e);
      insights = fallbackInsights(items); failed = true;
    }
    if (scoped && !recorded && !failed) replay.saveWeb("insights", b, insights);
    recordInsights(who, { how: "quiz", title, ...insights });
    console.log(`[insights] quiz "${title}": ${insights.strengths.length} strengths, ${insights.weaknesses.length} weaknesses, ${insights.improved.length} improved in ${Date.now() - t0}ms`);
    res.json(insights);
  });
}
