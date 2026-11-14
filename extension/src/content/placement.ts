import { toBox, type Box } from "./overlay";
export function overlap(a: Box, b: Box) {
  return Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) * Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
}
export function pageObstacles(): Box[] {
  const elements = [...document.querySelectorAll<HTMLElement>('[role="toolbar"], [role="navigation"], [role="banner"], [role="complementary"], header, nav')]
    .filter((el) => !el.closest('[id^="halo-"]'));
  const hud = document.getElementById("halo-hud")?.shadowRoot?.querySelector<HTMLElement>(".wrap");
  if (hud) elements.push(hud);
  elements.push(...(document.getElementById("halo-annotations")?.shadowRoot?.querySelectorAll<HTMLElement>(".pin,.note") ?? []));
  return elements.map((el) => el.getBoundingClientRect())
    .filter((r) => r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight && r.width * r.height < innerWidth * innerHeight * .7)
    .map((r) => toBox(r.left - 8, r.top - 8, r.width + 16, r.height + 16));
}
/** Return a clear spot, or null so the caller can use the side panel. */
export function placeCard(anchor: Box | null, width: number, height: number, obstacles = pageObstacles(), vw = innerWidth, vh = innerHeight): Box | null {
  const gap = 16, maxX = vw - width - gap, maxY = vh - height - gap;
  if (maxX < gap || maxY < gap) return null;
  const candidates: Box[] = [];
  const add = (x: number, y: number) => candidates.push(toBox(Math.max(gap, Math.min(x, maxX)), Math.max(gap, Math.min(y, maxY)), width, height));
  if (anchor) { add(anchor.right + gap, anchor.top); add(anchor.left - width - gap, anchor.top); add(anchor.left, anchor.bottom + gap); add(anchor.left, anchor.top - height - gap); }
  for (let y = gap; y <= maxY; y += 32) for (const x of [maxX, gap, Math.round(maxX / 2)]) add(x, y);
  add(maxX, maxY); add(gap, maxY);
  return candidates.find((box) => (!anchor || overlap(box, anchor) === 0) && obstacles.every((obstacle) => overlap(box, obstacle) === 0)) ?? null;
}
