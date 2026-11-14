import { ConversationView, type ConversationSnapshot, type ConversationAction } from "../shared/conversation";
import { getSettings, DEFAULT_SETTINGS, type Msg } from "../shared/types";

const $ = <T extends HTMLElement = HTMLElement>(s: string) => document.querySelector(s) as T;
let serverUrl = DEFAULT_SETTINGS.serverUrl;

// ---------- settings ----------
async function initSettings() {
  const s = await getSettings();
  serverUrl = s.serverUrl;
  $<HTMLInputElement>("#tutor").checked = s.tutorMode;
  $<HTMLInputElement>("#voice").checked = s.voiceOut;
  $<HTMLInputElement>("#server").value = s.serverUrl;
}
$("#tutor").addEventListener("change", (e) => chrome.storage.sync.set({ tutorMode: (e.target as HTMLInputElement).checked }));
$("#voice").addEventListener("change", (e) => chrome.storage.sync.set({ voiceOut: (e.target as HTMLInputElement).checked }));
$("#server").addEventListener("change", (e) => { serverUrl = (e.target as HTMLInputElement).value.trim(); chrome.storage.sync.set({ serverUrl }); refresh(); });
$("#draw").addEventListener("click", () => chrome.runtime.sendMessage({ type: "START_DRAW" } satisfies Msg));
$("#page").addEventListener("click", () => chrome.runtime.sendMessage({ type: "ASK_PAGE" } satisfies Msg));
$("#clear").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) chrome.tabs.sendMessage(tab.id, { type: "CLEAR_INK" } satisfies Msg).catch(() => {});
});
$("#pdf").addEventListener("click", () => chrome.runtime.sendMessage({ type: "OPEN_PDF_VIEWER" } satisfies Msg));
$("#mic").addEventListener("click", () => chrome.tabs.create({ url: chrome.runtime.getURL("setup.html") }));

// ---------- tabs ----------
const tabButtons = [...document.querySelectorAll<HTMLButtonElement>(".tabs button")];
function selectTab(button: HTMLButtonElement) {
  for (const tab of tabButtons) {
    const selected = tab === button;
    tab.classList.toggle("on", selected);
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
    const panel = $(`#tab-${tab.dataset.tab}`);
    panel.hidden = !selected;
    panel.classList.toggle("on", selected);
  }
}
tabButtons.forEach((button, index) => {
  button.addEventListener("click", () => selectTab(button));
  button.addEventListener("keydown", (event) => {
    let next: number;
    if (event.key === "ArrowRight") next = (index + 1) % tabButtons.length;
    else if (event.key === "ArrowLeft") next = (index - 1 + tabButtons.length) % tabButtons.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabButtons.length - 1;
    else return;
    event.preventDefault();
    selectTab(tabButtons[next]); tabButtons[next].focus();
  });
});
$(".brand").addEventListener("click", (event) => { event.preventDefault(); selectTab(tabButtons[0]); window.scrollTo({ top: 0, behavior: "auto" }); });

// ---------- data ----------
async function api<T>(path: string): Promise<T | null> {
  try {
    const r = await fetch(`${serverUrl.replace(/\/$/, "")}${path}`);
    return r.ok ? ((await r.json()) as T) : null;
  } catch { return null; }
}

interface Q { id: number; created_at: string; question: string; mode: string; topic: string | null; answer_text: string | null; title: string | null; parent_id: number | null }

async function refresh() {
  const health = await api<{ ok: boolean }>("/api/health");
  $("#health").className = "health " + (health ? "ok" : "bad");
  $("#connection-label").textContent = health ? "Connected" : "Server offline";
  $("#health").title = health ? "Server connected" : `Cannot reach ${serverUrl}. Start it with: cd server && npm start`;
  const [map, hist, cards] = await Promise.all([
    api<{ topic: string; count: number }[]>("/api/confusion"),
    api<Q[]>("/api/history"),
    api<Q[]>("/api/flashcards"),
  ]);
  const total = map ? map.reduce((sum, topic) => sum + topic.count, 0) : hist?.length;
  $("#question-count").textContent = total === undefined ? "Offline" : `${total} ${total === 1 ? "question" : "questions"}`;
  renderMap(map);
  renderHistory(hist);
  renderCards(cards);
}

