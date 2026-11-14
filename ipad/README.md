# Halo for iPad

A PDF-first native iPad app built with SwiftUI, PDFKit, PencilKit, Speech, and AVFoundation. The app reuses Halo’s existing `/api/ask` SSE protocol and server-side Gemini/Claude and ElevenLabs integration.

## The experience

There is no side panel. The page is the whole interface.

1. **Upload moment.** Import a PDF and Halo reads every page (`/api/digest`). A card appears over the document: Halo's own title, a spoken two-sentence brief in its voice (ElevenLabs), the three ideas to leave with in handwriting, a strip showing where the document gets hard, and "Start at page N". Pages Halo thinks will trip you up get a pulsing coral **tricky: <topic>** mark in the margin; tap it and Halo walks you through that page.
2. **Circle and ask.** Draw a loose circle with the Pencil (or a finger, via the bottom bar). A **note** (a frosted sheet of tracing paper, no colour or title bar) opens beside the circle and starts listening; stop talking and the question sends itself. Halo's answer is **handwritten live on the note** (with the unevenness of a real hand: drifting baseline, letters that vary in size and lean) while the voice speaks each step, with a coral tail pointing at what you circled. Nothing is written over the page, so dense book pages stay readable.
3. **Notes you can come back to.** Drag a note by its header, ask follow-ups on it, or put it away: a small numbered tab stays on the circle and reopens it. Every note is also collected in **Notes** (top bar), grouped by chapter.
4. **Chapters and search.** The top bar opens Chapters (from the PDF outline, or detected "Chapter N" headings), Notes, and a search across the book's text and your notes. Books over 80 pages are read by Halo one chapter at a time: tap ✦ on a chapter for its brief and tricky-page marks.
5. **Session summary.** The clipboard button in the top bar opens a full-screen written summary (`/api/recap`, no audio): for each question, what was asked (dictation slips cleaned up) and how it was explained in a few bullet points, with the sticky note beside it, grouped by chapter. Switch between Today and All notes; tap a note to return to it on its page. Offline or in demo mode the summary is built on the iPad from the notes.
6. **My notes.** The pencil-square button in the top bar opens a notebook for the document: type notes of your own, or switch to the pen and write and sketch them by hand with the Pencil (a page that grows as you fill it; a note can have both), however rough. **Enhance with AI** (`/api/notes/enhance`) organizes them under headings, expands shorthand, reads the handwriting (sent as a picture), adds missing detail (marked ✦ so you can tell it from your own points), flags anything you wrote that is wrong, lists key terms, and draws a diagram where one helps (`/api/notes/image`, appears a few seconds after the text). Your own text is never overwritten: switch between My notes and Enhanced. In demo mode the note is only regrouped on the iPad. Notes don't need a document: **Start a note** on the start screen (or **Quick notes** in the library sidebar) opens a free-standing notebook, saved in `quick-notes.json`; Halo enhances those from the notes alone. **Circle & ask** on the Enhanced version: loop any points (a circled heading or diagram takes its whole section) and pick Clean it up, Add detail, Explain it, Check it or Add a diagram, type, or say what you want (`/api/notes/refine`). Halo's answer appears in its handwriting under the circle: **Replace** swaps it in for the circled points, **Add below** adds just the new points under them, and any diagram goes into that section. Your own notes are never changed by it.
7. **Go deeper: Halo looks it up on the web.** Ask on a sticky note for "a video", "more detail", "sources" or "pictures of…" (or tap **Go deeper** once Halo has answered; **Look it up** on a selected or circled part of your notes; or type into **Halo goes and finds out** on the start screen). A full-screen board fills in live: Halo says out loud what it is looking for (`/api/dive/plan`); an explanation built from a Google Search with numbered source chips that open the page in the app (`/api/dive/answer`); YouTube videos that play in place (`/api/dive/videos`); and Halo **watches the best video itself** and offers "Skip to 5:05: it explains how ATP synthase uses…" (`/api/dive/moment`, Gemini video understanding). Real diagrams and photos come from Wikipedia and Wikimedia Commons with credits, picked by Halo for relevance (`/api/dive/images`). **Going a level deeper:** Halo stays docked under the board with the next question ready. Type it, say it (mic; a pause sends it), tap one of the three questions Halo expects next (`next` in `/api/dive/answer`), **dig into this** under any part of the answer, or **Ask Halo about this** on a picture. Each takes the board one level down; the line of rings along the top ("3 deep") is the way back up, and coming back looks nothing up again. **Save to my notes** keeps it all, including the video moments and sources, as a note. If the iPad's network can't reach a picture host, the server fetches it (`/api/dive/picture`, restricted to YouTube thumbnails, Wikimedia and favicons). No extra keys needed; set `YOUTUBE_API_KEY` to use the YouTube Data API instead of reading the results page.

