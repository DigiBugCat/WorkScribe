import { test } from "node:test";
import assert from "node:assert/strict";
import { alignRows, applyEvent, confirmJot, emptyLive, failJot, liveElapsed, loadMeeting } from "../src/lib/live";
import type { LiveAnswer, Note, Status } from "../src/lib/types";

const note = (id: string, at: number, text: string, extra: Partial<Note> = {}): Note => ({ id, at, text, state: "listening", excerpts: [], ...extra });
const status = (over: Partial<Status> = {}): Status => ({
  recording: true, meetingId: "m1", title: "Offline sync", elapsed: 10,
  sources: { mic: true, system: true, screen: false }, permissions: { microphone: true, screenRecording: true }, warming: false, ...over,
});
const answer = (id: string, at: number, extra: Partial<LiveAnswer> = {}): LiveAnswer => ({ id, at, question: "q", answer: "a", citations: [], done: true, ...extra });

test("rows preserve source insertion order even with nonchronological timestamps", () => {
  const rows = alignRows([note("n2", 545, "ship date"), note("n1", 492, "conflicts")], [{ clientId: "j1", text: "beta 40", at: 640 }, { clientId: "j0", text: "early", at: 10 }]);
  assert.deepEqual(rows.map((r) => r.key), ["n2", "n1", "j1", "j0"]);
  assert.equal(rows[3]!.pending?.clientId, "j0");
});

test("pending jot hidden once its note arrived over SSE (race with POST)", () => {
  const rows = alignRows([note("n1", 100.4, "photo cap?")], [{ clientId: "j1", text: "photo cap? ", at: 100 }]);
  assert.deepEqual(rows.map((r) => r.key), ["n1"]);
});

test("ties keep insertion order", () => {
  const rows = alignRows([note("a", 5, "a"), note("b", 5, "b")], [{ clientId: "c", text: "c", at: 5 }]);
  assert.deepEqual(rows.map((r) => r.key), ["a", "b", "c"]);
});

test("status starting a new meeting resets the state", () => {
  const s = emptyLive();
  s.notes.set("old", note("old", 1, "x"));
  const ch = applyEvent(s, { type: "status", status: status() });
  assert.ok(ch.has("meeting") && ch.has("status"));
  assert.equal(s.meetingId, "m1");
  assert.equal(s.title, "Offline sync");
  assert.equal(s.notes.size, 0);
  // Same meeting again: no reset.
  s.notes.set("n", note("n", 1, "y"));
  assert.ok(!applyEvent(s, { type: "status", status: status({ elapsed: 20 }) }).has("meeting"));
  assert.equal(s.notes.size, 1);
});

test("provisional segment replaced by final; late segment inserted in order; other meetings ignored", () => {
  const s = emptyLive();
  applyEvent(s, { type: "status", status: status() });
  applyEvent(s, { type: "segment", meetingId: "m1", segment: { id: "s1", speaker: "Marcus", start: 5, text: "If it's…", final: false } });
  applyEvent(s, { type: "segment", meetingId: "m1", segment: { id: "s2", speaker: "Priya", start: 9, text: "Okay", final: true } });
  applyEvent(s, { type: "segment", meetingId: "m1", segment: { id: "s1", speaker: "Marcus", start: 5, text: "If it's last-write-wins…", final: true } });
  applyEvent(s, { type: "segment", meetingId: "m1", segment: { id: "s0", speaker: "You", start: 1, text: "Hi", final: true } });
  assert.deepEqual(s.segments.map((x) => [x.id, x.final]), [["s0", true], ["s1", true], ["s2", true]]);
  const ch = applyEvent(s, { type: "segment", meetingId: "other", segment: { id: "z", speaker: "X", start: 1, text: "", final: true } });
  assert.equal(ch.size, 0);
  assert.equal(s.segments.length, 3);
});

