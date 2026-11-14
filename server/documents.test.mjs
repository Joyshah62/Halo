import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { convertOffice, ImportError, MAX_OFFICE_BYTES } from "./documents.js";

const candidates = process.env.LIBREOFFICE_PATH ? [process.env.LIBREOFFICE_PATH] : [
  "/Applications/LibreOffice.app/Contents/MacOS/soffice",
  ...String(process.env.PATH || "").split(path.delimiter).flatMap((p) => [path.join(p, "soffice"), path.join(p, "libreoffice")]),
];
const installed = candidates.some(existsSync);
const rejects = (status) => (error) => error instanceof ImportError && error.status === status;
test("Office import rejects unsupported, empty, oversized and mislabeled files", async () => {
  await assert.rejects(convertOffice(Buffer.from("test"), "exe"), rejects(415));
  await assert.rejects(convertOffice(Buffer.alloc(0), "docx"), rejects(400));
  await assert.rejects(convertOffice(Buffer.alloc(MAX_OFFICE_BYTES + 1), "pptx"), rejects(413));
  await assert.rejects(convertOffice(Buffer.from("not an Office file"), "docx"), rejects(422));
  await assert.rejects(convertOffice(Buffer.from("PK\x03\x04"), "../../pptx"), rejects(415));
});
test("missing converter returns an actionable availability error", async () => {
  const previous = process.env.LIBREOFFICE_PATH;
  process.env.LIBREOFFICE_PATH = "/no-such-halo-converter";
  try {
    await assert.rejects(convertOffice(Buffer.from("PK\x03\x04"), "pptx"), (error) => rejects(503)(error) && error.message.includes("Install LibreOffice"));
  } finally {
    if (previous === undefined) delete process.env.LIBREOFFICE_PATH; else process.env.LIBREOFFICE_PATH = previous;
  }
});
for (const extension of ["docx", "doc", "pptx", "ppt"]) {
  test(`${extension} converts to a two-page PDF`, { skip: !installed }, async () => {
    const input = await readFile(new URL(`./test-fixtures/office-sample.${extension}`, import.meta.url));
    const pdf = await convertOffice(input, extension);
    assert.equal(pdf.subarray(0, 5).toString(), "%PDF-");
    assert.equal((pdf.toString("latin1").match(/\/Type\s*\/Page\b/g) || []).length, 2);
  });
}
test("damaged Office archives fail without adding a document", { skip: !installed }, async () => {
  await assert.rejects(convertOffice(Buffer.from("PK\x03\x04broken"), "pptx"), rejects(422));
});
