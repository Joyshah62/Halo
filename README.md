# Halo — Crop & Ask

**Any page can answer back.** A Chrome extension: crop a section or choose the whole page, ask by voice or text, and a tutor explains it with handwritten notes, diagrams, and voice in a side panel or movable card.

Built for HackPrinceton (Education track). Spec and plan: [Halo — Circle & Ask.md](./Halo%20—%20Circle%20%26%20Ask.md).

```
extension/   Chrome MV3 extension (TypeScript, esbuild). Content script = crop + pins + conversation + player.
ipad/        Native SwiftUI iPad app: PDF reader, Pencil selection and notes, saved conversations.
server/      Node/Express. Holds the API keys, calls Gemini (vision; Claude optional) + ElevenLabs, streams steps, logs topics.
```

The native PDF-first iPad app is in [`ipad/`](./ipad/README.md). Open [`ipad/Halo.xcodeproj`](./ipad/Halo.xcodeproj) in full Xcode; setup and verification limits are documented there.

## Run it (5 minutes)

**Requires Node.js 24+** (the server uses built-in SQLite).

**1. Server**

```bash
cd server
npm install
cp .env.example .env     # add GEMINI_API_KEY (and ELEVENLABS_API_KEY for the good voice)
npm start                # http://localhost:8787
```

No keys yet? `HALO_MOCK=1 npm start` serves a canned chain-rule answer so the whole UI can be exercised offline. This is also the Wi-Fi-dies fallback for judging.

**2. Extension**

```bash
cd extension
npm install
npm run build            # → extension/dist   (npm run watch while developing)
```

Chrome → `chrome://extensions` → Developer mode → **Load unpacked** → pick `extension/dist`.

**3. One-time setup**

- Click the Halo toolbar icon: the side panel opens (confusion map, tutor toggle, history).
- In the side panel click **Enable mic** once (opens `setup.html`; grant mic access). Voice is recognised in the side panel so the permission is granted once, not per site.
- Keep the side panel open while demoing: it is where voice input runs.

## Use it

| Action | How |
|---|---|
| Crop mode | `Alt+C`, the **Crop section** pill, or **Crop a section** in the side panel; drag a rectangle in any direction |
| Whole page | Click **Whole page** in the floating controls or **Ask about whole page** in the side panel; no selection needed |
| Ask | Type a question and click **Send** / press `Enter`, or click the mic to speak |
| Follow-up | Ask in the side-panel conversation or floating card; Halo remembers the last 10 exchanges and keeps the original page/crop context |
| New conversation | Crop a different section or choose **Whole page** again. Earlier explanations collapse to numbered pins; click a pin to reopen |
| Tutor mode | Toggle in the side panel: hints and questions instead of solutions |
| Clear | Side panel → **Clear notes** removes local pins and conversations. `Esc` exits crop mode / collapses the active conversation |
| PDFs | Any `.pdf` URL opens in Halo's own viewer automatically (Chrome's built-in viewer blocks extensions) |

## Placement and slide notes

