// Opt-in transport contract against the actual Swift HTTP handlers, with isolated fixture providers.
// WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { rmSync, readFileSync, existsSync } from "node:fs";
import { canonicalPath } from "../src/lib/format";
import { WorkScribeClient } from "../src/lib/client";
import { nodeTransport } from "../src/lib/node-transport";
import { applyEvent, emptyLive } from "../src/lib/live";
import type { AskEvent, Discovery, LiveEvent } from "../src/lib/types";

test("real Swift API: discovery, wrapped detail, notes, streaming identity, citations and conversation reuse", {
  skip: !process.env.WORKSCRIBE_API_BINARY,
  timeout: 30000,
}, async () => {
  const proc = spawn(process.env.WORKSCRIBE_API_BINARY!, ["--serve-api-for-tests"], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  proc.stderr.on("data", (chunk) => { stderr += chunk; });
  let config: (Discovery & { root: string; meetingId: string }) | undefined;
  const ac = new AbortController();
  try {
    config = await new Promise((resolve, reject) => {
      let out = "";
      const timer = setTimeout(() => reject(new Error(`Server startup timed out: ${stderr}`)), 15000);
      proc.stdout.on("data", (chunk) => {
        out += chunk;
        if (out.includes("\n")) { clearTimeout(timer); resolve(JSON.parse(out.split("\n")[0]!)); }
      });
      proc.once("exit", (code) => { clearTimeout(timer); reject(new Error(`Server exited ${code}: ${stderr}`)); });
    });
    const c = config!;
    const client = new WorkScribeClient(nodeTransport, async () => c);
    assert.equal((await client.status()).recording, false);
    assert.equal((await client.meetings())[0]!.id, c.meetingId);
    const initial = await client.meeting(c.meetingId);
    assert.equal(initial.title, "API contract fixture");
    assert.equal(initial.segments[0]!.text, "Release is Friday.");
    const events: LiveEvent[] = [];
    const state = emptyLive();
    const { done } = await client.events((e) => { events.push(e); applyEvent(state, e); }, ac.signal);
    const wait = async (f: () => boolean) => {
      const until = Date.now() + 5000;
      while (!f()) { if (Date.now() > until) throw new Error("Event timeout"); await new Promise((r) => setTimeout(r, 10)); }
    };
    const n = await client.addNote(c.meetingId, "release", 2);
    assert.equal(n.state, "listening");
    assert.equal(n.line?.blockId, n.id);
    assert.equal(n.line?.documentId, c.meetingId);
    await wait(() => state.notes.get(n.id)?.state === "answered");
    await wait(() => events.some(e => e.type === 'line' && e.blockId === n.id && e.state === 'answered'));
    assert.ok(events.some(e => e.type === 'status' && 'model' in e && e.model === 'ready'));
    await client.patchNote(c.meetingId, n.id, { enhanced: { topic: "My release.", text: "User owns this." } });
    await new Promise((r) => setTimeout(r, 250));
    assert.equal((await client.meeting(c.meetingId)).notes.find((x) => x.id === n.id)!.enhanced?.text, "User owns this.");
    assert.equal(state.notes.get(n.id)!.enhanced?.text, "User owns this.");
    const edited = await client.addNote(c.meetingId, "draft", 3);
    await client.patchNote(c.meetingId, edited.id, { text: "release Friday" });
    await wait(() => state.notes.get(edited.id)?.state === "answered");
    const from = { answerId: "answer-1", question: "When?", askedBy: "Alex" };
    const answerNote = await client.addNote(c.meetingId, "Friday", 4, { fromAnswer: from });
    assert.deepEqual(answerNote.fromAnswer, from);
    assert.equal(answerNote.state, "quiet");
    const editedAnswer = await client.patchNote(c.meetingId, answerNote.id, { text: "Still Friday" });
    assert.equal(editedAnswer.state, "quiet");
    assert.deepEqual(editedAnswer.fromAnswer, from);
    await client.addNote(c.meetingId, "Release is Friday.", 5, { fromMissedTopic: { topic: "Release." } });
    assert.equal((await client.meeting(c.meetingId)).missedTopics.length, 0);
    await wait(() => state.missedTopics.length === 0 && state.notes.size === 4);
    const asks: AskEvent[] = [];
    await client.ask({ question: "Release?", meetingId: c.meetingId }, (e) => asks.push(e), new AbortController().signal);
    assert.deepEqual(asks.filter(e=>e.type!=="trace").map((e) => e.type), ["token", "token", "citations", "done"]);
    assert.ok(asks.some(e=>e.type==="trace" && e.trace.steps.length>0));
    const final = asks.find((e) => e.type === "citations")!;
    assert.equal(final.type, "citations");
    if (final.type !== "citations") throw new Error("Missing citations");
    assert.equal(final.answer, "Friday [1]. Confirmed [2].");
    assert.deepEqual(final.citations.map((x) => x.kind), ["meeting", "meeting"]);
    const end = asks.at(-1)!;
    if (end.type !== "done") throw new Error("Missing done");
    const next: AskEvent[] = [];
    await client.ask({ question: "Again?", conversationId: end.conversationId }, (e) => next.push(e), new AbortController().signal);
    assert.equal((next.at(-1) as { conversationId: string }).conversationId, end.conversationId);
    await wait(() => events.some((e) => e.type === "answer" && e.answer.done));
    const answers = events.filter((e) => e.type === "answer");
    assert.ok(answers.some((e) => e.type === "answer" && !e.answer.done));
    const first = answers[0]!;
    assert.ok(first.type === "answer" && answers.some((e) => e.type === "answer" && e.answer.done && e.answer.id === first.answer.id));
    assert.equal((await client.meeting(c.meetingId)).answers.length, 2);
    const attachment = await client.attach({ meetingId: c.meetingId }, { text: "fixture attachment" }) as { owner: string; attachment: { id: string } };
    assert.equal(attachment.owner, `meeting:${c.meetingId}`);
    assert.ok(attachment.attachment.id);
    const headers = { Origin: "app://obsidian.md" };
    const cors = await fetch(`http://127.0.0.1:${c.port}/v1/status`, { method: "OPTIONS", headers });
    assert.equal(cors.status, 204);
    assert.equal(cors.headers.get("access-control-allow-headers"), "Authorization, Content-Type");
    const denied = await fetch(`http://127.0.0.1:${c.port}/v1/status`);
    assert.equal(denied.status, 401);
    const owned = await client.patchNote(c.meetingId, n.id, { enhanced: { topic: "Mine", text: "Keep this wording" } });
    assert.equal(owned.userEdited, true);
    const handedBack = await client.patchNote(c.meetingId, n.id, { rewrite: true });
    assert.equal(handedBack.userEdited, false);
    await wait(() => state.notes.get(n.id)?.state === "answered");
    await client.done(c.meetingId);
    await wait(() => events.some(e => e.type === "purged" && e.meetingId === c.meetingId));
    const purged = await client.meeting(c.meetingId);
    assert.equal(purged.retention, "purged");
    assert.equal(purged.notes.length, 0);
    assert.equal(purged.segments.length, 0);
    assert.equal(purged.answers.length, 0);
    assert.ok(purged.vaultPath);
    const saved = readFileSync(purged.vaultPath!, "utf8");
    assert.ok(saved.includes("release"));
    assert.ok(!saved.includes("workscribe://"));
    assert.ok(!saved.includes("^e"));
    assert.ok(!existsSync(`${c.root}/Meetings/${c.meetingId}`));
    await assert.rejects(client.attach({ meetingId: c.meetingId }, { text: "Cannot recreate raw files" }));
    const later: AskEvent[] = [];
    await client.ask({ question: "What did my notes say?", meetingId: c.meetingId }, e => later.push(e), new AbortController().signal);
    const result = later.find(e => e.type === "citations");
    assert.ok(result && result.type === "citations" && result.citations.length > 0);
    if (result?.type === "citations") assert.ok(result.citations.every(x => x.kind === "note"));
    await client.done(c.meetingId);
    ac.abort();
    await done;
  } finally {
    ac.abort();
    if (proc.exitCode === null) { proc.kill("SIGTERM"); await once(proc, "exit"); }
    if (config?.root) rmSync(config.root, { recursive: true, force: true });
  }
});

test('real Swift API: document CAS, delete/reorder, ownership, same-file finalization and purge', {
  skip: !process.env.WORKSCRIBE_API_BINARY, timeout:30000,
}, async()=>{
  const proc=spawn(process.env.WORKSCRIBE_API_BINARY!,['--serve-api-for-tests'],{stdio:['ignore','pipe','pipe']});
  let root=''; let stderr=''; proc.stderr.on('data',x=>stderr+=x); const streamAbort=new AbortController();
  try {
    const c=await new Promise<Discovery & {root:string;meetingId:string}>((resolve,reject)=>{
      let out=''; const timer=setTimeout(()=>reject(new Error(stderr)),15000);
      proc.stdout.on('data',x=>{out+=x;if(out.includes('\n')){clearTimeout(timer);resolve(JSON.parse(out.split('\n')[0]));}});
      proc.once('exit',code=>{clearTimeout(timer);reject(new Error(`exit ${code}: ${stderr}`));});
    });
    root=c.root;
    const client=new WorkScribeClient(nodeTransport,async()=>c);
    let doc=await client.openDocument(c.meetingId);
    assert.ok(doc.path.startsWith(canonicalPath(root+'/Notes')+'/'));
    assert.equal(doc.path,canonicalPath(doc.path));
    const { writeFileSync, renameSync, symlinkSync }=await import('node:fs');
    const actualPath=doc.path;
    symlinkSync(canonicalPath(root+'/Notes'),root+'/Alias');
    doc.path=root+'/Alias/'+actualPath.split('/Notes/')[1];
    const prefix=doc.source;
    doc.source+='release Friday\n\nsecond';
    doc.blocks=[{id:'editor-a',from:prefix.length,to:prefix.length+14,text:'release Friday',at:4},
      {id:'editor-b',from:prefix.length+16,to:prefix.length+22,text:'second',at:5}];
    writeFileSync(doc.path,doc.source);
    doc=await client.syncDocument(c.meetingId,doc);
    assert.equal(doc.revision,1);
    assert.equal(doc.path,actualPath, 'server canonicalizes a document synced through an arbitrary symlink');
    await assert.rejects(client.addNote(c.meetingId,'legacy jot'),/409/);
    await assert.rejects(client.editNote(c.meetingId,'editor-a','legacy edit'),/409/);
    await assert.rejects(client.syncDocument(c.meetingId,{...doc,revision:0}),/409/);
    await assert.rejects(client.syncDocument(c.meetingId,{...doc,blocks:[doc.blocks[0],doc.blocks[0]]}),/422/);
    doc.source=prefix+'second edited\n\n> user wording';
    doc.blocks=[{id:'editor-b',from:prefix.length,to:prefix.length+13,text:'second edited',at:999,
      owned:{from:prefix.length+15,to:prefix.length+29,text:'> user wording'}}];
    const moved=doc.path.replace(/\.md$/,' renamed.md'); renameSync(doc.path,moved); doc.path=moved;
    writeFileSync(doc.path,doc.source);
    doc=await client.syncDocument(c.meetingId,doc);
    let m=await client.meeting(c.meetingId);
    assert.deepEqual(m.notes.map(n=>n.id),['editor-b']);
    assert.equal(m.notes[0].at,5); assert.equal(m.notes[0].userEdited,true);
    assert.equal(m.notes[0].enhanced?.text,'user wording');
    assert.equal(doc.blocks[0].at,5);
    writeFileSync(doc.path,doc.source+'\nexternal edit');
    const conflict=await client.finalizeDocument(c.meetingId);
    assert.ok(conflict.path.endsWith(' (WorkScribe).md'));
    // Use another fixture for subsequent finalization: the conflict copy is already committed.
    assert.ok(readFileSync(doc.path,'utf8').endsWith('external edit'));
    writeFileSync(doc.path,doc.source);
    doc=await client.syncDocument(c.meetingId,doc);
    doc.source+='\nexternal edit';
    writeFileSync(doc.path,doc.source);
    // External adjacent text remains part of the owned quote under Markdown lazy continuation;
    // the explicit ledger bounds are still verbatim and finalization does not touch either string.
    doc=await client.syncDocument(c.meetingId,doc);
    const events: LiveEvent[]=[];
    const stream=await client.events(e=>events.push(e),streamAbort.signal);
    await client.finalizeDocument(c.meetingId);
    await new Promise(r=>setTimeout(r,50));
    assert.ok(events.some(e=>e.type==='notes' && e.documentFinalized));
    streamAbort.abort();await stream.done;
    const final=readFileSync(doc.path,'utf8');
    assert.ok(final.includes('second edited')); assert.ok(final.includes('external edit')); assert.equal(final.split('> user wording').length,2);
    assert.ok(!final.includes('^e')); assert.ok(!final.includes('workscribe://'));
    await client.finalizeDocument(c.meetingId);
    assert.equal(readFileSync(doc.path,'utf8'),final);
    m=await client.meeting(c.meetingId); assert.equal(m.document?.finalized,true);
    await assert.rejects(client.syncDocument(c.meetingId,{...doc,source:doc.source+'forged'}),/409/);
    await client.done(c.meetingId); assert.equal(readFileSync(doc.path,'utf8'),final);
    assert.equal((await client.meeting(c.meetingId)).document,undefined);
  } finally {
    streamAbort.abort();proc.kill('SIGTERM'); await once(proc,'exit'); if(root) rmSync(root,{recursive:true,force:true});
  }
});
