// Wire types for the WorkScribe local HTTP API (version 1).
// Pure module: no `obsidian` import, so it can be unit-tested under node.
// Times: `startedAt`/`at` on wall clock are ISO-8601 strings; offsets inside a
// meeting (`start`, `end`, note `at` when numeric) are seconds from meeting start.

export interface Discovery {
  port: number;
  token: string;
  version: 1;
}

export interface Sources {
  mic: boolean;
  system: boolean;
  screen: boolean;
}

export interface Status {
  phase?: string;
  finalizationProgress?: number;
  recording: boolean;
  meetingId?: string;
  title?: string;
  startedAt?: string;
  /** Seconds since the recording started (0 when idle). */
  elapsed: number;
  sources: Sources;
  permissions: { screenRecording: boolean; microphone: boolean };
  /** Models still loading; recording may start but enhancement/answers lag. */
  warming: boolean;
  message?: string;
}

export interface MeetingSummary {
  id: string;
  title: string;
  startedAt: string;
  /** Seconds. */
  duration: number;
  speakers: string[];
  status: "recording" | "processing" | "ready" | string;
  vaultPath?: string;
  obsidianLink?: string;
  retention?: "live" | "finalized" | "purged" | "purging";
  purgeAt?: string;
}

export interface Segment {
  id: string;
  speaker: string;
  speakerId?: string;
  source?: string;
  /** Seconds from meeting start. */
  start: number;
  end?: number;
  text: string;
  /** Provisional segments are replaced (same id) by their final version. */
  final: boolean;
}

/** How an excerpt was matched to a note: inside the typing window and by meaning, or by meaning only (hollow tag). */
export type ExcerptMatch = "time+meaning" | "meaning";

export interface Excerpt {
  /** "E1", "E2"… numbered per meeting. */
  id: string;
  segmentId?: string;
  speaker: string;
  start: number;
  quote: string;
  match: ExcerptMatch;
}

export interface Enhancement {
  /** Bold lead, e.g. "Conflict resolution." */
  topic: string;
  text: string;
}

export type NoteState = "pending" | "enhancing" | "done" | "plain" | "paused";

export interface AITrace {
  sources?: {kind:string;title:string;text:string;link:string;thumbnail?:string;start?:number;end?:number}[];
  steps: { title: string; status: string; detail?: string }[];
  model?: string; location?: string; durationMs?: number;
  revisions: { version: number; text: string; reason: string; at: string }[];
}
export interface Note {
  trace?: AITrace;
  images?: { target: string; text?: string; caption?: string; method?: string; seconds?: number }[];
  id: string;
  /** Seconds from meeting start when the line was typed. */
  at: number;
  text: string;
  enhanced?: Enhancement | null;
  userEdited?: boolean;
  state: NoteState;
  excerpts: Excerpt[];
  /** Set when the line came from a live answer ("Add to notes"). */
  fromAnswer?: { answerId: string; askedBy?: string; question: string } | null;
  /** Explanation shown when there is no enhancement, e.g. "No matching speech yet." */
  hint?: string;
  /** Block id of this note's line in the meeting's vault note ("e1" → `^e1`), when the app knows it. */
  blockId?: string;
}

/** PATCH /v1/meetings/:id/notes/:noteId body: edit what you typed, or the enhanced text. */
export type NotePatch = { text: string } | { enhanced: Enhancement } | { rewrite: true };

export type MomentKind =
  | "meeting"
  | "note"
  | "clip"
  | "pdf"
  | "document"
  | "audio"
  | "video"
  | "image"
  | "screen";

export interface Moment {
  kind: MomentKind;
  title: string;
  snippet?: string;
  meetingId?: string;
  /** Absolute path on disk (vault files are recognised and opened in Obsidian). */
  path?: string;
  /** Seconds into a meeting/audio/video. */
  start?: number;
  page?: number;
  speaker?: string;
  /** data: URL or http(s) URL served by the app. */
  thumbnail?: string;
  /** Canonical link from the app (workscribe://…, file://…, https://…). */
  link?: string;
  /** Optional wall-clock time of the moment (ISO) for display. */
  date?: string;
}

export interface LiveAnswer {
  askedOfYou?: boolean;
  trace?: AITrace;
  id: string;
  /** Seconds from meeting start. */
  at: number;
  askedBy?: string;
  question: string;
  /** May contain citation markers [1] or [Source:1]; 1-based into citations. */
  answer: string;
  citations: Moment[];
  /** False while the answer is still streaming. */
  done: boolean;
}

export interface ActionItem {
  owner: string;
  text: string;
  askedBy?: string;
  quote?: string;
  at?: number;
  due?: string;
  done?: boolean;
}

export interface MissedTopic {
  topic: string;
  text: string;
  speaker?: string;
  start?: number;
  end?: number;
}

export interface Meeting extends MeetingSummary {
  endedAt?: string;
  document?: import("./anchors").NoteDocument;
  brief?: string;
  segments: Segment[];
  notes: Note[];
  missedTopics: MissedTopic[];
  actionItems: ActionItem[];
  answers: LiveAnswer[];
}

/** Events on GET /v1/events. SSE `event:` name = `type`; `data:` = JSON payload. */
export interface Clip {
  id: string;
  title: string;
  path: string;
  url?: string;
  meetingID?: string;
}

export type LiveEvent =
  | { type: "purged"; meetingId: string }
  | { type: "status"; status: Status }
  | { type: "segment"; meetingId: string; segment: Segment }
  | { type: "note"; meetingId: string; note: Note }
  | { type: "notes"; meetingId: string; notes: Note[]; missedTopics: MissedTopic[]; actionItems: ActionItem[]; documentFinalized?: boolean }
  | { type: "clip"; clip: Clip }
  | { type: "ask_request"; clip: Clip; question?: string; untrusted: true }
  | { type: "continue"; conversationId: string; title: string; meetingId?: string; markdown: string }
  | { type: "enhancement"; meetingId: string; upToDate: boolean }
  | { type: "answer"; meetingId?: string; answer: LiveAnswer }
  | { type: "screen"; meetingId: string; moment: Moment };

/** Events on POST /v1/ask (SSE). */
export type AskEvent =
  | {type:"trace";trace:AITrace}
  | { type: "token"; text: string }
  | { type: "citations"; trace?: AITrace; citations: Moment[]; answer?: string; conversationId?: string; state?: string; detail?: string }
  | { type: "done"; conversationId?: string }
  | { type: "error"; message: string };

export type Attachment = { path: string; name?: string } | { text: string; name?: string };

export interface AskRequest {
  question: string;
  meetingId?: string;
  conversationId?: string;
  attachments?: Attachment[];
}