const emptyIcon = `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 17V7a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H9l-4 4v-3Z"/><path d="M9 9h6M9 12h4"/></svg>`;
function emptyState(title: string, copy: string, hint?: string) {
  return `<div class="empty"><span class="empty-art">${emptyIcon}</span><b>${title}</b><p>${copy}</p>${hint ? `<span class="empty-hint">${hint}</span>` : ""}</div>`;
}
const offlineState = () => emptyState("Your trail will be here", "Connect to your Halo server to see your topics, questions, and flashcards.", "Check connection settings below");
function renderMap(rows: { topic: string; count: number }[] | null) {
  const el = $("#map");
  if (!rows) { el.innerHTML = offlineState(); return; }
  if (!rows.length) { el.innerHTML = emptyState("Room for a little curiosity", "The topics you explore will collect here, so you can see what needs another look.", "Start with a crop or the whole page ↗"); return; }
  const max = Math.max(1, ...rows.map((row) => row.count));
  el.innerHTML = rows.map((r) => `
    <div class="topic"><b>${esc(r.topic)}</b><span class="n">${r.count} ${r.count === 1 ? "question" : "questions"}</span>
    <div class="bar"><i style="width:${Math.max(8, (r.count / max) * 100)}%"></i></div></div>`).join("");
}
function renderHistory(rows: Q[] | null) {
  const el = $("#history");
  if (!rows) { el.innerHTML = `<li>${offlineState()}</li>`; return; }
  if (!rows.length) { el.innerHTML = `<li>${emptyState("Every question is a starting point", "Your questions and follow-ups will stay here for a second look.")}</li>`; return; }
  el.innerHTML = rows.map((q) => `<li>
    <div class="q">${q.parent_id ? "↳ " : ""}${esc(q.question)}</div>
    ${q.answer_text ? `<div class="a">${esc(q.answer_text)}</div>` : ""}
    <div class="meta">${q.parent_id ? `<span>Follow-up</span>` : ""}${q.mode === "hint" ? `<span class="hint">TUTOR HINT</span>` : ""}<span>${esc(q.topic || "")}</span><span>${esc(q.title || "")}</span></div>
  </li>`).join("");
}
const flippedCards = new Set<number>();
function renderCards(rows: Q[] | null) {
  const el = $("#cards");
  if (!rows) { el.innerHTML = offlineState(); return; }
  if (!rows.length) { el.innerHTML = emptyState("Turn an ‘aha’ into a habit", "Flashcards are made from your own questions. Come back for a quick memory check.", "Select a card to reveal the answer"); return; }
  el.innerHTML = rows.map((q) => `<button class="flash ${flippedCards.has(q.id) ? "flipped" : ""}" data-id="${q.id}" aria-label="${esc(q.question)}" aria-pressed="${flippedCards.has(q.id)}"><span class="inner">
    <span class="face front" aria-hidden="${flippedCards.has(q.id)}"><span class="t">${esc(q.topic || "question")}</span><span class="card-text">${esc(q.question)}</span><span class="flip-hint">Select to reveal answer ↗</span></span>
    <span class="face back" aria-hidden="${!flippedCards.has(q.id)}"><span class="t">The idea to remember</span><span class="card-text">${esc(q.answer_text || "")}</span><span class="flip-hint">Select to see question ↗</span></span>
  </span></button>`).join("");
  el.querySelectorAll<HTMLButtonElement>(".flash").forEach((card) => card.addEventListener("click", () => {
    const flipped = card.classList.toggle("flipped");
    const id = Number(card.dataset.id);
    if (flipped) flippedCards.add(id); else flippedCards.delete(id);
    card.setAttribute("aria-pressed", String(flipped));
    card.setAttribute("aria-label", flipped ? `${card.querySelector(".front .card-text")!.textContent}. Answer: ${card.querySelector(".back .card-text")!.textContent}` : card.querySelector(".front .card-text")!.textContent || "Flashcard");
    card.querySelector(".front")!.setAttribute("aria-hidden", String(flipped));
    card.querySelector(".back")!.setAttribute("aria-hidden", String(!flipped));
  }));
}
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

