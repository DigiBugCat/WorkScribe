import { imageContent, type NoteDocument, type Block } from "./anchors";
import { canonicalPath } from "./format";
// Tolerant decoders from untrusted JSON to the wire types. The app's API is
// being built in parallel, so these accept a few reasonable variants (noted
// inline) and never throw on missing optional fields. They throw ApiShapeError
// only when a required field is unusable.

import type {
  ActionItem,
  AskEvent,
  Discovery,
  Enhancement,
  Excerpt,
  LiveAnswer,
  LiveEvent,
  Meeting,
  MeetingSummary,
  MissedTopic,
  Moment,
  MomentKind,
  Note,
  NoteState,
  Segment,
  Status,
} from "./types";

export class ApiShapeError extends Error {
  constructor(what: string, detail: string) {
    super(`Unexpected ${what} from WorkScribe: ${detail}`);
    this.name = "ApiShapeError";
  }
}

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : typeof v === "number" ? String(v) : undefined);
const bool = (v: unknown, d = false): boolean => (typeof v === "boolean" ? v : d);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

/** Seconds from a number, a numeric string, or "mm:ss" / "h:mm:ss". */
export function seconds(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v !== "string" || v.trim() === "") return undefined;
  const s = v.trim();
  if (/^\d+(\.\d+)?$/.test(s)) return Number(s);
  const m = /^(?:(\d+):)?(\d{1,2}):(\d{2}(?:\.\d+)?)$/.exec(s);
  if (!m) return undefined;
  return Number(m[1] ?? 0) * 3600 + Number(m[2]) * 60 + Number(m[3]);
}

function need<T>(v: T | undefined, what: string, field: string): T {
  if (v === undefined) throw new ApiShapeError(what, `missing ${field}`);
  return v;
}

export function parseDiscovery(text: string): Discovery {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new ApiShapeError("api.json", "not valid JSON");
  }
  if (!isObj(raw)) throw new ApiShapeError("api.json", "not an object");
  const port = typeof raw.port === "number" ? raw.port : Number(raw.port);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new ApiShapeError("api.json", "bad port");
  const token = str(raw.token);
  if (!token) throw new ApiShapeError("api.json", "missing token");
  const version = raw.version ?? 1;
  if (version !== 1) throw new ApiShapeError("api.json", `unsupported version ${String(version)}`);
  return { port, token, version: 1 };
}

export function parseStatus(raw: unknown): Status {
  if (!isObj(raw)) throw new ApiShapeError("status", "not an object");
  const src = isObj(raw.sources) ? raw.sources : {};
  const perms = isObj(raw.permissions) ? raw.permissions : {};
  const startedAt = str(raw.startedAt);
  let elapsed = seconds(raw.elapsed);
  if (elapsed === undefined && startedAt) {
    const t = Date.parse(startedAt);
    elapsed = Number.isNaN(t) ? 0 : Math.max(0, (Date.now() - t) / 1000);
  }
  const s: Status = {
    recording: bool(raw.recording),
    phase: str(raw.phase),
    finalizationProgress: typeof raw.finalizationProgress === "number" ? raw.finalizationProgress : undefined,
    elapsed: elapsed ?? 0,
    sources: { mic: bool(src.mic), system: bool(src.system), screen: bool(src.screen) },
    permissions: {
      screenRecording: bool(perms.screenRecording, true),
      microphone: bool(perms.microphone, true),
    },
    warming: bool(raw.warming),
  };
  const meetingId = str(raw.meetingId);
  if (meetingId) s.meetingId = meetingId;
  const message = str(raw.message);
  if (message) s.message = message;
  const title = str(raw.title);
  if (title) s.title = title;
  if (startedAt) s.startedAt = startedAt;
  return s;
}

/** Speakers may be ["Priya"] or [{name:"Priya"}]. */
function speakerNames(v: unknown): string[] {
  return arr(v)
    .map((x) => (isObj(x) ? str(x.name) ?? str(x.label) : str(x)))
    .filter((x): x is string => !!x);
}

