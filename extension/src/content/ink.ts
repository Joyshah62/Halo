// Animated "teacher ink": handwriting (font outlines drawn stroke by stroke, then filled),
// arrows, underlines, boxes, checks. Lives in an SVG anchored to page coordinates so it
// scrolls with the page.
import opentype from "opentype.js";
import type { InkItem } from "../shared/types";
import { type Box, type Pt, toBox, smoothPathD, CIRCLE_COLOR } from "./overlay";

export const INK = "#3730d6";
const GREEN = "#15803d", RED = "#dc2626";
const FONT_SIZE = 24, LINE_H = 33;
const NS = "http://www.w3.org/2000/svg";

interface Line { x: number; baseline: number; width: number; text: string }
export interface AnswerCtx {
  group: SVGGElement;
  anchor: Box;            // page coords of the circled region
  side: "right" | "left" | "below";
  x: number; colWidth: number;
  nextBaseline: number;
  lines: Line[];
  text: string[];
  mode: "answer" | "hint";
}
export interface Answer { box: Box; text: string; id?: number }

const el = <K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number> = {}) => {
  const e = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
  return e;
};
const jit = (n: number) => (Math.random() - 0.5) * n;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function animateDraw(path: SVGPathElement, duration: number, delay = 0): Promise<void> {
  const L = path.getTotalLength() || 1;
  path.style.strokeDasharray = `${L}`;
  path.style.strokeDashoffset = `${L}`;
  const a = path.animate([{ strokeDashoffset: L }, { strokeDashoffset: 0 }], { duration: Math.max(60, duration), delay, fill: "forwards", easing: "ease-out" });
  return a.finished.then(() => { path.style.strokeDasharray = ""; path.style.strokeDashoffset = ""; });
}

export class Ink {
  private root: HTMLDivElement;
  private svg: SVGSVGElement;
  private font: opentype.Font | null = null;
  ready: Promise<void>;
  answers: Answer[] = [];
  private thinking: SVGGElement | null = null;

  constructor() {
    this.root = document.createElement("div");
    this.root.id = "halo-ink-root";
    Object.assign(this.root.style, { position: "absolute", left: "0", top: "0", width: "0", height: "0", overflow: "visible", zIndex: "2147483645", pointerEvents: "none" });
    this.svg = el("svg", { width: 1, height: 1 });
    this.svg.style.cssText = "position:absolute;left:0;top:0;overflow:visible;width:1px;height:1px;";
    this.root.appendChild(this.svg);
    document.documentElement.appendChild(this.root);
    this.ready = fetch(chrome.runtime.getURL("fonts/Caveat.ttf"))
      .then((r) => r.arrayBuffer())
      .then((buf) => { this.font = opentype.parse(buf); })
      .catch((e) => console.warn("[halo] font failed, falling back to system font", e));
  }

  drawSelection(box: Box) {
    const rect = el("rect", { x: box.left, y: box.top, width: box.width, height: box.height,
      fill: "none", stroke: CIRCLE_COLOR, "stroke-width": 2, "stroke-dasharray": "6 4", rx: 3 });
    this.svg.appendChild(rect);
  }

  // ---------- user circle ----------
  drawUserCircle(ptsPage: Pt[]) {
    const p = el("path", { d: smoothPathD(ptsPage), fill: "none", stroke: CIRCLE_COLOR, "stroke-width": 3.5, "stroke-linecap": "round", "stroke-linejoin": "round", opacity: 0.95 }) as SVGPathElement;
    p.style.filter = "drop-shadow(0 0 4px rgba(255,90,54,.35))";
    this.svg.appendChild(p);
    return p;
  }

