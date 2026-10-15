import test from 'node:test';
import assert from 'node:assert/strict';
import { EditorState } from '@codemirror/state';
import { imageContent, parseBlocks, reconcile } from '../src/lib/anchors';
import { imageInsertion, placeImage, imageBytes } from '../src/lib/image-insert';
import { parseDocument, parseNote } from '../src/lib/parse';

test('image-only paragraphs and list items are image blocks; mixed words remain shorthand', () => {
  for (const text of ['![[Pasted image.png]]', '- ![[shot.jpg|500]]', '1. ![screenshot](<my image.png>)', '- [ ] ![x](shot.png)']) {
    const [block] = parseBlocks(text); assert.equal(block.kind,'image'); assert.equal(block.shorthand,''); assert.equal(block.images?.length,1);
  }
  assert.equal(imageContent('![figure][ref]', '[ref]: a.png').images[0].target, 'a.png');
  const mixed = imageContent('stall in 12 mini ![[shot.png]]');
  assert.equal(mixed.kind,'text'); assert.equal(mixed.shorthand,'stall in 12 mini');
  assert.equal(imageContent('`![[shot.png]]`').images.length,0);
  assert.equal(imageContent('![remote](https://x.test/a.png)').kind,'image');
  assert.equal(imageContent('![[another note]]').images.length,0);
});

test('image identity, metadata, first time, copy, and wire parsing survive edits', () => {
  const original = reconcile('![[a.png]]', [], 12, undefined, () => 'a');
  const next = reconcile('caption ![[a.png]]',original,25,undefined,()=>'b');
  assert.equal(next[0].id,'a');assert.equal(next[0].at,12);assert.equal(next[0].kind,'text');
  const d = parseDocument({path:'/vault/test.md',source:'![[a.png]]',revision:0,blocks:original});
  assert.equal(d.blocks[0].kind,'image'); assert.equal(d.blocks[0].images?.[0].target,'a.png');
  const copy = reconcile('![[a.png]]\n\n![[a.png]]', original, 13, undefined, () => 'b');
  assert.deepEqual(copy.map(b=>b.id), ['a','b']);
  const n = parseNote({id:'a',text:'![[a.png]]',images:[{target:'a.png',text:'OCR',method:'vision-ocr',seconds:.2}]});
  assert.equal(n.images?.[0].text,'OCR');
});

test('grab insertion point maps edits while IO is pending and rejects malformed image payloads', () => {
  let state = EditorState.create({doc:'abc',extensions:[imageInsertion]});
  state = state.update({effects:placeImage.of({id:'x',at:3})}).state;
  state = state.update({changes:{from:0,insert:'hello '}}).state;
  assert.equal(state.field(imageInsertion)?.at,9);
  assert.throws(()=>imageBytes({filename:'../secret.png',png:'a'}));
  assert.throws(()=>imageBytes({filename:'screen.png',png:btoa('not a png')}));
  assert.equal(imageBytes({filename:'screen.png',png:btoa(String.fromCharCode(137,80,78,71,13,10,26,10))}).data.byteLength,8);
});

test('grab-moment contract works through the actual client and mock server', async () => {
  const { startMockServer } = await import('../dev/mock-server.mjs');
  const { WorkScribeClient } = await import('../src/lib/client');
  const { nodeTransport } = await import('../src/lib/node-transport');
  const { readDiscovery } = await import('../src/lib/discovery');
  const { mkdtempSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const root = mkdtempSync(join(tmpdir(),'ws-image-test-'));
  const server = await startMockServer({discovery:join(root,'api.json'),vault:join(root,'vault'),quiet:true});
  try {
    const client = new WorkScribeClient(nodeTransport,()=>readDiscovery(join(root,'api.json')));
    await assert.rejects(client.grabMoment('missing'));
    const status = await client.startRecording('Images');
    const bytes = imageBytes(await client.grabMoment(status!.meetingId!));
    assert.equal(bytes.filename,'Meeting screen mock.png'); assert.ok(bytes.data.byteLength > 8);
    await client.stopRecording();
    await assert.rejects(client.grabMoment(status!.meetingId!));
  } finally { await server.close(); rmSync(root,{recursive:true,force:true}); }
});
