import type { InkItem } from "./types";
import { cleanScene3D } from "../../../shared/scene3d/schema.js";

export interface DisplayMessage { role: "user" | "assistant"; text: string; ink?: InkItem[] }
export interface ConversationSnapshot {
  id: number;
  label: string;
  scope: string;
  messages: DisplayMessage[];
  busy: boolean;
  status: string;
  error?: string;
  draft: string;
  placement: "panel" | "card";
  sessions: { id: number; label: string; active: boolean }[];
}
export type ConversationAction =
  | { action: "ask"; question: string }
  | { action: "draft"; text: string }
  | { action: "mic" | "stop" | "close" | "float" | "dock" }
  | { action: "select"; id: number };

// One view for both surfaces, so switching placement never loses the conversation.
export class ConversationView {
  private root: ShadowRoot;
  private thread: HTMLElement;
  private input: HTMLTextAreaElement;
  private title: HTMLElement;
  private status: HTMLElement;
  private sessions: HTMLElement;
  private send: HTMLButtonElement;
  private mic: HTMLButtonElement;
  private stop: HTMLButtonElement;
  private move: HTMLButtonElement;
  private signature = "";
  private messageSignatures: string[] = [];
  private sessionSignature = "";
  private id = -1;
  private pendingDraft: string | null = null;
  private wasBusy = false;
  onAction: (action: ConversationAction) => void = () => {};
  onDrag: (event: PointerEvent) => void = () => {};
  constructor(public host: HTMLElement, floating = false) {
    this.root = host.attachShadow({ mode: "open" });
    this.root.innerHTML = `<style>
      @font-face{font-family:HaloInk;src:url("${chrome.runtime.getURL("fonts/Caveat.ttf")}") format("truetype");font-display:swap}
      :host{all:initial;display:block;color-scheme:light dark;font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#252b2a}
      *{box-sizing:border-box}button,textarea{font:inherit}button{cursor:pointer;color:inherit;background:none;border:0}button:focus-visible,textarea:focus-visible{outline:2px solid #688975;outline-offset:2px}button:disabled{opacity:.45;cursor:default}
      .view{background:#fff;border:1px solid #e6e8e0;border-radius:12px;overflow:hidden;display:flex;flex-direction:column;max-height:100%;height:100%}
      .head{display:flex;align-items:center;gap:6px;padding:12px;border-bottom:1px solid #e6e8e0;flex:none;${floating ? "cursor:grab;touch-action:none" : ""}}
      .heading{flex:1;min-width:0}.title{font-size:12px;font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.scope{font-size:10px;color:#747b76}.icon{padding:5px 7px;border-radius:6px;font-size:12px;flex:none}.icon:hover{background:#f1f4ee}
      .sessions{display:flex;gap:5px;overflow:auto;padding:8px 10px;border-bottom:1px solid #e6e8e0;flex:none}.sessions:empty{display:none}.session{font-size:10px;white-space:nowrap;background:#f1f4ee;padding:4px 8px;border-radius:6px}.session[aria-pressed=true]{background:#466454;color:#fff}
      .thread{overflow:auto;padding:12px;min-height:80px;flex:1;overscroll-behavior:contain;display:flex;flex-direction:column;gap:10px}.message{font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere;padding:10px;border-radius:9px;flex:none;background:#f1f4ee}.user{background:#fcf0e9;margin-left:20px}.who{font-size:9px;font-weight:650;text-transform:uppercase;letter-spacing:.8px;opacity:.65;margin-bottom:4px}.empty{padding:18px 4px;font-size:12px;color:#747b76;text-align:center}.ink{display:grid;gap:7px;margin-top:10px;border-top:1px solid #dfe6db;padding-top:9px;color:#466454}.ink-note{font-family:HaloInk,"Segoe Print",cursive;font-size:24px}.ink svg{width:100%;max-height:200px;overflow:visible}.ink svg text{font-family:HaloInk,cursive;font-size:16px}.ink img{width:100%;border-radius:6px}.ink .boxed{border:1px solid currentColor;border-radius:4px;padding:3px}.ink .underlined{text-decoration:underline;text-underline-offset:4px}
      .status{padding:0 12px 8px;color:#747b76;font-size:10px;flex:none;overflow-wrap:anywhere}.status.error{color:#af4e30}.compose{border-top:1px solid #e6e8e0;padding:10px;flex:none}.compose textarea{resize:vertical;min-height:48px;max-height:130px;width:100%;border:1px solid #dfe3dc;border-radius:8px;background:transparent;color:inherit;padding:9px;font-size:12px}.compose-row{display:flex;align-items:center;gap:6px;margin-top:6px}.tip{font-size:9px;color:#747b76;flex:1}.send{background:#e56b48;color:#fff;border-radius:7px;padding:6px 11px;font-size:11px}.stop{font-size:11px;border:1px solid #e6e8e0;border-radius:7px;padding:5px 8px}.stop[hidden]{display:none}
      @media(prefers-color-scheme:dark){:host{color:#e7eae2}.view{background:#252d27;border-color:#384138}.head,.compose,.sessions{border-color:#384138}.scope,.status,.tip,.empty{color:#a0aca0}.icon:hover,.session,.message{background:#303c32}.user{background:#49362c}.ink{color:#bbd5b9;border-color:#52614e}.compose textarea,.stop{border-color:#4c584e}.status.error{color:#ee9877}}
      @media(prefers-reduced-motion:no-preference){.thread{scroll-behavior:smooth}}
    </style><section class="view" aria-label="Halo conversation"><header class="head"><div class="heading"><div class="title"></div><div class="scope"></div></div><button class="icon move"></button><button class="icon close" aria-label="Collapse conversation" title="Collapse to numbered pin">−</button></header><nav class="sessions" aria-label="Conversations on this slide or page"></nav><div class="thread" role="log" aria-label="Conversation"></div><div class="status" role="status" aria-live="polite"></div><form class="compose"><textarea aria-label="Your question" placeholder="Ask about this section…" rows="2"></textarea><div class="compose-row"><button class="icon mic" type="button" aria-label="Ask by voice" title="Ask by voice">🎙</button><span class="tip">Enter to send · Shift+Enter for a new line</span><button class="stop" type="button" hidden>Stop</button><button class="send" type="submit">Send</button></div></form></section>`;
    this.thread = this.root.querySelector(".thread")!;
    this.input = this.root.querySelector("textarea")!;
    this.title = this.root.querySelector(".title")!;
    this.status = this.root.querySelector(".status")!;
    this.sessions = this.root.querySelector(".sessions")!;
    this.send = this.root.querySelector(".send")!;
    this.mic = this.root.querySelector(".mic")!;
    this.stop = this.root.querySelector(".stop")!;
    this.move = this.root.querySelector(".move")!;
    this.move.textContent = floating ? "Dock ↗" : "Float ↗";
    this.move.type = "button";
    this.move.setAttribute("aria-label", floating ? "Move conversation to side panel" : "Float conversation on page");
    this.move.addEventListener("click", () => this.onAction({ action: floating ? "dock" : "float" }));
    this.root.querySelector(".close")!.addEventListener("click", () => this.onAction({ action: "close" }));
    const submit = () => { if (this.input.value.trim() && !this.send.disabled) this.onAction({ action: "ask", question: this.input.value.trim() }); };
    this.root.querySelector("form")!.addEventListener("submit", (e) => { e.preventDefault(); submit(); });
    this.input.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(); } if (e.key === "Escape") this.onAction({ action: "close" }); });
    this.input.addEventListener("input", () => { this.pendingDraft = this.input.value; this.onAction({ action: "draft", text: this.input.value }); });
    this.mic.addEventListener("click", () => { this.pendingDraft = null; this.onAction({ action: "mic" }); });
    this.stop.addEventListener("click", () => this.onAction({ action: "stop" }));
    this.root.querySelector(".head")!.addEventListener("pointerdown", (event) => { if (!(event.target as Element).closest("button")) this.onDrag(event as PointerEvent); });
  }
  render(state: ConversationSnapshot) {
    const changed = state.id !== this.id;
    this.id = state.id;
    this.title.textContent = `#${state.id} · ${state.label}`;
    this.root.querySelector(".scope")!.textContent = state.scope;
    this.status.textContent = state.error || state.status;
    this.status.classList.toggle("error", !!state.error);
    this.send.disabled = this.mic.disabled = state.busy;
    this.stop.hidden = !state.busy;
    const submitted = state.busy && !this.wasBusy;
    this.wasBusy = state.busy;
    // Older draft acknowledgements must not overwrite characters still being typed.
    if (changed || submitted || this.pendingDraft === null || this.pendingDraft === state.draft) {
      this.input.value = state.draft; this.pendingDraft = null;
    }
    this.input.placeholder = state.messages.length ? "Ask a follow-up…" : "What would you like to understand?";
    const signature = JSON.stringify(state.messages);
    if (changed || signature !== this.signature) {
      const nearBottom = this.thread.scrollHeight - this.thread.scrollTop - this.thread.clientHeight < 70;
      this.signature = signature;
      // Keep unchanged messages mounted: advancing narration must not reset a model
      // the student is already rotating or create a fresh WebGL context for it.
      if (changed || !state.messages.length || !this.messageSignatures.length) this.thread.replaceChildren();
      if (!state.messages.length) { const empty = document.createElement("div"); empty.className = "empty"; empty.textContent = "Your page stays clear. Explore the explanation here."; this.thread.appendChild(empty); }
      const messageSignatures = state.messages.map(message => JSON.stringify(message));
      for (const [index, message] of state.messages.entries()) {
        if (!changed && this.messageSignatures[index] === messageSignatures[index] && this.thread.children[index]) continue;
        const el = document.createElement("article"); el.className = `message ${message.role}`;
        const who = document.createElement("div"); who.className = "who"; who.textContent = message.role === "user" ? "You" : "Halo";
        const text = document.createElement("div"); text.textContent = message.text;
        el.append(who, text);
        if (message.ink?.length) this.renderInk(el, message.ink);
        const existing = this.thread.children[index];
        if (existing) existing.replaceWith(el); else this.thread.appendChild(el);
      }
      if (state.messages.length) while (this.thread.children.length > state.messages.length) this.thread.lastElementChild?.remove();
      this.messageSignatures = messageSignatures;
      if (changed || nearBottom) this.thread.scrollTop = this.thread.scrollHeight;
    }
    const sessions = JSON.stringify(state.sessions);
    if (sessions !== this.sessionSignature) {
      this.sessionSignature = sessions;
      this.sessions.replaceChildren();
      for (const session of state.sessions) {
        const button = document.createElement("button"); button.className = "session";
        button.textContent = `#${session.id} ${session.label}`; button.setAttribute("aria-pressed", String(session.active));
        button.addEventListener("click", () => this.onAction({ action: "select", id: session.id }));
        this.sessions.appendChild(button);
      }
    }
  }
  focus() { this.input.focus({ preventScroll: true }); }
  private renderInk(parent: HTMLElement, items: InkItem[]) {
    const ink = document.createElement("div"); ink.className = "ink";
    let previous: HTMLElement | null = null;
    const ns = "http://www.w3.org/2000/svg";
    for (const item of items) {
      if (item.type === "text") { previous = document.createElement("div"); previous.className = "ink-note"; previous.textContent = item.value; ink.appendChild(previous); }
      else if (item.type === "box" || item.type === "underline") previous?.classList.add(item.type === "box" ? "boxed" : "underlined");
      else if (item.type === "sketch") {
        const svg = document.createElementNS(ns, "svg"); svg.setAttribute("viewBox", `-8 -8 ${item.w + 16} ${item.h + 16}`); svg.setAttribute("role", "img"); svg.setAttribute("aria-label", "Explanation diagram");
        for (const d of item.paths) { const path = document.createElementNS(ns, "path"); path.setAttribute("d", d); path.setAttribute("fill", "none"); path.setAttribute("stroke", "currentColor"); path.setAttribute("stroke-width", "1.8"); svg.appendChild(path); }
        for (const label of item.labels) { const text = document.createElementNS(ns, "text"); text.setAttribute("x", String(label.x)); text.setAttribute("y", String(label.y)); text.setAttribute("fill", "currentColor"); text.setAttribute("font-size", "11"); text.textContent = label.text; svg.appendChild(text); }
        ink.appendChild(svg);
      } else if (item.type === "scene3d") {
        const spec = cleanScene3D(item);
        if (spec) {
          const frame = document.createElement("iframe");
          frame.src = `${chrome.runtime.getURL("scene3d.html")}#${encodeURIComponent(JSON.stringify(spec))}`;
          frame.title = `Explore ${spec.model === "brain" ? "the human brain" : spec.model === "neuron" ? "a neuron" : "an animal cell"} in 3D`;
          frame.loading = "lazy"; frame.style.cssText = "width:100%;height:720px;border:0;border-radius:10px;background:#faf9f4";
          ink.appendChild(frame);
        }
      } else if (item.type === "image" && item.data && /^image\/(png|jpeg|webp)$/.test(item.mime || "")) {
        const image = document.createElement("img"); image.src = `data:${item.mime};base64,${item.data}`; image.alt = item.prompt; ink.appendChild(image);
      } else if (item.type === "check" || item.type === "cross") { const mark = document.createElement("span"); mark.textContent = item.type === "check" ? "✓" : "✗"; ink.appendChild(mark); }
    }
    if (ink.childNodes.length) parent.appendChild(ink);
  }
}
