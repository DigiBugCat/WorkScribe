import { test } from "node:test";
import assert from "node:assert/strict";
import { mapBlockIds, noteLines } from "../src/lib/blocks";
import type { Note } from "../src/lib/types";

const md = `---
workscribe_id: m1
type: meeting
---
<!-- workscribe:begin notes -->
## Brief
The team kept offline for v2.4 ^not-a-note

## Notes
- **Conflict resolution.** Field-level merge for checklists [[People/Marcus Chen]] ^e1
- **Ship date.** v2.4 moves from Oct 28 to Nov 4 ^e2
- android parity? ^e4
- a line without a block id

## Missed topics
- **Android parity.** 2.5 ^e9
`;

const note = (id: string, text: string, enhanced?: [string, string], blockId?: string): Note => {
  const n: Note = { id, at: 0, text, state: enhanced ? "done" : "plain", excerpts: [], enhanced: enhanced ? { topic: enhanced[0], text: enhanced[1] } : null };
  if (blockId) n.blockId = blockId;
  return n;
};

test("noteLines reads only the Notes section", () => {
  assert.deepEqual(noteLines(md).map((l) => l.blockId), ["e1", "e2", "e4"]);
  assert.equal(noteLines(md)[0]!.line, 9);
});

test("explicit blockId wins, then text match, regardless of order", () => {
  const notes = [
    note("n2", "ship date nov 4 not oct 28", ["Ship date.", "v2.4 moves from Oct 28 to Nov 4"]),
    note("n1", "conflicts", ["Conflict resolution.", "Field-level merge for checklists"], "e1"),
    note("n3", "android parity?"),
    note("n5", "never written"),
  ];
  const map = mapBlockIds(md, notes);
  assert.deepEqual(Object.fromEntries(map), { n1: "e1", n2: "e2", n3: "e4" });
});

test("order fallback only when counts match", () => {
  const plain = "## Notes\n- **X.** totally rewritten by hand ^e1\n- **Y.** also rewritten ^e2\n";
  const notes = [note("a", "foo", ["A.", "alpha"]), note("b", "bar", ["B.", "beta"])];
  assert.deepEqual(Object.fromEntries(mapBlockIds(plain, notes)), { a: "e1", b: "e2" });
  assert.equal(mapBlockIds(plain, [notes[0]!]).size, 0);
});

test("stale explicit blockId not present in the file is ignored", () => {
  const map = mapBlockIds(md, [note("n9", "zzzz", undefined, "e7")]);
  assert.equal(map.size, 0);
});