export function parseMeetingSummary(raw: unknown): MeetingSummary {
  if (!isObj(raw)) throw new ApiShapeError("meeting", "not an object");
  const m: MeetingSummary = {
    id: need(str(raw.id), "meeting", "id"),
    title: str(raw.title) ?? "Untitled meeting",
    startedAt: str(raw.startedAt) ?? "",
    duration: seconds(raw.duration) ?? 0,
    speakers: speakerNames(raw.speakers),
    status: str(raw.status) ?? "ready",
  };
  m.retention = str(raw.retention) as MeetingSummary["retention"];
  m.purgeAt = str(raw.purgeAt);
  const vp = str(raw.vaultPath);
  if (vp) m.vaultPath = vp;
  const link = str(raw.obsidianLink);
  if (link) m.obsidianLink = link;
  return m;
}

export function parseMeetingList(raw: unknown): MeetingSummary[] {
  // Accept a bare array or {meetings:[…]}.
  const list = Array.isArray(raw) ? raw : isObj(raw) ? arr(raw.meetings) : [];
  return list.map(parseMeetingSummary);
}

export function parseSegment(raw: unknown): Segment {
  if (!isObj(raw)) throw new ApiShapeError("segment", "not an object");
  const s: Segment = {
    id: need(str(raw.id), "segment", "id"),
    speaker: str(raw.speaker) ?? str(raw.speakerName) ?? "Speaker",
    start: seconds(raw.start) ?? 0,
    text: str(raw.text) ?? "",
    // `provisional: true` is accepted as the inverse of `final`.
    final: typeof raw.final === "boolean" ? raw.final : raw.provisional === true ? false : true,
  };
  const end = seconds(raw.end);
  if (end !== undefined) s.end = end;
  const sid = str(raw.speakerId) ?? str(raw.speakerKey);
  if (sid) s.speakerId = sid;
  if (typeof raw.source === 'string') s.source = raw.source;
  return s;
}

export function parseExcerpt(raw: unknown, i: number): Excerpt {
  const o = isObj(raw) ? raw : {};
  // `hollow: true` (meaning-only) is accepted in place of `match`.
  const match = o.match === "meaning" || o.hollow === true ? "meaning" : "time+meaning";
  const e: Excerpt = {
    id: str(o.id) ?? str(o.label) ?? str(o.ref) ?? `E${i + 1}`,
    speaker: str(o.speaker) ?? "Speaker",
    start: seconds(o.start) ?? seconds(o.at) ?? 0,
    quote: str(o.quote) ?? str(o.text) ?? "",
    match,
  };
  const seg = str(o.segmentId);
  if (seg) e.segmentId = seg;
  return e;
}

/** Enhancement as {topic,text} or a Markdown string like "**Topic.** text" / "* **Topic:** text". */
export function parseEnhancement(raw: unknown): Enhancement | null {
  if (raw == null) return null;
  if (isObj(raw)) {
    const text = str(raw.text) ?? "";
    const topic = str(raw.topic) ?? "";
    if (!text && !topic) return null;
    return { topic, text };
  }
  const s = str(raw);
  if (!s || !s.trim()) return null;
  const m = /^\s*(?:[*-]\s+)?\*\*(.+?)\*\*\s*(.*)$/s.exec(s);
  if (m) {
    let topic = m[1]!.trim();
    if (topic.endsWith(":")) topic = topic.slice(0, -1) + ".";
    else if (!/[.!?]$/.test(topic)) topic += ".";
    return { topic, text: m[2]!.trim() };
  }
  return { topic: "", text: s.trim() };
}

const NOTE_STATES: NoteState[] = ["pending", "enhancing", "done", "plain", "paused"];

