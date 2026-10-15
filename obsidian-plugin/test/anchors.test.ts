import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChangeSet } from '@codemirror/state';
import { parseBlocks, reconcile } from '../src/lib/anchors';
let seq = 0;
const id = () => `id-${++seq}`;
function edit(old: string, from: number, to: number, insert: string) {
  const c = ChangeSet.of({ from, to, insert }, old.length);
  return { c, text: old.slice(0, from) + insert + old.slice(to) };
}
test('Markdown units retain nested children, exclude context and opaque blocks', () => {
  const text = '---\nkey: value\n---\n# Context\n\nparagraph\ncontinued\n\n- parent\n  - child\n- [ ] task\n\n```js\nnot a note\n```\n\n> quote\n\n| a | b |\n|---|---|\n| x | y |\n';
  const b = parseBlocks(text);
  assert.deepEqual(b.map(x => x.text), ['paragraph\ncontinued', '- parent', '  - child', '- [ ] task']);
  assert.ok(b.every(x => text.slice(x.from, x.to) === x.text));
  assert.ok(b.every(x => x.section === 'Context'));
});
test('mapped duplicate paste keeps original, gives fresh identity to copy', () => {
  const s = 'alpha\n\nbeta'; const b = reconcile(s, [], 1, undefined, id);
  const {c,text} = edit(s, 0, 0, 'alpha\n\n');
  const next = reconcile(text,b,2,c,id);
  assert.equal(next[1].id,b[0].id); assert.notEqual(next[0].id,b[0].id); assert.equal(next[1].at,1);
});
test('split, merge, move and history restore have explicit identity semantics', () => {
  const s = 'alpha bravo\n\ncharlie'; const b = reconcile(s,[],1,undefined,id);
  const split = edit(s,5,6,'\n\n'); const n = reconcile(split.text,b,2,split.c,id);
  assert.equal(n[0].id,b[0].id); assert.notEqual(n[1].id,b[0].id);
  const merge = edit(split.text,5,7,' '); const m = reconcile(merge.text,n,3,merge.c,id);
  assert.equal(m[0].id,b[0].id);
  const moved = reconcile('charlie\n\nalpha bravo',m,4,undefined,id);
  assert.deepEqual(moved.map(x=>x.id),[b[1].id,b[0].id]);
  const deleted = reconcile('charlie',m,5,undefined,id);
  assert.equal(deleted[0].id,b[1].id);
  const undo = reconcile(s,deleted,6,undefined,id,m);
  assert.deepEqual(undo.map(x=>x.id),b.map(x=>x.id));
});
test('200 blocks retain IDs and first typed times across 1000 edits', () => {
  let text = Array.from({length:200},(_,i)=>`- note ${i}`).join('\n');
  let blocks = reconcile(text,[],12,undefined,id); const ids = blocks.map(x=>x.id);
  const start = performance.now();
  for(let j=0;j<1000;j++) {
    const p=blocks[j%200].to;
    const e=edit(text,p,p,'x'); blocks=reconcile(e.text,blocks,99,e.c,id); text=e.text;
    assert.deepEqual(blocks.map(x=>x.id),ids);
    assert.ok(blocks.every(b=>b.at===12));
  }
  console.log(`anchoring 200 blocks × 1000 edits: ${(performance.now()-start).toFixed(1)}ms`);
  assert.equal(text.includes('^e'),false);
});
test('unrelated offline replacement gets a fresh ID instead of inheriting old evidence',()=>{
  const previous=reconcile('budget for spring',[],1,undefined,id);
  assert.notEqual(reconcile('travel to Japan',previous,undefined,undefined,id)[0].id,previous[0].id);
  assert.equal(reconcile('budget for summer',previous,undefined,undefined,id)[0].id,previous[0].id);
});
test('owned text tracks edge typing and remains owned after quote formatting is removed',()=>{
  const source='parent\n\n> Mine';
  const old=[{id:'p',from:0,to:6,text:'parent',at:1,owned:{from:8,to:14,text:'> Mine'}}];
  const append=edit(source,14,14,' forever');
  const next=reconcile(append.text,old,2,append.c,id);
  assert.equal(next.length,1);assert.equal(next[0].owned?.text,'> Mine forever');
  const unquote=edit(append.text,8,10,'');
  const plain=reconcile(unquote.text,next,3,unquote.c,id);
  assert.equal(plain.length,1);assert.equal(plain[0].owned?.text,'Mine forever');
});
