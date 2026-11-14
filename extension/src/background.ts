import type { Msg, AskPayload } from "./shared/types";
import { getSettings } from "./shared/types";

const conversationPanels = new Map<number, Set<chrome.runtime.Port>>();

// Toolbar icon opens the side panel.
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});

// Alt+C toggles drawing mode in the active tab (works even on sites that swallow keys).
chrome.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "toggle-draw") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) chrome.tabs.sendMessage(tab.id, { type: "TOGGLE_DRAW" } satisfies Msg).catch(() => {});
});

// Open PDFs in our own viewer (Chrome's built-in viewer blocks extensions).
const VIEWER = chrome.runtime.getURL("pdf.html");
chrome.webNavigation.onCommitted.addListener((d) => {
  if (d.frameId !== 0) return;
  const u = d.url;
  if (u.startsWith(VIEWER) || !/^https?:\/\//.test(u)) return;
  if (/\.pdf($|[?#])/i.test(u)) {
    chrome.tabs.update(d.tabId, { url: `${VIEWER}?file=${encodeURIComponent(u)}` });
  }
});

chrome.runtime.onMessage.addListener((msg: Msg, sender, sendResponse) => {
  (async () => {
    switch (msg.type) {
      case "PRESENT_CONVERSATION": {
        const panels = sender.tab?.id ? conversationPanels.get(sender.tab.id) : undefined;
        let shown = false;
        for (const panel of panels ?? []) {
          try { panel.postMessage({ type: "STATE", tabId: sender.tab!.id, state: msg.state }); shown = true; } catch { panels?.delete(panel); }
        }
        sendResponse({ shown }); return;
      }
      case "CAPTURE": {
        const windowId = sender.tab?.windowId;
        const dataUrl = await chrome.tabs.captureVisibleTab(windowId!, { format: "png" });
        sendResponse({ dataUrl });
        return;
      }
      case "OPEN_SIDEPANEL": {
        try {
          if (!sender.tab?.id) { sendResponse({ ok: false }); return; }
          await chrome.sidePanel.open({ tabId: sender.tab.id }); sendResponse({ ok: true });
        } catch { sendResponse({ ok: false }); }
        return;
      }
      case "OPEN_PDF_VIEWER": {
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        if (tab?.id && tab.url) chrome.tabs.update(tab.id, { url: `${VIEWER}?file=${encodeURIComponent(tab.url)}` });
        sendResponse({ ok: true });
        return;
      }
      case "ASK_PAGE":
      case "START_DRAW": {
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        if (tab?.id) chrome.tabs.sendMessage(tab.id, { type: msg.type === "ASK_PAGE" ? "ASK_PAGE" : "TOGGLE_DRAW" } satisfies Msg).catch(() => {});
        sendResponse({ ok: true });
        return;
      }
      // Route voice only to panels bound to the originating tab.
      case "LISTEN_START":
      case "LISTEN_STOP": {
        const tabId = sender.tab?.id;
        let delivered = false;
        for (const panel of (tabId ? conversationPanels.get(tabId) : undefined) ?? []) {
          try { panel.postMessage({ type: msg.type, tabId }); delivered = true; } catch {}
        }
        sendResponse({ ok: delivered, ...(!delivered ? { error: "sidepanel-closed" } : {}) });
        return;
      }
      // Side panel → content script in the tab that asked.
      case "TRANSCRIPT":
      case "LISTEN_STATE": {
        if (msg.tabId) chrome.tabs.sendMessage(msg.tabId, msg).catch(() => {});
        sendResponse({ ok: true });
        return;
      }
      case "ACTIVITY": {
        // already broadcast to the side panel by the sender; nothing to do
        sendResponse({ ok: true });
        return;
      }
    }
  })().catch((e) => sendResponse({ error: String(e) }));
  return true; // async
});

// Streaming ask: content script connects a Port, we fetch SSE from the server
// (keys live on the server) and forward events as they arrive.
chrome.runtime.onConnect.addListener((port) => {
  if (port.name === "conversation-panel") {
    let boundTab: number | undefined;
    let binding = 0;
    const detach = () => {
      if (boundTab === undefined) return;
      const panels = conversationPanels.get(boundTab);
      panels?.delete(port);
      if (!panels?.size) {
        conversationPanels.delete(boundTab);
        void chrome.tabs.sendMessage(boundTab, { type: "PANEL_CLOSED" } satisfies Msg).catch(() => {});
      }
      boundTab = undefined;
    };
    port.onDisconnect.addListener(() => { binding++; detach(); });
    port.onMessage.addListener(async (message) => {
      if (message.type === "BIND" && Number.isInteger(message.tabId)) {
        const version = ++binding;
        if (boundTab !== message.tabId) detach();
        boundTab = message.tabId;
        const panels = conversationPanels.get(boundTab!) ?? new Set();
        panels.add(port); conversationPanels.set(boundTab!, panels);
        let state = null;
        try { state = await chrome.tabs.sendMessage(boundTab!, { type: "GET_CONVERSATION" } satisfies Msg); } catch {}
        if (version === binding) { try { port.postMessage({ type: "STATE", tabId: boundTab, state: state || null }); } catch {} }
      } else if (message.type === "COMMAND" && boundTab !== undefined) {
        void chrome.tabs.sendMessage(boundTab, { type: "CONVERSATION_ACTION", sessionId: message.sessionId, command: message.command } satisfies Msg).catch(() => {});
      }
    });
    return;
  }
  if (port.name !== "ask") return;
  const ctrl = new AbortController();
  port.onDisconnect.addListener(() => ctrl.abort());
  port.onMessage.addListener(async (payload: AskPayload) => {
    try {
      const { serverUrl } = await getSettings();
      const res = await fetch(`${serverUrl.replace(/\/$/, "")}/api/ask`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        signal: ctrl.signal,
      });
      if (!res.ok || !res.body) {
        port.postMessage({ event: "error", data: { message: `Server ${res.status}` } });
        return;
      }
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      let terminal = false;
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let idx;
        while ((idx = buf.indexOf("\n\n")) >= 0) {
          const chunk = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          let event = "message", data = "";
          for (const line of chunk.split("\n")) {
            if (line.startsWith("event: ")) event = line.slice(7).trim();
            else if (line.startsWith("data: ")) data += line.slice(6);
          }
          if (data) {
            try {
              const parsed = JSON.parse(data);
              if (event === "done" || event === "error") terminal = true;
              port.postMessage({ event, data: parsed });
            } catch {}
          }
        }
      }
      if (!terminal) port.postMessage({ event: "error", data: { message: "Connection ended before the answer finished. Please try again." } });
    } catch (e: any) {
      if (e?.name !== "AbortError") {
        try { port.postMessage({ event: "error", data: { message: e?.message || "Could not reach the Halo server. Is it running?" } }); } catch {}
      }
    }
  });
});