- **One active explanation:** full answers and diagrams open in the side panel. Earlier questions become numbered page pins; their conversation remains available from the pin or the conversation tabs.
- **Float / Dock:** use **Float ↗** to put an explanation on the page. Drag its header, resize the bottom corner, or move it near the left/right edge to snap it. **Dock ↗** returns it to the panel. Drafts, diagrams, and follow-ups move together.
- **Clear placement:** cards avoid the selected region, recognizable toolbars, navigation rails, the Halo controls, and other pins. If no clear spot exists and the side panel is available, the explanation stays in the panel. When Chrome cannot open a panel, a movable card is the fallback.
- **Slide-aware pins:** Google Slides URL IDs, accessible slide indicators (including PowerPoint's “Slide N of M”), and Halo PDF page numbers keep notes separate. Switching slides stops playback and restores that slide's last active conversation when you return. Crop pins use slide/canvas-relative positions when those bounds are available.
- **Brief pointing:** the selected region lights up while a relevant step is introduced and then fades. No long arrows or growing columns of writing across the source page. Short labels appear only where space permits.

Notes are held in memory for this tab (up to 24 conversations), survive slide changes, and reset when the page reloads or you clear notes. Server question history is retained. Editors that do not expose a slide identifier fall back to URL-level grouping; browser zoom or unusual custom canvas layouts may require a new crop.

## How it works

1. Content script captures a rectangular drag on a transparent canvas, or starts a whole-page conversation without a selection.
2. Background worker screenshots the tab (`captureVisibleTab`); the content script crops to the selected rectangle and collects the DOM text under it plus the page text. Halo controls and ink are hidden during capture.
3. Server sends optional crop + whole-viewport image + page text + recent conversation + question to Gemini with a prompt that returns **one step per line**: `{"say": "...", "ink": [...]}`. Steps stream back over SSE; each gets an ElevenLabs clip as it arrives.
4. The player speaks step N while its handwritten notes and diagrams appear in the explanation surface. The source briefly highlights instead of accumulating ink. Sync is per step: a step waits for its audio to finish.
5. Every question (including follow-ups linked to the previous turn) is logged to SQLite with its topic → confusion map + flashcards in the side panel.

Whole-page mode uses available DOM text across the page (trimmed to 12,000 characters) and a screenshot of the visible viewport. Offscreen diagrams and content that has not loaded are not captured. Conversation context is kept in memory per pin; collapsing a conversation preserves it, while reloading the page starts fresh.

Answer wire format (NDJSON from the model, SSE to the extension):

```json
{"mode":"answer","topic":"chain rule"}
{"say":"This 2 comes from differentiating x squared.","ink":[{"type":"arrow","to":"circled"},{"type":"text","value":"d/dx (x²) = 2x"}]}
{"say":"The chain rule multiplies by the inside derivative.","ink":[{"type":"text","value":"× inner derivative"},{"type":"underline","target":"previous"}]}
```

Ink primitives: `text`, `arrow` (to `circled` | `previous`), `underline`, `box`, `check`, `cross`, plus two for visual concepts:

- `sketch`: a small hand-drawn diagram the model describes as SVG paths and short labels in a 200×120 box (axes, curves, flows, geometry). Shown with the spoken step, with handwritten labels.
- `point` (iPad only, sent with `pointing: true`): `{"type":"point","quote":"<exact page text>","style":"highlight"|"underline"|"circle"}` marks printed text on the PDF page while that step is spoken, then fades. The checker uses `{"type":"point","line":n}` to underline the line a hint sends the student back to.
- `image`: for genuinely complex things (3-D structures, mechanisms). The server generates a whiteboard-style illustration with `gemini-2.5-flash-image` (about 5 s) while the previous step is still being spoken, then it appears beside the spoken explanation.

Voice: every step is synthesized with one model (`ELEVENLABS_MODEL_ID`, default `eleven_multilingual_v2`), so the voice never changes mid-answer. Each step gets its own clip, generated as the step arrives and played in order, so step 1 plays while later steps are still being written. The prompt makes the tutor talk like a person sitting next to you (contractions, "this 2x right here", no "Great question"), and the server strips any LaTeX before it is spoken.

## Explore in 3D

Halo has three models a student can hold: a **human brain**, a **neuron** and an **animal cell**.

The brain is real anatomy: 25 touchable parts (lobes, motor and somatosensory strips, hippocampus, amygdala, thalamus, basal ganglia, ventricles, brainstem, cerebellum…) built from the [BodyParts3D](https://lifesciencedb.jp/bp3d/) atlas. Drag to turn it, pinch to zoom, and switch between **Whole**, **See inside** (the cortex turns to glass), **Cut in half** (the classic midline view) and **Pull apart**. The neuron and cell are simplified schematics.

**Touch a part and ask.** On iPad the explorer is a full screen: the model on one side, Halo on the other. Touching a part names it and says what it does; then tap a suggested question, type, or use the microphone. While Halo answers, each step lights up the part it is talking about and turns the model to show it (opening it up if the part is deep inside), and tapping a line of the answer points at that part again. Without the server, Halo still answers from its notes on each part.

Ways in: the cards on the start screen, "show me the brain" in Halo's bar, or a 3D card that Halo adds to an answer, a lesson or a **Go deeper** board when a model helps. In Chrome the model appears in the explanation panel.

How it fits together:

- [`shared/scene3d/catalog.json`](shared/scene3d/catalog.json): models, part IDs, names and what each part does. The server prompt, the viewer and the iPad app all read it.
- [`extension/src/scene3d/viewer.ts`](extension/src/scene3d/viewer.ts): the Three.js viewer (rendering, touch, views). Hosts talk to it through `window.halo3d.select(part)` / `setView(view)` / `reset()`, and it reports `ready`, `select` and `view`.
- [`shared/scene3d/tools/build_brain.py`](shared/scene3d/tools/build_brain.py): turns the atlas meshes into `brain-data.js` (simplified, regrouped, with baked shading). Only needed to change the brain itself.
- [`ipad/Halo/Scene3DView.swift`](ipad/Halo/Scene3DView.swift): the explorer screen and the ask flow.
- `/api/ask` takes `explorer: {"model":"brain","focus":"hippocampus"}` for questions asked inside the explorer; answers carry `{"type":"scene3d","model":"brain","focus":"<part>"}` in each step. Only known model and part IDs cross the wire, never code or asset URLs.

After editing the viewer or catalog, run `npm run build` in `extension/`; it also refreshes the checked-in iPad bundle in `ipad/Halo/Resources/Scene3D/`.

Simulator: launch with `--scene3d brain [--touch hippocampus] [--explore-view half] [--explore-ask "what does it do?"]`.

Brain geometry: BodyParts3D, © The Database Center for Life Science, licensed under CC Attribution-Share Alike 2.1 Japan (credited in the viewer). Three.js is MIT.

## Flash cards from your notes (`POST /api/notes/flashcards`)

In **My notes** (or quick notes), tap Halo and choose **Make flash cards** for the open note, or **Flash cards from all my notes**. You can also type or say "make flash cards" anywhere. Halo writes one idea per card from your own words (handwriting included). Tap a card to flip it, then **Got it** or **Again** (or swipe right / left); "again" cards come back at the end, and the last screen lists the ones worth another go. A note's deck is saved with it and reopens as it was until the note changes; **New cards** writes a fresh deck.

The request is the same as the quiz's (`{ notes: [{ title, text }], image?, document?, learner? }`) and returns `{ title, cards: [{ front, back, hint, source }] }`. Simulator: `--quick-note "line|line" --flashcards [all] [--flip "fkfa"]` (f flips, k is Got it, a is Again).

**Home:** every page (the reader, notes, the lesson, quiz, recap, flash cards, the web board and the 3D explorer) has a house button that saves and goes straight back to the start screen. Saying or typing "go home" does the same.

## Halo watches you work (`POST /api/check`)

The student solves a problem by hand; when they pause, the client sends an image of the working. A LangGraph agent ([server/tutor.js](server/tutor.js)) decides whether to stay quiet, draw a ✓, or circle the first wrong line and give a hint (never the answer).

```
read ──► verify ──► every step checks out ─────────► ✓            (one model call, about 3 s)
               └──► judge ──► confirmed wrong ─────► circle + spoken hint   (two calls, about 6 s)
                          └─► not sure ────────────► stay quiet
```

- **read**: Gemini vision transcribes each line, where it sits on the image, and how it is meant to follow from the line above.
- **verify**: a math tool ([server/mathcheck.js](server/mathcheck.js), mathjs, numeric) tests each step: same solutions, equal value, or derivative of the previous line. The model never decides on its own that algebra is wrong.
- **judge**: runs only when a step failed or could not be tested. It looks at the image again with the tool's evidence; a mistake is flagged only when both agree, so a misread line does not interrupt a student who is right. It labels the mistake `slip` or `concept` and writes the hint.

Request: `{ image (base64), imageMime, problem?, pageText?, learner? }`. Response is SSE: `stage` per node, then `verdict` (`status`: `correct` | `wrong` | `unsure` | `nothing`, plus `line`, `box` as `{x, y, w, h}` in 0–1 of the image, `kind`, `concept`, every transcribed line with its box, and the tool results), then `meta` + `step` in the same shape as `/api/ask` when there is a hint, then `done`. Caught mistakes are logged to the confusion map.

`HALO_MOCK=1` serves a canned chain-rule mistake through the same graph. `npm test` in `server/` runs every `*.test.mjs`: the math checker (`mathcheck.test.mjs`), the lesson agent (`lesson.test.mjs`) and lesson source material (`lesson-material.test.mjs`). Set `LANGSMITH_TRACING=true` and `LANGSMITH_API_KEY` to see each run as a trace.

## Why am I stuck? (`POST /api/stuck`)

The checker says *which line* is wrong. This says *what the student doesn't know yet* and where their own book teaches it. That is an open-ended search, so it is a [LangChain Deep Agent](https://docs.langchain.com/oss/javascript/deepagents/overview) ([server/stuck.js](server/stuck.js)) rather than a fixed graph. On the iPad it is the **Why am I stuck?** button on the note Halo opens for a mistake.

| Deep Agents feature | What Halo uses it for |
|---|---|
| Planning (`write_todos`) | The agent writes its own 3 to 4 step plan; the app shows it ticking off live. |
| Filesystem (`StateBackend`) | The chapter is loaded as one file per page (`/book/page-012.md`). The agent greps and reads pages instead of having the whole book in its prompt. |
| Subagent (`book-scout`) | Does the page hunt in its own context window and returns only `{ page, quote, reason }` (typed with `responseFormat`). |
| Custom tool | The same `check_step` calculator the checker uses, to test a suspicion about the rule that was misapplied. |
| Long-term memory (`CompositeBackend` + `FilesystemBackend`, `memory:`) | `/memories/<learner>.md` is loaded into the prompt on every run. The agent records each gap there, so a repeat is recognised: "this is the same thing that caught you before". |
| Permissions | `/book` is read-only; the only place the agent may write is `/memories`. The scout cannot write at all. |
| Structured output (`responseFormat`) | A typed diagnosis: the gap, why it caused this mistake, page, exact quote, hint steps, a check question. |

**What Halo remembers about a learner** is one short file with two sections, and nothing else (no name, no handwriting, no answers):

```
# Gaps Halo has seen                      ← written by this agent
- derivative of the inside function | chain rule | seen 2 time(s) | p.3

# Topics they have covered                ← written by the server from real results
- the power rule | lesson | got it | Calculus Workbook p.1 | 2026-11-14 | 1 time(s)
- chain rule | practice | made a mistake | Calculus Workbook p.3 | 2026-11-14 | 2 time(s)
```

Topics come from chapter lessons (each concept as it is checked: got it, got it after n tries, nearly there, still learning, skipped) and from "Halo watches you work" (solved it / made a mistake; one problem counts once however many times it is checked). The lesson planner reads them, so a concept the student already got is kept short and one they skipped gets a gentler start; this agent reads them, so its first step can say "you practised this on page 3".

**Memory lives in [Backboard](https://backboard.io)** ([server/learner-memory.js](server/learner-memory.js)) when `BACKBOARD_API_KEY` is set: one Backboard assistant per learner (`halo-learner-id-<device id>`), one Backboard memory per gap. Before a run the agent's memory file is rebuilt from Backboard (about 0.1 s); after the answer is sent, the lines the agent changed are written back in the background, so the student never waits on it. Without a key, or if Backboard can't be reached, the local file in `server/memory/` is used instead. Learners are identified by an anonymous ID the iPad generates on first launch and keeps in the Keychain. There is no login; this is for the demo, and a real launch would use Sign in with Apple.

The server only trusts a quote it can find in the page text it was sent; the page number follows the quote. The answer never states the corrected line.

Request: `{ problem, lines, line, concept, hint?, title, chapter?, pages: [{ page, text }], learner?, learnerId? }` (the first four are the `/api/check` verdict's). Response is SSE: `todos` (the plan, whenever it changes) and `stage` (`{ name, say, page? }`, what the agent is doing now), then `diagnosis` (`gap`, `why`, `page`, `quote`, `seenBefore`, `question`), then `meta` + `step` as for `/api/ask` (the step that sends the student to the book carries a `point` with `page`), then `done`. About 10 s end to end on `gemini-3.5-flash`. `HALO_MOCK=1` serves a canned diagnosis without running the agent. With `LANGSMITH_TRACING=true` each run is a `halo-why-stuck` trace showing the plan, the subagent and every file operation.

## Chapter tutor on iPad

Open a PDF, choose a chapter in **Chapters**, and tap its graduation cap (or **Teach me** in the reader). Halo builds a concept roadmap from the selected pages, teaches through textbook excerpts, visual explanations, and examples revealed one move at a time, then pauses to check understanding. Relevant web explanations and Wikimedia diagrams supplement the book with source links; handwritten notes remain available on demand. Ask questions, type or dictate answers, use a hint, and revisit earlier boards. Partial or missed answers get a new explanation and another check; moving on without understanding is an explicit choice. The final recap and teaching can be saved to My notes. See [chapter lesson details and verification](ipad/README.md#chapter-lessons).

The server exposes `POST /api/lesson/start` with `{ title, chapter, pages: [{ page, text }], learner }` and `POST /api/lesson/answer` with `{ id, answer, action, concept, requestID }`. Both stream SSE. Reuse `requestID` when retrying an answer; concurrent identical retries replay one completed turn. Checkpoints currently live in server memory, so restarting the server requires a fresh lesson. The offline sample is scripted; imported chapters use the live model.

## Config (server/.env)

| Var | Default | Notes |
|---|---|---|
| `HALO_PROVIDER` | `gemini` | or `claude` |
| `GEMINI_API_KEY` | — | required unless `HALO_MOCK=1`; still used for `/api/check` and web lookup when provider is claude |
| `HALO_MODEL` | `gemini-3.5-flash` | any Gemini vision model; `claude-opus-5-5` when provider is claude |
| `GEMINI_THINKING_LEVEL` | `minimal` | Gemini 3+ thinking depth (`minimal`, `low`, `medium`, `high`) |
| `GEMINI_THINKING_BUDGET` | `0` | Gemini 2.x only |
| `ANTHROPIC_API_KEY` | — | only for `HALO_PROVIDER=claude` |
| `ELEVENLABS_API_KEY` | — | empty → browser speech synthesis fallback |
| `ELEVENLABS_VOICE_ID` | `VrUPKj92idNr4XrmO032` | "Hailey", a calm conversational voice |
| `ELEVENLABS_MODEL_ID` | `eleven_multilingual_v2` | one model for every step, so the voice never changes mid-answer |
| `GEMINI_IMAGE_MODEL` | `gemini-2.5-flash-image` | illustrations for the `image` primitive |
| `HALO_MOCK` | `0` | `1` = canned answers, no API calls (also turns file storage off) |
| `AWS_S3_BUCKET` / `AWS_REGION` | — / `us-east-1` | file storage bucket; with `MONGODB_URI` turns storage on |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | — | or any standard AWS credential source |
| `AWS_S3_PREFIX` / `AWS_S3_PUBLIC_URL` | — | optional key prefix; CDN base URL instead of the S3 URL |
| `MONGODB_URI` | — | Atlas connection string; records go to `MONGODB_DB` (`halo`) / `MONGODB_COLLECTION` (`files`) |

## Deploy to Render

[`render.yaml`](render.yaml) is a Render Blueprint for the server. Push to GitHub, then Render → **New → Blueprint** → pick this repo, and paste the secrets it asks for (Gemini, ElevenLabs, AWS, MongoDB). It runs `npm ci` / `npm start` in `server/` on Node 24, checks `/api/health`, and redeploys on every push that touches `server/`, `shared/` or `render.yaml`.

- **Plan:** `starter` with a 1 GB disk at `/var/data` holding the SQLite question log, lesson checkpoints, learner memory and logs. On the free plan, delete the `disk` block and set `plan: free`: that data then resets on every deploy, and the server sleeps after 15 idle minutes.
- **Office import:** Render's Node runtime has no LibreOffice, so `.ppt/.pptx/.doc/.docx` import returns "unavailable". PDFs work as usual.
- **Clients:** set the server URL to `https://<service>.onrender.com` in the extension's side panel and in the iPad app's settings.
- **Atlas:** Render's outbound IPs are not fixed, so allow `0.0.0.0/0` under Atlas Network Access (or use the IPs listed in the service's **Connect → Outbound** tab).

## File storage (S3 + MongoDB Atlas)

With `AWS_S3_BUCKET` and `MONGODB_URI` set, file bytes go to S3 and each file's record (`kind`, `bucket`, `key`, public `url`, `mime`, `size`, `name`, `meta`, `createdAt`) goes to MongoDB. `GET /api/health` reports `storage: true|false`. When either variable is missing, storage stays off and everything else works as before.

| What | Where it's stored |
|---|---|
| `POST /api/files?kind=upload\|document&name=…` (raw bytes, `Content-Type` = file type, ≤ 25 MB) | returns `201 { file }` |
| `GET /api/files?kind=&limit=` | lists records, newest first |
| Converted Office documents (`/api/documents/convert`) | kind `document`; link in the `X-Halo-File-Url` response header |
| Note diagrams (`/api/notes/image`) | kind `note-image`; `image.url` added to the reply |
| Ask screenshots (`/api/ask`) | kind `screenshot`, `meta.questionId` links it to the question; uploaded in the background |

URLs are public, so the bucket needs public read: turn off **Block public access** for it and add a bucket policy granting `s3:GetObject` on `arn:aws:s3:::<bucket>/*`. The server's IAM user needs `s3:PutObject` on the same resource. In Atlas, allow the server's IP under **Network Access**.

Server URL is editable at the bottom of the side panel (for a hosted backend on demo day).

Run extension checks with `cd extension && npm run typecheck && npm test && npm run build` using Node 24+.

## Troubleshooting

- **“Extension context invalidated” after reloading Halo**: refresh the website tab too, then reopen the side panel. Existing tabs keep their old injected code until refreshed. New builds detect invalidation, remove stale controls, and show a refresh notice; an unsent question is available to copy before refreshing.

- **Grey dot in side panel header**: server not reachable. `cd server && npm start`.
- **Mic "blocked"**: open the side panel → Enable microphone, grant, retry. Typing always works.
- **Nothing happens on Alt+C on Google Slides**: Slides swallows keys; the extension command still fires. If you remapped it, check `chrome://extensions/shortcuts`. The bottom pill always works.
- **Ink doesn't follow an inner scrolling pane** (Slides editor): ink is anchored to page coordinates; don't scroll the pane while an answer plays.
- **PDF won't open**: `file://` PDFs are not redirected; use an `http(s)` link or the side panel's **Open as PDF**.

## Demo flow (2 min)

1. Lecture deck in Google Slides → `Alt+C` → drag a crop around an equation → “Where does this 2 come from?”
2. Arrow + handwriting appear in the margin as the voice explains.
3. In the same conversation ask “Why?” or “Show me another example.”
4. Switch to an article → **Whole page** → “Explain the main idea.”
5. Tutor mode on → crop a wrong homework step → Halo writes a hint.
6. End on the confusion map.

### Import PowerPoint and Word on iPad

The iPad app accepts `.ppt`, `.pptx`, `.doc`, `.docx`, and PDF. Office files are converted to PDF by your Halo server, then saved locally for the same reader, annotations, search, and lesson tools. Install LibreOffice on the server and restart it; see [Office import setup](ipad/README.md#powerpoint-and-word-imports). PDF import works offline; Office conversion requires the server and accepts files up to 25 MB.

### Server diagnostics

Requests, stream progress, errors, disconnects, process exits, and restarts are recorded in `server/logs/server.jsonl` (gitignored). Follow them with `tail -f server/logs/server.jsonl`; override the folder with `HALO_LOG_DIR`. Every request has an `X-Halo-Request-ID` response header. Progress logs include the question ID and stage, without logging screenshots or document text. Development mode preserves terminal output across restarts. For a device demo, use `npm start` so editing source files cannot restart the server in the middle of a question or lesson.

Lesson checkpoints and completed retry responses are saved in `server/lessons.sqlite` (gitignored), so a restart between turns does not lose the lesson or apply the same reply twice. Set `HALO_LESSON_DB_PATH` to choose its location. Lessons started before this persistence update must be restarted once.
