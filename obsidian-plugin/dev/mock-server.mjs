#!/usr/bin/env node
import { realpathSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import {finalizeFormat} from './finalize-format.mjs';
// Mock of the WorkScribe local HTTP API (v1) for plugin development and tests.
//
//   node dev/mock-server.mjs [--port 47615] [--discovery dev/api.json]
//                            [--vault /path/to/vault] [--live] [--speed 1]
//
// Writes a discovery file ({port, token, version:1}) — by default dev/api.json,
// never the real ~/Library/Application Support/WorkScribe/api.json unless you
// pass that path explicitly. Point the plugin's "api.json path" setting at it.
// With --live a meeting starts immediately and plays a scripted call: transcript
// segments (provisional → final), enhancement of the lines you jot, a live answer
// and a screen moment.

import http from "node:http";
import { randomBytes } from "node:crypto";
import { mkdirSync, writeFileSync, rmSync, readFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------- sample data

const SPEAKERS = ["You", "Priya Raman", "Marcus Chen"];

/** The finished sample meeting from the mockups (design/unified/02, 03). */
function sampleMeeting(vault) {
  const seg = (id, speaker, start, text) => ({ id, speaker, start, end: start + 12, text, final: true });
  const segments = [
    seg("s1", "Priya Raman", 191, "The sync engine — Marcus, remind me, what does it do on conflicts today?"),
    seg("s2", "Marcus Chen", 190, "The sync engine is last-write-wins today, per record."),
    seg("s3", "Priya Raman", 451, "So the real question for offline is what happens when two people touch the same inspection."),
    seg("s4", "Marcus Chen", 478, "If it's last-write-wins, an inspector's checklist edits just vanish when the office touches the same job. And nobody finds out until the report's wrong."),
    seg("s5", "You", 494, "Does merging per field get us most of the way? Checklists are mostly booleans and notes."),
    seg("s6", "Priya Raman", 511, "Okay — merge at the field level for checklists, keep last-write-wins for the rest. Marcus, can you prototype that?"),
    seg("s7", "Marcus Chen", 524, "Yeah. Give me till Monday. Notes fields we'll just keep both versions and flag it."),
    seg("s8", "Priya Raman", 542, "Which brings us to the date. I don't think October 28th survives this."),
    seg("s9", "Marcus Chen", 556, "Not with the SQLite migration. QA needs a full week on it. November 4th."),
    seg("s10", "Priya Raman", 580, "Nov 4 then. I'll tell Halvorsen on Friday, before they hear it elsewhere."),
    seg("s11", "Priya Raman", 628, "For the beta, forty accounts. Halvorsen first — their contract names offline capture by year end."),
    seg("s12", "Marcus Chen", 760, "The photo queue is the scary part. The 12 mini stalled once the queue went past a gig."),
    seg("s13", "Priya Raman", 765, "What does the Halvorsen contract commit us to on offline?"),
    seg("s14", "You", 770, "Let's cap it: two hundred photos or one and a half gigs, oldest first on reconnect."),
    seg("s15", "Marcus Chen", 780, "…if we cap the queue we need to tell them what happens at the cap, not just silently stop."),
  ];
  const ex = (id, segId, match) => {
    const s = segments.find((x) => x.id === segId);
    return { id, segmentId: segId, speaker: s.speaker.split(" ")[0], start: s.start, quote: s.text, match };
  };
  const notes = [
    {
      id: "n1", blockId: "e1", at: 492, text: "offline conflicts → LWW?? marcus pushback", state: "done",
      enhanced: { topic: "Conflict resolution.", text: "Marcus warned last-write-wins would silently drop inspectors' checklist edits when the office edits the same job; the team agreed on a field-level merge for checklist items and last-write-wins for everything else." },
      excerpts: [ex("E1", "s4", "time+meaning"), ex("E2", "s6", "time+meaning"), ex("E3", "s2", "meaning")],
    },
    {
      id: "n2", blockId: "e2", at: 545, text: "ship date nov 4 not oct 28", state: "done",
      enhanced: { topic: "Ship date.", text: "v2.4 moves from Oct 28 to Nov 4 so QA gets a full week on the SQLite migration. Priya tells Halvorsen on Friday." },
      excerpts: [ex("E4", "s9", "time+meaning"), ex("E5", "s10", "time+meaning")],
    },
    {
      id: "n3", blockId: "e3", at: 640, text: "beta 40 accts, halvorsen first", state: "done",
      enhanced: { topic: "Beta cohort.", text: "40 accounts, Halvorsen Construction first because their contract names offline capture by year end." },
      excerpts: [ex("E6", "s11", "time+meaning")],
    },
    {
      id: "n4", blockId: "e4", at: 771, text: "photo uploads queue — cap?", state: "done",
      enhanced: { topic: "Photo queue.", text: "Cap at 200 photos or 1.5 GB per device, upload oldest first on reconnect, and show inspectors a banner at the cap." },
      excerpts: [ex("E7", "s12", "time+meaning"), ex("E8", "s14", "time+meaning"), ex("E9", "s15", "time+meaning")],
    },
  ];
  return {
    id: "m-2026-10-13-offline-sync",
    title: "Offline sync — v2.4 scope",
    startedAt: "2026-10-13T10:02:00-07:00",
    duration: 1920,
    speakers: SPEAKERS,
    status: "ready",
    vaultPath: "Meetings/2026-10-13 Offline sync — v2.4 scope.md",
    brief: "The team kept offline for v2.4 but moved the date to Nov 4. Checklists get a field-level merge instead of last-write-wins, the photo queue gets a hard cap, and Halvorsen leads a 40-account beta.",
    segments,
    notes,
    missedTopics: [
      { topic: "Android parity.", text: "Offline for Android lands in 2.5, not 2.4; Marcus wants the merge rule shared so behavior matches.", speaker: "Marcus Chen", start: 1334, end: 1420 },
      { topic: "Sync-failure analytics.", text: "Priya asked for an event on every failed sync with the queue size, so support can see who is stuck.", speaker: "Priya Raman", start: 1502, end: 1550 },
    ],
    actionItems: [
      { owner: "You", text: "Update PRD v3 with the checklist merge rule and photo cap", askedBy: "Priya Raman", quote: "Can you get that into the PRD before Marcus starts?", at: 1650, due: "2026-10-15" },
      { owner: "Marcus Chen", text: "Prototype field-level merge for checklists", askedBy: "Priya Raman", quote: "Give me till Monday.", at: 524, due: "2026-10-19" },
      { owner: "Marcus Chen", text: "Measure the photo queue at 200 photos on an iPhone 12", askedBy: "You", at: 832 },
      { owner: "Priya Raman", text: "Email Halvorsen about the Nov 4 date", askedBy: "Priya Raman", quote: "I'll tell them Friday, before they hear it elsewhere.", at: 845, due: "2026-10-16" },
    ],
    answers: [contractAnswer(vault, 768), photoAnswer(vault, 820)],
  };
}

function corpus(vault) {
  const v = (p) => join(vault, p);
  return [
    { kind: "meeting", title: "Note Pro · walk-and-talk with Marcus", meetingId: "m-2026-10-06-walk", start: 684, speaker: "Marcus", snippet: "The 12 mini just stalled once the queue went past a gig, and it never told anyone.", date: "2026-10-06" },
    { kind: "meeting", title: "Offline sync — v2.4 scope", meetingId: "m-2026-10-13-offline-sync", start: 780, speaker: "Marcus", snippet: "…if we cap the queue we need to tell them what happens at the cap, not just silently stop.", date: "2026-10-13" },
    { kind: "meeting", title: "Offline sync — v2.4 scope", meetingId: "m-2026-10-13-offline-sync", start: 478, speaker: "Marcus", snippet: "If it's last-write-wins, an inspector's checklist edits just vanish when the office touches the same job.", date: "2026-10-13" },
    { kind: "note", title: "Halvorsen site visit", path: v("Notes/Halvorsen site visit.md"), snippet: "Two inspectors had to delete photos mid-inspection — phones are 64 GB.", date: "2026-10-09" },
    { kind: "clip", title: "If your iPhone storage is full · Apple Support", path: v("Clips/If your iPhone storage is full.md"), snippet: "Some apps can't save new photos when storage is almost full.", link: "https://support.apple.com/en-us/HT201656", date: "2026-10-02" },
    { kind: "video", title: "Halvorsen yard walkthrough.mov", path: "/example/Movies/Site walkthroughs/Halvorsen yard walkthrough.mov", start: 185, snippet: "The phone shows “Storage almost full” beside the inspection form" },
    { kind: "audio", title: "Halvorsen yard memo.m4a", path: "/example/Recordings/Halvorsen yard memo.m4a", start: 872, snippet: "Field recording · sound matched by meaning" },
    { kind: "pdf", title: "Photo pipeline spec.pdf", path: "/example/Documents/Product docs/Photo pipeline spec.pdf", page: 6, snippet: "Uploads pause when free space drops below 2 GB; the queue is kept on disk." },
    { kind: "pdf", title: "Halvorsen MSA 2026.pdf", path: "/example/Documents/Contracts/Halvorsen MSA 2026.pdf", page: 14, snippet: "§7.2 Offline capture of inspections and photos by Dec 31, with sync within 24 hours of reconnecting." },
    { kind: "document", title: "Offline PRD v3.md", path: v("PRDs/Offline PRD v3.md"), snippet: "Sync model: last-write-wins per record." },
    { kind: "image", title: "IMG_2291.heic", path: "/example/Pictures/Site photos/IMG_2291.heic", snippet: "Screenshot of iOS storage settings on an inspector's phone", thumbnail: THUMB },
    { kind: "document", title: "Photo pipeline benchmarks.numbers", path: "/example/Documents/Product docs/Photo pipeline benchmarks.numbers", snippet: "iPhone 12: 3.1 MB average after HEIC compression; site day 140–180 photos." },
  ];
}

// A tiny inline SVG thumbnail for screen/image moments.
const THUMB =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="100"><rect width="160" height="100" fill="#e9e4d8"/><rect x="10" y="10" width="140" height="16" fill="#23456b"/><rect x="10" y="34" width="90" height="8" fill="#9db3c8"/><rect x="10" y="48" width="120" height="8" fill="#9db3c8"/><rect x="10" y="62" width="70" height="8" fill="#e3b7a0"/></svg>',
  );

function contractAnswer(vault, at) {
  return {
    id: "a-contract", at, askedBy: "Priya Raman", done: true,
    question: "What does the Halvorsen contract commit us to on offline?",
    answer: "Offline capture of inspections and photos by Dec 31, with sync within 24 hours of reconnecting [1]. Nothing on conflict handling [1]; PRD v3 still says last-write-wins [2].",
    citations: [
      { kind: "pdf", title: "Halvorsen MSA 2026.pdf", path: "/example/Documents/Contracts/Halvorsen MSA 2026.pdf", page: 14, snippet: "§7.2 Offline capture…" },
      { kind: "document", title: "Offline PRD v3.md", path: join(vault, "PRDs/Offline PRD v3.md"), snippet: "Sync model" },
    ],
  };
}

function photoAnswer(vault, at) {
  return {
    id: "a-photos", at, askedBy: "Marcus Chen", done: true,
    question: "What did we measure for photo sizes on the iPhone 12 last time?",
    answer: "3.1 MB average after HEIC compression; a site day ran 140–180 photos [1]. The 12 mini stalled above about 1 GB queued [2]; Apple puts a 12 MP HEIC at roughly half a JPEG [3].",
    citations: [
      { kind: "document", title: "Photo pipeline benchmarks.numbers", path: "/example/Documents/Product docs/Photo pipeline benchmarks.numbers" },
      { kind: "meeting", title: "Note Pro · walk-and-talk", meetingId: "m-2026-10-06-walk", start: 684, speaker: "Marcus" },
      { kind: "clip", title: "Image formats on iPhone · support.apple.com", path: join(vault, "Clips/Image formats on iPhone.md") },
    ],
  };
}

/** Canned enhancements for the shorthand in the mockup; anything else gets a generic one. */
const CANNED = [
  { re: /pricing/i, plain: "Not discussed" },
  { re: /lww|conflict/i, topic: "Conflict resolution.", text: "Marcus warned last-write-wins would silently drop inspectors' checklist edits; the team agreed on a field-level merge for checklists and last-write-wins for everything else.", segs: [["s4", "time+meaning"], ["s6", "time+meaning"], ["s2", "meaning"]] },
  { re: /ship|nov 4|oct 28/i, topic: "Ship date.", text: "v2.4 moves from Oct 28 to Nov 4 so QA gets a full week on the SQLite migration. Priya tells Halvorsen on Friday.", segs: [["s9", "time+meaning"], ["s10", "time+meaning"]] },
  { re: /beta|halvorsen/i, topic: "Beta cohort.", text: "40 accounts, Halvorsen Construction first because their contract names offline capture by year end.", segs: [["s11", "time+meaning"]] },
  { re: /photo|queue|cap/i, topic: "Photo queue.", text: "Cap at 200 photos or 1.5 GB per device, upload oldest first on reconnect, and show inspectors a banner at the cap.", segs: [["s12", "time+meaning"], ["s14", "time+meaning"], ["s15", "time+meaning"]] },
  { re: /android/i, plain: "No matching speech yet. Kept as typed; it will show up in missed topics if it's discussed later." },
];

// ---------------------------------------------------------------- server

export async function startMockServer(opts = {}) {
  const speed = opts.speed ?? 1;
  const token = opts.token ?? randomBytes(32).toString("hex");
  const ownsVault = !opts.vault;
  const requestedVault = opts.vault ?? mkdtempSync(join(tmpdir(), "workscribe-mock-vault-"));
  let ancestor = resolve(requestedVault);
  const tail = [];
  while (true) {
    try { ancestor = join(realpathSync.native(ancestor), ...tail.reverse()); break; }
    catch {
      const parent = dirname(ancestor);
      if (parent === ancestor) { ancestor = resolve(requestedVault); break; }
      tail.push(basename(ancestor)); ancestor = parent;
    }
  }
  const vault = ancestor;
  const log = opts.quiet ? () => {} : (...a) => console.log("[mock]", ...a);
  const past = sampleMeeting(vault);
  const meetings = new Map([[past.id, past]]);
  const summaries = [
    { id: "m-2026-10-12-crit", title: "Design crit — inspection checklist", startedAt: "2026-10-12T15:00:00-07:00", duration: 2700, speakers: ["You", "Lena Park", "Priya Raman"], status: "ready" },
    { id: "m-2026-10-08-kickoff", title: "Halvorsen kickoff", startedAt: "2026-10-08T09:30:00-07:00", duration: 3300, speakers: ["You", "Priya Raman", "Dana Halvorsen"], status: "ready" },
  ];
  const clients = new Set();
  const timers = new Set();
  let live = null; // { meeting, startedAt, answerSeq }
  let convSeq = 0;
  let eventSeq = 0;

  const later = (ms, fn) => {
    const t = setTimeout(() => {
      timers.delete(t);
      fn();
    }, ms / speed);
    timers.add(t);
  };

  const status = () => ({
    recording: !!live,
    phase: live ? "recording" : "ready",
    model: { provider: "none", name: "" },
    ...(live ? { meetingId: live.meeting.id, title: live.meeting.title, startedAt: new Date(live.startedAt).toISOString() } : {}),
    elapsed: live ? (Date.now() - live.startedAt) / 1000 : 0,
    sources: { mic: !!live, system: !!live, screen: !!live },
    permissions: { screenRecording: true, microphone: true },
    warming: false,
  });
  const elapsed = () => (live ? ((Date.now() - live.startedAt) / 1000) * speed : 0);

  const wireSegment = (s) => ({ ...s, end: s.end ?? s.start, source: s.source ?? "system", speakerKey: s.speakerKey ?? "system:speaker-1" });
  const wireMoment = (m, i) => ({ ...m, link: m.link ?? (m.meetingId
    ? `workscribe://meeting/${m.meetingId}?t=${m.start ?? 0}`
    : `workscribe://file?path=${encodeURIComponent(m.path ?? "")}`), attached: m.attached ?? false,
    ...(i === undefined ? {} : { number: i + 1 }) });
  const wireNote = (n) => {
    n.trace ??= {steps:[{title:'Matched transcript',status:'complete'}],model:'Scripted fixture',location:'Test server',durationMs:420,revisions:[]};
    if(n.enhanced && !n.edited && n.trace.revisions.at(-1)?.text!==n.enhanced.text) n.trace.revisions.push({version:n.trace.revisions.length+1,text:n.enhanced.text,reason:n.trace.revisions.length?'New transcript evidence':'First matching discussion',at:new Date().toISOString()});
    return ({trace:n.trace, images:n.images, id: n.id, text: n.text, ...(n.at == null ? {} : { at: n.at }),
    ...(n.enhanced ? { enhanced: n.enhanced } : {}), state: n.state, userEdited: n.edited === true,
    ...(n.fromAnswer ? { fromAnswer: n.fromAnswer } : {}), ...(n.blockId ? { blockId: n.blockId } : {}),
    excerpts: n.excerpts.map((e, i) => ({ id: `E${i + 1}`, match: e.match, chunkId: `${e.segmentId}#0`,
      segmentId: e.segmentId, speaker: e.speaker, start: e.start, end: e.end ?? e.start + 12,
      text: e.quote, hollow: e.match === "meaning", link: `workscribe://meeting/${past.id}?t=${e.start}&segment=${e.segmentId}` })) }); };
  const wireAnswer = (a) => ({ id: a.id, at: a.at, done: a.done, conversationId: a.conversationId ?? "mock-conversation",
    trace:a.trace ?? {steps:[{title:"Searched notes, transcript and files",status:a.done?"complete":"running",detail:`${a.citations.length} moments found`}],model:"Scripted fixture",location:"Test server",durationMs:420,revisions:[]}, question: a.question, answer: a.answer, state: a.done ? "answered" : "working", citations: a.citations.map(wireMoment) });
  const wireSummary = (m) => ({ id: m.id, title: m.title, startedAt: new Date(m.startedAt).toISOString(),
    ...(m.status === "recording" ? {} : { duration: m.duration }), speakers: m.speakers,
    status: m.status === "ready" ? "complete" : m.status, retention: m.retention ?? (m.status === "recording" ? "live" : "finalized"), purgeAt: m.purgeAt,
    ...(m.vaultPath ? { vaultPath: resolve(vault, m.vaultPath), obsidianLink: `obsidian://open?vault=${encodeURIComponent(vault.split("/").at(-1))}&file=${encodeURIComponent(m.vaultPath)}` } : {}) });
  const notesPayload = (m) => ({ meetingId: m.id, ...(m.document?.finalized ? {documentFinalized:true} : {}), notes: m.notes.map(wireNote),
    missedTopics: m.missedTopics.map((t) => ({ topic: t.topic, text: t.text, excerpts: [] })),
    actionItems: m.actionItems.map((a) => ({ owner:a.owner,due:a.due,text: a.text, quote: a.quote ?? a.text, at: a.at, noteId: a.noteId ?? "n1" })) });
  const broadcast = (event, data) => {
    if (event === "segment") { event = "transcript"; data = { ...data, segment: wireSegment(data.segment) }; }
    if (event === "note" || event === "enhancement") { event = "notes"; data = notesPayload(meetings.get(data.meetingId)); }
    if (event === "answer") data = { meetingId: data.meetingId, ...wireAnswer(data.answer) };
    if (event === "screen") { const m = data.moment; data = { meetingId: data.meetingId, id: "mock-screen", start: m.start,
      end: m.start + 1, text: m.snippet, app: "Browser", window: m.title, thumbnail: "/tmp/mock-screen.jpg", link: `workscribe://meeting/${data.meetingId}?t=${m.start}` }; }
    const frame = `id: ${++eventSeq}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of clients) res.write(frame);
  };

  function startRecording(title) {
    if (live) return;
    const id = `m-live-${Date.now().toString(36)}`;
    const meeting = {
      id, title: title || "Offline sync — v2.4 scope", startedAt: new Date().toISOString(), duration: 0,
      speakers: SPEAKERS, status: "recording", excerptSeq: 0, segments: [], notes: [], missedTopics: [], actionItems: [], answers: [],
    };
    meetings.set(id, meeting);
    live = { meeting, startedAt: Date.now(), answerSeq: 0 };
    log("recording started", id);
    broadcast("status", status());
    playScript(meeting);
  }

  function finalizeMockDocument(mt) {
    if (!mt.document.finalized) {
      if (readFileSync(mt.document.path, "utf8") !== mt.document.source) throw new Error("Unsynced file edits");
      const {text,insertions}=finalizeFormat(mt);mt.document.insertions=insertions;
      writeFileSync(mt.document.path,text); mt.document.finalized = true; mt.retention="finalized";
    }
    return mt.document;
  }

  function stopRecording() {
    if (!live) return;
    const m = live.meeting;
    for (const n of m.notes) if (!n.edited) {
      const c=CANNED.find(c=>c.re.test(n.text));
      if(c && !c.plain) { n.enhanced={topic:c.topic,text:c.text}; n.state="done"; }
      else if(n.state!=="done") n.state="plain";
    }
    m.brief="The team kept offline for v2.4 and moved the date to Nov 4.";
    m.missedTopics=[{topic:"Android parity.",text:"Android offline follows in 2.5."}];
    m.actionItems=[{owner:"Priya Raman",text:"Email Halvorsen about the Nov 4 date",due:"2026-10-16"}];
    m.status = "ready";m.endedAt=new Date().toISOString();
    m.retention = m.document ? "live" : "finalized"; m.purgeAt = new Date(Date.now() + 86_400_000).toISOString();
    m.duration = Math.round(elapsed());
    for (const t of timers) clearTimeout(t);
    timers.clear();
    live = null;

    broadcast("notes",notesPayload(m));
    log("recording stopped", m.id);
    broadcast("status", status());
  }

  function playScript(meeting) {
    const script = past.segments.slice().sort((a, b) => a.start - b.start);
    // Compress the sample call: one segment every ~4 s.
    script.forEach((s, i) => {
      const t0 = 1500 + i * 4000;
      const seg = { ...s, start: (t0 / 1000) * speed, end: undefined };
      const words = s.text.split(" ");
      const half = words.slice(0, Math.ceil(words.length / 2)).join(" ") + "…";
      later(t0, () => {
        if (live?.meeting !== meeting) return;
        broadcast("segment", { meetingId: meeting.id, segment: { ...seg, text: half, final: false } });
      });
      later(t0 + 1500, () => {
        if (live?.meeting !== meeting) return;
        const fin = { ...seg, end: seg.start + 3, final: true };
        meeting.segments.push(fin);
        broadcast("segment", { meetingId: meeting.id, segment: fin });
      });
    });
    // A detected question with a streamed live answer.
    later(1500 + 7 * 4000, () => {
      if (live?.meeting !== meeting) return;
      const a = { ...contractAnswer(vault, elapsed()), id: `a-${++live.answerSeq}`, answer: "", done: false };
      const full = contractAnswer(vault, 0).answer.split(/(?<= )/);
      let i = 0;
      const tick = () => {
        if (live?.meeting !== meeting) return;
        a.answer += full[i++] ?? "";
        a.done = i >= full.length;
        broadcast("answer", { meetingId: meeting.id, answer: { ...a, citations: a.done ? a.citations : [] } });
        if (a.done) meeting.answers.push({ ...a });
        else later(60, tick);
      };
      tick();
    });
    later(1500 + 11 * 4000, () => {
      if (live?.meeting !== meeting) return;
      const a = { ...photoAnswer(vault, elapsed()), id: `a-${++live.answerSeq}` };
      meeting.answers.push(a);
      broadcast("answer", { meetingId: meeting.id, answer: a });
    });
    later(1500 + 9 * 4000, () => {
      if (live?.meeting !== meeting) return;
      broadcast("screen", { meetingId: meeting.id, moment: { kind: "screen", title: "Shared screen · Offline PRD v3", meetingId: meeting.id, start: elapsed(), thumbnail: THUMB, snippet: "Sync model: last-write-wins per record" } });
    });
  }

  function enhance(meeting, note) {
    if (note.images?.length && !opts.imageEvidence && !note.text.replace(/!\[\[[^\]]+\]\]|!\[[^\]]*\]\([^)]*\)/g, '').replace(/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/, '').trim()) {
      note.state = "plain"; delete note.enhanced; return;
    }
    meeting.enhancing = (meeting.enhancing ?? 0) + 1;
    broadcast("enhancement", { meetingId: meeting.id, upToDate: false });
    later(400, () => {
      if (note.edited || !meeting.notes.includes(note)) return;
      note.state = "enhancing";
      broadcast("note", { meetingId: meeting.id, note });
    });
    later(1600, () => {
      if (note.edited || !meeting.notes.includes(note)) { meeting.enhancing--; broadcast("note", { meetingId: meeting.id, note }); return; }
      const c = note.images?.length && opts.imageEvidence
        ? { topic: "Launch trace.", text: "The iPhone 12 mini stalls for 2,900 ms during image decoding. Move image decode off the main thread.", segs: [] }
        : CANNED.find((x) => x.re.test(note.text));
      if (c?.plain) {
        note.state = "plain";
        note.hint = c.plain;
      } else if (c) {
        note.state = "done";
        note.enhanced = { topic: c.topic, text: c.text };
        note.excerpts = c.segs.map(([sid, match]) => {
          const s = meeting.segments.find((x) => x.id === sid) ?? past.segments.find((x) => x.id === sid);
          return { id: `E${++meeting.excerptSeq}`, segmentId: sid, speaker: s.speaker.split(" ")[0], start: s.start, quote: s.text, match };
        });
      } else {
        const last = meeting.segments.at(-1);
        const words = note.text.replace(/[?!.]+$/, "").split(/\s+/);
        note.state = last ? "done" : "plain";
        if (last) {
          note.enhanced = {
            topic: words.slice(0, 2).join(" ").replace(/^./, (x) => x.toUpperCase()) + ".",
            text: `${last.speaker.split(" ")[0]} said: “${last.text}” — noted as “${note.text}”.`,
          };
          note.excerpts = [{ id: `E${++meeting.excerptSeq}`, segmentId: last.id, speaker: last.speaker.split(" ")[0], start: last.start, quote: last.text, match: "time+meaning" }];
        } else {
          note.hint = "No matching speech yet. Kept as typed.";
        }
      }
      broadcast("note", { meetingId: meeting.id, note });
      meeting.enhancing--;
      if (meeting.enhancing === 0) broadcast("enhancement", { meetingId: meeting.id, upToDate: true });
    });
  }

  function askAnswer(body) {
    const q = String(body.question ?? "");
    const atts = Array.isArray(body.attachments) ? body.attachments : [];
    const c = corpus(vault);
    let text, cites;
    if (/photo|iphone|storage|12 mini/i.test(q)) {
      const a = photoAnswer(vault, 0);
      text = a.answer;
      cites = a.citations;
    } else if (/halvorsen|contract|msa/i.test(q)) {
      const a = contractAnswer(vault, 0);
      text = a.answer;
      cites = a.citations;
    } else if (/android/i.test(q)) {
      text = "Nothing was decided. In Monday's design crit, Lena assumed Android offline would wait for 2.5 [1]; nobody confirmed it. In the v2.4 call Marcus said 2.5 as well [2].";
      cites = [
        { kind: "meeting", title: "Design crit — inspection checklist", meetingId: "m-2026-10-12-crit", start: 1312, speaker: "Lena" },
        { kind: "meeting", title: "Offline sync — v2.4 scope", meetingId: past.id, start: 1334, speaker: "Marcus" },
      ];
    } else {
      text = `Here's what I found for “${q}”: the closest moments are the queue-cap discussion [1] and the Halvorsen site visit note [2].`;
      cites = [c[1], c[3]];
    }
    if (atts.length) {
      const names = atts.map((a, i) => a.name ?? (a.path ? a.path.split("/").at(-1) : `pasted text ${i + 1}`));
      text = `Using ${names.length === 1 ? names[0] : `${names.length} attachments`} [${cites.length + 1}]: ` + text;
      cites = [...cites, ...atts.map((a, i) => ({ kind: "document", title: names[i], ...(a.path ? { path: a.path } : {}), snippet: (a.text ?? "").slice(0, 120) || undefined }))];
    }
    return { text, cites };
  }

  function search(body) {
    const words = String(body.query ?? "").toLowerCase().split(/\W+/).filter((w) => w.length > 2);
    const kinds = Array.isArray(body.kinds) && body.kinds.length ? body.kinds : null;
    const scored = corpus(vault)
      .filter((m) => !kinds || kinds.includes(m.kind))
      .map((m) => {
        const hay = `${m.title} ${m.snippet ?? ""} ${m.speaker ?? ""}`.toLowerCase();
        return { m, score: words.reduce((s, w) => s + (hay.includes(w) ? 1 : 0), 0) };
      })
      .filter((x) => words.length === 0 || x.score > 0)
      .sort((a, b) => b.score - a.score);
    return scored.slice(0, body.limit ?? 20).map((x) => x.m);
  }

  const readBody = (req) =>
    new Promise((res) => {
      let s = "";
      req.on("data", (c) => (s += c));
      req.on("end", () => {
        try {
          res(s ? JSON.parse(s) : {});
        } catch {
          res({});
        }
      });
    });

  const server = http.createServer(async (req, res) => {
    if (!/^(127\.0\.0\.1|localhost|\[::1\])(?::\d+)?$/.test(req.headers.host ?? "")) return res.writeHead(403).end();
    const origin = req.headers.origin;
    if (origin === "app://obsidian.md") {
      res.setHeader("Access-Control-Allow-Origin", origin);
      res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
      res.setHeader("Access-Control-Allow-Methods", "GET, POST, PATCH, OPTIONS");
      res.setHeader("Vary", "Origin");
      res.setHeader("Access-Control-Max-Age", "600");
    }
    if (origin && origin !== "app://obsidian.md") return res.writeHead(403).end();
    if (req.method === "OPTIONS") return res.writeHead(origin === "app://obsidian.md" ? 204 : 403).end();
    if (req.headers.authorization !== `Bearer ${token}`) {
      res.writeHead(401, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: "unauthorized" }));
    }
    const url = new URL(req.url, "http://127.0.0.1");
    const p = url.pathname;
    const json = (code, obj) => {
      res.writeHead(code, { "Content-Type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    const sse = () => {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
      res.flushHeaders?.();
    };
    try {
      if (req.method === "GET" && p === "/v1/status") return json(200, status());
      if (req.method === "POST" && p === "/v1/recording/start") {
        const b = await readBody(req);
        startRecording(b.title);
        return json(200, status());
      }
      if (req.method === "POST" && p === "/v1/recording/stop") {
        stopRecording();
        return json(200, status());
      }
      if (req.method === "GET" && p === "/v1/meetings") {
        const limit = Number(url.searchParams.get("limit") ?? 20);
        const all = [...meetings.values()].reverse().map(({ segments, notes, missedTopics, actionItems, answers, brief, enhancing, excerptSeq, ...s }) => s);
        return json(200, [...all, ...summaries].slice(0, limit).map(wireSummary));
      }
      const resumeMatch = /^\/v1\/meetings\/([^/]+)\/resume$/.exec(p);
      if (req.method === 'POST' && resumeMatch) {
        const mt=meetings.get(decodeURIComponent(resumeMatch[1]));
        if(!mt || mt.document?.finalized || !mt.endedAt || Date.now()-Date.parse(mt.endedAt)>=600000 || live) return json(409,{error:'Resume unavailable'});
        live={meeting:mt,startedAt:Date.now()-mt.duration*1000/speed,answerSeq:mt.answers.length};mt.status='recording';mt.endedAt=undefined;mt.purgeAt=undefined;
        broadcast('status',status());return json(200,status());
      }
      let m = /^\/v1\/meetings\/([^/]+)$/.exec(p);
      if (req.method === "GET" && m) {
        const mt = meetings.get(decodeURIComponent(m[1]));
        return mt ? json(200, { meeting: wireSummary(mt), segments: mt.segments.map(wireSegment),
          ...notesPayload(mt), endedAt: mt.endedAt, document: mt.document, meetingId: undefined, answers: mt.answers.map((a) => ({ ...wireAnswer(a), createdAt: new Date(Date.parse(mt.startedAt) + a.at * 1000).toISOString() })), attachments: [], clips: [] }) : json(404, { error: "no such meeting" });
      }
      m = /^\/v1\/meetings\/([^/]+)\/grab-moment$/.exec(p);
      if (m) {
        if (req.method !== 'POST') return json(405, { error: 'Method not allowed' });
        if (!live || live.meeting.id !== m[1]) return json(409, { error: 'Screen awareness is not recording this meeting' });
        return json(200, { filename: 'Meeting screen mock.png', at: elapsed(), png: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5b8AAAAASUVORK5CYII=' });
      }
      m = /^\/v1\/meetings\/([^/]+)\/(document|finalize)$/.exec(p);
      if (m && ["POST", "PATCH"].includes(req.method)) {
        const mt = meetings.get(decodeURIComponent(m[1]));
        if (!mt) return json(404, { error: "no such meeting" });
        if (mt.retention === "purged") return json(409, { error: "Meeting was purged" });
        if (m[2] === "finalize") {
          if (mt.status === "recording") return json(409, { error: "Stop recording first" });
          if (!mt.document) return json(404, { error: "Open document first" });
          try { return json(200, finalizeMockDocument(mt)); }
          catch (e) { return json(409,{error:e.message}); }
        }
        if (req.method === "POST") {
          if (!mt.document) {
            const path = resolve(vault, "Meetings", new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Los_Angeles'}).format(new Date(mt.startedAt)) + " " + mt.title + ".md");
            mkdirSync(dirname(path), { recursive:true });
            let source = `---\ndate: ${new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Los_Angeles',dateStyle:'short',timeStyle:'short'}).format(new Date(mt.startedAt))}\ntags:\n  - meeting\nworkscribe: "${mt.id}"\n---\n\n`;
            const blocks=mt.notes.map(n=>{const from=source.length;source+=n.text;const to=source.length;source+='\n';return {id:n.id,from,to,text:n.text,at:n.at};});
            if(!blocks.length)source+="- ";
            if (!existsSync(path)) writeFileSync(path,source, { flag:"wx" });
            mt.document = { path, source: readFileSync(path,"utf8"), revision:0, blocks, finalized:false };
            mt.vaultPath=path;
          }
          if (!existsSync(mt.document.path)) {
            const moved = readdirSync(vault,{recursive:true}).filter(p=>p.endsWith('.md') && !p.startsWith('.')).map(p=>resolve(vault,p))
              .find(path=>readFileSync(path,'utf8').includes(`workscribe: "${mt.id}"`));
            if (moved) { mt.document.path=moved; mt.vaultPath=moved; }
          }
          return json(200,mt.document);
        }
        const b = await readBody(req);
        if (!mt.document) return json(404,{error:"Open document first"});
        if (b.revision !== mt.document.revision || (mt.document.finalized && b.source !== mt.document.source) || b.finalized) return json(409,{error:"Stale or finalized document"});
        if (typeof b.path !== 'string' || !resolve(b.path).startsWith(resolve(vault)+'/') || !existsSync(b.path) ||
            !readFileSync(b.path,'utf8').includes(`workscribe: "${mt.id}"`) || typeof b.source !== "string" || !Array.isArray(b.blocks) || b.blocks.length > 2000) return json(422,{error:"Invalid document"});
        let end=0; const ids=new Set();
        for (const block of b.blocks) {
          if (!block.id || ids.has(block.id) || !Number.isInteger(block.from) || !Number.isInteger(block.to) || block.from < end || block.to <= block.from || block.to>b.source.length || b.source.slice(block.from,block.to)!==block.text) return json(422,{error:"Invalid block"});
          ids.add(block.id); end=block.to;
          if (block.owned) {
            const o=block.owned;
            if (!Number.isInteger(o.from) || !Number.isInteger(o.to) || o.from<end || o.to<o.from || o.to>b.source.length || b.source.slice(o.from,o.to)!==o.text || !o.text.length) return json(422,{error:"Invalid ownership"});
            end=o.to;
          }
        }
        const old=new Map(mt.notes.map(n=>[n.id,n]));
        mt.notes=b.blocks.map(block=> {
          const n=old.get(block.id) ?? {id:block.id,at:block.at,text:block.text,excerpts:[],state:"pending"};
          n.images = block.images?.map(i => ({ target: i.target, method: "unavailable", ...(opts.imageEvidence ?? {}) }));
          const changed=n.text!==block.text; n.text=block.text; block.at=n.at;
          if (block.owned) { n.edited=true; n.enhanced={topic:"",text:block.owned.text.split("\n").map(s=>s.replace(/^> ?/,"")).join("\n")}; n.state="done"; }
          else { if(n.edited){const previous=n.trace?.revisions.at(-1)?.text;if(previous)n.enhanced={topic:"",text:previous};} if(n.edited || changed) n.state="pending"; n.edited=false; }
          return n;
        });
        mt.document={...b,revision:b.revision+1};
        for (const n of mt.notes) if(n.state==="pending") enhance(mt,n);
        broadcast("notes",notesPayload(mt));
        return json(200,mt.document);
      }
      m = /^\/v1\/meetings\/([^/]+)\/notes$/.exec(p);
      if (req.method === "POST" && m) {
        const mt = meetings.get(decodeURIComponent(m[1]));
        if (!mt) return json(404, { error: "no such meeting" });
        const b = await readBody(req);
        if (mt.document) return json(409, { error: "Edit the meeting document in Obsidian" });
        if (typeof b.text !== "string") return json(400, { error: "text required" });
        if (!b.text.trim()) return json(422, { error: "Note text is empty" });
        mt.excerptSeq ??= 9;
        const note = { id: `n-${Date.now().toString(36)}-${mt.notes.length}`, at: typeof b.at === "number" ? b.at : live?.meeting === mt ? elapsed() : undefined, text: b.text, state: "pending", enhanced: null, excerpts: [] };
        if (b.fromAnswer) note.fromAnswer = b.fromAnswer;
        const missed = b.fromMissedTopic ? mt.missedTopics.find((t) => t.topic === b.fromMissedTopic.topic) : null;
        if (missed) {
          // A missed topic added back: it becomes an enhanced note with that span as evidence.
          note.state = "done";
          note.enhanced = { topic: missed.topic, text: missed.text };
          note.edited = true;
          mt.missedTopics = mt.missedTopics.filter((t) => t !== missed);
        }
        mt.notes.push(note);
        broadcast("note", { meetingId: mt.id, note });
        if (b.fromAnswer) {
          note.state = "plain";
          broadcast("note", { meetingId: mt.id, note });
        } else if (!missed) enhance(mt, note);
        return json(201, wireNote(note));
      }
      m = /^\/v1\/meetings\/([^/]+)\/done$/.exec(p);
      if (req.method === "POST" && m) {
        const mt = meetings.get(decodeURIComponent(m[1]));
        if (!mt) return json(404, { error: "no such meeting" });
        if (mt.status === "recording") return json(409, { error: "Stop recording first" });
        mt.retention = "purged";
        delete mt.document; mt.segments = []; mt.notes = []; mt.answers = []; mt.missedTopics = []; mt.actionItems = [];
        broadcast("meeting.purged", { meetingId: mt.id });
        return json(200, wireSummary(mt));
      }
      m = /^\/v1\/meetings\/([^/]+)\/notes\/([^/]+)$/.exec(p);
      if (req.method === "PATCH" && m) {
        const mt = meetings.get(decodeURIComponent(m[1]));
        const note = mt?.notes.find((n) => n.id === decodeURIComponent(m[2]));
        if (!note) return json(404, { error: "no such note" });
        if (mt.document) return json(409, { error: "Edit the meeting document in Obsidian" });
        const b = await readBody(req);
        if ([typeof b.text === "string", b.enhanced != null, b.rewrite === true].filter(Boolean).length !== 1) return json(400, { error: "Give exactly one of text or enhanced" });
        if (b.rewrite === true) {
          note.edited = false; note.state = "pending"; enhance(mt, note);
          return json(200, wireNote(note));
        }
        if (b.enhanced && typeof b.enhanced === "object") {
          // Your edit of the enhanced line: saved as-is, never re-enhanced over.
          note.enhanced = { topic: String(b.enhanced.topic ?? ""), text: String(b.enhanced.text ?? "") };
          note.state = "done";
          note.edited = true;
          broadcast("note", { meetingId: mt.id, note });
          return json(200, wireNote(note));
        }
        if (typeof b.text !== "string" || !b.text) return json(400, { error: "text or enhanced required" });
        note.text = b.text;
        note.state = note.edited ? "done" : "pending";
        broadcast("note", { meetingId: mt.id, note });
        if (!note.edited) enhance(mt, note);
        return json(200, wireNote(note));
      }
      if (req.method === "GET" && p === "/v1/events") {
        sse();
        clients.add(res);
        res.write(`id: ${++eventSeq}\nevent: status\ndata: ${JSON.stringify(status())}\n\n`);
        const ka = setInterval(() => res.write(": keep-alive\n\n"), 15000);
        req.on("close", () => {
          clearInterval(ka);
          clients.delete(res);
        });
        return;
      }
      if (req.method === "POST" && p === "/v1/ask") {
        const b = await readBody(req);
        if (!b.question) return json(400, { error: "question required" });
        const { text, cites } = askAnswer(b);
        const conversationId = b.conversationId ?? `c-${++convSeq}`;
        sse();
        res.write(`event: started\ndata: ${JSON.stringify({ conversationId, messageId: `message-${convSeq}` })}\n\n`);
        const toks = text.split(/(?<= )/);
        let i = 0;
        let closed = false;
        req.on("close", () => (closed = true));
        res.on("close", () => (closed = true));
        const step = () => {
          if (closed) return;
          if (i < toks.length) {
            res.write(`event: token\ndata: ${JSON.stringify({ text: toks[i++] })}\n\n`);
            setTimeout(step, 25 / speed);
          } else {
            res.write(`event: citations\ndata: ${JSON.stringify({ conversationId, answer: text, state: "answered", citations: cites.map(wireMoment), trace: {steps:[{title:"Searched notes, transcript and files",status:"complete",detail:`${cites.length} moments found`}],model:"Scripted fixture",location:"Test server",durationMs:420,revisions:[]} })}\n\n`);
            res.write(`event: done\ndata: ${JSON.stringify({ conversationId })}\n\n`);
            res.end();
          }
        };
        step();
        return;
      }
      if (req.method === "POST" && p === "/v1/search") return json(200, search(await readBody(req)).map((m) => wireMoment(m)));
      if (req.method === "POST" && p === "/v1/attachments") {
        const b = await readBody(req);
        if (!b.path && !b.text) return json(400, { error: "path or text required" });
        return json(201, { attachment: { id: `att-${Date.now().toString(36)}`, kind: b.path ? "file" : "text", name: b.path?.split("/").at(-1) ?? "Note", indexState: "indexed" },
          owner: b.meetingId ? `meeting:${b.meetingId}` : `conversation:${b.conversationId ?? `c-${++convSeq}`}` });
      }
      json(404, { error: `no route ${req.method} ${p}` });
    } catch (e) {
      json(500, { error: String(e) });
    }
  });

  await new Promise((r) => server.listen(opts.port ?? 0, "127.0.0.1", r));
  const port = server.address().port;
  let discoveryPath = null;
  if (opts.discovery !== false) {
    discoveryPath = resolve(opts.discovery ?? join(HERE, "api.json"));
    mkdirSync(dirname(discoveryPath), { recursive: true });
    writeFileSync(discoveryPath, JSON.stringify({ port, token, version: 1 }, null, 2));
  }
  if (opts.live) startRecording();

  return {
    port,
    token,
    discoveryPath,
    startRecording,
    stopRecording,
    close: () =>
      new Promise((r) => {
        for (const t of timers) clearTimeout(t);
        for (const c of clients) c.end();
        if (discoveryPath) rmSync(discoveryPath, { force: true });
        server.close(() => {
          if (ownsVault) rmSync(vault, { recursive: true, force: true });
          r();
        });
        server.closeAllConnections?.();
      }),
  };
}

// ---------------------------------------------------------------- CLI

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const opt = (name, d) => {
    const i = args.indexOf(`--${name}`);
    return i >= 0 ? args[i + 1] : d;
  };
  const srv = await startMockServer({
    port: Number(opt("port", 47615)),
    discovery: opt("discovery", join(HERE, "api.json")),
    vault: opt("vault", undefined),
    speed: Number(opt("speed", 1)),
    live: args.includes("--live"),
  });
  console.log(`[mock] WorkScribe mock API on http://127.0.0.1:${srv.port}`);
  console.log(`[mock] discovery file: ${srv.discoveryPath}  (set this as "api.json path" in the plugin settings)`);
  const bye = async () => {
    await srv.close();
    process.exit(0);
  };
  process.on("SIGINT", bye);
  process.on("SIGTERM", bye);
}
