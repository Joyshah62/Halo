import { sendRuntimeMessage } from "../shared/runtime";
// Voice in. Prefers the side panel (extension origin: mic granted once from setup.html).
// Falls back to in-page speech recognition, then to typing.
export interface VoiceHandlers {
  onInterim: (t: string) => void;
  onFinal: (t: string) => void;
  onState: (s: "listening" | "idle" | "unavailable", detail?: string) => void;
}

type Rec = any;
let local: Rec | null = null;
let usingPanel = false;
let handlers: VoiceHandlers | null = null;

export async function startListening(h: VoiceHandlers) {
  stopListening();
  handlers = h;
  const resp = await sendRuntimeMessage({ type: "LISTEN_START" }).catch(() => null);
  if (handlers !== h) {
    if (resp?.ok) sendRuntimeMessage({ type: "LISTEN_STOP" }).catch(() => {});
    return;
  }
  if (resp?.ok) { usingPanel = true; return; }
  // side panel closed → try in-page recognition
  const SR = (window as any).webkitSpeechRecognition || (window as any).SpeechRecognition;
  if (!SR) { h.onState("unavailable", "Open the Halo side panel for voice, or type below."); return; }
  try {
    local = new SR();
    local.lang = navigator.language || "en-US";
    local.interimResults = true;
    local.continuous = false;
    local.onstart = () => { if (handlers === h) h.onState("listening"); };
    local.onresult = (e: any) => {
      if (handlers !== h) return;
      let interim = "", final = "";
      for (const r of e.results) (r.isFinal ? (final += r[0].transcript) : (interim += r[0].transcript));
      if (final) h.onFinal(final.trim()); else if (interim) h.onInterim(interim);
    };
    local.onerror = (e: any) => { if (handlers === h) h.onState("unavailable", e.error === "not-allowed" ? "Mic blocked on this site. Open the Halo side panel for voice, or type below." : `Mic: ${e.error}`); };
    local.onend = () => { if (handlers === h) h.onState("idle"); };
    local.start();
  } catch (e: any) {
    h.onState("unavailable", "Voice unavailable here. Type your question below.");
  }
}

export function stopListening() {
  if (usingPanel) sendRuntimeMessage({ type: "LISTEN_STOP" }).catch(() => {});
  usingPanel = false;
  try { local?.stop(); } catch {}
  local = null;
  handlers = null;
}

/** Called by the content script when the side panel relays a result. */
export function panelEvent(msg: any) {
  if (!handlers) return;
  if (msg.type === "TRANSCRIPT") (msg.final ? handlers.onFinal(msg.text) : handlers.onInterim(msg.text));
  else if (msg.type === "LISTEN_STATE") handlers.onState(msg.state, msg.detail);
}
