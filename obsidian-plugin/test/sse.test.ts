import { test } from "node:test";
import assert from "node:assert/strict";
import { SseParser, type SseMessage } from "../src/lib/sse";

function parse(chunks: string[]): SseMessage[] {
  const out: SseMessage[] = [];
  const p = new SseParser((m) => out.push(m));
  for (const c of chunks) p.push(c);
  p.end();
  return out;
}

test("named events with JSON data", () => {
  const msgs = parse(['event: segment\ndata: {"id":"s1"}\n\n', "event: note\ndata: {}\n\n"]);
  assert.deepEqual(msgs, [
    { event: "segment", data: '{"id":"s1"}' },
    { event: "note", data: "{}" },
  ]);
});

test("events split at arbitrary chunk boundaries", () => {
  const whole = 'event: token\ndata: {"text":"Hel"}\n\nevent: token\ndata: {"text":"lo"}\n\n';
  for (let i = 1; i < whole.length; i++) {
    const msgs = parse([whole.slice(0, i), whole.slice(i)]);
    assert.equal(msgs.length, 2, `split at ${i}`);
    assert.equal(msgs[1]!.data, '{"text":"lo"}');
  }
  // One character at a time.
  assert.equal(parse(whole.split("")).length, 2);
});

test("CRLF and lone CR line endings, including CRLF split across chunks", () => {
  assert.deepEqual(parse(["data: a\r\n\r\ndata: b\r\r"]).map((m) => m.data), ["a", "b"]);
  assert.deepEqual(parse(["data: a\r", "\n\r", "\n"]).map((m) => m.data), ["a"]);
});

test("comments are ignored, multi-line data joined, default event is message", () => {
  const msgs = parse([": keep-alive\n\ndata: line1\ndata: line2\nid: 7\nretry: 3000\n\n"]);
  assert.deepEqual(msgs, [{ event: "message", data: "line1\nline2", id: "7", retry: 3000 }]);
});

test("BOM stripped; field without colon; no space after colon", () => {
  const msgs = parse(["﻿event:done\ndata\n\n"]);
  assert.deepEqual(msgs, [{ event: "done", data: "" }]);
});

test("trailing event without blank line is discarded", () => {
  assert.equal(parse(["data: partial"]).length, 0);
});
