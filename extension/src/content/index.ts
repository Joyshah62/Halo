import { sendRuntimeMessage, runtimeAvailable, onRuntimeInvalidated, showReloadNotice } from "../shared/runtime";
// The page owns context and playback; either the panel or one floating card presents it.
import { Overlay, type Box, toBox } from "./overlay";
import { captureCrop, textInBox, pageText } from "./capture";
import { Player } from "./player";
import { ExplanationCard } from "./bubble";
import { Annotations } from "./annotations";
import { currentSurface, watchSurface, surfaceContentBounds, type Surface } from "./surface";
import { Hud } from "./hud";
import { placeCard } from "./placement";
import { startListening, stopListening, panelEvent } from "./voice";
import { getSettings, type AskPayload, type AskEvent, type ConversationTurn, type Msg } from "../shared/types";
import type { ConversationSnapshot, DisplayMessage, ConversationAction } from "../shared/conversation";

if (!(window as any).__halo) {
  (window as any).__halo = true;
  const overlay = new Overlay(), card = new ExplanationCard(), annotations = new Annotations(), hud = new Hud();
  interface Session {
    relative?: { left: number; top: number; width: number; height: number };
    id: number; surface: Surface; box: Box; selectionMode: "crop" | "page";
    capture: Promise<Awaited<ReturnType<typeof captureCrop>>>;
    circledText: string; pageText: string; title: string; url: string;
    conversation: ConversationTurn[]; messages: DisplayMessage[];
    previous?: { text: string; id?: number };
    label: string; status: string; error?: string; draft: string; note?: string;
    busy: boolean; placement: "panel" | "card";
  }
  const lifetime = new AbortController();
  let disposed = false;
  let surface = currentSurface(), active: Session | null = null;
  const sessions: Session[] = [];
  const lastActive = new Map<string, number>();
  let nextId = 1, run = 0, revision = 0;
  let port: chrome.runtime.Port | null = null, player: Player | null = null;
  let panelAvailable = false;
  const toPage = (box: Box): Box => toBox(box.left + scrollX, box.top + scrollY, box.width, box.height);
  const visibleSessions = () => sessions.filter((session) => session.surface.key === surface.key);
  function snapshot(): ConversationSnapshot | null {
    if (!active) return null;
    return { id: active.id, label: active.label, scope: `${surface.label} · ${active.selectionMode === "page" ? "Whole page" : "Cropped section"}`, messages: active.messages,
      busy: active.busy, status: active.status, error: active.error, draft: active.draft, placement: active.placement,
      sessions: visibleSessions().map((session) => ({ id: session.id, label: session.label, active: session === active })) };
  }
  function anchorBox(session: Session): Box {
    const bounds = session.relative ? surfaceContentBounds() : null;
    return bounds && session.relative ? toBox(scrollX + bounds.left + session.relative.left * bounds.width, scrollY + bounds.top + session.relative.top * bounds.height,
      session.relative.width * bounds.width, session.relative.height * bounds.height) : session.box;
  }
  function renderAnnotations() {
    if (disposed) return;
    annotations.render(visibleSessions().map((session) => ({ id: session.id, box: anchorBox(session), page: session.selectionMode === "page", label: session.label,
      active: session === active, note: session === active && !session.busy ? session.note : undefined })));
  }
  async function present() {
    if (disposed || !runtimeAvailable()) return;
    const version = ++revision;
    const state = snapshot(); renderAnnotations();
    const response = await sendRuntimeMessage({ type: "PRESENT_CONVERSATION", state } satisfies Msg).catch(() => null);
    if (disposed || version !== revision) return;
    panelAvailable = !!response?.shown;
    if (!state || !active || overlay.drawing) { card.hide(); return; }
    if (state.placement === "panel" && panelAvailable) card.hide();
    else card.show(state, active.selectionMode === "crop" ? anchorBox(active) : null);
  }
  // Must run on the originating click/drag gesture so Chrome can open the panel.
  function openPanel() {
    void sendRuntimeMessage({ type: "OPEN_SIDEPANEL" } satisfies Msg).then(() => present()).catch(() => present());
  }
  overlay.onModeChange = (on) => { hud.set(on); if (on) { stopRun(); card.hide(); } void present(); };
  hud.onToggle = () => overlay.toggle();
  hud.onPage = () => select(toBox(0, 0, innerWidth, innerHeight), "page");
  overlay.onCircle = (selection) => select(selection.box, "crop");
  annotations.onSelect = (id) => { activate(id); openPanelIfWanted(); };
  card.onAction = command;
  function openPanelIfWanted() { if (active?.placement === "panel") openPanel(); }

  function select(box: Box, selectionMode: "crop" | "page") {
    if (disposed || !runtimeAvailable()) return;
    stopRun(); overlay.setDrawing(false);
    surface = currentSurface();
    const session: Session = {
      id: nextId++, surface: { ...surface }, box: toPage(box), selectionMode,
      capture: Promise.resolve(null), circledText: selectionMode === "crop" ? textInBox(box) : "", pageText: pageText(),
      title: document.title, url: location.href, conversation: [], messages: [], label: selectionMode === "page" ? "Whole-page question" : "New section",
      status: "Ask by voice or text. Your page stays clear.", draft: "", busy: false, placement: "panel",
    };
    const bounds = selectionMode === "crop" ? surfaceContentBounds() : null;
    if (bounds && bounds.width > 0 && bounds.height > 0 && box.left >= bounds.left && box.right <= bounds.right && box.top >= bounds.top && box.bottom <= bounds.bottom) {
      session.relative = { left: (box.left - bounds.left) / bounds.width, top: (box.top - bounds.top) / bounds.height, width: box.width / bounds.width, height: box.height / bounds.height };
    }
    active = session; sessions.push(session); lastActive.set(surface.key, session.id);
    // Keep screenshots and conversation context bounded for a long study session.
    if (sessions.length > 24) sessions.shift();
    session.capture = captureCrop(box).then((capture) => currentSurface().key === session.surface.key ? capture : null).catch(() => null);
    void session.capture.then(() => { if (active === session) void present(); });
    openPanel(); void present();
  }
  function activate(id: number) {
    const session = visibleSessions().find((item) => item.id === id);
    if (!session) return;
    stopRun(); active = session; lastActive.set(surface.key, id); void present();
  }
  function stopRun() {
    run++; stopListening();
    player?.stop(); player = null;
    try { port?.disconnect(); } catch {} port = null;
    annotations.clearPoint();
    if (active?.busy) { active.busy = false; active.status = "Stopped. You can ask another question."; }
  }
  function collapse() { stopRun(); active = null; lastActive.delete(surface.key); card.hide(); void present(); }
  function command(action: ConversationAction) {
    if (disposed || !runtimeAvailable()) return;
    if (action.action === "select") { activate(action.id); return; }
    if (!active) return;
    switch (action.action) {
      case "ask": void ask(action.question); break;
      case "draft": active.draft = action.text; void present(); break;
      case "mic": listen(); break;
      case "stop": stopRun(); void present(); break;
      case "close": collapse(); break;
      case "float": {
        const box = anchorBox(active);
        const anchor = active.selectionMode === "crop" ? toBox(box.left - scrollX, box.top - scrollY, box.width, box.height) : null;
        if (panelAvailable && !placeCard(anchor, Math.min(340, innerWidth - 24), Math.min(440, innerHeight - 32))) {
          active.status = "No clear space on this page — keeping the explanation in the side panel.";
        } else active.placement = "card";
        void present(); break;
      }
      case "dock": active.placement = "panel"; openPanel(); void present(); break;
    }
  }
  function listen() {
    if (disposed || !runtimeAvailable() || !active || active.busy) return;
    const session = active;
    session.status = "Starting microphone…"; session.error = undefined; void present();
    startListening({
      onInterim: (text) => { if (active === session && !session.busy) { session.draft = text; void present(); } },
      onFinal: (text) => { if (active === session && !session.busy) void ask(text); },
      onState: (state, detail) => {
        if (active !== session || session.busy) return;
        session.status = state === "listening" ? "Listening… Ask your question out loud." : detail || "Click the mic to retry, or type a question."; void present();
      },
    });
  }
  async function ask(question: string) {
    question = question.trim();
    if (disposed || !runtimeAvailable() || !active || active.busy || !question) return;
    stopRun();
    const session = active, token = run;
    const valid = () => active === session && token === run && currentSurface().key === session.surface.key;
    session.busy = true; session.error = undefined; session.draft = ""; session.status = "Thinking…";
    session.messages.push({ role: "user", text: question });
    if (!session.conversation.length) session.label = question.slice(0, 70);
    void present();
    let terminal = false;
    let requestPort: chrome.runtime.Port | null = null;
    const fail = (message: string) => {
      if (!valid() || terminal) return;
      terminal = true; player?.stop(); player = null;
      annotations.clearPoint(); session.busy = false; session.error = message; session.draft = question;
      try { requestPort?.disconnect(); } catch {} if (port === requestPort) port = null;
      void present();
    };
    try {
      const [settings, capture] = await Promise.all([getSettings(), session.capture]);
      if (!valid()) return;
      if (!capture && !session.circledText && !session.pageText) throw new Error("Couldn't read this page. Try a readable section or another page.");
      const payload: AskPayload = { question, selectionMode: session.selectionMode, conversation: session.conversation.slice(-20),
        image: session.selectionMode === "crop" ? capture?.image : undefined, imageMime: capture?.imageMime, contextImage: capture?.contextImage,
        circledText: session.circledText, pageText: session.pageText, pageTitle: session.title, pageUrl: session.url,
        supports3D: true, tutorMode: settings.tutorMode, previousAnswer: session.previous?.text, parentId: session.previous?.id };
      void sendRuntimeMessage({ type: "ACTIVITY", kind: "question", text: question }).catch(() => {});
      const currentPlayer = new Player(settings.voiceOut); player = currentPlayer;
      const answer: string[] = [];
      currentPlayer.onStep = (step) => {
        if (!valid()) return;
        const text = step.say.replace(/\[[a-z ]+\]/gi, "").trim();
        session.messages.push({ role: "assistant", text, ink: step.ink });
        session.status = settings.voiceOut ? "Speaking… Follow the highlighted section." : "Explaining…";
        const note = step.ink.find((item) => item.type === "text");
        if (note?.type === "text") session.note = note.value;
        if (session.selectionMode === "crop" && (step.index === 0 || step.ink.some((item) => item.type === "arrow" && item.to === "circled"))) annotations.point(anchorBox(session));
        void present();
      };
      let questionId: number | undefined;
      requestPort = chrome.runtime.connect({ name: "ask" }); port = requestPort;
      const activePort = requestPort;
      activePort.onMessage.addListener((event: AskEvent) => {
        if (!valid() || terminal) return;
        switch (event.event) {
          case "start": questionId = event.data.id; break;
          case "meta": session.status = event.data.mode === "hint" ? "A hint to help you find the next step…" : "Working through it…"; void present(); break;
          case "step": answer.push(event.data.say); currentPlayer.push(event.data); break;
          case "done":
            terminal = true; activePort.disconnect(); if (port === activePort) port = null;
            void currentPlayer.finish().then(() => {
              if (!valid() || player !== currentPlayer) return;
              const text = answer.join(" ");
              session.conversation.push({ role: "user", text: question }, { role: "assistant", text });
              session.conversation = session.conversation.slice(-20);
              session.previous = { text, id: questionId }; session.busy = false; session.status = "Keep going — ask a follow-up by voice or text.";
              player = null; annotations.clearPoint(); void present();
              void sendRuntimeMessage({ type: "ACTIVITY", kind: "answer", text }).catch(() => {});
            }); break;
          case "error": fail(event.data.message); break;
        }
      });
      activePort.onDisconnect.addListener(() => { if (!terminal) fail("Connection ended before the answer finished. Please try again."); });
      activePort.postMessage(payload);
    } catch (error) { fail(error instanceof Error ? error.message : "Could not start the question. Please try again."); }
  }
  const stopWatchingSurface = watchSurface((next) => {
    stopRun(); surface = next;
    active = sessions.find((session) => session.id === lastActive.get(next.key) && session.surface.key === next.key) ?? null;
    card.hide(); void present();
  });
  document.addEventListener("visibilitychange", () => { if (document.hidden) { stopRun(); void present(); } }, { signal: lifetime.signal });
  window.addEventListener("scroll", () => renderAnnotations(), { passive: true, capture: true, signal: lifetime.signal });
  const annotationInterval = setInterval(renderAnnotations, 700);
  window.addEventListener("resize", () => renderAnnotations(), { signal: lifetime.signal });
  window.addEventListener("keydown", (event) => {
    if (event.altKey && !event.ctrlKey && !event.metaKey && (event.code === "KeyC" || event.key.toLowerCase() === "c" || event.key === "ç")) { event.preventDefault(); overlay.toggle(); }
    else if (event.key === "Escape") { if (overlay.drawing) overlay.setDrawing(false); else if (active) collapse(); }
  }, { capture: true, signal: lifetime.signal });
  const stopMonitoringRuntime = setInterval(() => { runtimeAvailable(); }, 1500);
  onRuntimeInvalidated(() => {
    if (disposed) return;
    const draft = active?.draft || active?.messages.filter((message) => message.role === "user").at(-1)?.text || "";
    disposed = true; revision++;
    stopRun(); active = null;
    lifetime.abort(); stopWatchingSurface(); clearInterval(annotationInterval); clearInterval(stopMonitoringRuntime);
    overlay.destroy(); card.destroy(); annotations.destroy(); hud.destroy();
    showReloadNotice(draft);
  });
  chrome.runtime.onMessage.addListener((message, _sender, respond) => {
    if (disposed) return;
    if (message.type === "GET_CONVERSATION") { respond(snapshot()); void present(); return; }
    if (message.type === "CONVERSATION_ACTION" && active?.id === message.sessionId) command(message.command);
    else if (message.type === "PANEL_CLOSED") { panelAvailable = false; if (active) card.show(snapshot()!, active.selectionMode === "crop" ? anchorBox(active) : null); }
    else if (message.type === "TOGGLE_DRAW") overlay.toggle();
    else if (message.type === "ASK_PAGE") hud.onPage();
    else if (message.type === "TRANSCRIPT" || message.type === "LISTEN_STATE") panelEvent(message);
    else if (message.type === "CLEAR_INK") { stopRun(); sessions.length = 0; lastActive.clear(); active = null; void present(); }
  });
}
