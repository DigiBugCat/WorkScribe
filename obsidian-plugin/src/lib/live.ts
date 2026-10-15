// Live meeting state: a small reducer over /v1/events plus the optimistic
// jots the user typed, and the row alignment the editor renders.
// Pure (no DOM, no obsidian) so it is unit-tested.

import type { ActionItem, MissedTopic, LiveAnswer, LiveEvent, Meeting, Moment, Note, Segment, Status } from "./types";

export interface PendingJot {
  clientId: string;
  text: string;
  /** Seconds from meeting start when Enter was pressed. */
  at: number;
  error?: string;
}

/** One row of the two-pane editor: shorthand on the left, what it became on the right. */
export interface Row {
  key: string;
  at: number;
  text: string;
  note?: Note;
  pending?: PendingJot;
}

/** Rows ordered by typing time (stable for ties), pending jots folded in, duplicates dropped. */
export function alignRows(notes: Iterable<Note>, pending: Iterable<PendingJot>): Row[] {
  const rows: Row[] = [];
  const confirmed = [...notes];
  for (const n of confirmed) rows.push({ key: n.id, at: n.at, text: n.text, note: n });
  for (const p of pending) {
    // If the server's note already arrived over SSE before the POST returned, don't show it twice.
    const dup = confirmed.some((n) => n.text.trim() === p.text.trim() && Math.abs(n.at - p.at) <= 5);
    if (!dup) rows.push({ key: p.clientId, at: p.at, text: p.text, pending: p });
  }
  return rows;
}

export interface LiveState {
  status: Status | null;
  purgeAt?: string;
  endedAt?: string;
  retention?: string;
  meetingId: string | null;
  title: string;
  segments: Segment[];
  notes: Map<string, Note>;
  missedTopics: MissedTopic[];
  actionItems: ActionItem[];
  pending: PendingJot[];
  /** The single live-answer slot: newer answers replace older ones. */
  answer: LiveAnswer | null;
  answers: LiveAnswer[];
  dismissedAnswerId: string | null;
  upToDate: boolean;
  screens: Moment[];
}

export function emptyLive(): LiveState {
  return {
    status: null,
    meetingId: null,
    title: "",
    segments: [],
    notes: new Map(),
    missedTopics: [],
    actionItems: [],
    pending: [],
    answer: null,
    answers: [],
    dismissedAnswerId: null,
    upToDate: true,
    screens: [],
  };
}

/** Load a full meeting (GET /v1/meetings/:id) into the state, e.g. when the view opens mid-call. */
export function loadMeeting(state: LiveState, m: Meeting): void {
  state.meetingId = m.id;
  state.title = m.title;
  state.purgeAt=m.purgeAt;state.retention=m.retention;state.endedAt=m.endedAt;
  state.segments = [...m.segments].sort((a, b) => a.start - b.start);
  state.notes = new Map(m.notes.map((n) => [n.id, n]));
  state.missedTopics = m.missedTopics;
  state.actionItems = m.actionItems;
  state.pending = [];
  const last = m.answers[m.answers.length - 1];
  state.answer = last ?? null;
  state.answers = [...m.answers];
  state.upToDate = m.notes.every((n) => n.state !== "pending" && n.state !== "enhancing");
}

export type Change = "status" | "meeting" | "segments" | "notes" | "answer" | "enhancement" | "screen";

/** Apply one event; returns what changed (empty when the event was for another meeting). */
export function applyEvent(state: LiveState, ev: LiveEvent): Set<Change> {
  const changed = new Set<Change>();
  if (ev.type === "status") {
    const s = ev.status;
    state.status = s;
    changed.add("status");
    if (s.recording && s.meetingId && s.meetingId !== state.meetingId) {
      Object.assign(state, emptyLive(), { status: s });
      state.meetingId = s.meetingId;
      state.title = s.title ?? "Meeting";
      changed.add("meeting");
    } else if (s.title && s.title !== state.title && s.meetingId === state.meetingId) {
      state.title = s.title;
      changed.add("meeting");
    }
    return changed;
  }
  const mid = "meetingId" in ev ? ev.meetingId : undefined;
  if (mid && state.meetingId && mid !== state.meetingId) return changed;
  if (mid && !state.meetingId) state.meetingId = mid;

  switch (ev.type) {
    case "purged":
      Object.assign(state, emptyLive(), { status: state.status });
      for (const key of ["meeting", "notes", "segments", "screen", "answer", "enhancement"] as Change[]) changed.add(key);
      break;
    case "segment": {
      const seg = ev.segment;
      const i = state.segments.findIndex((s) => s.id === seg.id);
      if (i >= 0) state.segments[i] = seg;
      else {
        // Usually appended at the end; keep order by start for late finals.
        let j = state.segments.length;
        while (j > 0 && state.segments[j - 1]!.start > seg.start) j--;
        state.segments.splice(j, 0, seg);
      }
      changed.add("segments");
      break;
    }
    case "notes":
      state.notes = new Map(ev.notes.map((n) => [n.id, n]));
      state.missedTopics = ev.missedTopics;
      state.actionItems = ev.actionItems;
      state.upToDate = ev.notes.every((n) => n.state !== "pending" && n.state !== "enhancing");
      changed.add("notes");
      changed.add("enhancement");
      break;
    case "note": {
      const prev = state.notes.get(ev.note.id);
      // Keep an existing enhancement if an update arrives without one (e.g. text edit echo).
      const note = prev && !ev.note.enhanced && prev.enhanced && ev.note.state !== "plain"
        ? { ...ev.note, enhanced: prev.enhanced }
        : ev.note;
      state.notes.set(note.id, note);
      changed.add("notes");
      break;
    }
    case "enhancement":
      state.upToDate = ev.upToDate;
      changed.add("enhancement");
      break;
    case "answer":
      if (ev.answer.id === state.dismissedAnswerId) break;
      const index=state.answers.findIndex(a=>a.id===ev.answer.id);
      if(index<0)state.answers.push(ev.answer);else state.answers[index]=ev.answer;
      // One slot: an update for the same id or any newer answer replaces it.
      if (!state.answer || state.answer.id === ev.answer.id || ev.answer.at >= state.answer.at) {
        state.answer = ev.answer;
        changed.add("answer");
      }
      break;
    case "screen":
      state.screens.push(ev.moment);
      if (state.screens.length > 50) state.screens.shift();
      changed.add("screen");
      break;
  }
  return changed;
}

/** Mark a pending jot as confirmed by the server's note. */
export function confirmJot(state: LiveState, clientId: string, note: Note): void {
  state.pending = state.pending.filter((p) => p.clientId !== clientId);
  const prev = state.notes.get(note.id);
  // SSE may already have delivered a newer version (with enhancement): keep it.
  if (!prev || (!prev.enhanced && note.enhanced)) state.notes.set(note.id, note);
}

export function failJot(state: LiveState, clientId: string, error: string): void {
  const p = state.pending.find((x) => x.clientId === clientId);
  if (p) p.error = error;
}

/** Seconds into the meeting right now, from the last status and the local clock. */
export function liveElapsed(status: Status | null, receivedAtMs: number, nowMs: number): number {
  if (!status || !status.recording) return 0;
  if (status.startedAt) {
    const t = Date.parse(status.startedAt);
    if (!Number.isNaN(t)) return Math.max(0, (nowMs - t) / 1000);
  }
  return status.elapsed + Math.max(0, (nowMs - receivedAtMs) / 1000);
}
