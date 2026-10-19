import { canonicalPath } from "../src/lib/format";
// End-to-end: the real client + Node transport + SSE parser against dev/mock-server.mjs.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startMockServer, type MockServer } from "../dev/mock-server.mjs";
import { ApiError, WorkScribeClient } from "../src/lib/client";
import { EventsConnection, type ConnState } from "../src/lib/connection";
import { readDiscovery } from "../src/lib/discovery";
import { applyEvent, emptyLive } from "../src/lib/live";
import { nodeTransport } from "../src/lib/node-transport";
import type { AskEvent, LiveEvent } from "../src/lib/types";

let srv: MockServer;
let dir: string;
let client: WorkScribeClient;
let vault: string;

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "ws-plugin-test-"));
  vault=join(dir,"vault");
  srv = await startMockServer({ discovery: join(dir, "api.json"), vault, speed: 20, quiet: true });
  client = new WorkScribeClient(nodeTransport, () => readDiscovery(join(dir, "api.json")));
});

after(async () => {
  await srv.close();
  rmSync(dir, { recursive: true, force: true });
});

function until<T>(pred: () => T | undefined | false, ms = 4000): Promise<T> {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const tick = () => {
      const v = pred();
      if (v) return resolve(v);
      if (Date.now() - t0 > ms) return reject(new Error("timed out"));
      setTimeout(tick, 20);
    };
    tick();
  });
}

test("status, meeting list and the sample meeting", async () => {
  const s = await client.status();
  assert.equal(s.recording, false);
  const list = await client.meetings(10);
  assert.ok(list.some((m) => m.title === "Offline sync — v2.4 scope"));
  const m = await client.meeting("m-2026-10-13-offline-sync");
  assert.deepEqual(m.speakers, ["You", "Priya Raman", "Marcus Chen"]);
  assert.equal(m.notes[0]!.excerpts.find((e) => e.id === "E3")!.match, "meaning");
  assert.equal(m.actionItems.length, 4);
  assert.equal(m.answers[0]!.citations[0]!.page, 14);
});

test("live meeting over SSE: segments, jot → enhancement, live answer", async () => {
  const state = emptyLive();
  const events: LiveEvent[] = [];
  const ac = new AbortController();
  const { done } = await client.events((ev) => {
    events.push(ev);
    applyEvent(state, ev);
  }, ac.signal);
  await until(() => events.some((e) => e.type === "status"));
  await client.startRecording("Offline sync — v2.4 scope");
  await until(() => state.meetingId && state.status?.recording);
  await until(() => state.segments.some((s) => !s.final));
  await until(() => state.segments.some((s) => s.final));

  const n = await client.addNote(state.meetingId!, "offline conflicts → LWW?? marcus pushback", 12.3);
  assert.equal(n.state, "listening");
  const enhanced = await until(() => {
    const x = state.notes.get(n.id);
    return x?.state === "answered" ? x : undefined;
  });
  assert.equal(enhanced.enhanced?.topic, "Conflict resolution.");
  assert.ok(enhanced.excerpts.some((e) => e.match === "meaning"));
  await until(() => state.upToDate);

  const plain = await client.addNote(state.meetingId!, "android parity?");
  await until(() => state.notes.get(plain.id)?.state === "quiet");

  const edited = await client.editNote(state.meetingId!, plain.id, "ship date nov 4 not oct 28");
  assert.equal(edited.text, "ship date nov 4 not oct 28");
  await until(() => state.notes.get(plain.id)?.enhanced?.topic === "Ship date.");

  const ans = await until(() => (state.answer?.done ? state.answer : undefined), 6000);
  assert.ok(ans.citations.length > 0);
  assert.ok(events.some((e) => e.type === "answer" && !e.answer.done), "answer streamed in pieces");

  await client.stopRecording();
  await until(() => state.status && !state.status.recording);
  ac.abort();
  await done;
});

test("ask streams tokens then citations, with attachments", async () => {
  const evs: AskEvent[] = [];
  await client.ask(
    { question: "What does the Halvorsen contract say about offline?", attachments: [{ path: `${vault}/Notes/a.md` }, { text: "pasted" }] },
    (e) => evs.push(e),
    new AbortController().signal,
  );
  const tokens = evs.filter((e) => e.type === "token");
  assert.ok(tokens.length > 5);
  const text = tokens.map((e) => (e.type === "token" ? e.text : "")).join("");
  assert.match(text, /Dec 31.*\[1\]/);
  const cites = evs.find((e) => e.type === "citations");
  assert.ok(cites && cites.type === "citations" && cites.citations.length === 4);
  const done = evs.at(-1);
  assert.ok(done?.type === "done" && done.conversationId);
});

test("ask can be cancelled mid-stream", async () => {
  const ac = new AbortController();
  let n = 0;
  await assert.rejects(
    client.ask({ question: "anything at all about storage" }, () => {
      if (++n === 2) ac.abort();
    }, ac.signal).then(() => {
      if (ac.signal.aborted) throw new ApiError("aborted", "Cancelled");
    }),
    (e: unknown) => e instanceof ApiError && e.kind === "aborted",
  );
});

