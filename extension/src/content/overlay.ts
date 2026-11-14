// Transparent drawing canvas over the page. Only intercepts the mouse while
// drawing mode is on; otherwise clicks pass through to the page.
export interface Pt { x: number; y: number }
export interface Box { left: number; top: number; width: number; height: number; right: number; bottom: number }

export const CIRCLE_COLOR = "#ff5a36";

export function toBox(l: number, t: number, w: number, h: number): Box {
  return { left: l, top: t, width: w, height: h, right: l + w, bottom: t + h };
}
export function bboxOf(pts: Pt[], pad = 0): Box {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const p of pts) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y); }
  return toBox(x0 - pad, y0 - pad, x1 - x0 + pad * 2, y1 - y0 + pad * 2);
}

export interface Circle { points: Pt[]; box: Box } // viewport coordinates

export class Overlay {
  private lifetime = new AbortController();
  private canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private pts: Pt[] = [];
  private down = false;
  private _drawing = false;
  onCircle: (c: Circle) => void = () => {};
  onModeChange: (on: boolean) => void = () => {};

  constructor() {
    this.canvas = document.createElement("canvas");
    this.canvas.id = "halo-overlay";
    Object.assign(this.canvas.style, {
      position: "fixed", inset: "0", width: "100vw", height: "100vh",
      zIndex: "2147483646", pointerEvents: "none", cursor: "crosshair",
    } as CSSStyleDeclaration);
    document.documentElement.appendChild(this.canvas);
    this.ctx = this.canvas.getContext("2d")!;
    this.resize();
    window.addEventListener("resize", () => this.resize(), { signal: this.lifetime.signal });

    this.canvas.addEventListener("pointerdown", (e) => {
      if (!this._drawing || e.button !== 0) return;
      e.preventDefault();
      this.down = true;
      this.pts = [{ x: e.clientX, y: e.clientY }];
      this.canvas.setPointerCapture(e.pointerId);
    });
    this.canvas.addEventListener("pointermove", (e) => {
      if (!this.down) return;
      const p = { x: e.clientX, y: e.clientY };
      const last = this.pts[this.pts.length - 1];
      if (Math.hypot(p.x - last.x, p.y - last.y) < 2) return;
      this.pts.push(p);
      this.render();
    });
    const up = (e: PointerEvent) => {
      if (!this.down) return;
      this.down = false;
      this.pts.push({ x: e.clientX, y: e.clientY });
      this.finishStroke();
    };
    this.canvas.addEventListener("pointerup", up);
    this.canvas.addEventListener("pointercancel", () => { this.down = false; this.pts = []; this.clear(); });
  }

  destroy() { this.lifetime.abort(); this.canvas.remove(); }

  get drawing() { return this._drawing; }

  setDrawing(on: boolean) {
    if (this._drawing === on) return;
    this._drawing = on;
    this.canvas.style.pointerEvents = on ? "auto" : "none";
    if (!on) { this.down = false; this.pts = []; this.clear(); }
    this.onModeChange(on);
  }
  toggle() { this.setDrawing(!this._drawing); }

  clear() { this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height); }

  private resize() {
    const dpr = devicePixelRatio || 1;
    this.canvas.width = innerWidth * dpr;
    this.canvas.height = innerHeight * dpr;
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.render();
  }

  private render() {
    this.clear();
    if (this.pts.length < 2) return;
    const c = this.ctx;
    c.save();
    const a = this.pts[0], b = this.pts[this.pts.length - 1];
    const box = toBox(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y));
    c.fillStyle = "rgba(255,90,54,.10)";
    c.fillRect(box.left, box.top, box.width, box.height);
    c.strokeStyle = CIRCLE_COLOR; c.lineWidth = 2;
    c.setLineDash([6, 4]);
    c.strokeRect(box.left, box.top, box.width, box.height);
    c.restore();
  }

  private finishStroke() {
    const a = this.pts[0], b = this.pts[this.pts.length - 1];
    const box = toBox(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y));
    if (box.width < 12 || box.height < 12) { this.pts = []; this.clear(); return; }
    this.onCircle({ points: [a, { x: b.x, y: a.y }, b, { x: a.x, y: b.y }, a], box });
    this.pts = [];
  }
}

export function isClosed(pts: Pt[], box: Box) {
  const a = pts[0], b = pts[pts.length - 1];
  const diag = Math.hypot(box.width, box.height);
  return Math.hypot(a.x - b.x, a.y - b.y) < Math.max(48, diag * 0.45);
}

export function drawSmooth(c: CanvasRenderingContext2D, pts: Pt[]) {
  c.moveTo(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length - 1; i++) {
    const mx = (pts[i].x + pts[i + 1].x) / 2, my = (pts[i].y + pts[i + 1].y) / 2;
    c.quadraticCurveTo(pts[i].x, pts[i].y, mx, my);
  }
  const l = pts[pts.length - 1];
  c.lineTo(l.x, l.y);
}

/** SVG path data for a smoothed polyline. */
export function smoothPathD(pts: Pt[]): string {
  if (pts.length < 2) return "";
  let d = `M${pts[0].x.toFixed(1)} ${pts[0].y.toFixed(1)}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const mx = (pts[i].x + pts[i + 1].x) / 2, my = (pts[i].y + pts[i + 1].y) / 2;
    d += ` Q${pts[i].x.toFixed(1)} ${pts[i].y.toFixed(1)} ${mx.toFixed(1)} ${my.toFixed(1)}`;
  }
  const l = pts[pts.length - 1];
  d += ` L${l.x.toFixed(1)} ${l.y.toFixed(1)}`;
  return d;
}
