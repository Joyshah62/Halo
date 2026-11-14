export interface Scene3DSpec { model: "brain" | "neuron" | "animal-cell"; focus?: string; caption: string }
export type InkItem =
  | ({ type: "scene3d" } & Scene3DSpec)
  | { type: "text"; value: string }
  | { type: "arrow"; to: "circled" | "previous" }
  | { type: "underline"; target?: "previous" }
  | { type: "box"; target?: "previous" }
  | { type: "check" }
  | { type: "cross" }
  | { type: "sketch"; w: number; h: number; paths: string[]; labels: { x: number; y: number; text: string }[] }
  | { type: "image"; prompt: string; mime?: string; data?: string };

export interface Step {
  index: number;
  say: string;
  ink: InkItem[];
  audio: string | null; // base64 mp3
}

export interface Meta { mode: "answer" | "hint"; topic: string }

export interface ConversationTurn { role: "user" | "assistant"; text: string }

export interface AskPayload {
  supports3D?: boolean;
  selectionMode?: "crop" | "page";
  conversation?: ConversationTurn[];
  question: string;
  image?: string;        // base64 crop (no data: prefix)
  imageMime?: string;
  contextImage?: string; // base64 downscaled viewport
  pageText?: string;
  circledText?: string;
  pageTitle?: string;
  pageUrl?: string;
  tutorMode: boolean;
  previousAnswer?: string;
  parentId?: number;
}

export type AskEvent =
  | { event: "start"; data: { id: number } }
  | { event: "meta"; data: Meta }
  | { event: "step"; data: Step }
  | { event: "done"; data: { id: number; steps: number; ms: number } }
  | { event: "error"; data: { message: string } };

export interface Settings {
  serverUrl: string;
  tutorMode: boolean;
  voiceOut: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  serverUrl: "http://localhost:8787",
  tutorMode: false,
  voiceOut: true,
};

export async function getSettings(): Promise<Settings> {
  const s = await chrome.storage.sync.get(DEFAULT_SETTINGS as unknown as Record<string, unknown>);
  return { ...DEFAULT_SETTINGS, ...s } as Settings;
}

// runtime messages
export type Msg =
  | { type: "PRESENT_CONVERSATION"; state: import("./conversation").ConversationSnapshot | null }
  | { type: "GET_CONVERSATION" }
  | { type: "CONVERSATION_ACTION"; sessionId: number; command: import("./conversation").ConversationAction }
  | { type: "PANEL_CLOSED" }
  | { type: "CAPTURE" }
  | { type: "TOGGLE_DRAW" }
  | { type: "START_DRAW" }
  | { type: "ASK_PAGE" }
  | { type: "OPEN_SIDEPANEL" }
  | { type: "LISTEN_START"; tabId?: number }
  | { type: "LISTEN_STOP" }
  | { type: "TRANSCRIPT"; text: string; final: boolean; tabId?: number }
  | { type: "LISTEN_STATE"; state: "listening" | "idle" | "unavailable"; detail?: string; tabId?: number }
  | { type: "ACTIVITY"; kind: "circle" | "question" | "answer"; text?: string }
  | { type: "OPEN_PDF_VIEWER" }
  | { type: "CLEAR_INK" };
