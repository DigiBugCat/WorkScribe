import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EditorState, Transaction, type TransactionSpec } from '@codemirror/state';
import { history, undo, redo } from '@codemirror/commands';
import { meetingEditor, refreshAI, ownBlock, setDocument, type EditorSession } from '../src/lib/editor-extension';
import { reconcile, quoteAI } from '../src/lib/anchors';
import type { Note } from '../src/lib/types';

function setup(text = 'hello world') {
  const blocks = reconcile(text,[],2,undefined,()=> 'n1');
  const note: Note = {id:'n1',text,at:2,excerpts:[],state:'done',enhanced:{topic:'Hello.',text:'First version'}};
  const session: EditorSession = {id:'meeting',document:{path:'/test.md',source:text,blocks,revision:0},notes:new Map([['n1',note]])};
  const ext=meetingEditor({ session:()=>session,elapsed:()=>100,changed:()=>{},mounted:()=>{},unmounted:()=>{},action:()=>{},takeOver:()=>{},why:()=>{},replaceDocument:(_s,d)=>{session.document=d;} });
  let state=EditorState.create({doc:text,extensions:[history(),ext.extension]});
  const dispatch=(tr: Transaction)=>{state=tr.state;};
  return {ext,session,get state(){return state;},dispatch,update:(spec: TransactionSpec)=>{dispatch(state.update(spec)); if(spec.changes) session.document={...session.document,source:state.doc.toString(),blocks:state.field(ext.field).blocks};},
    command:(f: typeof undo)=>f({get state(){return state;},dispatch})};
}
test('AI rewrites never touch file, selection, or undo history',()=>{
  const x=setup();
  x.update({changes:{from:11,insert:'!'},selection:{anchor:12},userEvent:'input'});
  const doc=x.state.doc.toString(), selection=x.state.selection.toJSON();
  for(let i=0;i<25;i++) {
    x.session.notes.set('n1',{...x.session.notes.get('n1')!,enhanced:{topic:'Hello.',text:`Updated ${i}`}});
    x.update({effects:refreshAI.of(),annotations:Transaction.addToHistory.of(false)});
    assert.equal(x.state.doc.toString(),doc); assert.deepEqual(x.state.selection.toJSON(),selection);
  }
  assert.ok(x.command(undo)); assert.equal(x.state.doc.toString(),'hello world');
  assert.ok(x.command(redo)); assert.equal(x.state.doc.toString(),doc);
});
test('taking ownership is one undoable insertion; redo restores ownership',()=>{
  const x=setup(); const text=quoteAI('My line');
  x.update({changes:{from:11,insert:'\n\n'+text+'\n'}, effects:ownBlock.of({id:'n1',owned:{from:13,to:13+text.length,text}}),userEvent:'input'});
  assert.equal(x.state.field(x.ext.field).blocks[0].owned?.text,text);
  assert.ok(x.command(undo)); assert.equal(x.state.doc.toString(),'hello world');
  assert.equal(x.state.field(x.ext.field).blocks[0].owned,undefined);
  assert.ok(x.command(redo));
  assert.equal(x.state.field(x.ext.field).blocks[0].owned?.text,text);
});
test('deleting a block removes decorations and undo restores the same identity',()=>{
  const x=setup(); x.update({changes:{from:0,to:11},userEvent:'delete'});
  assert.equal(x.state.field(x.ext.field).blocks.length,0);
  assert.equal(x.state.field(x.ext.field).decorations.size,0);
  assert.ok(x.command(undo)); assert.equal(x.state.field(x.ext.field).blocks[0].id,'n1');
});
test('200-block transaction benchmark includes parsing, mapping and decorations',()=>{
  const text=Array.from({length:200},(_,i)=>`- block ${i}`).join('\n'); let sequence=0;
  const blocks=reconcile(text,[],0,undefined,()=>String(sequence++));
  const session:EditorSession={id:'m',document:{path:'/test',source:text,revision:0,blocks},notes:new Map(blocks.map(b=>[b.id,{id:b.id,at:0,text:b.text,excerpts:[],state:'done',enhanced:{topic:'',text:'A long AI line '.repeat(30)}}]))};
  const e=meetingEditor({session:()=>session,elapsed:()=>2,changed:()=>{},mounted:()=>{},unmounted:()=>{},action:()=>{},takeOver:()=>{},why:()=>{},replaceDocument:(_s,d)=>{session.document=d;}});
  let state=EditorState.create({doc:text,extensions:e.extension}); const times:number[]=[];
  for(let i=0;i<200;i++) { const t=performance.now(); state=state.update({changes:{from:state.doc.length,insert:'x'}}).state; times.push(performance.now()-t); }
  times.sort((a,b)=>a-b); console.log(`200-block CM transaction p50=${times[100].toFixed(2)}ms p95=${times[190].toFixed(2)}ms`);
  assert.equal(state.field(e.field).blocks.length,200); assert.ok(times[190]<30,'typing p95 exceeds a frame budget on the test host');
});

test('cut/paste preserves identity while copying after ordinary deletion does not',()=>{
  const x=setup(); x.update({changes:{from:0,to:11},userEvent:'delete.cut'});
  x.update({changes:{from:0,insert:'hello world'},userEvent:'input.paste'});
  assert.equal(x.state.field(x.ext.field).blocks[0].id,'n1');
  x.update({changes:{from:0,to:11},userEvent:'delete'});
  x.update({changes:{from:0,insert:'hello world'},userEvent:'input.paste'});
  assert.notEqual(x.state.field(x.ext.field).blocks[0].id,'n1');
});
test('mirrored editors adopt the canonical IDs and first typed times',()=>{
  const x=setup();
  x.update({changes:{from:11,insert:'\n\nnew block'},userEvent:'input'});
  x.session.document={...x.session.document,source:x.state.doc.toString(),blocks:x.state.field(x.ext.field).blocks};
  const y=EditorState.create({doc:'hello world',extensions:x.ext.extension});
  const changed=y.update({changes:{from:11,insert:'\n\nnew block'}}).state;
  assert.deepEqual(changed.field(x.ext.field).blocks.map(b=>b.id),x.session.document.blocks.map(b=>b.id));
});

test('Finalize text and pencil retirement undo as one transaction',()=>{
 const x=setup();const before={...x.session.document};const after={...before,source:'hello world\n*First version*',finalized:true};
 x.update({changes:{from:0,to:x.state.doc.length,insert:after.source},effects:setDocument.of({document:after,previous:before}),userEvent:'input.finalize'});
 assert.equal(x.state.field(x.ext.field).decorations.size,0);
 assert.ok(x.command(undo));assert.equal(x.state.doc.toString(),before.source);assert.equal(x.session.document.finalized,undefined);
 assert.equal(x.state.field(x.ext.field).blocks[0].id,'n1');
 assert.ok(x.command(redo));assert.equal(x.state.doc.toString(),after.source);assert.equal(x.session.document.finalized,true);
});