  // ---------- layout ----------
  /** Which side of the circle the answer column goes on (page-coords anchor). */
  static chooseSide(anchor: Box): "right" | "left" | "below" {
    const vw = innerWidth, vLeft = anchor.left - scrollX, vRight = anchor.right - scrollX;
    if (vw - vRight >= 280) return "right";
    if (vLeft >= 280) return "left";
    return "below";
  }
  startAnswer(anchor: Box, mode: "answer" | "hint"): AnswerCtx {
    const sx = scrollX, vw = innerWidth;
    const vLeft = anchor.left - sx, vRight = anchor.right - sx;
    const group = el("g") as SVGGElement;
    this.svg.appendChild(group);
    const base = { group, anchor, lines: [], text: [], mode } as Partial<AnswerCtx>;
    const side = Ink.chooseSide(anchor);
    const GAP = 48; // room for the arrow between circle and writing
    if (side === "right") {
      const colWidth = Math.min(340, vw - vRight - GAP - 16);
      return { ...base, side, x: anchor.right + GAP, colWidth, nextBaseline: anchor.top + FONT_SIZE } as AnswerCtx;
    }
    if (side === "left") {
      const colWidth = Math.min(340, vLeft - GAP - 16);
      return { ...base, side, x: anchor.left - GAP - colWidth, colWidth, nextBaseline: anchor.top + FONT_SIZE } as AnswerCtx;
    }
    const colWidth = Math.min(460, vw - 48);
    const x = Math.min(anchor.left, sx + vw - colWidth - 24);
    return { ...base, side, x, colWidth, nextBaseline: anchor.bottom + 30 + FONT_SIZE } as AnswerCtx;
  }

  private penStart(ctx: AnswerCtx): Pt {
    // where the next stroke of writing begins
    if (ctx.side === "left") return { x: ctx.x + ctx.colWidth + 6, y: ctx.nextBaseline - FONT_SIZE * 0.35 };
    return { x: ctx.x - 8, y: ctx.nextBaseline - FONT_SIZE * 0.35 };
  }

  // ---------- thinking mark ----------
  showThinking(ctx: AnswerCtx) {
    this.hideThinking();
    const p = this.penStart(ctx);
    const g = el("g") as SVGGElement;
    const c = el("circle", { cx: p.x + 14, cy: p.y, r: 6, fill: INK, opacity: 0.8 });
    const ring = el("circle", { cx: p.x + 14, cy: p.y, r: 6, fill: "none", stroke: INK, "stroke-width": 2, opacity: 0.6 });
    g.append(ring, c);
    ctx.group.appendChild(g);
    c.animate([{ r: 5 }, { r: 7 }, { r: 5 }], { duration: 900, iterations: Infinity });
    ring.animate([{ r: 6, opacity: 0.6 }, { r: 20, opacity: 0 }], { duration: 1100, iterations: Infinity });
    this.thinking = g;
  }
  hideThinking() { this.thinking?.remove(); this.thinking = null; }

  // ---------- step drawing ----------
  /** Draw a step's ink within roughly `budgetMs` (paced to the audio). */
  async drawStep(ctx: AnswerCtx, items: InkItem[], budgetMs: number, signal?: AbortSignal) {
    this.hideThinking();
    if (!items.length) return;
    const cost = (i: InkItem) => i.type === "text" ? Math.max(6, i.value.length) : i.type === "arrow" ? 10 : i.type === "box" ? 8 : i.type === "sketch" ? 30 : i.type === "image" ? 12 : 5;
    const total = items.reduce((s, i) => s + cost(i), 0);
    // A teacher points first, then writes: arrows to the circled thing go before this step's text.
    items = [...items.filter((i) => i.type === "arrow" && i.to === "circled"), ...items.filter((i) => !(i.type === "arrow" && i.to === "circled"))];
    for (const item of items) {
      if (signal?.aborted) return;
      const share = (budgetMs * 0.85 * cost(item)) / total;
      switch (item.type) {
        case "text": await this.drawText(ctx, item.value, share); break;
        case "arrow": await this.drawArrow(ctx, item.to, Math.min(share, 700)); break;
        case "underline": await this.drawUnderline(ctx, Math.min(share, 500)); break;
        case "box": await this.drawBox(ctx, Math.min(share, 600)); break;
        case "check": await this.drawMark(ctx, "check", 350); break;
        case "cross": await this.drawMark(ctx, "cross", 350); break;
        case "sketch": await this.drawSketch(ctx, item, share); break;
        case "image": await this.drawImage(ctx, item); break;
      }
      await sleep(60);
    }
  }

  private advance(ch: string) {
    if (this.font) {
      const gi = this.font.charToGlyphIndex(ch);
      if (gi > 0) return this.font.getAdvanceWidth(ch, FONT_SIZE);
    }
    return FONT_SIZE * (ch === " " ? 0.3 : 0.58);
  }
  private measure(s: string) { let w = 0; for (const ch of s) w += this.advance(ch); return w; }