export function parseNote(raw: unknown): Note {
  if (!isObj(raw)) throw new ApiShapeError("note", "not an object");
  const enhanced = parseEnhancement(raw.enhanced ?? raw.enhancement);
  const st = str(raw.state) ?? str(raw.status);
  const state: NoteState = NOTE_STATES.includes(st as NoteState)
    ? (st as NoteState)
    : enhanced
      ? "done"
      : "pending";
  // Excerpts may be under `excerpts` or `refs`.
  const excerpts = arr(raw.excerpts ?? raw.refs).map(parseExcerpt);
  const n: Note = {
    id: need(str(raw.id), "note", "id"),
    at: seconds(raw.at) ?? 0,
    text: str(raw.text) ?? str(raw.shorthand) ?? "",
    enhanced,
    state,
    excerpts, trace: parseTrace(raw.trace),
    images: arr(raw.images).filter(isObj).map(i => ({ target: str(i.target) ?? "", text: str(i.text), caption: str(i.caption), method: str(i.method), seconds: seconds(i.seconds) })),
  };
  // The parallel image pipeline supplies only evidence actually used by enhancement.
  // Keep this adapter at the wire boundary; native capture remains owned by that pipeline.
  const images=arr(raw.images).filter(isObj).filter(i=>typeof i.target==='string');
  if(images.length) {
    n.trace ??= {steps:[],revisions:[]};
    n.trace.sources=[...(n.trace.sources??[]),...images.map(i=>({kind:'image',title:str(i.target)!,
      text:[str(i.caption),str(i.text),str(i.method)?`Read on this Mac · ${str(i.method)?.includes('gemma')?'Gemma + OCR':str(i.method)}`:undefined, typeof i.seconds === 'number' ? `${i.seconds.toFixed(1)} s` : undefined].filter(Boolean).join('\n'),
      link:'obsidian://open?file='+encodeURIComponent(str(i.target)!)}))];
  }
  if (isObj(raw.fromAnswer)) {
    n.fromAnswer = {
      answerId: str(raw.fromAnswer.answerId) ?? "",
      question: str(raw.fromAnswer.question) ?? "",
    };
    const by = str(raw.fromAnswer.askedBy);
    if (by) n.fromAnswer.askedBy = by;
  }
  const hint = str(raw.hint);
  if (hint) n.hint = hint;
  const block = str(raw.blockId) ?? str(raw.blockID);
  if (block) n.blockId = block.replace(/^\^/, "");
  n.userEdited = bool(raw.userEdited);
  return n;
}

const KINDS: MomentKind[] = ["meeting", "note", "clip", "pdf", "document", "audio", "video", "image", "screen"];

export function parseMoment(raw: unknown): Moment {
  if (!isObj(raw)) throw new ApiShapeError("moment", "not an object");
  const k = raw.kind === "meetingSegment" ? "meeting" : str(raw.kind) ?? "document";
  const m: Moment = {
    kind: KINDS.includes(k as MomentKind) ? (k as MomentKind) : "document",
    title: str(raw.title) ?? str(raw.name) ?? "Untitled",
  };
  const opt = <K extends keyof Moment>(key: K, v: Moment[K] | undefined) => {
    if (v !== undefined && v !== "") m[key] = v;
  };
  opt("snippet", str(raw.snippet));
  opt("meetingId", str(raw.meetingId));
  opt("path", str(raw.path));
  opt("start", seconds(raw.start));
  opt("page", typeof raw.page === "number" ? raw.page : seconds(raw.page));
  opt("speaker", str(raw.speaker));
  opt("thumbnail", str(raw.thumbnail));
  opt("link", str(raw.link));
  opt("date", str(raw.date));
  return m;
}

export function parseMoments(raw: unknown): Moment[] {
  const list = Array.isArray(raw) ? raw : isObj(raw) ? arr(raw.moments ?? raw.results) : [];
  return list.map(parseMoment);
}

export function parseAnswer(raw: unknown): LiveAnswer {
  if (!isObj(raw)) throw new ApiShapeError("answer", "not an object");
  const a: LiveAnswer = {
    id: need(str(raw.id), "answer", "id"),
    at: seconds(raw.at) ?? 0,
    question: str(raw.question) ?? "",
    askedOfYou: raw.askedOfYou === true,
    answer: str(raw.answer) ?? "",
    citations: arr(raw.citations).map(parseMoment),
    done: bool(raw.done, true), trace: parseTrace(raw.trace),
  };
  const by = str(raw.askedBy);
  if (by) a.askedBy = by;
  return a;
}

function parseAction(raw: unknown): ActionItem {
  const o = isObj(raw) ? raw : {};
  const a: ActionItem = { owner: str(o.owner) ?? "Unassigned", text: str(o.text) ?? str(o.action) ?? "" };
  const by = str(o.askedBy);
  if (by) a.askedBy = by;
  const q = str(o.quote);
  if (q) a.quote = q;
  const at = seconds(o.at);
  if (at !== undefined) a.at = at;
  const due = str(o.due);
  if (due) a.due = due;
  if (typeof o.done === "boolean") a.done = o.done;
  return a;
}

