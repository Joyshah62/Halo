// Load before SDKs: some capture the global fetch implementation at import time.
// Node 24's bundled Undici can crash when a peer sends FIN while the body parser
// is paused. The pinned dependency includes nodejs/undici#5474's parser fix.
import { fetch, Headers, Request, Response, FormData } from "undici";

Object.assign(globalThis, { fetch, Headers, Request, Response, FormData });
