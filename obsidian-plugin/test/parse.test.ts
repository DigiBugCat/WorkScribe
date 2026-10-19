import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ApiShapeError,
  parseAskEvent,
  parseDiscovery,
  parseEnhancement,
  parseLiveEvent,
  parseMeeting,
  parseMeetingList,
  parseMoment,
  parseNote,
  parseStatus,
  seconds,
} from "../src/lib/parse";

test("discovery: valid, string port, bad inputs", () => {
  assert.deepEqual(parseDiscovery('{"port":47615,"token":"t","version":1}'), { port: 47615, token: "t", version: 1 });
  assert.equal(parseDiscovery('{"port":"8080","token":"t"}').port, 8080);
  assert.throws(() => parseDiscovery("nope"), ApiShapeError);
  assert.throws(() => parseDiscovery('{"port":0,"token":"t"}'), /bad port/);
  assert.throws(() => parseDiscovery('{"port":1,"token":""}'), /missing token/);
  assert.throws(() => parseDiscovery('{"port":1,"token":"t","version":2}'), /unsupported version/);
});

test("seconds from numbers and clock strings", () => {
  assert.equal(seconds(492), 492);
  assert.equal(seconds("08:12"), 492);
  assert.equal(seconds("1:02:03"), 3723);
  assert.equal(seconds("12.5"), 12.5);
  assert.equal(seconds("soon"), undefined);
});

test("status defaults and elapsed from startedAt", () => {
  const s = parseStatus({ recording: true, meetingId: "m1", startedAt: new Date(Date.now() - 65000).toISOString() });
  assert.equal(s.recording, true);
  assert.ok(s.elapsed >= 64 && s.elapsed < 70);
  assert.deepEqual(s.sources, { mic: false, system: false, screen: false });
  assert.deepEqual(s.permissions, { screenRecording: true, microphone: true });
  assert.throws(() => parseStatus([]), ApiShapeError);
});

test("enhancement as object or Markdown bullet", () => {
  assert.deepEqual(parseEnhancement({ topic: "Ship date.", text: "Nov 4" }), { topic: "Ship date.", text: "Nov 4" });
  assert.deepEqual(parseEnhancement("* **Ship date:** Nov 4, not Oct 28"), { topic: "Ship date.", text: "Nov 4, not Oct 28" });
  assert.deepEqual(parseEnhancement("**Beta** 40 accounts"), { topic: "Beta.", text: "40 accounts" });
  assert.deepEqual(parseEnhancement("just text"), { topic: "", text: "just text" });
  assert.equal(parseEnhancement(""), null);
  assert.equal(parseEnhancement(null), null);
});

test("note: hollow flag, refs alias, inferred state", () => {
  const n = parseNote({
    id: "n1",
    at: "08:12",
    shorthand: "offline conflicts → LWW??",
    enhanced: "**Conflict resolution.** Field-level merge.",
    refs: [{ id: "E1", speaker: "Marcus", start: 478, quote: "If it's…" }, { ref: "E3", speaker: "Marcus", at: "03:10", text: "The sync engine…", hollow: true }],
  });
  assert.equal(n.at, 492);
  assert.equal(n.text, "offline conflicts → LWW??");
  assert.equal(n.state, "answered");
  assert.equal(n.enhanced?.topic, "Conflict resolution.");
  assert.deepEqual(n.excerpts.map((e) => [e.id, e.match, e.start]), [["E1", "time+meaning", 478], ["E3", "meaning", 190]]);
  assert.equal(parseNote({ id: "n2", text: "x" }).state, "listening");
});

test("meeting list: bare array or wrapped; speakers as objects", () => {
  const list = parseMeetingList({ meetings: [{ id: "m", title: "T", speakers: [{ name: "Priya" }, "Marcus"], duration: "32:00" }] });
  assert.equal(list[0]!.duration, 1920);
  assert.deepEqual(list[0]!.speakers, ["Priya", "Marcus"]);
  assert.equal(parseMeetingList([{ id: "a" }])[0]!.title, "Untitled meeting");
});

test("full meeting with segments, notes, actions, answers", () => {
  const m = parseMeeting({
    id: "m1", title: "Offline sync", segments: [{ id: "s1", speaker: "Marcus Chen", start: 1, text: "hi", provisional: true }],
    notes: [{ id: "n1", text: "x", state: "quiet", hint: "No matching speech yet." }],
    actionItems: [{ owner: "You", action: "Update PRD", askedBy: "Priya", at: "27:30" }],
    answers: [{ id: "a1", question: "q", answer: "a [1]", citations: [{ kind: "pdf", title: "MSA", page: 14 }] }],
    missedTopics: [{ topic: "Android parity.", text: "2.5" }],
  });
  assert.equal(m.segments[0]!.final, false);
  assert.equal(m.notes[0]!.hint, "No matching speech yet.");
  assert.equal(m.actionItems[0]!.text, "Update PRD");
  assert.equal(m.actionItems[0]!.at, 1650);
  assert.equal(m.answers[0]!.done, true);
  assert.equal(m.answers[0]!.citations[0]!.page, 14);
});

