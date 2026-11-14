import { ConversationView, type ConversationSnapshot, type ConversationAction } from "../shared/conversation";
import { type Box, toBox } from "./overlay";
import { placeCard } from "./placement";

export class ExplanationCard {
  private lifetime = new AbortController();
  private observer: ResizeObserver;
  private host = document.createElement("div");
  private view: ConversationView;
  private position: { x: number; y: number } | null = null;
  private session = -1;
  private snap: "left" | "right" | null = null;
  onAction: (action: ConversationAction) => void = () => {};
  visible = false;
  constructor() {
    this.host.id = "halo-bubble-host";
    this.host.style.cssText = "position:fixed;z-index:2147483647;display:none;width:340px;height:440px;min-width:260px;min-height:240px;max-width:calc(100vw - 24px);max-height:calc(100vh - 32px);resize:both;overflow:hidden;border-radius:12px;box-shadow:0 8px 35px #17221c30";
    this.view = new ConversationView(this.host, true);
    this.view.onAction = (action) => this.onAction(action);
    this.view.onDrag = (event) => this.drag(event);
    document.documentElement.appendChild(this.host);
    window.addEventListener("resize", () => this.clamp(), { signal: this.lifetime.signal });
    this.observer = new ResizeObserver(() => this.clamp());
    this.observer.observe(this.host);
  }
  show(state: ConversationSnapshot, anchor: Box | null) {
    const fresh = this.session !== state.id;
    if (fresh) { this.position = null; this.snap = null; this.session = state.id; }
    this.host.style.display = "block"; this.visible = true;
    if (!this.position) {
      const width = Math.min(340, innerWidth - 24), height = Math.min(440, innerHeight - 32);
      const viewportAnchor = anchor ? toBox(anchor.left - scrollX, anchor.top - scrollY, anchor.width, anchor.height) : null;
      const spot = placeCard(viewportAnchor, width, height);
      this.position = spot ? { x: spot.left, y: spot.top } : { x: Math.max(12, innerWidth - width - 16), y: Math.max(16, innerHeight - height - 90) };
      if (!spot && !state.error) state = { ...state, status: "Limited space here — drag this card or dock it in the side panel." };
    }
    this.clamp(); this.view.render(state);
    if (fresh) this.view.focus();
  }
  destroy() { this.lifetime.abort(); this.observer.disconnect(); this.host.remove(); }
  hide() { this.visible = false; this.host.style.display = "none"; }
  private clamp() {
    if (!this.position || !this.visible) return;
    const rect = this.host.getBoundingClientRect();
    if (this.snap) this.position.x = this.snap === "left" ? 12 : innerWidth - rect.width - 12;
    this.position.x = Math.max(12, Math.min(this.position.x, innerWidth - rect.width - 12));
    this.position.y = Math.max(16, Math.min(this.position.y, innerHeight - rect.height - 16));
    this.host.style.left = `${this.position.x}px`; this.host.style.top = `${this.position.y}px`;
  }
  private drag(event: PointerEvent) {
    if (event.button !== 0 || !this.position) return;
    event.preventDefault();
    const target = event.currentTarget as HTMLElement;
    target.setPointerCapture(event.pointerId);
    const start = { x: event.clientX, y: event.clientY, ...{ left: this.position.x, top: this.position.y } };
    this.snap = null;
    const move = (e: PointerEvent) => { this.position = { x: start.left + e.clientX - start.x, y: start.top + e.clientY - start.y }; this.clamp(); };
    const end = (e: PointerEvent) => {
      target.removeEventListener("pointermove", move); target.removeEventListener("pointerup", end); target.removeEventListener("pointercancel", end);
      if (target.hasPointerCapture(e.pointerId)) target.releasePointerCapture(e.pointerId);
      const rect = this.host.getBoundingClientRect();
      if (rect.left < 40) this.snap = "left"; else if (innerWidth - rect.right < 40) this.snap = "right";
      this.clamp();
    };
    target.addEventListener("pointermove", move); target.addEventListener("pointerup", end); target.addEventListener("pointercancel", end);
  }
}
