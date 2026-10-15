// WorkScribe API client. Transport-agnostic: the plugin plugs in Obsidian's
// requestUrl (JSON) + Node http (SSE streaming); tests plug in Node http only.

import { SseParser } from "./sse";
import {
  ApiShapeError,
  parseAskEvent,
  parseLiveEvent,
  parseMeeting,
  parseMeetingList,
  parseMoments,
  parseNote,
  parseDocument,
  parseStatus,
} from "./parse";
import type { AskEvent, AskRequest, Attachment, Discovery, LiveEvent, Meeting, MeetingSummary, Moment, MomentKind, Note, NotePatch, Status } from "./types";

export interface JsonResponse {
  status: number;
  text: string;
}

export interface Transport {
  json(method: string, url: string, headers: Record<string, string>, body?: string): Promise<JsonResponse>;
  /** Resolve with the HTTP status once headers arrive; then feed body text to onText until the stream ends (onEnd). */
  stream(
    method: string,
    url: string,
    headers: Record<string, string>,
    body: string | undefined,
    onText: (chunk: string) => void,
    signal: AbortSignal,
  ): Promise<{ status: number; done: Promise<void> }>;
}

export type ApiErrorKind = "offline" | "auth" | "http" | "shape" | "aborted";

export class ApiError extends Error {
  constructor(
    readonly kind: ApiErrorKind,
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export const NOT_RUNNING = "WorkScribe isn't running";

export class WorkScribeClient {
  constructor(
    private readonly transport: Transport,
    private readonly discover: () => Promise<Discovery>,
  ) {}

  private async base(): Promise<{ url: string; headers: Record<string, string> }> {
    let d: Discovery;
    try {
      d = await this.discover();
    } catch (e) {
      if (e instanceof ApiError) throw e;
      throw new ApiError("offline", `${NOT_RUNNING} (${(e as Error).message})`);
    }
    return {
      url: `http://127.0.0.1:${d.port}`,
      headers: { Authorization: `Bearer ${d.token}`, Accept: "application/json" },
    };
  }

  private async call(method: string, path: string, body?: unknown): Promise<unknown> {
    const { url, headers } = await this.base();
    const h = { ...headers };
    let payload: string | undefined;
    if (body !== undefined) {
      h["Content-Type"] = "application/json";
      payload = JSON.stringify(body);
    }
    let res: JsonResponse;
    try {
      res = await this.transport.json(method, url + path, h, payload);
    } catch (e) {
      throw new ApiError("offline", `${NOT_RUNNING} (${(e as Error).message})`);
    }
    return decodeJson(res, `${method} ${path}`);
  }

  async status(): Promise<Status> {
    return wrapShape(() => this.call("GET", "/v1/status").then(parseStatus));
  }

  async resumeRecording(id: string): Promise<Status> {
    return parseStatus(await this.call("POST", `/v1/meetings/${encodeURIComponent(id)}/resume`, {}));
  }

  async startRecording(title?: string): Promise<Status | null> {
    const raw = await this.call("POST", "/v1/recording/start", title ? { title } : {});
    return safe(() => parseStatus(raw));
  }

  async stopRecording(): Promise<Status | null> {
    const raw = await this.call("POST", "/v1/recording/stop", {});
    return safe(() => parseStatus(raw));
  }

  grabMoment(id: string): Promise<unknown> { return this.call('POST', `/v1/meetings/${encodeURIComponent(id)}/grab-moment`, {}); }

  async openDocument(id: string): Promise<import("./anchors").NoteDocument> {
    return wrapShape(() => this.call("POST", `/v1/meetings/${encodeURIComponent(id)}/document`, {}).then(parseDocument));
  }
  async syncDocument(id: string, document: import("./anchors").NoteDocument): Promise<import("./anchors").NoteDocument> {
    return wrapShape(() => this.call("PATCH", `/v1/meetings/${encodeURIComponent(id)}/document`, document).then(parseDocument));
  }
  async finalizeDocument(id: string): Promise<import("./anchors").NoteDocument> {
    return wrapShape(() => this.call("POST", `/v1/meetings/${encodeURIComponent(id)}/finalize`, {}).then(parseDocument));
  }

  async meetings(limit = 20): Promise<MeetingSummary[]> {
    return wrapShape(() => this.call("GET", `/v1/meetings?limit=${limit}`).then(parseMeetingList));
  }

  async meeting(id: string): Promise<Meeting> {
    return wrapShape(() => this.call("GET", `/v1/meetings/${encodeURIComponent(id)}`).then(parseMeeting));
  }

  async addNote(meetingId: string, text: string, at?: number, extra?: Record<string, unknown>): Promise<Note> {
    const body: Record<string, unknown> = { text, ...extra };
    if (at !== undefined) body.at = Math.round(at * 10) / 10;
    return wrapShape(() => this.call("POST", `/v1/meetings/${encodeURIComponent(meetingId)}/notes`, body).then(unwrap("note")).then(parseNote));
  }

  async editNote(meetingId: string, noteId: string, text: string): Promise<Note> {
    return this.patchNote(meetingId, noteId, { text });
  }

  /** `{text}` edits the shorthand (and re-enhances); `{enhanced:{topic,text}}` saves your edit of the enhanced line. */
  async done(id: string): Promise<void> {
    await this.call("POST", `/v1/meetings/${encodeURIComponent(id)}/done`, {});
  }

  async patchNote(meetingId: string, noteId: string, patch: NotePatch): Promise<Note> {
    return wrapShape(() =>
      this.call("PATCH", `/v1/meetings/${encodeURIComponent(meetingId)}/notes/${encodeURIComponent(noteId)}`, patch)
        .then(unwrap("note"))
        .then(parseNote),
    );
  }

  async search(query: string, kinds?: MomentKind[], limit = 20): Promise<Moment[]> {
    const body: Record<string, unknown> = { query, limit };
    if (kinds && kinds.length) body.kinds = kinds;
    return wrapShape(() => this.call("POST", "/v1/search", body).then(parseMoments));
  }

  async attach(target: { meetingId?: string; conversationId?: string }, a: Attachment): Promise<unknown> {
    return this.call("POST", "/v1/attachments", { ...target, ...a });
  }

  /** Stream an answer. Resolves when the stream finishes; events arrive through onEvent. */
  async ask(req: AskRequest, onEvent: (ev: AskEvent) => void, signal: AbortSignal): Promise<void> {
    const { done } = await this.openStream("POST", "/v1/ask", req, signal, (event, data) => {
      const ev = parseAskEvent(event, data);
      if (ev) onEvent(ev);
    });
    await done;
  }

  /** Subscribe to /v1/events. Resolves when connected, with `done` settling when the stream ends. */
  async events(onEvent: (ev: LiveEvent) => void, signal: AbortSignal): Promise<{ done: Promise<void> }> {
    return this.openStream("GET", "/v1/events", undefined, signal, (event, data) => {
      const ev = parseLiveEvent(event, data);
      if (ev) onEvent(ev);
    });
  }

  private async openStream(
    method: string,
    path: string,
    body: unknown,
    signal: AbortSignal,
    onMessage: (event: string, data: string) => void,
  ): Promise<{ done: Promise<void> }> {
    const { url, headers } = await this.base();
    const h: Record<string, string> = { ...headers, Accept: "text/event-stream" };
    let payload: string | undefined;
    if (body !== undefined) {
      h["Content-Type"] = "application/json";
      payload = JSON.stringify(body);
    }
    const parser = new SseParser((m) => onMessage(m.event, m.data));
    let errText = "";
    let failed = false;
    let res: { status: number; done: Promise<void> };
    try {
      res = await this.transport.stream(method, url + path, h, payload, (chunk) => (failed ? (errText += chunk) : parser.push(chunk)), signal);
    } catch (e) {
      if (signal.aborted) throw new ApiError("aborted", "Cancelled");
      throw new ApiError("offline", `${NOT_RUNNING} (${(e as Error).message})`);
    }
    if (res.status >= 400) {
      failed = true;
      await res.done.catch(() => undefined);
      throw httpError(res.status, errText, `${method} ${path}`);
    }
    // Wrapped in an object so the async function doesn't adopt (and wait for) the inner promise.
    return {
      done: res.done.then(
        () => parser.end(),
        (e: unknown) => {
          parser.end();
          if (signal.aborted) return;
          throw new ApiError("offline", `Stream ended: ${(e as Error).message}`);
        },
      ),
    };
  }
}

function unwrap(key: string) {
  return (raw: unknown): unknown =>
    typeof raw === "object" && raw !== null && key in raw ? (raw as Record<string, unknown>)[key] : raw;
}

function safe<T>(f: () => T): T | null {
  try {
    return f();
  } catch {
    return null;
  }
}

async function wrapShape<T>(f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof ApiShapeError) throw new ApiError("shape", e.message);
    throw e;
  }
}

function httpError(status: number, text: string, what: string): ApiError {
  let msg = text.trim();
  try {
    const j = JSON.parse(text) as { error?: unknown; message?: unknown };
    msg = String(j.error ?? j.message ?? msg);
  } catch {
    /* plain text */
  }
  if (status === 401 || status === 403) return new ApiError("auth", "WorkScribe rejected the token in api.json. Restart WorkScribe or check the api.json path.", status);
  return new ApiError("http", `${what} failed (${status})${msg ? `: ${msg.slice(0, 200)}` : ""}`, status);
}

export function decodeJson(res: JsonResponse, what: string): unknown {
  if (res.status >= 400) throw httpError(res.status, res.text, what);
  if (res.status === 204 || res.text.trim() === "") return {};
  try {
    return JSON.parse(res.text);
  } catch {
    throw new ApiError("shape", `${what} returned non-JSON`);
  }
}