  private wrap(text: string, width: number): string[] {
    const words = text.split(/\s+/).filter(Boolean);
    const lines: string[] = []; let cur = "";
    for (const w of words) {
      const t = cur ? cur + " " + w : w;
      if (this.measure(t) <= width || !cur) cur = t; else { lines.push(cur); cur = w; }
    }
    if (cur) lines.push(cur);
    return lines;
  }

  private async drawText(ctx: AnswerCtx, text: string, budget: number) {
    await this.ready;
    const lines = this.wrap(text, ctx.colWidth);
    const nGlyphs = Math.max(1, text.replace(/\s/g, "").length);
    const per = Math.min(95, Math.max(28, budget / nGlyphs));
    const color = ctx.mode === "hint" ? "#b45309" : INK;
    for (const ln of lines) {
      const width = this.measure(ln);
      const baseline = ctx.nextBaseline;
      const x = ctx.side === "left" ? ctx.x + ctx.colWidth - width : ctx.x;
      // soft paper behind the line so ink reads over busy pages
      const bg = el("rect", { x: x - 6, y: baseline - FONT_SIZE * 0.85, width: width + 12, height: LINE_H, rx: 7, fill: "rgba(255,255,255,0.82)", opacity: 0 });
      ctx.group.appendChild(bg);
      bg.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220, fill: "forwards" });
      const g = el("g", { fill: color, stroke: color, "stroke-width": 1.1, "stroke-linejoin": "round" }) as SVGGElement;
      ctx.group.appendChild(g);
      let cx = x;
      const anims: Promise<unknown>[] = [];
      let k = 0;
      for (const ch of ln) {
        const adv = this.advance(ch);
        if (ch !== " ") {
          const gi = this.font ? this.font.charToGlyphIndex(ch) : 0;
          if (this.font && gi > 0) {
            const d = this.font.getPath(ch, cx + jit(0.6), baseline + jit(0.8), FONT_SIZE).toPathData(2);
            const p = el("path", { d, "fill-opacity": 0 }) as SVGPathElement;
            g.appendChild(p);
            const delay = k * per;
            anims.push(animateDraw(p, per * 1.8, delay).then(() => p.animate([{ fillOpacity: 0 }, { fillOpacity: 1 }], { duration: 160, fill: "forwards" }).finished));
          } else {
            const t = el("text", { x: cx, y: baseline, "font-size": FONT_SIZE, "font-family": "Caveat, 'Segoe UI Symbol', 'Apple Symbols', serif", stroke: "none", opacity: 0 });
            t.textContent = ch;
            g.appendChild(t);
            t.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200, delay: k * per, fill: "forwards" });
          }
          k++;
        }
        cx += adv;
      }
      ctx.lines.push({ x, baseline, width, text: ln });
      ctx.nextBaseline += LINE_H;
      await Promise.all(anims);
    }
    ctx.text.push(text);
  }

  private async drawArrow(ctx: AnswerCtx, to: "circled" | "previous", budget: number) {
    const from = this.penStart(ctx);
    let target: Pt;
    if (to === "previous") {
      const prev = ctx.lines[ctx.lines.length - 1];
      if (!prev) return;
      target = { x: prev.x - 6, y: prev.baseline - FONT_SIZE * 0.3 };
      from.x = ctx.side === "left" ? prev.x + prev.width + 24 : prev.x - 26;
      from.y = ctx.nextBaseline - 4;
    } else {
      target = nearestEdgePoint(ctx.anchor, from, 8);
    }
    const dx = target.x - from.x, dy = target.y - from.y, len = Math.hypot(dx, dy) || 1;
    // slight curve for a hand-drawn feel
    const nx = -dy / len, ny = dx / len, bend = Math.min(40, len * 0.18) * (Math.random() < 0.5 ? 1 : -1);
    const cx = (from.x + target.x) / 2 + nx * bend, cy = (from.y + target.y) / 2 + ny * bend;
    const color = ctx.mode === "hint" ? "#b45309" : INK;
    const shaft = el("path", { d: `M${from.x} ${from.y} Q${cx} ${cy} ${target.x} ${target.y}`, fill: "none", stroke: color, "stroke-width": 2.4, "stroke-linecap": "round" }) as SVGPathElement;
    ctx.group.appendChild(shaft);
    await animateDraw(shaft, budget * 0.75);
    // arrowhead along the tangent at the end
    const tx = target.x - cx, ty = target.y - cy, tl = Math.hypot(tx, ty) || 1;
    const ux = tx / tl, uy = ty / tl, s = 14;
    const h1 = { x: target.x - ux * s - uy * s * 0.6, y: target.y - uy * s + ux * s * 0.6 };
    const h2 = { x: target.x - ux * s + uy * s * 0.6, y: target.y - uy * s - ux * s * 0.6 };
    const head = el("path", { d: `M${h1.x} ${h1.y} L${target.x} ${target.y} L${h2.x} ${h2.y}`, fill: "none", stroke: color, "stroke-width": 2.4, "stroke-linecap": "round", "stroke-linejoin": "round" }) as SVGPathElement;
    ctx.group.appendChild(head);
    await animateDraw(head, budget * 0.25);
  }

  private async drawUnderline(ctx: AnswerCtx, budget: number) {
    const prev = ctx.lines[ctx.lines.length - 1]; if (!prev) return;
    const y = prev.baseline + 6; let d = `M${prev.x - 2} ${y}`;
    for (let x = prev.x + 7; x <= prev.x + prev.width + 4; x += 7) d += ` Q${x - 3.5} ${y + (((x / 7) | 0) % 2 ? 3 : -3)} ${x} ${y}`;
    const p = el("path", { d, fill: "none", stroke: ctx.mode === "hint" ? "#b45309" : INK, "stroke-width": 2, "stroke-linecap": "round" }) as SVGPathElement;
    ctx.group.appendChild(p);
    await animateDraw(p, budget);
  }

  private async drawBox(ctx: AnswerCtx, budget: number) {
    const prev = ctx.lines[ctx.lines.length - 1]; if (!prev) return;
    const x0 = prev.x - 9, y0 = prev.baseline - FONT_SIZE * 0.95, x1 = prev.x + prev.width + 9, y1 = prev.baseline + 9;
    const d = `M${x0 + jit(2)} ${y0 + jit(2)} L${x1 + jit(2)} ${y0 + jit(2)} L${x1 + jit(2)} ${y1 + jit(2)} L${x0 + jit(2)} ${y1 + jit(2)} L${x0 + jit(2)} ${y0 - 3}`;
    const p = el("path", { d, fill: "none", stroke: ctx.mode === "hint" ? "#b45309" : INK, "stroke-width": 2.2, "stroke-linejoin": "round", "stroke-linecap": "round" }) as SVGPathElement;
    ctx.group.appendChild(p);
    await animateDraw(p, budget);
  }

  private async drawMark(ctx: AnswerCtx, kind: "check" | "cross", budget: number) {
    const prev = ctx.lines[ctx.lines.length - 1];
    const x = prev ? (ctx.side === "left" ? prev.x - 30 : prev.x + prev.width + 14) : ctx.x;
    const y = prev ? prev.baseline - 4 : ctx.nextBaseline;
    const color = kind === "check" ? GREEN : RED;
    const d = kind === "check" ? `M${x} ${y - 8} L${x + 7} ${y} L${x + 20} ${y - 18}` : `M${x} ${y - 18} L${x + 16} ${y} M${x + 16} ${y - 18} L${x} ${y}`;
    const p = el("path", { d, fill: "none", stroke: color, "stroke-width": 3, "stroke-linecap": "round", "stroke-linejoin": "round" }) as SVGPathElement;
    ctx.group.appendChild(p);
    await animateDraw(p, budget);
  }

  // ---------- diagrams ----------
  /** A hand-drawn diagram the model described as SVG paths in a w×h box; scaled to the column. */
  private async drawSketch(ctx: AnswerCtx, item: Extract<InkItem, { type: "sketch" }>, budget: number) {
    await this.ready;
    if (!item.paths.length && !item.labels.length) return;
    const scale = Math.min(1.4, ctx.colWidth / item.w);
    const top = ctx.nextBaseline - FONT_SIZE + 6;
    const color = ctx.mode === "hint" ? "#b45309" : INK;
    const g = el("g", { fill: "none", stroke: color, "stroke-width": 2.2 / scale, "stroke-linecap": "round", "stroke-linejoin": "round" }) as SVGGElement;
    const paths: SVGPathElement[] = [];
    for (const d of item.paths) {
      const p = el("path", { d }) as SVGPathElement;
      g.appendChild(p); paths.push(p);
    }
    // labels as handwriting glyphs (the page may not have the Caveat web font)
    const labelSize = 21 / scale;
    for (const l of item.labels) {
      const lg = el("g", { fill: color, stroke: "none", opacity: 0 }) as SVGGElement;
      let cx = l.x;
      for (const ch of l.text) {
        const gi = this.font ? this.font.charToGlyphIndex(ch) : 0;
        if (this.font && gi > 0 && ch !== " ") {
          lg.appendChild(el("path", { d: this.font.getPath(ch, cx, l.y, labelSize).toPathData(2) }));
          cx += this.font.getAdvanceWidth(ch, labelSize);
        } else if (ch !== " ") {
          const t = el("text", { x: cx, y: l.y, "font-size": labelSize, "font-family": "Caveat, cursive" }); t.textContent = ch; lg.appendChild(t);
          cx += labelSize * 0.55;
        } else cx += labelSize * 0.3;
      }
      g.appendChild(lg);
    }
    // measure the real drawing, then place it and size the paper behind it
    ctx.group.appendChild(g);
    let bb: DOMRect;
    try { bb = g.getBBox(); } catch { bb = new DOMRect(0, 0, item.w, item.h); }
    if (!(bb.width > 0)) bb = new DOMRect(0, 0, item.w, item.h);
    const W = bb.width * scale, H = bb.height * scale;
    const x0 = ctx.side === "left" ? ctx.x + ctx.colWidth - W : ctx.x;
    g.setAttribute("transform", `translate(${x0 - bb.x * scale} ${top - bb.y * scale}) scale(${scale})`);
    const bg = el("rect", { x: x0 - 10, y: top - 8, width: W + 20, height: H + 16, rx: 10, fill: "rgba(255,255,255,0.85)", opacity: 0 });
    ctx.group.insertBefore(bg, g);
    bg.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 250, fill: "forwards" });
    // hide everything, then draw path by path, then fade labels in
    for (const p of paths) { const L = p.getTotalLength() || 1; p.style.strokeDasharray = `${L}`; p.style.strokeDashoffset = `${L}`; }
    const per = (budget * 0.8) / Math.max(1, paths.length + item.labels.length * 0.5);
    for (const p of paths) { try { await animateDraw(p, Math.min(1400, per)); } catch { p.remove(); } }
    for (const lg of Array.from(g.children).filter((c) => c.tagName === "g")) {
      await (lg as SVGGElement).animate([{ opacity: 0 }, { opacity: 1 }], { duration: Math.min(300, per / 2), fill: "forwards" }).finished;
    }
    this.registerBlock(ctx, x0, top, W, H);
  }

  /** A generated illustration for genuinely complex things; fades in with a sketchy frame. */
  private async drawImage(ctx: AnswerCtx, item: Extract<InkItem, { type: "image" }>) {
    if (!item.data) return;
    const { src, ratio } = await trimWhitespace(`data:${item.mime || "image/png"};base64,${item.data}`);
    const W = Math.min(ctx.colWidth, 320), H = Math.round(W * ratio);
    const top = ctx.nextBaseline - FONT_SIZE + 6;
    const x0 = ctx.side === "left" ? ctx.x + ctx.colWidth - W : ctx.x;
    const img = el("image", { x: x0, y: top, width: W, height: H, href: src, opacity: 0, preserveAspectRatio: "xMidYMid meet" });
    img.style.filter = "drop-shadow(0 4px 10px rgba(20,20,60,.15))";
    ctx.group.appendChild(img);
    const frame = el("path", { d: `M${x0 + jit(2)} ${top + jit(2)} L${x0 + W + jit(2)} ${top + jit(2)} L${x0 + W + jit(2)} ${top + H + jit(2)} L${x0 + jit(2)} ${top + H + jit(2)} Z`, fill: "none", stroke: INK, "stroke-width": 2, "stroke-linejoin": "round" }) as SVGPathElement;
    ctx.group.appendChild(frame);
    await Promise.all([animateDraw(frame, 700), img.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 600, delay: 200, fill: "forwards" }).finished]);
    this.registerBlock(ctx, x0, top, W, H);
  }

  /** Reserve vertical space for a non-text block so later lines go underneath. */
  private registerBlock(ctx: AnswerCtx, x: number, top: number, w: number, h: number) {
    ctx.lines.push({ x, baseline: top + h, width: w, text: "" });
    ctx.nextBaseline = top + h + 14 + FONT_SIZE;
  }

  // ---------- follow-ups ----------
  finishAnswer(ctx: AnswerCtx, id?: number) {
    if (!ctx.lines.length) return;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const l of ctx.lines) { x0 = Math.min(x0, l.x); y0 = Math.min(y0, l.baseline - FONT_SIZE); x1 = Math.max(x1, l.x + l.width); y1 = Math.max(y1, l.baseline + 8); }
    this.answers.push({ box: toBox(x0, y0, x1 - x0, y1 - y0), text: ctx.text.join(" "), id });
  }
  /** Did the student circle one of Halo's own answers? */
  hitAnswer(boxPage: Box): Answer | null {
    const cx = boxPage.left + boxPage.width / 2, cy = boxPage.top + boxPage.height / 2;
    for (let i = this.answers.length - 1; i >= 0; i--) {
      const a = this.answers[i].box;
      const ix = Math.max(0, Math.min(a.right, boxPage.right) - Math.max(a.left, boxPage.left));
      const iy = Math.max(0, Math.min(a.bottom, boxPage.bottom) - Math.max(a.top, boxPage.top));
      const inter = ix * iy, area = boxPage.width * boxPage.height;
      if ((cx > a.left && cx < a.right && cy > a.top && cy < a.bottom) || inter > area * 0.3) return this.answers[i];
    }
    return null;
  }

  clearAll() {
    this.svg.replaceChildren();
    this.answers = [];
    this.thinking = null;
  }
}

