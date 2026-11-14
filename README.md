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

Voice: the first step is synthesized with a low-latency model (`eleven_turbo_v2_5`) so the answer starts fast; later steps use `eleven_v3`, the most natural model, generated in the background while step 1 plays. The prompt makes the tutor talk like a person sitting next to you (contractions, "this 2x right here", no "Great question"), and the server strips any LaTeX before it is spoken.

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

`HALO_MOCK=1` serves a canned chain-rule mistake through the same graph. `npm test` in `server/` runs the math checker's tests. Set `LANGSMITH_TRACING=true` and `LANGSMITH_API_KEY` to see each run as a trace.

## Chapter tutor on iPad

Open a PDF, choose a chapter in **Chapters**, and tap its graduation cap (or **Teach me** in the reader). Halo builds a concept roadmap from the selected pages, teaches through textbook excerpts, visual explanations, and examples revealed one move at a time, then pauses to check understanding. Relevant web explanations and Wikimedia diagrams supplement the book with source links; handwritten notes remain available on demand. Ask questions, type or dictate answers, use a hint, and revisit earlier boards. Partial or missed answers get a new explanation and another check; moving on without understanding is an explicit choice. The final recap and teaching can be saved to My notes. See [chapter lesson details and verification](ipad/README.md#chapter-lessons).

The server exposes `POST /api/lesson/start` with `{ title, chapter, pages: [{ page, text }], learner }` and `POST /api/lesson/answer` with `{ id, answer, action, concept, requestID }`. Both stream SSE. Reuse `requestID` when retrying an answer; concurrent identical retries replay one completed turn. Checkpoints currently live in server memory, so restarting the server requires a fresh lesson. The offline sample is scripted; imported chapters use the live model.

## Config (server/.env)

| Var | Default | Notes |
|---|---|---|
| `HALO_PROVIDER` | `gemini` | or `claude` |
| `GEMINI_API_KEY` | — | required unless `HALO_MOCK=1` or provider is claude |
| `HALO_MODEL` | `gemini-3.5-flash` | any Gemini vision model; `claude-opus-5-5` when provider is claude |
| `GEMINI_THINKING_LEVEL` | `minimal` | Gemini 3+ thinking depth (`minimal`, `low`, `medium`, `high`) |
| `GEMINI_THINKING_BUDGET` | `0` | Gemini 2.x only |
| `ANTHROPIC_API_KEY` | — | only for `HALO_PROVIDER=claude` |
| `ELEVENLABS_API_KEY` | — | empty → browser speech synthesis fallback |
| `ELEVENLABS_VOICE_ID` | `Xb7hH8MSUJpSbSDYk0k2` | "Alice – Clear, Engaging Educator" |
| `ELEVENLABS_MODEL_ID` | `eleven_v3` | natural voice for steps 2+ (about 4 s per clip, pipelined) |
| `ELEVENLABS_FAST_MODEL_ID` | `eleven_turbo_v2_5` | first step, about 0.5 s |
| `GEMINI_IMAGE_MODEL` | `gemini-2.5-flash-image` | illustrations for the `image` primitive |
| `HALO_MOCK` | `0` | `1` = canned answers, no API calls |

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