**Look and layout.** Every page shares one kit (`Halo/Design.swift`): dotted desk paper, the coral ring, serif titles, handwritten chips, yellow sticky notes and taped prints. Halo's answers on a page no longer float: they are written in **Halo's margin** (`HaloMargin` in `ThreadPill.swift`), docked beside the page in landscape and under it in portrait, with an arrow to the circle; the page resizes and scrolls so the circle stays in view. Chapters, sticky notes and search share one top-bar button.
7. **It knows you.** First launch asks name, course, level and how you like things explained. That profile, plus the topics you've asked about across all your documents, travels with every question, so the tutor pitches depth and examples at you and connects today's question to yesterday's.

Everything (circles, ink, threads, Halo's read of each document, your handwriting) is saved locally and redrawn when you come back.

## Project map

```text
Halo/
  HaloApp.swift          Library, the studio screen (page + floating pill + bottom bar), welcome overlay
  StudyStore.swift       State machine: circles → listening → asking → ink + voice; digest; learner profile; launch script
  PDFReader.swift        PDFKit with per-page overlays: Pencil lasso, thread hit-testing, PencilKit notes, pill anchoring
  MarginInk.swift        Ink engine: note layout from font outlines (stroke-animated), sketches, images; on-page circles, note tabs, hotspots
  Companion.swift        Halo the companion: the dock (avatar + "Ask Halo anything" + page tools) and the avatar's menu
  ThreadPill.swift       The sticky note (listen / type / captions / follow-ups), the paper Halo writes on, transcript popover
  Landing.swift          Start screen: what Halo does, import / sample, pick up where you left off
  Notebook.swift         My notes: the student's own notes and Halo's enhanced version
  Recap.swift            Session summary: each question, how it was explained, and its note
  Navigator.swift        Chapters (outline or detected), notes by chapter, book + notes search
  Welcome.swift          Upload-moment card, reading banner, first-launch onboarding
  Audio.swift            Dictation (with silence auto-send) and step audio playback
  PDFCapture.swift       Page + crop images for the model, with the student's circle drawn on
  SampleLesson.swift     Offline sample PDF, canned answers and document map
Sources/HaloCore/        Models (sessions, lasso, learner profile, document map), repository, SSE client, digest client
```

## Scripted demos and screenshots

The app accepts launch arguments so a demo can run without touching the screen (also how it was verified on the simulator):

```sh
xcrun simctl launch <udid> dev.halo.ipad --sample --live --page 2 \
  --circle 0.07,0.60,0.31,0.06 --ask "Where does this 2x come from?"
```

`--sample` opens the sample lesson (`--open /path/to.pdf` opens any PDF on the simulator's host; `--panel chapters|notes`, `--search "text"` and `--close` drive the new panels), `--live` uses the real server instead of canned answers, `--page N` jumps there after the welcome, `--circle x,y,w,h` (normalized) stands in for a Pencil stroke, `--ask` types and sends a question, `--stay` leaves the welcome card open.

## Open and run

1. Install **full Xcode 16 or newer** and its iOS simulator SDK. Command Line Tools alone cannot build the UI.
2. Open [`Halo.xcodeproj`](Halo.xcodeproj).
3. Select the **Halo** scheme and an iPad simulator, then Run.
4. For a physical iPad, select the connected iPad. Signing lives in [`Halo/Signing.xcconfig`](Halo/Signing.xcconfig), not in the project file. To build with your own Apple team, create `Halo/Signing.local.xcconfig` (gitignored) with your own `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER`. Do not pick a team under Signing & Capabilities: Xcode would write it into the project and override the file for everyone.
5. Tap **Try an offline sample lesson**, or import a PDF.

The deployment target is **iPadOS 17+**. There are no third-party Swift dependencies. The app target compiles `Sources/HaloCore` directly; the same files are a separate Swift package for host-side validation.

Command-line simulator build, once full Xcode is selected:

```sh
xcodebuild -project ipad/Halo.xcodeproj -scheme Halo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/HaloDerivedData CODE_SIGNING_ALLOWED=NO build
```

## Connect to the existing backend

Start `server/` as described in the root README. In the iPad app, open **Settings**, enter the server URL, and choose **Test connection**. Turn off **Offline sample answers** to use live AI.

- Simulator on the same Mac: `http://localhost:8787`.
- Physical iPad: use `http://your-mac.local:8787` on the same Wi-Fi, with access allowed through the Mac firewall, or use a hosted HTTPS backend.
- `localhost` on a physical iPad points to the iPad, not the development Mac.

The app permits local-network development connections through `NSAllowsLocalNetworking`; unrestricted cleartext networking is not enabled. Use HTTPS for hosted servers. The current backend is a development service without user authentication; add authentication before exposing it publicly.

API keys stay in `server/.env`. A live question sends a rendered current-page image, an optional exact crop, current-page text, and the last ten conversation exchanges. Microphone and speech-recognition permissions are requested only when dictating; recognition may use Apple’s servers. No audio is sent to the Halo backend for dictation.

## Project map

```text
Halo/                       SwiftUI application and native platform adapters
  HaloApp.swift             Library, import flow, adaptive workspace
  StudyStore.swift          Conversation, persistence, cancellation, request orchestration
  PDFReader.swift           Per-page PDFKit overlays, PencilKit, crop selection, pins
  PDFCapture.swift          Page/crop images and handwriting composition
  ConversationPane.swift    Chat, handwritten notes, images, sandboxed SVG diagrams
  Audio.swift               Dictation and cancellable step-by-step audio playback
  SampleLesson.swift        Generated sample PDF and clearly labelled offline answers
  SettingsView.swift        Server connection and study preferences
Sources/HaloCore/           Shared Codable models, local repository, HTTP/SSE client
Tests/HaloCoreTests/         Executable checks, including mocked URLSession transport
```

The local library is stored in Application Support/Halo. Documents have stable UUIDs; notes are versioned JSON with per-page normalized top-left crop coordinates and PencilKit drawing data. Images and TTS clips used for answers are not written as separate media files; generated diagram/image content is retained in the saved messages. Reimporting a PDF creates a separate library copy.

## Verification

The core checks run with Swift and the macOS SDK, without XCTest or an iPad SDK:

```sh
swift run --package-path ipad HaloCoreChecks
```

They cover reverse/clipped crops, SSE comments/CRLF/multiline data, unknown and invalid events, follow-up request fields, URL validation, persisted drawings/conversations, schema protection, real URLSession decoding using an in-process URLProtocol stub, and incomplete-stream recovery. They make no external network calls.

In a restricted workspace, direct compiler caches and build artifacts to temporary folders:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/halo-swift-modules \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/halo-swift-modules \
swift run --package-path ipad --scratch-path /tmp/halo-swift-build \
  --cache-path /tmp/halo-swift-cache --disable-sandbox HaloCoreChecks
```

The core compiles and its checks pass on the development machine. The native app now builds successfully with **Xcode 27.2**, and has been installed and exercised on the **iOS 18.4 iPad Pro 13-inch (M4) simulator**. Simulator checks covered opening a sample PDF, opening the page conversation, completing an offline answer, asking a follow-up, and stopping speech mid-answer. The simulator build reports no Swift source warnings.

Physical Apple Pencil input, rotated PDFs, microphone permissions, live server audio, and real-device local-network permissions still need device verification.

## Simulator speech diagnostics

Apple’s voice services may log `MobileAsset.VoiceServices... failed: 2`; a log line alone does not establish an app crash. Halo initializes system speech only when it actually needs a fallback voice, caches its selected voice, and places a timeout on playback. A missing or stalled voice switches the remaining answer to text with a visible notice; it does not block follow-ups. Server-provided audio clips use AVAudioPlayer and do not initialize the system speech synthesizer. Stop/cancel handles both audio and speech completion.

If speech remains unavailable, disable **Read answers aloud**, configure server audio, or check downloaded voices in the device’s Accessibility settings. The simulator may not have the same voice assets as a physical iPad.

PDFKit layout changes are distinguished from finger scrolling so resizing the reader for a conversation cannot close that conversation. Pencil tool-picker observers are removed when switching documents, and redundant show requests are avoided.

## First device pass

Pencil routing regression: in **Circle**, draw with Pencil and confirm a coral
stroke appears without moving the PDF. In **Write**, write across both blank
paper and existing circles and confirm ink appears without scrolling or opening
a thread. In both modes, one finger should scroll and two fingers should pinch
to zoom. With **Circle with a finger too** enabled, one finger circles and two
fingers scroll. Return to **Read** and confirm normal navigation is restored.
Repeat after switching pages, reopening a document, and rotating the iPad.
This requires a physical Apple Pencil; scripted circle launch arguments bypass
touch routing and cannot verify it.

1. Open the sample, zoom in, select with Pencil, and confirm fingers continue to pan and pinch.
2. Enable Use finger and crop in both drag directions; compare the answer crop with the source.
3. Write a note, switch pages, reopen the app, and confirm drawing/pin alignment.
4. Ask about a crop, ask a follow-up, then ask about a full page; stop an answer mid-playback.
5. Rotate the iPad and resize its window while a conversation is open.
6. Import portrait, landscape, and rotated PDFs, including Files/iCloud documents.
7. Test microphone denial, offline connectivity, and reconnection to a live server.

The app currently accepts PDFs, not raw PowerPoint/Word files or screenshots. It does not overlay other iPad apps, include an embedded browser, sync across devices, or export annotated PDFs. No App Store distribution or signing is configured. Add a shipping App Icon and complete device QA before distribution.

Caveat is bundled under the SIL Open Font License; see `Halo/Resources/Caveat-OFL.txt`.

## Chapter lessons

Tap **Teach me** in the reader, or the graduation cap beside a chapter in **Chapters**. Tap **Build my lesson**. Halo reads the selected chapter and creates a roadmap of concepts in prerequisite order, then teaches one at a time with spoken explanations and animated handwritten notes. **In the book** opens the source page without losing your place in the lesson.

Each concept ends with a short open question or a choice. Type, dictate (then send), ask your own question, request a nudge, or leave it for later. Partial answers receive a repair and another check. The tutor keeps checking until the idea is clear or you choose to leave it for later; a skip never counts as understanding. Earlier boards remain accessible from the roadmap. The final recap separates concepts you understood from those to revisit. **Keep my lesson notes** saves the teaching, answers, and recap in **My notes**.

Closing the workspace keeps the current lesson available while this document remains open in the app. Active graph checkpoints are held in server memory: restarting the server or reopening the app requires a fresh lesson. Saved notebook notes remain available. Interrupted answer requests can be recovered without advancing twice. Live lessons require a PDF text layer and a chapter of up to 120 pages; image-only scans need OCR before importing. The offline calculus sample includes a clearly labelled scripted lesson; imported books require live mode.

Simulator smoke test (the current project bundle ID is `com.joyshah.halo`):

```sh
xcrun simctl launch <udid> com.joyshah.halo --sample --lesson --silent
# Add --lesson-intro to stop at the introduction.
# Or --lesson-replies "bring the power down and subtract one|x² + 1|the inside changes, so multiply by its derivative"
```

The server tests also exercise the real LangGraph checkpoint/resume flow, private answer criteria, follow-up questions, rechecks, skips, invalid input, mastery replacement, and simultaneous retries. They use an in-memory test database and no network calls.

### Source-led lesson scenes

Each concept now uses **Notice → See it → Try it** rather than opening on a full handwritten board:

- **Notice** shows a short passage matched against the actual PDF text, its page number, and an original-page preview.
- **See it** shows a compact flow, comparison, or cycle explaining the relationship. Relevant Wikimedia diagrams appear with creator, license, and original-source links when available.
- **Try it** works through a concrete example one move at a time, with a reveal control and a final connection back to the concept.

When voice is enabled, the active scene follows the tutor’s explanation. Muted lessons leave scene navigation and example reveals to the learner. Handwritten notes are available under **Tutor’s notes**. The question and answer controls stay on screen.

The server gathers source material in `server/lesson-material.js`. It sends the textbook anchor immediately, builds a teaching scene from the surrounding pages, and searches for supplementary explanations and diagrams in parallel. Quotes that cannot be found in the supplied PDF text are replaced with an actual extracted passage. Web prose is shown only with its grounding citations; uploaded textbook copies and video landing pages are excluded from reading evidence. Missing web services do not prevent textbook-based teaching. Lesson scenes and source links are included when saving the lesson to My notes.

For screenshots, add `--lesson-phase source|visual|example` and optionally `--lesson-moves 2` to the existing sample launch command. These run locally without web retrieval in offline sample mode.

## Halo, the companion

The avatar sits in a dock at the bottom of the page (top, while writing). Type anything into **Ask Halo anything…** with no circle: a question is asked about the page in front of you; "go to page 12", "next page", "find entropy", "quiz me" / "teach me", "recap", "open my notes", "what's this chapter about?" do what they say; "show me a video…" goes to the web (`StudyStore.askHalo`). Tap the avatar for a menu of everything Halo can do. It listens, thinks and talks with the app, dozes after 75 s of nothing (tap to wake), beams when a step of working is right, and keeps a streak with confetti at 3, 5 and every 5 after. On the start screen it greets you above the same ask bar (answered from the web) and your shelf of documents.

Scripted checks: `--sample --say "go to page 3"`, `--sample --launcher`, `--sample --cheer 3`.

## PowerPoint and Word imports

**Import a document** accepts PDF, PowerPoint (`.ppt`, `.pptx`), and Word (`.doc`, `.docx`) from Files or **Open in Halo**. Office files up to 25 MB are sent to the configured Halo server and converted to PDF. The app saves that PDF under the original document name; search, circle-and-ask, handwriting, notes, and lessons then work as they do for PDFs. The source file is unchanged. Saved documents reopen offline; the initial Office conversion requires the server even in sample-answer mode.

Install LibreOffice on the server (`brew install --cask libreoffice` on macOS, or `sudo apt-get install libreoffice` on Debian/Ubuntu), then restart the Halo server. Set `LIBREOFFICE_PATH` in `server/.env` if the executable is not on PATH or in `/Applications/LibreOffice.app`. Conversion uses an isolated profile with macros disabled and removes temporary files afterward. No third-party conversion service is used.

Slides become static PDF pages. Animations, transitions, and embedded videos are not interactive; missing fonts may change layout. Password-protected or damaged files should be exported as unlocked PDFs. Import errors leave the existing library unchanged.