/** Crop the near-white margin generated images tend to have; returns a JPEG data URL and its h/w ratio. */
async function trimWhitespace(src: string): Promise<{ src: string; ratio: number }> {
  const im = await new Promise<HTMLImageElement | null>((res) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => res(null); i.src = src; });
  if (!im) return { src, ratio: 1 };
  try {
    const c = document.createElement("canvas"); c.width = im.naturalWidth; c.height = im.naturalHeight;
    const g = c.getContext("2d")!; g.drawImage(im, 0, 0);
    const { data, width, height } = g.getImageData(0, 0, c.width, c.height);
    let x0 = width, y0 = height, x1 = 0, y1 = 0;
    for (let y = 0; y < height; y += 2) for (let x = 0; x < width; x += 2) {
      const i = (y * width + x) * 4;
      if (data[i] < 225 || data[i + 1] < 225 || data[i + 2] < 225) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    }
    if (x1 <= x0 || y1 <= y0) return { src, ratio: height / width };
    const pad = Math.round(Math.min(width, height) * 0.04);
    x0 = Math.max(0, x0 - pad); y0 = Math.max(0, y0 - pad); x1 = Math.min(width, x1 + pad); y1 = Math.min(height, y1 + pad);
    const out = document.createElement("canvas"); const scale = Math.min(1, 900 / (x1 - x0));
    out.width = Math.round((x1 - x0) * scale); out.height = Math.round((y1 - y0) * scale);
    out.getContext("2d")!.drawImage(c, x0, y0, x1 - x0, y1 - y0, 0, 0, out.width, out.height);
    return { src: out.toDataURL("image/jpeg", 0.9), ratio: out.height / out.width };
  } catch { return { src, ratio: im.naturalHeight / im.naturalWidth || 1 }; }
}

function nearestEdgePoint(b: Box, from: Pt, gap: number): Pt {
  const cx = Math.max(b.left, Math.min(b.right, from.x));
  const cy = Math.max(b.top, Math.min(b.bottom, from.y));
  // push slightly outward from the box toward `from`
  const mx = (b.left + b.right) / 2, my = (b.top + b.bottom) / 2;
  const dx = from.x - mx, dy = from.y - my, l = Math.hypot(dx, dy) || 1;
  return { x: cx + (dx / l) * gap, y: cy + (dy / l) * gap };
}