test("moment: unknown kind falls back to document; empty strings dropped", () => {
  const m = parseMoment({ kind: "hologram", title: "X", snippet: "", start: "00:05" });
  assert.equal(m.kind, "document");
  assert.equal(m.snippet, undefined);
  assert.equal(m.start, 5);
});

test("live events: wrapped and bare payloads, type-in-data, unknown ignored", () => {
  const a = parseLiveEvent("segment", '{"meetingId":"m1","segment":{"id":"s1","speaker":"Priya","start":3,"text":"hi","final":false}}');
  assert.equal(a?.type, "segment");
  assert.equal(a?.type === "segment" && a.segment.final, false);
  const b = parseLiveEvent("segment", '{"meetingId":"m1","id":"s2","speaker":"P","start":4,"text":"yo"}');
  assert.equal(b?.type === "segment" && b.segment.id, "s2");
  const c = parseLiveEvent("message", '{"type":"enhancement","meetingId":"m1","upToDate":true}');
  assert.deepEqual(c, { type: "enhancement", meetingId: "m1", upToDate: true });
  const d = parseLiveEvent("status", '{"recording":false}');
  assert.equal(d?.type === "status" && "status" in d && d.status.recording, false);
  assert.equal(parseLiveEvent("wat", "{}"), null);
  assert.equal(parseLiveEvent("segment", "not json"), null);
  assert.equal(parseLiveEvent("segment", '{"segment":{}}'), null, "missing id is dropped, not thrown");
  const e = parseLiveEvent("answer", '{"meetingId":"m1","answer":{"id":"a","question":"q","answer":"x","done":false}}');
  assert.equal(e?.type === "answer" && e.answer.done, false);
});

test("ask events: JSON tokens, plain-text tokens, citations, done, error", () => {
  assert.deepEqual(parseAskEvent("token", '{"text":"Hel"}'), { type: "token", text: "Hel" });
  assert.deepEqual(parseAskEvent("token", "lo"), { type: "token", text: "lo" });
  assert.deepEqual(parseAskEvent("message", '"raw string"'), { type: "token", text: "raw string" });
  const c = parseAskEvent("citations", '{"citations":[{"kind":"meeting","title":"T","meetingId":"m","start":5}]}');
  assert.equal(c?.type === "citations" && c.citations[0]!.meetingId, "m");
  const c2 = parseAskEvent("citations", '[{"kind":"clip","title":"Clip"}]');
  assert.equal(c2?.type === "citations" && c2.citations.length, 1);
  assert.deepEqual(parseAskEvent("done", '{"conversationId":"c1"}'), { type: "done", conversationId: "c1" });
  assert.deepEqual(parseAskEvent("error", '{"message":"model not loaded"}'), { type: "error", message: "model not loaded" });
});

test("canonical app payloads retain wrapped meetings, batched notes, and final answers", () => {
  const m = parseMeeting({ meeting: { id: "m", title: "Wrapped", obsidianLink: "obsidian://open?vault=Work&file=Meetings%2Fm.md" },
    segments: [], notes: [], missedTopics: [], actionItems: [], answers: [] });
  assert.equal(m.id, "m");
  assert.ok(m.obsidianLink);
  const batch = parseLiveEvent("notes", JSON.stringify({ meetingId: "m", notes: [{ id: "n", text: "release", state: "found", excerpts: [] }], missedTopics: [], actionItems: [] }));
  assert.equal(batch?.type, "notes");
  const answer = parseLiveEvent("answer", JSON.stringify({ id: "a", at: 4, meetingId: "m", conversationId: "c", question: "When?", answer: "Friday [1]", done: true, citations: [] }));
  assert.ok(answer?.type === "answer" && answer.answer.id === "a");
  const result = parseAskEvent("citations", JSON.stringify({ answer: "Friday [1]", citations: [], conversationId: "c" }));
  assert.ok(result?.type === "citations" && result.answer === "Friday [1]");
  assert.equal(parseAskEvent("started", '{"conversationId":"c","messageId":"a"}'), null);
  assert.equal(parseLiveEvent("clip", '{"id":"p","title":"Page","path":"Clips/p.md"}')?.type, "clip");
  assert.equal(parseLiveEvent("ask_request", '{"clip":{"id":"p","title":"Page"},"untrusted":true}')?.type, "ask_request");
  assert.equal(parseLiveEvent("continue", '{"conversationId":"c","title":"Chat","markdown":"Question and answer"}')?.type, "continue");
});
