import * as pdfjs from "pdfjs-dist";
pdfjs.GlobalWorkerOptions.workerSrc = chrome.runtime.getURL("pdf.worker.min.mjs");

const file = new URLSearchParams(location.search).get("file");
const name = document.getElementById("name")!;
const pages = document.getElementById("pages")!;
const textEl = document.getElementById("text")!;

(async () => {
  if (!file) { name.textContent = "No PDF given. Use ?file=<url>"; return; }
  name.textContent = decodeURIComponent(file.split("/").pop() || file);
  document.title = `${name.textContent} · Halo`;
  try {
    const data = new Uint8Array(await (await fetch(file)).arrayBuffer());
    const doc = await pdfjs.getDocument({ data }).promise;
    const scale = Math.min(1.6, (Math.min(innerWidth, 1000) - 40) / 612);
    const chunks: string[] = [];
    for (let i = 1; i <= doc.numPages; i++) {
      const page = await doc.getPage(i);
      const vp = page.getViewport({ scale: scale * (devicePixelRatio || 1) });
      const canvas = document.createElement("canvas");
      canvas.dataset.haloPage = String(i);
      canvas.width = vp.width; canvas.height = vp.height;
      canvas.style.width = `${vp.width / (devicePixelRatio || 1)}px`;
      canvas.style.height = `${vp.height / (devicePixelRatio || 1)}px`;
      pages.appendChild(canvas);
      await page.render({ canvasContext: canvas.getContext("2d")!, viewport: vp, canvas }).promise;
      const tc = await page.getTextContent();
      chunks.push(`--- page ${i} ---\n` + tc.items.map((it: any) => it.str).join(" "));
      // the hidden text gives Halo whole-document context; the screenshot gives it the circled math
      textEl.textContent = chunks.join("\n");
    }
  } catch (e: any) {
    name.textContent = `Could not load PDF: ${e?.message || e}`;
  }
})();
