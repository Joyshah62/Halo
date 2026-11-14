export interface Surface { key: string; label: string }
const own = (el: Element) => !!el.closest('[id^="halo-"]');
/** Stable slide/page identifiers only; ordinary text edits do not create new surfaces. */
export function currentSurface(): Surface {
  const explicit = document.querySelector<HTMLElement>('[data-halo-surface][aria-current="true"], [data-halo-surface][aria-selected="true"]');
  if (explicit) return { key: `${location.pathname}:surface:${explicit.dataset.haloSurface}`, label: explicit.getAttribute("aria-label") || "Current slide" };
  const pdfPages = [...document.querySelectorAll<HTMLElement>("canvas[data-halo-page]")];
  if (pdfPages.length) {
    const target = pdfPages.reduce((best, page) => Math.abs(page.getBoundingClientRect().top - innerHeight * .25) < Math.abs(best.getBoundingClientRect().top - innerHeight * .25) ? page : best);
    return { key: `${location.pathname}${location.search}:pdf:${target.dataset.haloPage}`, label: `Page ${target.dataset.haloPage}` };
  }
  const match = location.hash.match(/(?:slide=id\.|slide=|page=|slideid=)([^&]+)/i);
  if (match) return { key: `${location.pathname}:${match[0]}`, label: /page=/i.test(match[0]) ? `Page ${match[1]}` : "Current slide" };
  for (const el of document.querySelectorAll<HTMLElement>('[aria-selected="true"], [aria-current="page"], [role="status"], [aria-live="polite"]')) {
    if (own(el)) continue;
    const text = `${el.getAttribute("aria-label") || ""} ${el.innerText || ""}`.trim();
    const slide = text.match(/\bslide\s+(\d+)(?:\s+(?:of|\/)\s*\d+)?\b/i);
    if (slide) return { key: `${location.pathname}:slide:${slide[1]}`, label: `Slide ${slide[1]}` };
  }
  // Office's slide count is sometimes plain text rather than an accessible status.
  if (/powerpoint|officeapps|office\.com|microsoft365/i.test(location.href)) {
    const slide = (document.body?.innerText || "").match(/\bslide\s+(\d+)\s+of\s+\d+\b/i);
    if (slide) return { key: `${location.pathname}:slide:${slide[1]}`, label: `Slide ${slide[1]}` };
  }
  return { key: location.href, label: "This page" };
}
export function watchSurface(onChange: (surface: Surface) => void) {
  let current = currentSurface();
  const check = () => { const next = currentSurface(); if (next.key !== current.key) { current = next; onChange(next); } };
  window.addEventListener("hashchange", check);
  window.addEventListener("popstate", check);
  // Catches editor slide switches that do not modify the URL, without observing Halo's rendering.
  const interval = setInterval(check, 700);
  return () => { clearInterval(interval); window.removeEventListener("hashchange", check); window.removeEventListener("popstate", check); };
}

/** Content bounds let a pin move with a slide canvas when an editor zooms or scrolls. */
export function surfaceContentBounds(): DOMRect | null {
  const explicit = document.querySelector<HTMLElement>('[data-halo-surface][aria-current="true"], [data-halo-surface][aria-selected="true"]');
  if (explicit) return explicit.getBoundingClientRect();
  const canvases = [...document.querySelectorAll<HTMLElement>('canvas[data-halo-page], canvas, [aria-label="Slide canvas"]')]
    .filter((element) => !own(element))
    .map((element) => element.getBoundingClientRect())
    .filter((rect) => rect.width > 200 && rect.height > 100 && rect.right > 0 && rect.left < innerWidth && rect.bottom > 0 && rect.top < innerHeight);
  return canvases.sort((a, b) => {
    const area = (r: DOMRect) => Math.max(0, Math.min(innerWidth, r.right) - Math.max(0, r.left)) * Math.max(0, Math.min(innerHeight, r.bottom) - Math.max(0, r.top));
    return area(b) - area(a);
  })[0] ?? null;
}
