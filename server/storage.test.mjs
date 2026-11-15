import test from "node:test";
import assert from "node:assert/strict";
import { createStorage, publicUrl, objectKey, StorageError } from "./storage.js";

function fakes() {
  const sent = [], rows = [];
  const s3 = { send: async (command) => { sent.push(command.input); return {}; } };
  const files = {
    insertOne: async (doc) => { rows.push(doc); return { insertedId: `id${rows.length}` }; },
    find: (query) => {
      let out = rows.filter((r) => !query.kind || r.kind === query.kind).map((r, i) => ({ _id: `id${i + 1}`, ...r }));
      const cursor = { sort: () => { out = out.reverse(); return cursor; }, limit: (n) => { out = out.slice(0, n); return cursor; }, toArray: async () => out };
      return cursor;
    },
  };
  return { s3, files, sent, rows };
}

test("store uploads to S3 and records the public link in Mongo", async () => {
  const { s3, files, sent, rows } = fakes();
  const storage = createStorage({ s3, files, bucket: "halo-files", region: "us-east-2", prefix: "halo/" });
  const file = await storage.store({ data: Buffer.from("%PDF-1.7"), mime: "application/pdf", kind: "document", name: "Week 3.pdf", meta: { learner: "a" } });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].Bucket, "halo-files");
  assert.equal(sent[0].ContentType, "application/pdf");
  assert.match(sent[0].Key, /^halo\/document\/\d{4}\/\d{2}\/\d{2}\/[0-9a-f-]{36}\.pdf$/);
  assert.equal(file.url, `https://halo-files.s3.us-east-2.amazonaws.com/${sent[0].Key}`);
  assert.equal(file.id, "id1");
  assert.equal(rows[0].url, file.url);
  assert.equal(rows[0].size, 8);
  assert.deepEqual(rows[0].meta, { learner: "a" });
});

test("store rejects empty files and unknown kinds without touching S3", async () => {
  const { s3, files, sent } = fakes();
  const storage = createStorage({ s3, files, bucket: "b", region: "us-east-1" });
  await assert.rejects(storage.store({ data: Buffer.alloc(0) }), StorageError);
  await assert.rejects(storage.store({ data: Buffer.from("x"), kind: "nope" }), StorageError);
  assert.equal(sent.length, 0);
});

test("list filters by kind, newest first", async () => {
  const { s3, files } = fakes();
  const storage = createStorage({ s3, files, bucket: "b", region: "us-east-1" });
  await storage.store({ data: Buffer.from("a"), mime: "image/png", kind: "screenshot" });
  await storage.store({ data: Buffer.from("b"), mime: "image/png", kind: "note-image" });
  await storage.store({ data: Buffer.from("c"), mime: "image/png", kind: "screenshot" });
  const shots = await storage.list({ kind: "screenshot" });
  assert.equal(shots.length, 2);
  assert.equal(shots[0].size, 1);
  assert.ok(shots.every((f) => f.kind === "screenshot" && f.id));
});

test("public URLs encode keys and honour a CDN base", () => {
  assert.equal(publicUrl("upload/a b.png", { bucket: "b", region: "eu-west-1" }), "https://b.s3.eu-west-1.amazonaws.com/upload/a%20b.png");
  assert.equal(publicUrl("upload/x.png", { base: "https://cdn.example.com/" }), "https://cdn.example.com/upload/x.png");
  assert.match(objectKey("upload", "application/octet-stream", "slides.PPTX"), /\.pptx$/);
  assert.match(objectKey("upload", "application/octet-stream", "noext"), /\.bin$/);
});
