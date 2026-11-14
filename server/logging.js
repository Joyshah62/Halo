import { appendFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const root = path.dirname(fileURLToPath(import.meta.url));
const directory = process.env.HALO_LOG_DIR || path.join(root, "logs");
export const logFile = path.join(directory, "server.jsonl");
let warned = false;
function redact(value) {
  return String(value).replace(/AIza[\w-]{20,}|(?:sk-ant-|sk-proj-|sk-svcacct-)[\w-]+|gh[pousr]_[\w]+/g, "[redacted]")
    .replace(/([?&](?:key|api_key|token)=)[^&\s]+/gi, "$1[redacted]")
    .replace(/((?:api[_-]?key|authorization|xi-api-key)["'\s]*[:=]["'\s]*)(?:Bearer )?[^\s,"'}]+/gi, "$1[redacted]").slice(0, 8000);
}
export function errorDetails(error) {
  return { name: error?.name, message: redact(error?.message || error), code: error?.code, status: error?.status,
    stack: error?.stack ? redact(error.stack) : undefined };
}
export function log(event, details = {}, level = "info") {
  const row = { time: new Date().toISOString(), pid: process.pid, level, event, ...details };
  try {
    mkdirSync(directory, { recursive: true });
    appendFileSync(logFile, JSON.stringify(row) + "\n", { mode: 0o600 });
  } catch (error) {
    if (!warned) { warned = true; console.error("[logging] Could not write server log:", error.message); }
  }
  console.log(`[${row.time}] [${event}] ${JSON.stringify(details)}`);
}
export function requestLogging(req, res, next) {
  const id = randomUUID(), started = Date.now();
  res.locals.requestID = id;
  res.setHeader("X-Halo-Request-ID", id);
  log("request.started", { request: id, method: req.method, path: req.path, client: req.get("X-Halo-Client") || "unversioned" });
  res.once("finish", () => log("request.finished", { request: id, status: res.statusCode, ms: Date.now() - started }));
  res.once("close", () => {
    if (!res.writableFinished) log("request.disconnected", { request: id, question: res.locals.questionID, stage: res.locals.stage, ms: Date.now() - started }, "warn");
  });
  next();
}
export function installProcessLogging() {
  log("server.boot", { node: process.version, file: logFile });
  process.on("uncaughtExceptionMonitor", (error, origin) => log("process.crash", { origin, ...errorDetails(error) }, "error"));
  process.on("exit", (code) => log("process.exit", { code }, code ? "error" : "info"));
  for (const signal of ["SIGTERM", "SIGINT"]) {
    // Record the signal, then restore Node's normal termination behavior.
    process.once(signal, () => { log("process.signal", { signal }); process.kill(process.pid, signal); });
  }
}
