// Node `http` transport. Used for SSE inside Obsidian (desktop has Node
// integration; this sidesteps CORS for app://obsidian.md and lets us send the
// Authorization header, which EventSource cannot) and for everything in tests.

import * as http from "http";
import type { JsonResponse, Transport } from "./client";

function request(
  method: string,
  url: string,
  headers: Record<string, string>,
  body: string | undefined,
  signal?: AbortSignal,
): Promise<http.IncomingMessage> {
  return new Promise((resolve, reject) => {
    const h: Record<string, string | number> = { ...headers };
    if (body !== undefined) h["Content-Length"] = Buffer.byteLength(body);
    const req = http.request(url, { method, headers: h, signal }, resolve);
    req.on("error", reject);
    req.setTimeout(15000, () => req.destroy(new Error("timed out connecting")));
    if (body !== undefined) req.write(body);
    req.end();
  });
}

export const nodeTransport: Transport = {
  async json(method, url, headers, body): Promise<JsonResponse> {
    const res = await request(method, url, headers, body);
    res.setEncoding("utf8");
    let text = "";
    for await (const chunk of res) text += chunk as string;
    return { status: res.statusCode ?? 0, text };
  },

  async stream(method, url, headers, body, onText, signal) {
    const res = await request(method, url, headers, body, signal);
    // Streams are long-lived: no idle timeout once headers arrived.
    res.socket?.setTimeout(0);
    res.setEncoding("utf8");
    const done = new Promise<void>((resolve, reject) => {
      res.on("data", (c: string) => onText(c));
      res.on("end", () => resolve());
      res.on("error", reject);
      res.on("aborted", () => reject(new Error("connection closed")));
      signal.addEventListener("abort", () => {
        res.destroy();
        resolve();
      });
    });
    return { status: res.statusCode ?? 0, done };
  },
};
