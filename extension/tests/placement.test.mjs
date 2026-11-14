import { test, after } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
const directory = await mkdtemp(join(tmpdir(), "halo-placement-"));
after(() => rm(directory, { recursive: true, force: true }));
async function module(name) {
  const target = join(directory, `${name}.mjs`);
  await build({ entryPoints: [fileURLToPath(new URL(`../src/content/${name}.ts`, import.meta.url))], outfile: target, bundle: true, platform: "node", format: "esm" });
  return import(pathToFileURL(target).href);
}
const { placeCard, overlap } = await module("placement");
const { currentSurface } = await module("surface");
const box = (left, top, width, height) => ({ left, top, width, height, right: left + width, bottom: top + height });
test("card stays clear of the selected content, toolbar, and slide rail", () => {
  const selection = box(350, 240, 420, 160);
  const obstacles = [box(0, 0, 1400, 150), box(0, 150, 220, 750), box(550, 840, 300, 60)];
  const card = placeCard(selection, 340, 440, obstacles, 1400, 900);
  assert.ok(card, "available space should be found");
  assert.equal(overlap(card, selection), 0);
  for (const obstacle of obstacles) assert.equal(overlap(card, obstacle), 0);
  assert.ok(card.left >= 16 && card.top >= 16 && card.right <= 1384 && card.bottom <= 884);
});
test("crowded pages and small viewports fall back to the panel", () => {
  assert.equal(placeCard(box(0, 0, 800, 600), 340, 440, [], 800, 600), null);
  assert.equal(placeCard(null, 340, 440, [], 300, 400), null);
  assert.equal(placeCard(null, 340, 440, [box(0, 0, 800, 600)], 800, 600), null);
});
function page({ url = "https://example.com/lecture", selected = null, status = [], pages = [], text = "" } = {}) {
  globalThis.location = new URL(url);
  globalThis.innerHeight = 800;
  globalThis.document = { querySelector: () => selected, querySelectorAll: selector => selector.includes("canvas") ? pages : status, body: { innerText: text } };
}
const element = (label) => ({ closest: () => null, getAttribute: () => label, innerText: "" });
test("Google Slides hashes identify the current slide and restore the same key", () => {
  page({ url: "https://docs.google.com/presentation/d/demo/edit#slide=id.first" }); const first = currentSurface().key;
  page({ url: "https://docs.google.com/presentation/d/demo/edit#slide=id.second" }); assert.notEqual(currentSurface().key, first);
  page({ url: "https://docs.google.com/presentation/d/demo/edit#slide=id.first" }); assert.equal(currentSurface().key, first);
});
test("PowerPoint uses its slide status even when the URL stays unchanged", () => {
  page({ status: [element("Slide 5 of 12")] }); assert.equal(currentSurface().label, "Slide 5"); const key = currentSurface().key;
  page({ status: [element("Slide 6 of 12")] }); assert.notEqual(currentSurface().key, key);
  page({ url: "https://powerpoint.office.com/edit", text: "Presentation · Slide 8 of 12" }); assert.equal(currentSurface().label, "Slide 8");
});
test("PDF annotations belong to the page at the reading position", () => {
  page({ pages: [ { dataset: { haloPage: "1" }, getBoundingClientRect: () => ({ top: -700 }) }, { dataset: { haloPage: "2" }, getBoundingClientRect: () => ({ top: 180 }) } ] });
  assert.equal(currentSurface().label, "Page 2");
});