test("search returns moments; kinds filter", async () => {
  const all = await client.search("inspector phone storage photos");
  assert.ok(all.length >= 3);
  assert.ok(all.some((m) => m.kind === "clip" && m.path?.startsWith(canonicalPath(vault))));
  const pdfs = await client.search("storage photos queue", ["pdf"]);
  assert.ok(pdfs.length > 0 && pdfs.every((m) => m.kind === "pdf"));
});

test("past meeting: edit enhanced text, add a missed topic to notes", async () => {
  const id = "m-2026-10-13-offline-sync";
  const before = await client.meeting(id);
  assert.equal(before.notes[0]!.blockId, "e1");
  const n = await client.patchNote(id, "n2", { enhanced: { topic: "Ship date.", text: "Nov 4, confirmed with QA." } });
  assert.equal(n.enhanced?.text, "Nov 4, confirmed with QA.");
  assert.equal(n.state, "answered");
  const t = before.missedTopics[0]!;
  const added = await client.addNote(id, `${t.topic} ${t.text}`, t.start, { fromMissedTopic: { topic: t.topic } });
  assert.equal(added.enhanced?.topic, t.topic);
  const after = await client.meeting(id);
  assert.equal(after.missedTopics.length, before.missedTopics.length - 1);
  assert.equal(after.notes.find((x) => x.id === "n2")!.enhanced?.text, "Nov 4, confirmed with QA.");
});

test("attachments endpoint", async () => {
  const r = (await client.attach({ conversationId: "c1" }, { text: "hello" })) as { attachment: { indexState: string }; owner: string };
  assert.equal(r.attachment.indexState, "indexed");
  assert.equal(r.owner, "conversation:c1");
});

test("bad token → auth error; missing api.json → offline", async () => {
  const bad = join(dir, "bad.json");
  writeFileSync(bad, JSON.stringify({ port: srv.port, token: "wrong", version: 1 }));
  const c2 = new WorkScribeClient(nodeTransport, () => readDiscovery(bad));
  await assert.rejects(c2.status(), (e: unknown) => e instanceof ApiError && e.kind === "auth");
  await assert.rejects(c2.events(() => undefined, new AbortController().signal), (e: unknown) => e instanceof ApiError && e.kind === "auth");
  const c3 = new WorkScribeClient(nodeTransport, () => readDiscovery(join(dir, "missing.json")));
  await assert.rejects(c3.status(), (e: unknown) => e instanceof ApiError && e.kind === "offline" && /isn't running/.test(e.message));
  // Port with nothing listening.
  const dead = join(dir, "dead.json");
  writeFileSync(dead, JSON.stringify({ port: 1, token: "x", version: 1 }));
  const c4 = new WorkScribeClient(nodeTransport, () => readDiscovery(dead));
  await assert.rejects(c4.meetings(), (e: unknown) => e instanceof ApiError && e.kind === "offline");
});

test("EventsConnection goes online, then offline when the app is unreachable", async () => {
  const states: ConnState[] = [];
  const got: LiveEvent[] = [];
  const conn = new EventsConnection(client, (e) => got.push(e), (s) => states.push(s));
  conn.start();
  await until(() => states.some((s) => s.kind === "online"));
  await until(() => got.some((e) => e.type === "status"));
  conn.stop();

  const offStates: ConnState[] = [];
  const c3 = new WorkScribeClient(nodeTransport, () => readDiscovery(join(dir, "missing.json")));
  const off = new EventsConnection(c3, () => undefined, (s) => offStates.push(s), { set: () => 0, clear: () => undefined });
  off.start();
  await until(() => offStates.some((s) => s.kind === "offline"));
  off.stop();
});


test("Done clears raw meeting data and emits the purged contract", async () => {
  const status = await client.startRecording("Ephemeral test");
  const id = status!.meetingId!;
  const note = await client.addNote(id, "release Friday", 2);
  const edited = await client.patchNote(id, note.id, { enhanced: { topic: "Mine", text: "My text" } });
  assert.equal(edited.userEdited, true);
  assert.equal((await client.patchNote(id, note.id, { rewrite: true })).userEdited, false);
  await client.stopRecording();
  const before = await client.meeting(id);
  assert.equal(before.retention, "finalized");
  assert.ok(before.purgeAt);
  await client.done(id);
  const after = await client.meeting(id);
  assert.equal(after.retention, "purged");
  assert.equal(after.notes.length, 0); assert.equal(after.segments.length, 0);
  await client.done(id);
});


test('surface replay and Make preview travel through the real client and SSE decoder',async()=>{
 const events:LiveEvent[]=[];const ac=new AbortController();const {done}=await client.events(e=>events.push(e),ac.signal);
 srv.replaySurfaces();
 await until(()=>events.some(e=>e.type==='check'));
 assert.ok(events.some(e=>e.type==='line'&&e.state==='answered'));
 assert.ok(events.some(e=>e.type==='pin'&&e.anchor.kind==='cell'));
 assert.ok(events.some(e=>e.type==='status'&&'model' in e&&e.model==='ready'));
 const request=await client.makeDiagram('surface-demo','sketch');
 const preview=await until(()=>events.find(e=>e.type==='preview'&&e.requestId===request.requestId));
 assert.ok(preview.type==='preview'&&preview.mermaid.includes('flowchart'));
 ac.abort();await done.catch(()=>{});
});