function parseMissed(raw: unknown): MissedTopic {
  const o = isObj(raw) ? raw : {};
  const t: MissedTopic = { topic: str(o.topic) ?? "", text: str(o.text) ?? "" };
  const sp = str(o.speaker);
  if (sp) t.speaker = sp;
  const s = seconds(o.start);
  if (s !== undefined) t.start = s;
  const e = seconds(o.end);
  if (e !== undefined) t.end = e;
  return t;
}

export function parseMeeting(raw: unknown): Meeting {
  const o = raw as Obj;
  const base = parseMeetingSummary(isObj(o.meeting) ? o.meeting : raw);
  const m: Meeting = {
    ...base,
    endedAt: str(o.endedAt),
    segments: arr(o.segments).map(parseSegment),
    notes: arr(o.notes).map(parseNote),
    missedTopics: arr(o.missedTopics).map(parseMissed),
    actionItems: arr(o.actionItems).map(parseAction),
    answers: arr(o.answers).map(parseAnswer),
  };
  if (o.document != null) m.document = parseDocument(o.document);
  const brief = str(o.brief);
  if (brief) m.brief = brief;
  return m;
}

function parseJson(data: string): unknown {
  try {
    return JSON.parse(data);
  } catch {
    return undefined;
  }
}

/**
 * Decode one /v1/events SSE message. Payloads may be the bare object
 * (`event: segment` / `data: {segment fields…, meetingId}`) or wrapped
 * (`data: {meetingId, segment:{…}}`). Unknown events return null.
 */
export function parseLiveEvent(event: string, data: string): LiveEvent | null {
  const raw = parseJson(data);
  if (!isObj(raw)) return null;
  const type = event === "message" ? str(raw.type) ?? "" : event;
  const meetingId = str(raw.meetingId) ?? "";
  try {
    switch (type) {
      case "meeting.purged":
        return { type: "purged", meetingId: need(str(raw.meetingId), "purged", "meetingId") };
      case "status":
        return { type, status: parseStatus(raw.status ?? raw) };
      case "segment":
      case "transcript":
        return { type: "segment", meetingId, segment: parseSegment(raw.segment ?? raw) };
      case "note":
      case "enhancement.note":
        return { type: "note", meetingId, note: parseNote(raw.note ?? raw) };
      case "notes":
        return { type, meetingId, ...(raw.documentFinalized === true ? { documentFinalized: true } : {}), notes: arr(raw.notes).map(parseNote),
          missedTopics: arr(raw.missedTopics).map(parseMissed), actionItems: arr(raw.actionItems).map(parseAction) };
      case "clip":
        return { type, clip: raw as unknown as import("./types").Clip };
      case "ask_request":
        if (!isObj(raw.clip)) return null;
        return { type, clip: raw.clip as unknown as import("./types").Clip, question: str(raw.question), untrusted: true };
      case "continue":
        return { type, conversationId: need(str(raw.conversationId), "continue", "conversationId"),
          title: str(raw.title) ?? "Conversation", meetingId: str(raw.meetingId), markdown: str(raw.markdown) ?? "" };
      case "enhancement":
        return { type, meetingId, upToDate: bool(raw.upToDate) };
      case "answer":
      case "live_answer": {
        const ev: LiveEvent = { type: "answer", answer: parseAnswer(isObj(raw.answer) ? raw.answer : raw) };
        if (meetingId) ev.meetingId = meetingId;
        return ev;
      }
      case "screen":
        return { type, meetingId, moment: parseMoment(raw.moment ?? { kind: "screen", ...raw, snippet: raw.text, title: raw.app ?? raw.window ?? "Screen" }) };
      default:
        return null;
    }
  } catch {
    return null;
  }
}

