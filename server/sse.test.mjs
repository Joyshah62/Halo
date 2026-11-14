import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { once } from "node:events";
import { eventStream } from "./sse.js";

test("slow answers send heartbeat comments and a complete terminal event", async () => {
  let stream;
  const server = http.createServer((_req, res) => {
    stream = eventStream(res, { heartbeatMs: 10 });
    stream.send("start", { id: 1 });
    setTimeout(() => {
      stream.send("step", { index: 0, say: "A local test answer", ink: [], audio: null });
      stream.send("done", {}); res.end();
    }, 65);
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}`);
    assert.match(response.headers.get("content-type"), /text\/event-stream/);
    const text = await response.text();
    assert.match(text, /: keepalive\n\n/);
    assert.match(text, /event: step/); assert.match(text, /event: done/);
    assert.equal(stream.closed, true);
    assert.equal(stream.send("step", { say: "too late" }), false);
  } finally { server.closeAllConnections(); await new Promise((r) => server.close(r)); }
});

test("client disconnect stops heartbeats and late audio writes", async () => {
  let stream, disconnected;
  const closed = new Promise((r) => { disconnected = r; });
  const server = http.createServer((_req, res) => {
    stream = eventStream(res, { heartbeatMs: 10 });
    res.once("close", disconnected);
    stream.send("start", {});
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}`);
    await response.body.cancel(); await closed;
    assert.equal(stream.closed, true);
    assert.equal(stream.send("step", { say: "late speech" }), false);
  } finally { server.closeAllConnections(); await new Promise((r) => server.close(r)); }
});
