// "Go deeper": Halo looks a question up on the live web.
//   plan    → what to search for (one fast model call)
//   answer  → an explanation grounded in Google Search, with the pages it used as numbered sources
//   videos  → YouTube results that can be played inside the app
//   moment  → Gemini watches one of those videos and finds the part that answers the question
//   images  → real diagrams and photos from Wikipedia / Wikimedia Commons, with credits
import { generateJSON, MODEL } from "./llm.js";
import { speak } from "./tts.js";

const isMock = () => process.env.HALO_MOCK === "1";
const BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const WIKI_AGENT = "HaloStudyApp/1.0 (student project)";
const clip = (value, n) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, n);
const plain = (html) => clip(String(html ?? "").replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">"), 400);

async function get(url, { ms = 6000, headers = {}, redirect = "follow" } = {}) {
  return fetch(url, { headers, redirect, signal: AbortSignal.timeout(ms) });
}
function learnerLine(learner) {
  if (!learner || typeof learner !== "object") return "";
  const bits = [learner.course && `studying ${clip(learner.course, 60)}`, learner.level && `level: ${clip(learner.level, 40)}`, learner.style && `likes explanations that are ${clip(learner.style, 60)}`].filter(Boolean);
  return bits.length ? `The student is ${bits.join("; ")}.` : "";
}
async function gemini() {
  const { GoogleGenAI } = await import("@google/genai");
  return new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
}
const thinking = () => (/gemini-2\./i.test(MODEL) ? { thinkingBudget: 0 } : { thinkingLevel: "minimal" });
// Search grounding and video understanding are Gemini features, whatever model writes the other answers.
const WEB_MODEL = process.env.HALO_WEB_MODEL || (/^gemini/i.test(MODEL) ? MODEL : "gemini-3.5-flash");

// ---------- plan ----------
const PLAN_SYSTEM = `You are Halo, a study tutor. A student wants to go deeper on something, and you are about to look it up on the web for them.
Reply with JSON only:
{"title": "the topic as a short title, 2 to 6 words",
 "say": "one short friendly sentence, said out loud while you search, naming what you are going to find for them. No more than 22 words.",
 "web": "the Google search you would run",
 "video": "a YouTube search that finds a good teaching video on exactly this, 3 to 7 words",
 "wiki": "the title of the Wikipedia article that covers it best",
 "image": "2 to 4 words to search for diagrams or photos of it"}`;

export async function plan({ question, context, document, learner }) {
  const q = clip(question, 300);
  if (isMock()) return { title: q.slice(0, 40) || "Your question", say: "Let me look that up for you.", web: q, video: q, wiki: q, image: q };
  const raw = await generateJSON({ system: PLAN_SYSTEM, text: [
    `The student asked: "${q || "Explain this in detail"}"`,
    context && `What they were looking at when they asked:\n"""${clip(context, 1500)}"""`,
    document && `It is from: ${clip(document, 120)}`,
    learnerLine(learner),
  ].filter(Boolean).join("\n\n") });
  const title = clip(raw.title, 60) || q.slice(0, 40) || "Your question";
  return {
    title,
    say: clip(raw.say, 200) || "Let me look that up for you.",
    web: clip(raw.web, 120) || title, video: clip(raw.video, 80) || title, wiki: clip(raw.wiki, 80) || title, image: clip(raw.image, 60) || title,
  };
}

// ---------- answer, grounded in search ----------
const ANSWER_SYSTEM = `You are Halo, a warm, sharp study tutor. Always search Google before you answer, and build the answer from what you find.
Write for a student who asked to have this explained in detail. Be concrete: one worked example or everyday picture beats three abstract sentences.
Explain the idea itself. The app shows videos, pictures and links beside your answer, so never recommend a video, channel or website, and never tell the student to search for something.
Plain text only. No markdown except the "## " headings. No LaTeX and no dollar signs: write maths with ordinary characters (x², dy/dx, ×, √).
Use exactly this shape:

## <heading, 2 to 5 words>
<one paragraph, 2 to 4 sentences>

Three or four sections like that, in the order a good teacher would say them, then two last lines:
TAKEAWAY: <the one sentence to remember>
SAY: <two short spoken sentences that give the heart of it, as if said out loud to the student>`;

