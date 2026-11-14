// Deterministic math checks for "Halo watches you work".
// The model reads the handwriting; this decides whether one line really follows from the one before.
// Everything is numeric (sampling + root finding), so it never needs a symbolic proof and never guesses:
// each check returns "ok", "mismatch" (with evidence) or "unknown" (can't tell: leave it to the judge).
import { create, all } from "mathjs";

const math = create(all);
const parse = math.parse;
const derivative = math.derivative;
// Expressions come from a model reading a photo: treat them as untrusted (mathjs security guidance).
const blocked = (name) => () => { throw new Error(`${name} is disabled`); };
math.import(
  { import: blocked("import"), createUnit: blocked("createUnit"), evaluate: blocked("evaluate"),
    parse: blocked("parse"), simplify: blocked("simplify"), derivative: blocked("derivative"),
    resolve: blocked("resolve"), reviver: blocked("reviver") },
  { override: true },
);

const CONSTANTS = new Set(["pi", "e", "tau", "phi", "i", "Infinity", "NaN", "true", "false", "null"]);
const SUPERS = { "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "ⁿ": "n" };

/** Tidy the things a transcription tends to leave in, so mathjs can parse it. */
export function normalize(src) {
  return String(src ?? "")
    .slice(0, 240)
    .replace(/[−–—]/g, "-")
    .replace(/[×·⋅∙]/g, "*")
    .replace(/÷/g, "/")
    .replace(/√\s*\(/g, "sqrt(")
    .replace(/√\s*([A-Za-z0-9.]+)/g, "sqrt($1)")
    .replace(/π/g, "pi")
    .replace(/([⁰¹²³⁴⁵⁶⁷⁸⁹ⁿ]+)/g, (m) => "^(" + [...m].map((c) => SUPERS[c]).join("") + ")")
    .replace(/\bln\s*\(/g, "log(")
    .replace(/\*\*/g, "^")
    // mathjs reads "x(x+1)" as calling a function x. In handwriting that is always x times (x+1).
    .replace(/([A-Za-z]+)\s*\(/g, (m, name) => (name === "diff" || (name.length > 1 && typeof math[name] === "function") ? m : `${name}*(`))
    .trim();
}

/** Split "lhs = rhs" on a lone "=", or return null when it isn't a single equation. */
function splitEquation(src) {
  const parts = src.split(/(?<![<>=!])=(?!=)/);
  if (parts.length !== 2 || !parts[0].trim() || !parts[1].trim()) return null;
  if (/[<>≤≥≠]/.test(src)) return null;
  return parts;
}

/** Replace diff(expr, x) with the actual derivative, so a "d/dx" line can be evaluated. */
function expandDiff(root, fallbackVar) {
  return root.transform((n) => {
    if (n.isFunctionNode && n.fn?.name === "diff") {
      const v = n.args[1]?.isSymbolNode ? n.args[1].name : fallbackVar;
      return derivative(expandDiff(n.args[0], fallbackVar), v);
    }
    return n;
  });
}

/**
 * Parse one transcribed line.
 * @returns {{ kind: "equation", lhs, rhs, f } | { kind: "expression", f } | null}
 *          f is a mathjs node: lhs - rhs for an equation, the expression otherwise.
 */
export function parseLine(src, variable = "x") {
  const text = normalize(src);
  if (!text) return null;
  try {
    const eq = splitEquation(text);
    if (eq) {
      const lhs = expandDiff(parse(eq[0]), variable);
      const rhs = expandDiff(parse(eq[1]), variable);
      return { kind: "equation", lhs, rhs, f: new math.OperatorNode("-", "subtract", [lhs, rhs]) };
    }
    if (text.includes("=")) return null;
    return { kind: "expression", f: expandDiff(parse(text), variable) };
  } catch {
    return null;
  }
}

function symbolsOf(...nodes) {
  const out = new Set();
  for (const node of nodes) {
    node.traverse((n, _path, parent) => {
      if (!n.isSymbolNode || CONSTANTS.has(n.name)) return;
      if (parent?.isFunctionNode && parent.fn === n) return; // sin, sqrt, ...
      out.add(n.name);
    });
  }
  return [...out].sort();
}

function evalAt(code, scope) {
  try {
    const v = code.evaluate({ ...scope });
    return typeof v === "number" && Number.isFinite(v) ? v : null;
  } catch {
    return null;
  }
}

const close = (a, b, tol = 1e-7) => Math.abs(a - b) <= tol * Math.max(1, Math.abs(a), Math.abs(b));

// Fixed, slightly awkward sample points: reproducible, and unlikely to land on a root or a pole.
const SAMPLES = [0.37, 1.13, 1.91, 2.47, 3.21, 0.73, -0.59, -1.37, -2.23, 4.6, 0.11, 5.83];
function scopes(vars) {
  return SAMPLES.map((_, i) => Object.fromEntries(vars.map((v, j) => [v, SAMPLES[(i + j * 5) % SAMPLES.length]])));
}

const fmt = (n) => (Number.isInteger(n) ? String(n) : String(Number(n.toFixed(4))));

/** Do two expressions have the same value everywhere we can evaluate them? */
export function sameValue(a, b) {
  const vars = symbolsOf(a, b);
  const ca = a.compile(), cb = b.compile();
  let valid = 0;
  for (const scope of scopes(vars)) {
    const va = evalAt(ca, scope), vb = evalAt(cb, scope);
    if (va === null || vb === null) continue;
    valid++;
    if (!close(va, vb)) {
      // Prefer a clean point for the evidence the judge reads.
      const clean = Object.fromEntries(vars.map((v) => [v, 2]));
      const ka = evalAt(ca, clean), kb = evalAt(cb, clean);
      const at = ka !== null && kb !== null && !close(ka, kb) ? { scope: clean, a: ka, b: kb } : { scope, a: va, b: vb };
      const where = vars.length ? `at ${vars.map((v) => `${v} = ${fmt(at.scope[v])}`).join(", ")}: ` : "";
      return { result: "mismatch", evidence: `${where}the earlier line gives ${fmt(at.a)}, this line gives ${fmt(at.b)}` };
    }
  }
  if (valid < (vars.length ? 3 : 1)) return { result: "unknown", evidence: "could not evaluate both lines numerically" };
  return { result: "ok", evidence: `equal at ${valid} test points` };
}

/** Real roots of a one-variable function on [-100, 100] (sign changes + exact grid hits). */
function roots(code, variable, fixed) {
  const f = (x) => evalAt(code, { ...fixed, [variable]: x });
  const found = [];
  const add = (r) => { if (!found.some((q) => close(q, r, 1e-6))) found.push(r); };
  const STEP = 0.05, N = 4000;
  let px = -100, pv = f(px);
  for (let k = 1; k <= N; k++) {
    const x = -100 + k * STEP, v = f(x);
    if (v !== null && Math.abs(v) < 1e-10) add(Number(x.toFixed(6)));
    else if (pv !== null && v !== null && Math.abs(pv) >= 1e-10 && Math.sign(pv) !== Math.sign(v)) {
      let lo = px, hi = x, flo = pv;
      for (let it = 0; it < 60; it++) {
        const mid = (lo + hi) / 2, fm = f(mid);
        if (fm === null) break;
        if (Math.sign(fm) === Math.sign(flo)) { lo = mid; flo = fm; } else hi = mid;
      }
      const r = (lo + hi) / 2, fr = f(r);
      // A sign change across a pole (1/x) is not a root.
      if (fr !== null && Math.abs(fr) < 1e-5 * Math.max(1, Math.abs(pv), Math.abs(v))) add(r);
    }
    px = x; pv = v;
  }
  return found.sort((a, b) => a - b);
}

/** Do two equations have the same solutions? */
export function sameSolutions(a, b) {
  const vars = symbolsOf(a, b);
  if (!vars.length) return { result: "unknown", evidence: "no variable to solve for" };
  const ca = a.compile(), cb = b.compile();

  // 1. lhs - rhs of one is a constant multiple of the other: a plain rearrangement.
  let ratio = null, proportional = true, valid = 0, bothZero = 0;
  for (const scope of scopes(vars)) {
    const va = evalAt(ca, scope), vb = evalAt(cb, scope);
    if (va === null || vb === null) continue;
    valid++;
    if (Math.abs(va) < 1e-9 && Math.abs(vb) < 1e-9) { bothZero++; continue; }
    if (Math.abs(vb) < 1e-9 || Math.abs(va) < 1e-9) { proportional = false; break; }
    const r = va / vb;
    if (ratio === null) ratio = r; else if (!close(r, ratio, 1e-6)) { proportional = false; break; }
  }
  if (valid >= 3 && bothZero === valid) return { result: "ok", evidence: "both are identities" };
  if (valid >= 3 && proportional && ratio !== null) return { result: "ok", evidence: "same equation, rearranged" };

  // 2. Compare the solution sets, solving for one variable with the others pinned.
  const variable = vars[0];
  const pins = vars.length === 1 ? [{}] : [0, 1, 2].map((t) => Object.fromEntries(vars.slice(1).map((v, j) => [v, SAMPLES[(t * 3 + j) % 6]])));
  let compared = 0;
  for (const fixed of pins) {
    const ra = roots(ca, variable, fixed), rb = roots(cb, variable, fixed);
    if (!ra.length && !rb.length) continue;
    compared++;
    const same = ra.length === rb.length && ra.every((r, i) => close(r, rb[i], 1e-5));
    if (!same) {
      const show = (rs) => (rs.length ? rs.map(fmt).join(", ") : "none");
      const pinned = vars.length > 1 ? ` (with ${Object.entries(fixed).map(([k, v]) => `${k} = ${fmt(v)}`).join(", ")})` : "";
      return { result: "mismatch", evidence: `the earlier line is solved by ${variable} = ${show(ra)}; this line is solved by ${variable} = ${show(rb)}${pinned}` };
    }
  }
  if (!compared) return { result: "unknown", evidence: "found no real solutions to compare" };
  return { result: "ok", evidence: "same solutions" };
}

const valueSide = (line) => (line.kind === "equation" ? line.rhs : line.f);

/**
 * Does `next` follow from `prev`?
 * @param {"same_solutions"|"equal_value"|"derivative_of_previous"} relation
 * @returns {{ result: "ok"|"mismatch"|"unknown", evidence: string }}
 */
export function checkStep(prevSrc, nextSrc, relation, variable = "x") {
  const prev = parseLine(prevSrc, variable), next = parseLine(nextSrc, variable);
  if (!prev || !next) return { result: "unknown", evidence: `could not parse ${!prev ? "the earlier line" : "this line"}` };
  try {
    if (relation === "derivative_of_previous") {
      return sameValue(derivative(valueSide(prev), variable), valueSide(next));
    }
    if (relation === "same_solutions") {
      if (prev.kind !== "equation" || next.kind !== "equation") return { result: "unknown", evidence: "both lines must be equations" };
      return sameSolutions(prev.f, next.f);
    }
    if (relation === "equal_value") return sameValue(valueSide(prev), valueSide(next));
    return { result: "unknown", evidence: "no relation to check" };
  } catch (e) {
    return { result: "unknown", evidence: `check failed: ${String(e.message || e).slice(0, 80)}` };
  }
}
