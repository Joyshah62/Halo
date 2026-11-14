// Office imports become PDFs so annotations and page coordinates use the same reader.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { access, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const run = promisify(execFile);
export const OFFICE_EXTENSIONS = new Set(["ppt", "pptx", "doc", "docx"]);
export const MAX_OFFICE_BYTES = 25 * 1024 * 1024;
let active = 0;
export class ImportError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
async function executable() {
  const candidates = process.env.LIBREOFFICE_PATH ? [process.env.LIBREOFFICE_PATH] : [
    "/Applications/LibreOffice.app/Contents/MacOS/soffice",
    ...String(process.env.PATH || "").split(path.delimiter).filter(Boolean).flatMap((dir) => [path.join(dir, "soffice"), path.join(dir, "libreoffice")]),
  ];
  for (const candidate of candidates) {
    try { await access(candidate, constants.X_OK); return candidate; } catch { /* next location */ }
  }
  throw new ImportError(503, "Office import is unavailable on this Halo server. Install LibreOffice on the server, or export your document as PDF.");
}
export async function convertOffice(data, extension) {
  const ext = String(extension || "").toLowerCase();
  if (!OFFICE_EXTENSIONS.has(ext)) throw new ImportError(415, "Choose a PowerPoint (.ppt, .pptx) or Word (.doc, .docx) file.");
  if (!Buffer.isBuffer(data) || !data.length) throw new ImportError(400, "The document is empty.");
  if (data.length > MAX_OFFICE_BYTES) throw new ImportError(413, "Choose a document smaller than 25 MB.");
  const signature = ext.endsWith("x") ? Buffer.from([0x50, 0x4b, 0x03, 0x04]) : Buffer.from("d0cf11e0a1b11ae1", "hex");
  if (!data.subarray(0, signature.length).equals(signature)) throw new ImportError(422, "This file does not match its Office format. Try opening it in Word or PowerPoint and saving a new copy.");
  if (active >= 2) throw new ImportError(429, "Halo is importing other documents. Try again in a moment.");
  active++;
  let folder;
  try {
    const binary = await executable();
    folder = await mkdtemp(path.join(tmpdir(), "halo-office-"));
    const profile = path.join(folder, "profile"), out = path.join(folder, "out");
    await mkdir(path.join(profile, "user"), { recursive: true });
    await mkdir(out);
    // A fresh profile prevents interference with a running desktop instance and disables document macros.
    await writeFile(path.join(profile, "user", "registrymodifications.xcu"), `<?xml version="1.0"?><oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item></oor:items>`);
    const input = path.join(folder, `document.${ext}`);
    await writeFile(input, data);
    try {
      await run(binary, [`-env:UserInstallation=${pathToFileURL(profile).href}`, "--headless", "--nologo", "--nodefault", "--norestore", "--convert-to", "pdf", "--outdir", out, input], { timeout: 90000, killSignal: "SIGKILL", maxBuffer: 1024 * 1024 });
    } catch (error) {
      if (error.killed) throw new ImportError(504, "This document took too long to convert. Try a smaller file or export it as PDF.");
      throw new ImportError(422, "Halo couldn’t convert this document. Check that it opens without a password, or export it as PDF.");
    }
    const output = path.join(out, "document.pdf");
    const size = await stat(output).catch(() => null);
    if (!size || size.size > 100 * 1024 * 1024) throw new ImportError(422, "Halo couldn’t create a readable PDF. Remove any password or export it as PDF yourself.");
    const pdf = await readFile(output);
    if (pdf.subarray(0, 5).toString() !== "%PDF-") throw new ImportError(422, "The converted document could not be read. Try exporting it as PDF.");
    return pdf;
  } finally {
    active--;
    if (folder) await rm(folder, { recursive: true, force: true });
  }
}
