// Transport inside Obsidian: requestUrl for JSON (no CORS, desktop + main
// process networking) and Node http for SSE streams (headers + no CORS).
// If Node http is unavailable for any reason, streams fall back to fetch with a
// ReadableStream reader, which needs the app to allow Origin app://obsidian.md.

import { requestUrl } from "obsidian";
import type { Transport } from "../lib/client";
import { nodeTransport } from "../lib/node-transport";

async function fetchStream(
  method: string,
  url: string,
  headers: Record<string, string>,
  body: string | undefined,
  onText: (chunk: string) => void,
  signal: AbortSignal,
): Promise<{ status: number; done: Promise<void> }> {
  const init: RequestInit = { method, headers, signal };
  if (body !== undefined) init.body = body;
  const res = await fetch(url, init);
  const reader = res.body?.getReader();
  const decoder = new TextDecoder();
  const done = (async () => {
    if (!reader) return;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        onText(decoder.decode(value, { stream: true }));
      }
    } catch (e) {
      if (!signal.aborted) throw e;
    }
  })();
  return { status: res.status, done };
}

function hasNodeHttp(): boolean {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    return typeof require === "function" && !!require("http");
  } catch {
    return false;
  }
}

export function obsidianTransport(): Transport {
  const node = hasNodeHttp();
  return {
    async json(method, url, headers, body) {
      const res = await requestUrl({ url, method, headers, ...(body !== undefined ? { body } : {}), throw: false });
      return { status: res.status, text: res.text };
    },
    stream: node ? nodeTransport.stream : fetchStream,
  };
}
