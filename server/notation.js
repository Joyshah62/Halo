// Formulas and code, typeset properly instead of handwritten.
//
// Halo writes in Caveat, which is lovely for "outside′ × inside′" and useless for a fraction over a fraction, a
// matrix or ten lines of Python. So the model can put two more kinds of ink in a step:
//   {"type":"math","tex":"\\frac{d}{dx}(x^2+1)^3 = 3(x^2+1)^2 \\cdot 2x"}
//   {"type":"code","lang":"python","value":"for row in rows:\n    print(row)"}
// Here each becomes a crisp PNG in Halo's ink colour (math: MathJax → SVG → resvg; code: monospaced SVG with a
// little colour → resvg) and is sent as an ordinary "image" ink item, with its natural width in `w`, so every
// client that can show a picture shows it at the right size. If something can't be typeset, the item falls back
// to a plain text line, so a step is never lost.
import { mathjax } from "mathjax-full/js/mathjax.js";
import { TeX } from "mathjax-full/js/input/tex.js";
import { SVG } from "mathjax-full/js/output/svg.js";
import { liteAdaptor } from "mathjax-full/js/adaptors/liteAdaptor.js";
import { RegisterHTMLHandler } from "mathjax-full/js/handlers/html.js";
import { AllPackages } from "mathjax-full/js/input/tex/AllPackages.js";
import { Resvg } from "@resvg/resvg-js";

const INK = "#3830D6";          // HaloStyle.ink
const SCALE = 3;                // pixels per layout point: sharp on a Retina iPad at full column width
const EX = 10;                 // layout points per MathJax ex: about the x-height of the 27 pt handwriting beside it
const MAX_WIDTH = 400;          // the note column (InkLayout.width); wider things are scaled down to fit

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const document = mathjax.document("", {
  InputJax: new TeX({ packages: AllPackages.filter((p) => !["require", "autoload"].includes(p)), formatError: (_jax, error) => { throw error; } }),
  OutputJax: new SVG({ fontCache: "none" }),
});

function png(svg, width) {
  const rendered = new Resvg(svg, { fitTo: { mode: "width", value: Math.round(width * SCALE) }, background: "rgba(0,0,0,0)", font: { loadSystemFonts: true, defaultFontFamily: "Menlo" } }).render();
  return rendered.asPng().toString("base64");
}

/** LaTeX → { mime, data, w, h } (w, h in layout points), or null if it doesn't typeset. */
export function renderMath(tex) {
  const source = String(tex ?? "").trim().replace(/^\$+|\$+$/g, "").replace(/^\\\[|\\\]$/g, "").trim().slice(0, 600);
  if (!source) return null;
  try {
    const node = document.convert(source, { display: true });
    let svg = adaptor.innerHTML(node);
    const ex = (name) => Number(svg.match(new RegExp(`${name}="([\\d.]+)ex"`))?.[1]);
    let w = ex("width") * EX, h = ex("height") * EX;
    if (!(w > 0 && h > 0)) return null;
    if (w > MAX_WIDTH) { h *= MAX_WIDTH / w; w = MAX_WIDTH; }
    svg = svg.replace(/currentColor/g, INK)
      .replace(/width="[\d.]+ex"/, `width="${w.toFixed(1)}"`).replace(/height="[\d.]+ex"/, `height="${h.toFixed(1)}"`);
    return { mime: "image/png", data: png(svg, w), w: Math.round(w), h: Math.round(h) };
  } catch {
    return null;
  }
}

