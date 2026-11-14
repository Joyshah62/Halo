import { log, errorDetails } from "./logging.js";
// Keep idle streams alive while the model or speech service is working, and never write after EOF.
export function eventStream(res, { heartbeatMs = 15000, onHeartbeat = () => {} } = {}) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  res.flushHeaders();
  let closed = false;
  const stop = () => { closed = true; clearInterval(heartbeat); };
  const heartbeat = setInterval(() => {
    if (!closed && !res.destroyed && !res.writableEnded) {
      res.write(": keepalive\n\n"); onHeartbeat();
    }
  }, heartbeatMs);
  heartbeat.unref();
  res.once("close", stop);
  res.once("finish", stop);
  res.once("error", stop);
  return {
    get closed() { return closed || res.destroyed || res.writableEnded; },
    send(event, data) {
      if (this.closed) return false;
      if (event === "error") log("stream.error", { request: res.locals?.requestID, ...errorDetails(data?.message || "Unknown stream error") }, "error");
      return res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    },
  };
}
