// Run in a child process: the original bug throws outside fetch's promise and
// kills the process. Use a real socket, with no live API calls or credentials.
import assert from "node:assert/strict";
import { createServer } from "node:net";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";

const mode = process.argv[2];
const payload = Buffer.alloc(96 * 1024, "a");
const server = createServer(socket => {
  socket.on("error", () => {});
  socket.once("data", () => {
    const framing = mode === "eof" ? ""
      : mode === "chunked-truncated" ? "Transfer-Encoding: chunked\r\n"
      : `Content-Length: ${payload.length + (mode === "length-truncated" ? 500 : 0)}\r\n`;
    socket.write(`HTTP/1.1 200 OK\r\nConnection: close\r\n${framing}\r\n`);
    if (mode === "chunked-truncated") socket.write(`${payload.length.toString(16)}\r\n`);
    // Deliberately omit the chunk terminator in the truncated case.
    socket.end(payload);
  });
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
try {
  const response = await fetch(`http://127.0.0.1:${server.address().port}`, {
    signal: AbortSignal.timeout(3000),
  });
  // Leave the response unread until FIN reaches the paused parser.
  await delay(150);
  if (mode.endsWith("truncated")) {
    await assert.rejects(response.arrayBuffer());
  } else {
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), payload);
  }
} finally {
  server.close();
}
