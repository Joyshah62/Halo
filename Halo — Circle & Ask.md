# Halo — Circle & Ask

Nov 9, 2026 · @Joy

## Current interaction update

The implemented interaction now uses a rectangular crop instead of drawing a circle. Press Alt+C and drag to select a section, or choose Whole page to ask without selecting anything. A persistent question box accepts text and voice follow-ups, shows the conversation, and passes the last 10 exchanges to the model while retaining the original crop/page context. New selections start new conversations; follow-up questions link to the prior question in history. Whole-page mode reads available page text plus a visible-viewport screenshot, so offscreen visual content is not captured. Explanations now open in the side panel, with an optional draggable/resizable card. Earlier conversations collapse into numbered pins, slide/page changes hide unrelated pins and stop playback, and short-lived source highlights replace long arrows and accumulated ink. Pins and their conversations are retained locally across slide changes (up to 24 conversations, until reload or clear). The original proposal below records the initial circle-based design; see README.md for current usage.

## The pitch

**Any page can answer back.** A Chrome extension: circle anything on a web page, ask out loud, and a tutor writes and explains the answer right next to it.

Today, a student stuck on one line of a lecture slide has to leave the page: screenshot it, open a chat app, type out the equation, and lose their place. The explanation that comes back is a wall of text with no link to what they were looking at. Halo keeps the whole loop on the page, in the same medium the student is already working in: ink and voice.

## What it does

On any web page, the student circles something with the mouse or trackpad and asks about it by voice. Halo reads the circled region together with the whole page, then answers right there: it writes the explanation in the margin stroke by stroke and speaks it aloud at the same time.

&#91;embedded content: core loop · 4 steps, follow-up loop\]

The answer itself can be circled for a follow-up, and every question is logged to the confusion map. Tutor mode changes only the answer step: hints instead of solutions.

## Key features

| Feature | What it does | Why it matters |
| --- | --- | --- |
| Teacher-style ink | Answers appear as short handwritten lines, quick sketches, underlines and arrows in the margin, not paragraphs | Feels like a tutor at a whiteboard, not a chatbot |
| Ink and voice in sync | The voice says "this term" at the moment the arrow is drawn to it | The memorable moment of the demo |
| Whole-page context | Reads the full page or slide deck, not just the circled crop, so a circled "λ" means what it means in this lecture | Answers fit the course, not a generic definition |
| Follow-ups on the answer | Circle part of the answer itself and ask again; a nested explanation appears beside it | A conversation that lives on the page |
| Tutor mode | One toggle: instead of answering, it writes a hint or a question back | Helps students learn rather than copy |
| Confusion map | Logs every circle; at the end it shows which topics you asked about most and builds flashcards from your own questions | Turns confusion into a study plan |
| Read and simplify | Circle a dense paragraph to hear it read aloud and simplified, key terms highlighted | Accessibility for dyslexia and low vision |

Works on any web page: Google Slides and Docs, Canvas and other course sites, online textbooks, articles, and PDFs opened in the extension's own viewer. No importing.

## Who it's for and HackPrinceton fit

- **Students** who study from online slides, course sites and PDFs, especially in math-heavy courses.
- **Students with reading difficulties**, who get read-aloud and simplified explanations on demand.
- **Self-learners** working through textbooks with no TA nearby.

It targets the **Education** track: it makes learning more personal and accessible. Against the judging rubric:

| Criterion | How Halo scores |
| --- | --- |
| Creativity | The page answers in ink and voice, synced; the answer lives where the question was asked |
| Utility | Works on real course websites and PDFs, live in front of judges, with nothing to import |
| Charity | Tutor mode supports honest learning; read-aloud mode serves students with dyslexia or low vision |
| Avidity | A tool the team would use in its own classes |