function parseAnswer(text) {
  const sections = [];
  let takeaway = "", say = "";
  for (const block of String(text).split(/\n(?=##\s)/)) {
    const lines = block.split("\n").map((l) => l.trim()).filter(Boolean);
    const body = [];
    let heading = "";
    for (const line of lines) {
      if (/^##\s*/.test(line)) heading = line.replace(/^#+\s*/, "").replace(/[*_]/g, "");
      else if (/^\**TAKEAWAY\**\s*:/i.test(line)) takeaway = line.replace(/^\**TAKEAWAY\**\s*:\s*/i, "");
      else if (/^\**SAY\**\s*:/i.test(line)) say = line.replace(/^\**SAY\**\s*:\s*/i, "");
      else body.push(line);
    }
    if (heading && body.length) sections.push({ heading: clip(heading[0].toUpperCase() + heading.slice(1), 60), text: clip(body.join(" ").replace(/\$/g, "").replace(/\*\*/g, ""), 900), cites: [] });
  }
  return { sections: sections.slice(0, 5), takeaway: clip(takeaway.replace(/\$|\*\*/g, ""), 260), say: clip(say.replace(/\$|\*\*/g, ""), 320) };
}

/** Follows Google's grounding redirect to the real page and reads its title. Never throws. */
async function resolveSource(chunk) {
  const site = clip(chunk?.web?.title, 60);
  let url = chunk?.web?.uri || "", title = "";
  try {
    const hop = await get(url, { ms: 2500, redirect: "manual", headers: { "User-Agent": BROWSER } });
    const location = hop.headers.get("location");
    if (location) url = location;
    if (/youtube\.com\/watch|youtu\.be\//.test(url)) {
      const video = await (await get(`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(url)}`, { ms: 2500 })).json();
      title = clip(video.title, 110);
    } else {
      const page = await get(url, { ms: 2500, headers: { "User-Agent": BROWSER, Accept: "text/html" } });
      if (page.ok && /html/.test(page.headers.get("content-type") || "")) {
        const head = (await page.text()).slice(0, 60000);
        title = plain(head.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]).slice(0, 110);
      }
    }
  } catch { /* keep what we have */ }
  let host = site;
  try { host = new URL(url).hostname.replace(/^www\./, ""); } catch { /* not a URL */ }
  if (/vertexaisearch|google\.com$/.test(host) && site) host = site;
  if (/^(just a moment|access denied|attention required|403|404|error)/i.test(title)) title = "";
  if (!title) {
    // No readable title: the last part of the address usually names the page.
    try { title = clip(decodeURIComponent(new URL(url).pathname.split("/").filter(Boolean).pop() || "").replace(/\.[a-z]{2,5}$/i, "").replace(/[_-]+/g, " "), 80); } catch { /* not a URL */ }
    if (title.length < 6 || /^[\d\s]+$/.test(title) || /vertexaisearch/.test(url)) title = "";
    else title = title[0].toUpperCase() + title.slice(1);
  }
  return { title: title || site || host, url, site: host };
}

export async function answer({ question, topic, context, learner, narrate = true, concise = false }) {
  const q = clip(question, 300) || `Explain ${clip(topic, 80)} in detail`;
  if (isMock()) {
    return { sections: [{ heading: "Offline", text: "The Halo server is in mock mode, so nothing was searched. Start it with a Gemini key to see a real answer with sources.", cites: [] }],
      takeaway: "Mock mode: no web search.", say: "", audio: null, sources: [], searches: [] };
  }
  const ai = await gemini();
  const t0 = Date.now();
  const r = await ai.models.generateContent({
    model: WEB_MODEL,
    contents: [
      `The student asked: "${q}"`,
      topic && `Topic: ${clip(topic, 80)}`,
      context && `What they were looking at when they asked (their slide, book or notes):\n"""${clip(context, 2500)}"""`,
      learnerLine(learner),
    ].filter(Boolean).join("\n\n"),
    config: { systemInstruction: ANSWER_SYSTEM + (concise ? "\nFor this request, use only TWO short sections: the core idea and one concrete example, at most 160 words total. Search for and cite university teaching pages, original authoritative sources, or open textbooks such as OpenStax and LibreTexts. Do not use Scribd, CourseHero, Chegg, Studocu, or YouTube as reading sources. Omit the SAY line." : ""), tools: [{ googleSearch: {} }], thinkingConfig: thinking(), maxOutputTokens: 1800, temperature: 0.4 },
  });
  const out = parseAnswer(r.text || "");
  if (!out.sections.length) throw new Error("Halo couldn't put an answer together. Try asking again.");
  const meta = r.candidates?.[0]?.groundingMetadata || {};
  const chunks = Array.isArray(meta.groundingChunks) ? meta.groundingChunks : [];
  // Which section each cited passage landed in → which pages back that section.
  const used = [];
  const number = (chunk) => { let i = used.indexOf(chunk); if (i < 0 && used.length < 6) { used.push(chunk); i = used.length - 1; } return i; };
  for (const support of Array.isArray(meta.groundingSupports) ? meta.groundingSupports : []) {
    const probe = clip(String(support?.segment?.text || "").replace(/\$|\*\*/g, ""), 60).slice(0, 45);
    const section = probe.length > 12 ? out.sections.find((s) => s.text.includes(probe)) : null;
    for (const index of support?.groundingChunkIndices || []) {
      if (!chunks[index]?.web?.uri) continue;
      const n = number(index);
      if (n >= 0 && section && !section.cites.includes(n + 1) && section.cites.length < 3) section.cites.push(n + 1);
    }
  }
  chunks.forEach((c, i) => { if (c?.web?.uri) number(i); });
  const [sources, audio] = await Promise.all([Promise.all(used.map((i) => resolveSource(chunks[i]))), narrate && out.say ? speak(out.say) : null]);
  for (const s of out.sections) s.cites.sort((a, b) => a - b);
  console.log(`[dive] answer "${q.slice(0, 50)}" ${out.sections.length} sections, ${sources.length} sources in ${Date.now() - t0}ms`);
  return { ...out, audio, sources, searches: (meta.webSearchQueries || []).map((s) => clip(s, 80)).slice(0, 4) };
}

// ---------- videos ----------
const seconds = (length) => String(length || "").split(":").reduce((total, part) => total * 60 + (Number(part) || 0), 0);

async function youtubeSearch(query) {
  if (process.env.YOUTUBE_API_KEY) {
    try {
      const found = await (await get(`https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&videoEmbeddable=true&maxResults=8&q=${encodeURIComponent(query)}&key=${process.env.YOUTUBE_API_KEY}`)).json();
      const ids = (found.items || []).map((i) => i.id?.videoId).filter(Boolean);
      const details = ids.length ? await (await get(`https://www.googleapis.com/youtube/v3/videos?part=contentDetails,statistics,snippet&id=${ids.join(",")}&key=${process.env.YOUTUBE_API_KEY}`)).json() : {};
      const list = (details.items || []).map((v) => {
        const [, h, m, s] = String(v.contentDetails?.duration || "").match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/) || [];
        const length = [h, h ? String(m || 0).padStart(2, "0") : m || "0", String(s || 0).padStart(2, "0")].filter((p) => p !== undefined).join(":");
        return { id: v.id, title: v.snippet?.title, channel: v.snippet?.channelTitle, length, views: v.statistics?.viewCount ? `${Number(v.statistics.viewCount).toLocaleString("en-US")} views` : "" };
      });
      if (list.length) return list;
    } catch (e) { console.warn("[dive] YouTube API failed, reading the results page instead:", e.message.slice(0, 120)); }
  }
  // No key needed: the results page carries its data as JSON. "sp" narrows it to videos.
  const html = await (await get(`https://www.youtube.com/results?search_query=${encodeURIComponent(query)}&sp=EgIQAQ%253D%253D&hl=en`, { headers: { "User-Agent": BROWSER, "Accept-Language": "en-US,en;q=0.9" } })).text();
  const data = JSON.parse(html.match(/var ytInitialData = (\{.*?\});<\/script>/s)?.[1] || "{}");
  const shelves = data.contents?.twoColumnSearchResultsRenderer?.primaryContents?.sectionListRenderer?.contents || [];
  return shelves.flatMap((c) => c.itemSectionRenderer?.contents || []).map((i) => i.videoRenderer).filter(Boolean).map((v) => ({
    id: v.videoId, title: v.title?.runs?.map((r) => r.text).join("") || "", channel: v.ownerText?.runs?.[0]?.text || "",
    length: v.lengthText?.simpleText || "", views: v.shortViewCountText?.simpleText || v.viewCountText?.simpleText || "",
  }));
}

export async function videos(query) {
  const q = clip(query, 100);
  if (!q || isMock()) return [];
  const t0 = Date.now();
  // Skip clips too short to teach anything and lectures too long to sit through; keep YouTube's order otherwise.
  const found = (await youtubeSearch(q)).filter((v) => /^[\w-]{11}$/.test(v.id || "") && v.title).filter((v) => { const s = seconds(v.length); return s >= 75 && s <= 45 * 60; }).slice(0, 8);
  // oEmbed says no for videos whose owners don't allow them to be played inside other apps.
  // Well-watched videos first (a clip a handful of people have seen is rarely the best teacher), YouTube's order within each group.
  const watchers = (v) => { const m = String(v.views).replace(/,/g, "").match(/([\d.]+)\s*([KMB])?/i); return m ? Number(m[1]) * ({ K: 1e3, M: 1e6, B: 1e9 }[(m[2] || "").toUpperCase()] || 1) : 0; };
  found.sort((a, b) => (watchers(b) >= 20000) - (watchers(a) >= 20000));
  const playable = await Promise.all(found.map(async (v) => {
    try { return (await get(`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(`https://www.youtube.com/watch?v=${v.id}`)}`, { ms: 2500 })).ok; } catch { return true; }
  }));
  const out = found.filter((_, i) => playable[i]).slice(0, 4).map((v) => ({ id: v.id, title: clip(v.title, 120), channel: clip(v.channel, 60), length: clip(v.length, 12), views: clip(v.views, 24) }));
  console.log(`[dive] videos "${q}" → ${out.length} in ${Date.now() - t0}ms`);
  return out;
}

/** Gemini watches the video and finds where the student's question is answered. → { start (seconds), why } or null */
export async function moment({ videoId, question, title }) {
  if (isMock() || !/^[\w-]{11}$/.test(String(videoId))) return null;
  const t0 = Date.now();
  try {
    const ai = await gemini();
    const r = await ai.models.generateContent({
      model: WEB_MODEL,
      contents: [{ role: "user", parts: [
        { fileData: { fileUri: `https://www.youtube.com/watch?v=${videoId}`, mimeType: "video/*" } },
        { text: `A student asked: "${clip(question, 300)}"\nFind the moment in this video where the explanation that best answers them begins (not the intro).\nReply with JSON only: {"start": <seconds from the beginning, a whole number>, "why": "<what is shown or said there, in at most 16 words, starting with a verb, e.g. 'draws the two rates as gears turning each other'>"}\nIf the video never covers it, reply {"start": -1, "why": ""}.` },
      ] }],
      config: { thinkingConfig: thinking(), mediaResolution: "MEDIA_RESOLUTION_LOW", responseMimeType: "application/json", maxOutputTokens: 300, temperature: 0.2 },
    });
    const raw = JSON.parse(String(r.text || "").replace(/```[a-z]*|```/g, "").match(/\{[\s\S]*\}/)?.[0] || "{}");
    const start = Math.floor(Number(raw.start));
    console.log(`[dive] watched ${videoId} "${clip(title, 40)}" → ${start}s in ${Date.now() - t0}ms`);
    if (!Number.isFinite(start) || start < 0 || !raw.why) return null;
    return { start, why: clip(raw.why, 140) };
  } catch (e) {
    console.warn("[dive] could not watch", videoId, e.message.slice(0, 160));
    return null;
  }
}

// ---------- pictures ----------
const JUNK = /(icon|logo|lock|shackle|portrait|symbol|wiki|commons|question[ _]book|ambox|edit-clear|padlock|folder|stub|flag of|crystal|nuvola|text-x|disambig|portal|increase|decrease|steady|arrow|button|star|oojs|speaker|sound|loudspeaker|blank|red[ _]pog|signature|emblem|coat of arms|\.ogg|\.ogv|\.webm|\.pdf|\.djvu|\.tif)/i;

function picture(page) {
  const info = page?.imageinfo?.[0];
  if (!info?.thumburl || !/^image\/(jpeg|png|gif|svg\+xml|webp)$/.test(info.mime || "")) return null;
  if ((info.width || 0) < 260 || (info.height || 0) < 180 || JUNK.test(page.title || "")) return null;
  const ratio = info.width / info.height;
  if (ratio > 3.2 || ratio < 0.4) return null;
  const meta = info.extmetadata || {};
  const name = clip(String(page.title || "").replace(/^File:/, "").replace(/\.[a-z0-9]+$/i, "").replace(/[_-]+/g, " "), 70);
  const about = plain(meta.ImageDescription?.value);
  return {
    thumb: info.thumburl, title: about && about.length <= 110 ? about : name,
    credit: plain(meta.Artist?.value).slice(0, 50), license: clip(meta.LicenseShortName?.value, 24),
    page: info.descriptionurl || "", width: info.thumbwidth || info.width, height: info.thumbheight || info.height,
  };
}
async function wiki(host, params) {
  const url = `https://${host}/w/api.php?format=json&origin=*&${new URLSearchParams(params)}`;
  return (await get(url, { headers: { "User-Agent": WIKI_AGENT } })).json();
}
const IMAGE_INFO = { prop: "imageinfo", iiprop: "url|size|mime|extmetadata", iiurlwidth: "720", iiextmetadatafilter: "ImageDescription|Artist|LicenseShortName" };

export async function images({ wiki: article, query, question }) {
  if (isMock()) return [];
  const t0 = Date.now();
  // The pictures a Wikipedia article uses are the ones editors chose to explain the idea; Commons fills in after.
  const fromArticle = (async () => {
    const title = clip(article || query, 80);
    if (!title) return [];
    const found = await wiki("en.wikipedia.org", { action: "query", list: "search", srsearch: title, srlimit: "1" });
    const page = found.query?.search?.[0]?.title;
    if (!page) return [];
    const r = await wiki("en.wikipedia.org", { action: "query", generator: "images", titles: page, gimlimit: "40", ...IMAGE_INFO });
    return Object.values(r.query?.pages || {});
  })().catch(() => []);
  const fromCommons = (async () => {
    const q = clip(query || article, 60);
    if (!q) return [];
    const r = await wiki("commons.wikimedia.org", { action: "query", generator: "search", gsrnamespace: "6", gsrlimit: "12", gsrsearch: q, ...IMAGE_INFO });
    return Object.values(r.query?.pages || {}).sort((a, b) => (a.index || 0) - (b.index || 0));
  })().catch(() => []);
  const [a, b] = await Promise.all([fromArticle, fromCommons]);
  const seen = new Set(), found = [];
  // The same diagram is often uploaded once per language ("Chain rule de.png"): keep one, English first.
  const stem = (page) => String(page.title || "").toLowerCase().replace(/^file:/, "").replace(/\.[a-z0-9]+$/, "").replace(/[\s_-]+\(?[a-z]{2,3}\)?$/, "").replace(/[\s_-]+/g, " ");
  const english = (page) => (/[\s_-]en\.[a-z0-9]+$/i.test(page.title || "") ? 0 : 1);
  for (const page of [...a, ...[...b].sort((x, y) => english(x) - english(y))]) {
    const item = picture(page);
    if (!item || seen.has(item.thumb) || seen.has(stem(page))) continue;
    seen.add(item.thumb); seen.add(stem(page)); found.push(item);
    if (found.length === 18) break;
  }
  // An article carries plenty of pictures that are beside the point. Halo picks the ones that teach this.
  let out = found.slice(0, 4);
  if (found.length > 2) {
    try {
      const raw = await generateJSON({
        system: `You choose pictures for a student's study board. Reply with JSON only: {"pick": [{"n": <number of the picture>, "caption": "<what it shows and why it helps, at most 12 words>"}]}. Choose up to 4 that would genuinely help someone understand the topic: diagrams first, then photos that show the idea. Leave out portraits, book pages, loosely related photos and anything not in English. Fewer is better than off-topic; an empty list is fine.`,
        text: `Topic: ${clip(article || query, 80)}${question ? `\nThe student asked: "${clip(question, 200)}"` : ""}\n\nPictures:\n${found.map((f, i) => `${i + 1}. ${f.title}`).join("\n")}`,
      });
      const picks = (Array.isArray(raw.pick) ? raw.pick : []).map((p) => ({ item: found[Number(p?.n) - 1], caption: clip(p?.caption, 90) })).filter((p) => p.item);
      out = [...new Set(picks.map((p) => p.item))].slice(0, 4).map((item) => ({ ...item, title: picks.find((p) => p.item === item).caption || item.title }));
    } catch (e) { console.warn("[dive] picking pictures failed:", e.message.slice(0, 120)); }
  }
  console.log(`[dive] images "${clip(article || query, 40)}" → ${out.length} (${a.length} from the article, ${b.length} from Commons) in ${Date.now() - t0}ms`);
  return out;
}
