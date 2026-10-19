import { test } from "node:test";
import assert from "node:assert/strict";
import {
  citationsToMarkdown,
  noteName,
  clock,
  duration,
  meetingUrl,
  momentMarkdown,
  momentTarget,
  momentWhere,
  parseBlockId,
  parseObsidianOpen,
  safeFilename,
  splitCitations,
  vaultRelative,
  canonicalPath,
  type LinkContext,
} from "../src/lib/format";
import type { Moment } from "../src/lib/types";

const ctx: LinkContext = { vaultName: "Work", vaultBase: "/example/Obsidian/Work" };

test("clock and duration", () => {
  assert.equal(clock(492), "08:12");
  assert.equal(clock(3723), "1:02:03");
  assert.equal(clock(-3), "00:00");
  assert.equal(clock(undefined), "00:00");
  assert.equal(duration(1920), "32 min");
  assert.equal(duration(45), "45 s");
  assert.equal(duration(4500), "1 h 15 min");
});

test("vaultRelative rejects sibling prefixes", () => {
  assert.equal(vaultRelative("/example/Obsidian/Work/Notes/a.md", ctx.vaultBase), "Notes/a.md");
  assert.equal(vaultRelative("/example/Obsidian/Work2/a.md", ctx.vaultBase), null);
  assert.equal(vaultRelative("/example/Obsidian/Work/a.md", "/example/Obsidian/Work/"), "a.md");
  assert.equal(vaultRelative("/x", null), null);
});

test("meeting URLs", () => {
  assert.equal(meetingUrl("m 1", 492.7), "workscribe://meeting/m%201?t=492");
  assert.equal(meetingUrl("m1"), "workscribe://meeting/m1");
});

test("moment targets: vault note, vault PDF page, meeting, external link, file path", () => {
  const note: Moment = { kind: "note", title: "Halvorsen site visit", path: "/example/Obsidian/Work/Notes/Halvorsen site visit.md" };
  assert.deepEqual(momentTarget(note, ctx), { kind: "vault", path: "Notes/Halvorsen site visit.md" });
  const pdf: Moment = { kind: "pdf", title: "MSA", path: "/example/Obsidian/Work/Contracts/MSA.pdf", page: 14 };
  assert.deepEqual(momentTarget(pdf, ctx), { kind: "vault", path: "Contracts/MSA.pdf", subpath: "#page=14" });
  const mt: Moment = { kind: "meeting", title: "Offline sync", meetingId: "m1", start: 478, speaker: "Marcus" };
  assert.deepEqual(momentTarget(mt, ctx), { kind: "external", url: "workscribe://meeting/m1?t=478" });
  const ext: Moment = { kind: "clip", title: "Apple", link: "https://support.apple.com/x" };
  assert.deepEqual(momentTarget(ext, ctx), { kind: "external", url: "https://support.apple.com/x" });
  const ob: Moment = { kind: "note", title: "n", link: "obsidian://open?vault=Work&file=Notes%2Fa.md" };
  assert.deepEqual(momentTarget(ob, ctx), { kind: "vault", path: "Notes/a.md" });
  const file: Moment = { kind: "pdf", title: "Spec", path: "/example/Documents/Photo pipeline spec.pdf", page: 6 };
  assert.deepEqual(momentTarget(file, ctx), { kind: "external", url: "file:///example/Documents/Photo%20pipeline%20spec.pdf#page=6" });
  assert.equal(momentTarget({ kind: "document", title: "nothing" }, ctx), null);
});

test("moment labels and Markdown links", () => {
  const mt: Moment = { kind: "meeting", title: "Offline sync — v2.4 scope", meetingId: "m1", start: 478, speaker: "Marcus" };
  assert.equal(momentWhere(mt), "Marcus · 07:58");
  assert.equal(momentMarkdown(mt, ctx), "[Offline sync — v2.4 scope · Marcus · 07:58](workscribe://meeting/m1?t=478)");
  const note: Moment = { kind: "note", title: "Halvorsen site visit", path: "/example/Obsidian/Work/Notes/Halvorsen site visit.md" };
  assert.equal(momentMarkdown(note, ctx), "[[Notes/Halvorsen site visit|Halvorsen site visit]]");
  const pdf: Moment = { kind: "pdf", title: "MSA", path: "/example/Obsidian/Work/MSA.pdf", page: 14 };
  assert.equal(momentMarkdown(pdf, ctx), "[[MSA.pdf#page=14|MSA · p. 14]]");
  const vid: Moment = { kind: "video", title: "Yard walk (raw).mov", path: "/example/Movies/Yard walk (raw).mov", start: 185 };
  assert.equal(momentMarkdown(vid, ctx), "[Yard walk (raw).mov · at 03:05](file:///example/Movies/Yard%20walk%20(raw%29.mov)");
});

test("citation markers", () => {
  assert.deepEqual(splitCitations("A [1]. B [2, 3]; C [Source:4][Source: 5]"), [
    { text: "A " }, { cite: 1 }, { text: ". B " }, { cite: 2 }, { cite: 3 }, { text: "; C " }, { cite: 4 }, { cite: 5 },
  ]);
  assert.deepEqual(splitCitations("no cites [x]"), [{ text: "no cites [x]" }]);
  const md = citationsToMarkdown("Dec 31 [Source:1].", [{ kind: "meeting", title: "T", meetingId: "m", start: 5 }], ctx);
  assert.equal(md, "Dec 31 [1].\n\n1. [T · 00:05](workscribe://meeting/m?t=5)");
});

test("misc helpers", () => {
  assert.deepEqual(parseObsidianOpen("obsidian://open?vault=My%20Vault&file=a%2Fb"), { vault: "My Vault", file: "a/b" });
  assert.equal(parseObsidianOpen("https://x"), null);
  assert.equal(parseBlockId("id=m-1"), "m-1");
  assert.equal(parseBlockId("title: x\nid: \"m-2\""), "m-2");
  assert.equal(parseBlockId("m-3"), "m-3");
  assert.equal(parseBlockId("two words"), null);
  assert.equal(safeFilename('What: is "this"? / ok'), "What is this ok");
});

test("vault paths match through macOS's /private links", () => {
  assert.equal(canonicalPath("/private/tmp/vault/a.md"), "/private/tmp/vault/a.md");
  assert.equal(canonicalPath("/private/var/folders/x"), "/private/var/folders/x");
  assert.equal(canonicalPath("/private/tmpfoo/a.md"), "/private/tmpfoo/a.md");
  assert.equal(canonicalPath("/example/private/tmp/a.md"), "/example/private/tmp/a.md");
  assert.equal(vaultRelative("/tmp/test-vault/Meetings/a.md", "/private/tmp/test-vault"), "Meetings/a.md");
  assert.equal(vaultRelative("/private/tmp/test-vault/Meetings/a.md", "/tmp/test-vault/"), "Meetings/a.md");
});

test("noteName makes a meeting title safe for a file name, like the app does", () => {
  assert.equal(noteName("Beta Plan and Feature Freeze Details"), "Beta Plan and Feature Freeze Details");
  assert.equal(noteName("Q4: pricing / tiers? [draft] #beta"), "Q4 pricing tiers draft beta");
  assert.equal(noteName("  ...  "), "Untitled");
  assert.equal(noteName("x".repeat(200)).length, 120);
});