test("note updates keep a prior enhancement when an echo arrives without one", () => {
  const s = emptyLive();
  s.meetingId = "m1";
  applyEvent(s, { type: "note", meetingId: "m1", note: note("n1", 1, "x", { state: "answered", enhanced: { topic: "T.", text: "body" } }) });
  applyEvent(s, { type: "note", meetingId: "m1", note: note("n1", 1, "x", { state: "found" }) });
  assert.equal(s.notes.get("n1")!.enhanced?.text, "body");
  applyEvent(s, { type: "note", meetingId: "m1", note: note("n1", 1, "x", { state: "quiet" }) });
  assert.ok(!s.notes.get("n1")!.enhanced, "a plain result clears the enhancement");
});

test("one live-answer slot: newer or same-id replaces, older ignored, dismissed stays dismissed", () => {
  const s = emptyLive();
  s.meetingId = "m1";
  applyEvent(s, { type: "answer", meetingId: "m1", answer: answer("a1", 100, { done: false, answer: "Off" }) });
  applyEvent(s, { type: "answer", meetingId: "m1", answer: answer("a1", 100, { answer: "Offline capture" }) });
  assert.equal(s.answer?.answer, "Offline capture");
  applyEvent(s, { type: "answer", meetingId: "m1", answer: answer("a2", 200) });
  assert.equal(s.answer?.id, "a2");
  assert.equal(applyEvent(s, { type: "answer", meetingId: "m1", answer: answer("a0", 50) }).size, 0);
  assert.equal(s.answer?.id, "a2");
  s.dismissedAnswerId = "a2";
  s.answer = null;
  applyEvent(s, { type: "answer", meetingId: "m1", answer: answer("a2", 200, { answer: "update" }) });
  assert.equal(s.answer, null);
});

test("enhancement flag and screen moments", () => {
  const s = emptyLive();
  applyEvent(s, { type: "enhancement", meetingId: "m1", upToDate: false });
  assert.equal(s.upToDate, false);
  applyEvent(s, { type: "screen", meetingId: "m1", moment: { kind: "screen", title: "PRD" } });
  assert.equal(s.screens.length, 1);
});

test("confirm and fail optimistic jots", () => {
  const s = emptyLive();
  s.pending.push({ clientId: "j1", text: "x", at: 1 }, { clientId: "j2", text: "y", at: 2 });
  // SSE delivered the enhanced version first; the POST response must not clobber it.
  s.notes.set("n1", note("n1", 1, "x", { state: "answered", enhanced: { topic: "X.", text: "x!" } }));
  confirmJot(s, "j1", note("n1", 1, "x"));
  assert.equal(s.notes.get("n1")!.enhanced?.text, "x!");
  assert.deepEqual(s.pending.map((p) => p.clientId), ["j2"]);
  failJot(s, "j2", "offline");
  assert.equal(s.pending[0]!.error, "offline");
});

test("loadMeeting fills state and computes up-to-date", () => {
  const s = emptyLive();
  loadMeeting(s, {
    id: "m1", title: "T", startedAt: "", duration: 0, speakers: [], status: "recording",
    segments: [{ id: "b", speaker: "P", start: 9, text: "", final: true }, { id: "a", speaker: "P", start: 1, text: "", final: true }],
    notes: [note("n1", 1, "x", { state: "found" })], missedTopics: [], actionItems: [], answers: [answer("a1", 5)],
  });
  assert.deepEqual(s.segments.map((x) => x.id), ["a", "b"]);
  assert.equal(s.upToDate, false);
  assert.equal(s.answer?.id, "a1");
});

test("elapsed from startedAt or from elapsed + local clock", () => {
  const now = Date.parse("2026-10-13T10:16:07Z");
  assert.equal(liveElapsed(status({ startedAt: "2026-10-13T10:02:00Z" }), 0, now), 847);
  assert.equal(liveElapsed(status({ elapsed: 100 }), now - 5000, now), 105);
  assert.equal(liveElapsed(status({ recording: false }), 0, now), 0);
  assert.equal(liveElapsed(null, 0, now), 0);
});
