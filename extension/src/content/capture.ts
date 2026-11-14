import { sendRuntimeMessage } from "../shared/runtime";
import type { Box } from "./overlay";

const HALO_IDS = new Set(["halo-overlay", "halo-ink-root", "halo-bubble-host", "halo-hud", "halo-annotations"]);

function loadImage(src: string) {
  return new Promise<HTMLImageElement>((res, rej) => {
    const img = new Image();
    img.onload = () => res(img);
    img.onerror = rej;
    img.src = src;
  });
}

/** Screenshot the visible tab, crop to the box (viewport coords), and also return a
 *  downscaled whole-viewport image for context (canvas sites have no DOM text). */
export async function captureCrop(box: Box): Promise<{ image: string; imageMime: string; contextImage: string } | null> {
  const elements = [...HALO_IDS].map((id) => document.getElementById(id)).filter((e): e is HTMLElement => !!e);
  const previous = elements.map((e) => e.style.visibility);
  elements.forEach((e) => { e.style.visibility = "hidden"; });
  let resp;
  try {
    await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
    // The bubble may have been created while waiting for the next paint.
    document.getElementById("halo-bubble-host")?.style.setProperty("visibility", "hidden");
    resp = await sendRuntimeMessage({ type: "CAPTURE" });
  } finally {
    elements.forEach((e, i) => { e.style.visibility = previous[i]; });
  }
  if (!resp?.dataUrl) return null;
  const img = await loadImage(resp.dataUrl);
  const scale = img.naturalWidth / innerWidth; // handles devicePixelRatio
  const pad = 0;
  const sx = Math.max(0, (box.left - pad) * scale);
  const sy = Math.max(0, (box.top - pad) * scale);
  const sw = Math.min(img.naturalWidth - sx, (box.width + pad * 2) * scale);
  const sh = Math.min(img.naturalHeight - sy, (box.height + pad * 2) * scale);

  const crop = document.createElement("canvas");
  // keep crops readable but bounded
  const cs = Math.min(1, 1600 / Math.max(sw, sh));
  crop.width = Math.max(1, Math.round(sw * cs));
  crop.height = Math.max(1, Math.round(sh * cs));
  crop.getContext("2d")!.drawImage(img, sx, sy, sw, sh, 0, 0, crop.width, crop.height);

  const ctxC = document.createElement("canvas");
  const k = Math.min(1, 1400 / img.naturalWidth);
  ctxC.width = Math.round(img.naturalWidth * k);
  ctxC.height = Math.round(img.naturalHeight * k);
  ctxC.getContext("2d")!.drawImage(img, 0, 0, ctxC.width, ctxC.height);

  const strip = (u: string) => u.slice(u.indexOf(",") + 1);
  return {
    image: strip(crop.toDataURL("image/jpeg", 0.92)),
    imageMime: "image/jpeg",
    contextImage: strip(ctxC.toDataURL("image/jpeg", 0.7)),
  };
}

function isOurs(n: Node | null) {
  for (let e = n as HTMLElement | null; e; e = e.parentElement) if (e.id && HALO_IDS.has(e.id)) return true;
  return false;
}

/** Text of DOM nodes whose rects intersect the box (viewport coords). */
export function textInBox(box: Box, limit = 2000): string {
  const out: string[] = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (n.nodeValue && n.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT),
  });
  let total = 0;
  let node: Node | null;
  while ((node = walker.nextNode())) {
    if (isOurs(node)) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    const rects = range.getClientRects();
    let hit = false;
    for (const r of rects) {
      if (r.width === 0 || r.height === 0) continue;
      if (r.right > box.left && r.left < box.right && r.bottom > box.top && r.top < box.bottom) { hit = true; break; }
    }
    if (hit) {
      const t = node.nodeValue!.replace(/\s+/g, " ").trim();
      out.push(t);
      total += t.length;
      if (total > limit) break;
    }
  }
  return out.join(" ").slice(0, limit);
}

export function pageText(limit = 12000): string {
  const nodes: string[] = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let node: Node | null;
  while ((node = walker.nextNode())) {
    if (isOurs(node) || !node.nodeValue?.trim() || node.parentElement?.closest("script,style,noscript")) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    if (range.getClientRects().length) nodes.push(node.nodeValue.trim());
  }
  const t = nodes.join("\n").replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  if (t.length <= limit) return t;
  // keep head and tail so the circled part is likely included
  return t.slice(0, limit * 0.7) + "\n…\n" + t.slice(-limit * 0.3);
}
