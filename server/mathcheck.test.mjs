// node --test mathcheck.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkStep, normalize } from "./mathcheck.js";

const is = (prev, next, relation, expected, variable) =>
  assert.equal(checkStep(prev, next, relation, variable).result, expected, `${prev}  →  ${next}  (${relation})`);

test("equations: correct rearrangements", () => {
  is("2x + 3 = 7", "2x = 4", "same_solutions", "ok");
  is("2x = 4", "x = 2", "same_solutions", "ok");
  is("3(x - 2) = 9", "3x - 6 = 9", "same_solutions", "ok");
  is("x^2 - 5x + 6 = 0", "(x - 2)(x - 3) = 0", "same_solutions", "ok");
  is("x/3 + 1 = 4", "x = 9", "same_solutions", "ok");
  is("sqrt(x) = 3", "x = 9", "same_solutions", "ok");
});

test("equations: slips are caught", () => {
  is("2x + 3 = 7", "2x = 10", "same_solutions", "mismatch"); // sign slip moving the 3
  is("3(x - 2) = 9", "3x - 2 = 9", "same_solutions", "mismatch"); // didn't distribute
  is("2x = 4", "x = 8", "same_solutions", "mismatch"); // multiplied instead of divided
  is("x^2 = 4", "x = 2", "same_solutions", "mismatch"); // lost the negative root
  is("-2x = 6", "x = 3", "same_solutions", "mismatch");
});

test("equations: several variables", () => {
  is("2a + b = c", "a = (c - b)/2", "same_solutions", "ok");
  is("2a + b = c", "a = (c + b)/2", "same_solutions", "mismatch");
  is("F = m*a", "a = F/m", "same_solutions", "ok");
});

test("expressions: simplification", () => {
  is("3(x^2+1)^2 * 2x", "6x(x^2+1)^2", "equal_value", "ok");
  is("(x+1)^2", "x^2 + 2x + 1", "equal_value", "ok");
  is("(x+1)^2", "x^2 + 1", "equal_value", "mismatch");
  is("y = 2(x + 3)", "y = 2x + 6", "equal_value", "ok");
  is("12/4 + 3*2", "9", "equal_value", "ok");
  is("12/4 + 3*2", "12", "equal_value", "mismatch");
});

test("derivatives", () => {
  is("(x^2+1)^3", "3(x^2+1)^2 * 2x", "derivative_of_previous", "ok");
  is("(x^2+1)^3", "3(x^2+1)^2", "derivative_of_previous", "mismatch"); // forgot the inner derivative
  is("diff((x^2+1)^3, x)", "6x(x^2+1)^2", "equal_value", "ok");
  is("diff(sin(3x), x)", "cos(3x)", "equal_value", "mismatch");
  is("y = t^3 - 2t", "3t^2 - 2", "derivative_of_previous", "ok", "t");
});

test("unicode from handwriting is tolerated", () => {
  assert.equal(normalize("3(x²+1)² · 2x"), "3(x^(2)+1)^(2) * 2x");
  is("3(x²+1)² · 2x", "6x(x²+1)²", "equal_value", "ok");
  is("2x − 4 = 0", "x = 2", "same_solutions", "ok");
  is("√(x) = 3", "x = 9", "same_solutions", "ok");
});

test("things it cannot judge are unknown, never a false alarm", () => {
  is("x = ±2", "x = 2", "same_solutions", "unknown");
  is("so the slope is positive", "x = 2", "same_solutions", "unknown");
  is("x > 3", "x > 2", "same_solutions", "unknown");
  is("", "x = 2", "equal_value", "unknown");
});

test("untrusted input cannot reach mathjs internals", () => {
  is('import({a: 1})', "1", "equal_value", "unknown");
  is('evaluate("1+1")', "2", "equal_value", "unknown");
});
