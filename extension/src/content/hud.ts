// Floating pill: shows draw-mode state and gives a mouse way to toggle it.
export class Hud {
  private host: HTMLDivElement;
  private pill: HTMLButtonElement;
  onToggle: () => void = () => {};
  onPage: () => void = () => {};
  constructor() {
    this.host = document.createElement("div");
    this.host.id = "halo-hud";
    const sh = this.host.attachShadow({ mode: "open" });
    sh.innerHTML = `<style>
      :host{all:initial}
      .wrap{position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:2147483647;display:flex;gap:8px;align-items:center;font:13px/1 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,sans-serif;pointer-events:auto}
      button{border:0;cursor:pointer;border-radius:999px;padding:10px 16px;font:inherit;font-weight:600;display:flex;align-items:center;gap:8px;box-shadow:0 8px 24px rgba(20,20,60,.22);transition:transform .15s,background .15s}
      button:hover{transform:translateY(-1px)}
      .pill{background:#1b1b2f;color:#fff}
      .pill.on{background:#ff5a36}
      .dot{width:10px;height:10px;border-radius:50%;border:2px solid currentColor}
      .page{background:#fff;color:#1b1b2f;padding:10px 12px;display:flex}
      .wrap.on .page{display:flex}
      kbd{font:11px ui-monospace,Menlo,monospace;background:rgba(255,255,255,.18);padding:2px 6px;border-radius:5px}
    </style>
    <div class="wrap"><button class="pill"><span class="dot"></span><span class="label">Crop section</span> <kbd>Alt+C</kbd></button><button class="page" title="Ask about the whole page">Whole page</button></div>`;
    this.pill = sh.querySelector(".pill")!;
    this.pill.addEventListener("click", () => this.onToggle());
    sh.querySelector(".page")!.addEventListener("click", () => this.onPage());
    document.documentElement.appendChild(this.host);
  }
  set(on: boolean) {
    this.pill.classList.toggle("on", on);
    this.host.shadowRoot!.querySelector(".wrap")!.classList.toggle("on", on);
    this.pill.querySelector(".label")!.textContent = on ? "Drag to crop · Esc to stop" : "Crop section";
  }
  destroy() { this.host.remove(); }
  hide(h: boolean) { this.host.style.display = h ? "none" : ""; }
}
