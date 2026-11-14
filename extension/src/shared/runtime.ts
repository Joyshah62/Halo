import type { Msg } from "./types";

const invalidationListeners = new Set<() => void>();
let invalidated = false;
export function isContextInvalidated(error: unknown): boolean {
  return /extension context invalidated|extension has been (?:updated|reloaded)/i.test(error instanceof Error ? error.message : String(error));
}
function invalidate() {
  if (invalidated) return;
  invalidated = true;
  for (const listener of invalidationListeners) listener();
}
export function runtimeAvailable(): boolean {
  try {
    if (!invalidated && chrome.runtime?.id) return true;
  } catch {}
  invalidate(); return false;
}
export function onRuntimeInvalidated(listener: () => void) {
  invalidationListeners.add(listener);
  if (invalidated) listener();
  return () => invalidationListeners.delete(listener);
}
/** Chrome can throw synchronously after a reload, before it returns a Promise. */
export async function sendRuntimeMessage(message: Msg): Promise<any> {
  if (!runtimeAvailable()) return null;
  try { return await chrome.runtime.sendMessage(message); }
  catch (error) { if (isContextInvalidated(error)) invalidate(); return null; }
}

export function showReloadNotice(draft: string) {
  document.getElementById("halo-reload-notice")?.remove();
  const host = document.createElement("div"); host.id = "halo-reload-notice";
  host.style.cssText = "position:fixed;right:20px;bottom:20px;width:min(340px,calc(100vw - 40px));z-index:2147483647";
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `<style>:host{all:initial}.notice{padding:18px;border:1px solid #e6e8e0;border-radius:12px;background:#fffaf5;color:#252b2a;box-shadow:0 6px 30px #17221c26;font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}b{font-size:14px}p{margin:7px 0 12px;color:#667068}textarea{box-sizing:border-box;width:100%;padding:9px;border:1px solid #dfe3dc;border-radius:8px;background:white;color:#252b2a;font:inherit;resize:vertical;margin-bottom:10px}button{border:0;border-radius:7px;padding:8px 12px;font:inherit;cursor:pointer;background:#e56b48;color:white}.dismiss{background:transparent;color:#667068}button:focus-visible,textarea:focus-visible{outline:2px solid #466454;outline-offset:3px}</style><section class="notice" role="alert"><b>Halo was reloaded</b><p>Refresh this page to reconnect to the updated extension.</p><textarea readonly aria-label="Your unsent question" rows="2" hidden></textarea><button class="refresh">Refresh page</button><button class="dismiss">Dismiss</button></section>`;
  const input = root.querySelector("textarea")!;
  if (draft) { input.hidden = false; input.value = draft; root.querySelector("p")!.textContent += " You can copy your question below before refreshing."; }
  root.querySelector(".refresh")!.addEventListener("click", () => location.reload());
  root.querySelector(".dismiss")!.addEventListener("click", () => host.remove());
  document.documentElement.appendChild(host);
}