/** Decode one /v1/ask SSE message. A plain-text token (non-JSON data) is accepted for `token`. */
export function parseAskEvent(event: string, data: string): AskEvent | null {
  const raw = parseJson(data);
  const type = event === "message" && isObj(raw) ? str(raw.type) ?? "token" : event;
  switch (type) {
    case "token":
    case "message":
      if (isObj(raw)) return { type: "token", text: str(raw.text) ?? str(raw.token) ?? "" };
      if (typeof raw === "string") return { type: "token", text: raw };
      return { type: "token", text: data };
    case "trace": {const trace=parseTrace(raw);return trace?{type:"trace",trace}:null;}
    case "citations":
      return { type, citations: parseMoments(isObj(raw) ? raw.citations : raw),
        ...(isObj(raw) ? { answer: str(raw.answer), conversationId: str(raw.conversationId), state: str(raw.state), detail: str(raw.detail), trace: parseTrace(raw.trace) } : {}) };
    case "done": {
      const ev: AskEvent = { type };
      const cid = isObj(raw) ? str(raw.conversationId) : undefined;
      if (cid) ev.conversationId = cid;
      return ev;
    }
    case "error":
      return { type, message: (isObj(raw) ? str(raw.message) : undefined) ?? data };
    default:
      return null;
  }
}

export function parseDocument(raw: unknown): NoteDocument {
  if (!isObj(raw) || typeof raw.path !== "string" || typeof raw.source !== "string" ||
      !Number.isSafeInteger(raw.revision) || Number(raw.revision) < 0 || !Array.isArray(raw.blocks))
    throw new ApiShapeError("document", "invalid snapshot");
  let end = 0; const ids = new Set<string>();
  const blocks: Block[] = raw.blocks.map((b: unknown) => {
    if (!isObj(b) || typeof b.id !== "string" || !b.id || ids.has(b.id) ||
        !Number.isSafeInteger(b.from) || !Number.isSafeInteger(b.to) || Number(b.from) < end ||
        Number(b.to) <= Number(b.from) || Number(b.to) > (raw.source as string).length ||
        typeof b.text !== "string" || (raw.source as string).slice(Number(b.from), Number(b.to)) !== b.text)
      throw new ApiShapeError("document", "invalid block");
    ids.add(b.id); end = Number(b.to);
    const block: Block = { id: b.id, from: Number(b.from), to: end, text: b.text, ...imageContent(b.text) };
    if (Array.isArray(b.images)) block.images = b.images.filter(isObj).filter(i => typeof i.target === "string").map(i => ({ target: String(i.target), path: str(i.path) }));
    if (typeof b.at === "number" && Number.isFinite(b.at) && b.at >= 0) block.at = b.at;
    if (typeof b.section === "string") block.section = b.section;
    if (b.owned != null) {
      const o = b.owned;
      if (!isObj(o) || !Number.isSafeInteger(o.from) || !Number.isSafeInteger(o.to) || Number(o.from) < end ||
          Number(o.to) < Number(o.from) || Number(o.to) > (raw.source as string).length || typeof o.text !== "string" ||
          !o.text.length || (raw.source as string).slice(Number(o.from), Number(o.to)) !== o.text)
        throw new ApiShapeError("document", "invalid owned range");
      block.owned = { from: Number(o.from), to: Number(o.to), text: o.text }; end = Number(o.to);
    }
    return block;
  });
  return { path: canonicalPath(raw.path), source: raw.source, revision: Number(raw.revision), blocks, insertions:arr(raw.insertions).filter(isObj).filter(i=>typeof i.at==='number'&&typeof i.text==='string').map(i=>({at:i.at as number,text:i.text as string})), finalized: raw.finalized === true };
}

export function parseTrace(raw: unknown): import('./types').AITrace | undefined {
  if (!isObj(raw)) return undefined;
  return { ...(Array.isArray(raw.sources)?{sources:raw.sources.filter(isObj).map(s=>({kind:str(s.kind)??'',title:str(s.title)??'',text:str(s.text)??'',link:str(s.link)??'',thumbnail:str(s.thumbnail),start:typeof s.start==='number'?s.start:undefined,end:typeof s.end==='number'?s.end:undefined}))}:{}), model: str(raw.model), location: str(raw.location), durationMs: typeof raw.durationMs === 'number' ? raw.durationMs : undefined,
    steps: arr(raw.steps).filter(isObj).map(s => ({title: str(s.title) ?? '', status: str(s.status) ?? 'complete', detail: str(s.detail)})),
    revisions: arr(raw.revisions).filter(isObj).map(v => ({version: typeof v.version === 'number' ? v.version : 1, text: str(v.text) ?? '', reason: str(v.reason) ?? '', at: str(v.at) ?? ''})) };
}
