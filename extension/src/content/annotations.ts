import { type Box, toBox } from "./overlay";
import { overlap, pageObstacles } from "./placement";
export interface Pin { id: number; box: Box; label: string; active: boolean; page: boolean; note?: string }
export class Annotations {
  private host = document.createElement("div");
  private root: ShadowRoot;
  private pulse: HTMLElement | null = null;
  private timer?: ReturnType<typeof setTimeout>;
  private signature = "";
  onSelect: (id: number) => void = () => {};
  constructor() {
    this.host.id = "halo-annotations";
    this.host.style.cssText = "position:absolute;left:0;top:0;width:0;height:0;z-index:2147483645;pointer-events:none";
    this.root = this.host.attachShadow({ mode: "open" });
    this.root.innerHTML = `<style>:host{all:initial}.pin{position:absolute;pointer-events:auto;background:#fffaf5;border:1.5px solid #e56b48;color:#a74125;border-radius:50%;width:28px;height:28px;font:600 12px -apple-system,sans-serif;cursor:pointer;box-shadow:0 2px 8px #0002}.pin[aria-pressed=true]{background:#e56b48;color:#fff}.pin:focus-visible{outline:3px solid #466454;outline-offset:3px}.outline,.pulse{position:absolute;box-sizing:border-box;border:1.5px dashed #e56b48;border-radius:5px;pointer-events:none}.outline{opacity:.45}.pulse{background:#ffc46626;border:2px solid #e56b48;transition:opacity .4s}.note{position:absolute;max-width:180px;padding:5px 8px;background:#fffaf5;color:#466454;border:1px solid #e7e8df;border-radius:6px;font:12px/1.4 Georgia,serif;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;pointer-events:none}@media(prefers-reduced-motion:reduce){.pulse{transition:none}}</style><div class="pins"></div>`;
    document.documentElement.appendChild(this.host);
  }
  render(pins: Pin[]) {
    const signature = JSON.stringify(pins) + `:${innerWidth}:${scrollX}:${scrollY}`;
    if (signature === this.signature) return;
    this.signature = signature;
    const container = this.root.querySelector(".pins")!; container.replaceChildren();
    const occupied = pageObstacles().map((b) => toBox(b.left + scrollX, b.top + scrollY, b.width, b.height));
    for (const pin of pins) {
      let x = pin.page ? scrollX + innerWidth - 48 : pin.box.right + 6;
      let y = pin.page ? scrollY + 200 + pins.filter((p) => p.page && p.id < pin.id).length * 34 : pin.box.top;
      x = Math.max(scrollX + 12, Math.min(x, scrollX + innerWidth - 40));
      // Stack nearby pins instead of putting their hit targets on top of each other.
      for (let i = 0; i < 40 && occupied.some((b) => overlap(toBox(x, y, 30, 30), b) > 0); i++) y += 34;
      const button = document.createElement("button"); button.className = "pin"; button.textContent = String(pin.id);
      button.style.left = `${x}px`; button.style.top = `${y}px`; button.setAttribute("aria-label", `Open conversation ${pin.id}: ${pin.label}`); button.setAttribute("aria-pressed", String(pin.active)); button.title = pin.label;
      button.addEventListener("click", () => this.onSelect(pin.id)); container.appendChild(button);
      occupied.push(toBox(x, y, 32, 32));
      if (pin.active && !pin.page) {
        const outline = document.createElement("div"); outline.className = "outline"; this.position(outline, pin.box); container.appendChild(outline);
        if (pin.note) {
          const noteBox = toBox(pin.box.left, pin.box.bottom + 8, 180, 30);
          const readable = (x: number, y: number) => document.elementsFromPoint(x - scrollX, y - scrollY)
            .some((element) => !element.closest('[id^="halo-"]') && (element.closest("canvas,img,video,svg,p,h1,h2,h3,li,table,[contenteditable='true']") || [...element.childNodes].some((node) => node.nodeType === Node.TEXT_NODE && node.textContent?.trim())));
          const clearOfText = !readable(noteBox.left + 4, noteBox.top + 4) && !readable(noteBox.right - 4, noteBox.top + 4) && !readable(noteBox.left + 90, noteBox.bottom - 4);
          if (clearOfText && noteBox.right < scrollX + innerWidth - 16 && noteBox.bottom < scrollY + innerHeight - 100 && !occupied.some((b) => overlap(noteBox, b) > 0)) {
            const note = document.createElement("div"); note.className = "note"; note.textContent = pin.note.slice(0, 45); this.position(note, noteBox); container.appendChild(note);
          }
        }
      }
    }
  }
  point(box: Box) {
    this.clearPoint();
    this.pulse = document.createElement("div"); this.pulse.className = "pulse"; this.position(this.pulse, box); this.root.appendChild(this.pulse);
    this.timer = setTimeout(() => { if (this.pulse) this.pulse.style.opacity = "0"; this.timer = setTimeout(() => this.clearPoint(), 450); }, 1800);
  }
  destroy() { this.clearPoint(); this.host.remove(); }
  clearPoint() { clearTimeout(this.timer); this.pulse?.remove(); this.pulse = null; }
  private position(el: HTMLElement, box: Box) { Object.assign(el.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px` }); }
}