Open question: which sponsor prizes to also target (for example MLH's ElevenLabs prize for the voice, if offered this term).

## Demo flow (2 minutes)

1. Open a real, messy lecture deck in Google Slides.
2. Circle an equation and ask out loud: "Where does this 2 come from?"
3. The answer draws itself next to the slide with an arrow to the term, while the voice explains in sync.
4. Circle part of that answer and ask a follow-up; a nested explanation appears beside it.
5. Switch to a news article and circle a sentence: same experience, nothing imported.
6. Turn on tutor mode, circle a deliberately wrong homework step, and it writes only a hint.
7. End on the confusion map in the side panel.

# Build plan

The goal is one working circle-ask-answer loop by hour 14, then polish. Build a Chrome extension used with a mouse or trackpad, so it works on the sites students already use. An iPad version with Apple Pencil comes later. Hours below count from the start of hacking on Nov 13; line them up with the official schedule once it is out.

## Architecture

&#91;embedded content: architecture · extension, server, AI services\]

The extension sends the circled crop (cut from a screenshot of the tab), the page's text and the transcribed question to the server. The server asks the vision LLM for answer steps, gets audio for each step from TTS, logs the topic, and streams steps plus audio back to the player. API keys never live in the extension.

## Tech stack

| Piece | Tool | Notes |
| --- | --- | --- |
| Extension | Chrome Manifest V3, React + Vite (CRXJS plugin) | One codebase for the content script, side panel and background worker |
| Drawing layer | Content script adds a transparent canvas over the page | Toggle with a shortcut (for example Alt+C) so normal clicking still works |
| Circle detection | Closed-loop check on the mouse stroke + bounding box | Stroke ends near where it started → it's a circle |
| What's under the circle | `chrome.tabs.captureVisibleTab`, cropped; plus DOM text inside the box | The screenshot covers canvas-drawn sites like Google Slides |
| PDFs | The extension's own PDF.js viewer page | Chrome's built-in PDF viewer blocks extensions |
| Voice in | Web Speech API in the side panel; Whisper as backup | Grant mic access once from an extension setup page |
| Brain | Vision LLM (Claude or Gemini) | Gets the crop, the page text and the question; returns JSON only |
| Voice out | ElevenLabs streaming TTS | Browser speech synthesis as a free fallback |
| Ink rendering | SVG overlay placed next to the circle; stroke-dash animation + a handwriting font | Re-position on scroll and resize |
| Side panel | Chrome Side Panel API | Tutor-mode toggle, question history, confusion map |
| Backend | FastAPI or Node (Express) | Holds API keys, calls the AI, streams results |
| Storage | SQLite or Supabase | Circles, questions and topics for the confusion map |
| Distribution | Load unpacked for the demo; public GitHub repo with install steps | Chrome Web Store review takes days, so skip it for now |

## Answer format

The AI never returns a paragraph. It returns a list of short steps, each pairing what to draw with what to say, so ink and voice stay in sync. Lock this format in the first hours: the frontend and the AI work can then run in parallel against it.

```json
{
  "mode": "answer",
  "topic": "chain rule",
  "steps": [
    {
      "say": "This 2 comes from differentiating x squared.",
      "ink": [
        {"type": "arrow", "to": "circled"},
        {"type": "text", "value": "d/dx (x²) = 2x"}
      ]
    },
    {
      "say": "The chain rule multiplies it by the inside derivative.",
      "ink": [
        {"type": "underline", "target": "previous"},
        {"type": "text", "value": "× inner derivative"}
      ]
    }
  ]
}
```

The player plays step 1's audio while drawing step 1's ink, then moves on. In tutor mode, `mode` is `"hint"` and the steps hold only a question or a nudge. `topic` feeds the confusion map.

## Team split

Assumes a team of 4 (the HackPrinceton maximum). With 3, merge roles 3 and 4.

| Role | Owns | Done when |
| --- | --- | --- |
| 1. Canvas | Content-script overlay, mouse circle capture, tab screenshot and crop, DOM text, PDF viewer page | A circle on any page sends a clean crop + page image |
| 2. AI | Backend, prompts, JSON format, tutor mode, retries on bad JSON | A crop + question returns valid steps in under 4 s to first step |
| 3. Ink + voice | Animated ink renderer, TTS, step-by-step sync, follow-ups | Steps draw and speak in sync; circling an answer starts a follow-up |
| 4. Product + demo (Joy) | Voice input, confusion map, UI polish, demo script, Devpost, pitch | The 2-minute demo runs end to end without a hiccup |

Everyone tests on the real demo sites (Google Slides, a course site, a PDF) from hour 14 onward, not just on a test page.

## 36-hour schedule

&#91;embedded content: 36-hour schedule · 5 phases, 2 gates\]

If the loop isn't working on real websites by hour 14, drop follow-ups and the confusion map and spend everything on the core loop. Plan sleep in shifts during Polish so someone fresh runs the demo.

## Scope

**Must have** (the demo fails without these):

- On any web page or PDF, circle a region and ask by voice
- Answer drawn in the margin with synced voice
- Follow-up by circling the answer
- Tutor mode toggle

**Stretch** (only after hour 24):

- Confusion map with flashcards
- Upload page for PowerPoint, Word and photos (converted to pages)
- Read-and-simplify accessibility mode
- Answers drawn as diagrams, not just text and arrows
- Later, not at the hackathon: a Safari version for iPad with Apple Pencil

Cut stretch items without regret. A smooth core loop beats five half-working features.

## Risks and fallbacks

| Risk | Fallback |
| --- | --- |
| Slow AI response kills the magic | Stream the response; start drawing and speaking step 1 while the rest generates. Show a pulsing "thinking" mark next to the circle |
| AI returns broken JSON | Validate the schema, retry once, then fall back to plain text next to the circle |
| Overlay blocks normal clicking on the page | Drawing mode only while the shortcut is on; otherwise the canvas lets clicks pass through |
| Site draws on a canvas, so no DOM text (Google Slides, Docs) | Rely on the screenshot and the vision model for those sites |
| PDFs open in Chrome's own viewer, where extensions can't draw | Catch PDF links and open them in the extension's PDF.js viewer |
| Ink drifts when the page scrolls | Anchor ink to page coordinates and re-position on scroll |
| Mic or speech recognition flaky in a loud hall | A text box appears after each circle; type the question instead |
| Circle detection misfires | A "lasso" button: the next stroke always counts as a circle |
| TTS credits run out or lag | Browser speech synthesis as backup |
| Venue Wi-Fi drops during judging | Pre-record a 2-minute demo video; keep a phone hotspot ready |
| Ink and voice drift out of sync | Sync per step, not per word: each step waits for its audio to finish |

## Before the event

Past HackPrinceton rules required the GitHub repo to be created during the event, so prepare everything except the project code.

- [ ] Confirm the team and assign the four roles
- [ ] Get API keys and credits: LLM, ElevenLabs, hosting
- [ ] Build a throwaway extension to test the overlay, tab screenshot and mic permission in Chrome
- [ ] Pick 3 real demo pages: a Google Slides deck, a course or article page, and a math-heavy PDF
- [ ] Draft the AI prompt and the JSON format, and test them in a chat window
- [ ] Choose the handwriting font and check it reads well over busy pages
- [ ] Bring laptops, chargers and a hotspot; sign in to the demo Google account ahead of time
- [ ] Read this year's rules and sponsor prizes once they're posted