// ---------- voice in (runs here so the mic permission is granted once) ----------
const SR = (window as any).webkitSpeechRecognition || (window as any).SpeechRecognition;
let rec: any = null;
const listenEl = $("#listen");
function startRec(tabId?: number) {
  stopRec();
  const send = (m: Msg) => chrome.runtime.sendMessage({ ...m, tabId }).catch(() => {});
  if (!SR) { send({ type: "LISTEN_STATE", state: "unavailable", detail: "Speech recognition not available in this browser." }); return; }
  rec = new SR();
  const mine = rec;
  rec.lang = navigator.language || "en-US";
  rec.interimResults = true;
  rec.continuous = false;
  rec.onstart = () => { if (rec !== mine) return; listenEl.textContent = "● Listening…"; listenEl.className = "listen on"; send({ type: "LISTEN_STATE", state: "listening" }); };
  rec.onresult = (e: any) => {
    if (rec !== mine) return;
    let interim = "", final = "";
    for (const r of e.results) (r.isFinal ? (final += r[0].transcript) : (interim += r[0].transcript));
    if (final) { listenEl.textContent = `“${final.trim()}”`; send({ type: "TRANSCRIPT", text: final.trim(), final: true }); }
    else if (interim) { listenEl.textContent = interim; send({ type: "TRANSCRIPT", text: interim, final: false }); }
  };
  rec.onerror = (e: any) => {
    if (rec !== mine) return;
    listenEl.className = "listen";
    const detail = e.error === "not-allowed" ? "Microphone blocked. Click “Enable microphone” above." : `Mic: ${e.error}`;
    listenEl.textContent = detail;
    send({ type: "LISTEN_STATE", state: "unavailable", detail });
  };
  rec.onend = () => { if (rec !== mine) return; listenEl.className = "listen"; send({ type: "LISTEN_STATE", state: "idle" }); if (rec === mine) rec = null; };
  try { rec.start(); } catch (e: any) { send({ type: "LISTEN_STATE", state: "unavailable", detail: String(e?.message || e) }); }
}
function stopRec() { try { rec?.stop(); } catch {} rec = null; }

chrome.runtime.onMessage.addListener((msg: any) => {
  // Only act on the copy relayed by the background (it carries the tab id);
  // the content script's original broadcast also reaches this page.
  if (msg.type === "LISTEN_START" && msg.tabId === panelTab) startRec(msg.tabId);
  else if (msg.type === "LISTEN_STOP" && msg.tabId === panelTab) stopRec();
  else if (msg.type === "ACTIVITY") {
    if (msg.kind === "answer") setTimeout(refresh, 400);
    if (msg.kind === "question") { listenEl.textContent = `“${msg.text}”`; listenEl.className = "listen"; }
  }
});

initSettings().then(refresh);
setInterval(refresh, 15000);

// Live conversations are scoped to the tab bound to this panel, not global broadcasts.
const conversationView = new ConversationView($("#conversation-view"));
let conversationState: ConversationSnapshot | null = null;
let conversationPort: chrome.runtime.Port | null = null;
let panelTab: number | undefined;
function sendConversationAction(command: ConversationAction) {
  if (!conversationState || !conversationPort) return;
  try { conversationPort.postMessage({ type: "COMMAND", sessionId: conversationState.id, command }); } catch {}
}
conversationView.onAction = sendConversationAction;
$("#dock-conversation").addEventListener("click", () => sendConversationAction({ action: "dock" }));
function renderConversation(state: ConversationSnapshot | null) {
  const newSession = state && state.id !== conversationState?.id;
  conversationState = state;
  $("#conversation").hidden = !state;
  document.body.classList.toggle("has-conversation", !!state);
  if (!state) return;
  const floating = state.placement === "card";
  $("#conversation-view").hidden = floating;
  $("#floating-notice").hidden = !floating;
  if (newSession) (document.querySelector(".learning-settings") as HTMLDetailsElement).open = false;
  conversationView.render(state);
  if (newSession && !floating) conversationView.focus();
}
async function bindConversationTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || !conversationPort) { renderConversation(null); return; }
  panelTab = tab.id;
  try { conversationPort.postMessage({ type: "BIND", tabId: tab.id }); } catch {}
}
function connectConversations() {
  const port = chrome.runtime.connect({ name: "conversation-panel" }); conversationPort = port;
  port.onMessage.addListener((message) => {
    if (conversationPort !== port || message.tabId !== panelTab) return;
    if (message.type === "STATE") renderConversation(message.state);
    else if (message.type === "LISTEN_START") startRec(message.tabId);
    else if (message.type === "LISTEN_STOP") stopRec();
  });
  port.onDisconnect.addListener(() => {
    if (conversationPort !== port) return;
    conversationPort = null; renderConversation(null);
    setTimeout(connectConversations, 800);
  });
  void bindConversationTab();
}
chrome.tabs.onActivated.addListener(() => { stopRec(); renderConversation(null); void bindConversationTab(); });
chrome.tabs.onUpdated.addListener((id, change) => { if (id === panelTab && change.status === "complete") void bindConversationTab(); });
connectConversations();