// ---------- code ----------
const KEYWORDS = new Set(`and as assert async await break case catch class const continue def default del do elif else enum except export
extends false finally fn for from func function global if impl import in interface is lambda let match mut new nil none not null
of or package pass private protected public raise return self static struct super switch this throw throws true try type typeof
var void while with yield True False None SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER HAVING INSERT INTO VALUES
UPDATE SET DELETE CREATE TABLE PRIMARY KEY FOREIGN REFERENCES NOT NULL AND OR AS DISTINCT LIMIT int float double char bool string
boolean long short unsigned print`.split(/\s+/));
const COLORS = { plain: "#1C1C2E", keyword: "#3830D6", string: "#B5520A", number: "#C2410C", comment: "#8A8AA0" };
const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** One line → [[kind, text]]. Small and forgiving: comments, strings, numbers and keywords across common languages. */
function tokens(line, lang) {
  const out = [];
  const hash = /^(py|python|rb|ruby|sh|bash|shell|r|yaml|toml)$/i.test(lang || "");
  const re = hash
    ? /(#.*$)|("(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)|(\s+|.)/g
    : /(\/\/.*$|--.*$|#.*$)|("(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`[^`]*`?)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)|(\s+|.)/g;
  for (const m of line.matchAll(re)) {
    const kind = m[1] ? "comment" : m[2] ? "string" : m[3] ? "number" : m[4] && KEYWORDS.has(m[4]) ? "keyword" : "plain";
    const last = out[out.length - 1];
    if (last && last[0] === kind) last[1] += m[0]; else out.push([kind, m[0]]);
  }
  return out;
}

/** Source code → { mime, data, w, h } in layout points: a light card of monospaced, lightly coloured lines. */
export function renderCode(code, lang = "") {
  const lines = String(code ?? "").replace(/\t/g, "    ").replace(/\s+$/, "").split("\n").slice(0, 24).map((l) => l.slice(0, 80));
  if (!lines.some((l) => l.trim())) return null;
  // Keep the indentation that matters: drop only what every line shares.
  const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length));
  const body = lines.map((l) => l.slice(indent));
  const longest = Math.max(...body.map((l) => l.length), 8);
  let size = 15;
  const charW = () => size * 0.602, lineH = () => size * 1.45, pad = 14;
  // Long lines shrink the type (down to 11 pt) before the block is scaled to fit the column.
  while (pad * 2 + longest * charW() > MAX_WIDTH && size > 11) size -= 0.5;
  const w = Math.min(MAX_WIDTH, Math.ceil(pad * 2 + longest * charW())), h = Math.ceil(pad * 2 + body.length * lineH() - (lineH() - size) * 0.6);
  const label = lang ? `<text x="${w - 10}" y="${pad - 2}" text-anchor="end" font-family="Menlo, DejaVu Sans Mono, monospace" font-size="9" fill="${COLORS.comment}">${escape(String(lang).toLowerCase().slice(0, 12))}</text>` : "";
  const text = body.map((line, i) => {
    const spans = tokens(line, lang).map(([kind, t]) => `<tspan fill="${COLORS[kind]}"${kind === "keyword" ? ' font-weight="bold"' : ""}>${escape(t)}</tspan>`).join("");
    return `<text x="${pad}" y="${(pad + size + i * lineH()).toFixed(1)}" xml:space="preserve" font-family="Menlo, DejaVu Sans Mono, monospace" font-size="${size}">${spans}</text>`;
  }).join("");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">`
    + `<rect x="0.5" y="0.5" width="${w - 1}" height="${h - 1}" rx="10" fill="#F4F3FB" stroke="#3830D6" stroke-opacity="0.18"/>${label}${text}</svg>`;
  try { return { mime: "image/png", data: png(svg, w), w, h }; } catch { return null; }
}

/** A "math" or "code" ink item → an "image" item (or a plain text line if it can't be typeset). */
export function typeset(item) {
  if (item?.type === "math") {
    const picture = renderMath(item.tex);
    // `alt` is the formula as text, for the chat history: the next question can refer back to it.
    return picture ? { type: "image", ...picture, alt: "$" + String(item.tex).trim().slice(0, 300) + "$" } : { type: "text", value: plainMath(item.tex) };
  }
  if (item?.type === "code") {
    const picture = renderCode(item.value, item.lang);
    const fence = "`".repeat(3);
    return picture ? { type: "image", ...picture, alt: fence + String(item.lang || "").toLowerCase().slice(0, 12) + "\n" + String(item.value).slice(0, 600) + "\n" + fence }
      : { type: "text", value: String(item.value ?? "").split("\n")[0].slice(0, 90) };
  }
  return item;
}

/** A last resort for LaTeX that won't typeset: readable plain text. */
export function plainMath(tex) {
  return String(tex ?? "").replace(/\\frac\{([^}]*)\}\{([^}]*)\}/g, "($1)/($2)").replace(/\\(cdot|times)/g, "×").replace(/\\sqrt\{([^}]*)\}/g, "√($1)")
    .replace(/\^\{([^}]*)\}/g, "^$1").replace(/_\{([^}]*)\}/g, "_$1").replace(/\\left|\\right/g, "").replace(/\\([a-zA-Z]+)/g, "$1").replace(/[{}$]/g, "").slice(0, 90);
}
