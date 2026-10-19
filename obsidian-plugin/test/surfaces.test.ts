import {test} from 'node:test';
import assert from 'node:assert/strict';
import {EditorState,ChangeSet,Transaction} from '@codemirror/state';
import {history,undo,redo} from '@codemirror/commands';
import {reconcile,parseBlocks} from '../src/lib/anchors';
import {SurfaceStore} from '../src/lib/surface-store';
import {linePresentation} from '../src/ui/surfaces/line';
import {pinRange} from '../src/ui/surfaces/pin';
import {diagramInsertion} from '../src/ui/surfaces/make';
import {surfaceStatus} from '../src/ui/surfaces/status';
import {surfaceDecorations,type SurfaceHost} from '../src/ui/surfaces';
import {parseLiveEvent} from '../src/lib/parse';
import type {LineEvent} from '../src/lib/types';
import {readFileSync} from 'node:fs';
const base:LineEvent={type:'line',documentId:'d',blockId:'b',state:'listening',revision:0,sources:[]};
const block={id:'b',from:0,to:4,text:'why?',at:0};
test('line lifecycle: timed silence, found nib, answered/settled, quiet question and ownership',()=>{
 assert.equal(linePresentation(base,block,true,7,0),null);
 assert.equal(linePresentation(base,block,true,8,0),'');
 assert.equal(linePresentation(base,block,false,50,0),null);
 assert.equal(linePresentation({...base,state:'found'},block,true,10,1499),null);
 assert.equal(linePresentation({...base,state:'found'},block,true,10,1500),'');
 for(const state of ['answered','settled'] as const)assert.equal(linePresentation({...base,state,text:'Evidence'},block,true,10,0),'Evidence');
 assert.equal(linePresentation({...base,state:'quiet'},block,false,10,0),'Not discussed');
 assert.equal(linePresentation({...base,state:'quiet'},{...block,text:'jot'},false,10,0),null);
 assert.equal(linePresentation({...base,state:'yours'},block,false,10,0),null);
});
test('pin anchors resolve cells, escaped pipes, code lines and task without writes',()=>{
 const text='| Area | Decision |\n| --- | --- |\n| Photos | cap\\|still? |';const b={id:'t',from:0,to:text.length,text};
 const r=pinRange(b,{kind:'cell',path:[2,1]})!;assert.equal(text.slice(r.from,r.to),'cap\\|still?');
 assert.equal(pinRange(b,{kind:'cell',path:[2,20]}),null);
 const task={...b,text:'- [ ] Tell Halvorsen',to:20};assert.ok(pinRange(task,{kind:'task',path:[]}));assert.equal(task.text,'- [ ] Tell Halvorsen');
});
test('pin and check references survive inserted rows and go quiet when their text is edited',()=>{
 let source='| A | B |\n|---|---|\n| x | cap? |\n\nWe ship in November.';
 let i=0;let blocks=reconcile(source,[],0,undefined,()=>String(i++));const store=new SurfaceStore();const table=blocks[0],prose=blocks[1];
 store.apply({type:'pin',documentId:'d',blockId:table.id,anchor:{kind:'cell',path:[2,1]},sources:[]});
 store.apply({type:'check',documentId:'d',blockId:prose.id,sentence:{from:0,to:prose.text.length},verdict:'supported',sources:[]});
 const at=source.indexOf('| x');const changes=ChangeSet.of({from:at,insert:'| new | row |\n'},source.length);store.mapEdits('d',blocks,changes);
 source=changes.apply(EditorState.create({doc:source}).doc).toString();blocks=reconcile(source,blocks,0,changes);
 const pin=[...store.pins.values()][0],next=blocks.find(b=>b.id===table.id)!;const range=pinRange(next,pin.anchor)!;
 assert.equal(source.slice(range.from,range.to),'cap?');assert.equal(store.checks.size,1);
 const edit=ChangeSet.of({from:range.from,to:range.to,insert:'changed'},source.length);store.mapEdits('d',blocks,edit);assert.equal(store.pins.size,0);
});
test('pin and check decorations do not touch prose/table or undo history',()=>{
 const source='A sentence.\n\n| A | B |\n|---|---|\n| x | y |';let i=0;const blocks=reconcile(source,[],0,undefined,()=>String(i++));const store=new SurfaceStore();
 const host:SurfaceHost={store,recording:()=>false,elapsed:()=>0,sources:()=>{},own:()=>{},rewrite:()=>{},openSources:()=>{},preview:()=>undefined,pending:()=>false,make:()=>{},discard:()=>{},insert:()=>{},renderMermaid:()=>{}};
 store.apply({type:'check',documentId:'d',blockId:blocks[0].id,sentence:{from:0,to:11},verdict:'differs',note:'Different',sources:[]});
 store.apply({type:'pin',documentId:'d',blockId:blocks[1].id,anchor:{kind:'cell',path:[2,1]},sources:[]});
 const state=EditorState.create({doc:source,extensions:history()});assert.equal(surfaceDecorations(host,'d',blocks,()=>false).length,4);
 assert.equal(state.doc.toString(),source);assert.equal(undo({state,dispatch:()=>assert.fail('No automatic history')}),false);
});
test('Make insert is one undoable Markdown edit and preserves sketch exactly',()=>{
 const source='```sketch\nA -> B\n```';const b={id:'b',from:0,to:source.length,text:source};let state=EditorState.create({doc:source,extensions:history()});
 state=state.update({changes:diagramInsertion(b,'flowchart LR\n A --> B'),userEvent:'input.make-diagram'}).state;
 assert.ok(state.doc.toString().startsWith(source));assert.ok(state.doc.toString().includes('```mermaid'));
 const dispatch=(tr:Transaction)=>{state=tr.state;};assert.ok(undo({get state(){return state;},dispatch}));assert.equal(state.doc.toString(),source);assert.ok(redo({get state(){return state;},dispatch}));
 assert.ok(diagramInsertion(b,'```\nmalformed').insert.startsWith('\n\n````mermaid'));
});
test('surface decoding, revisions, purge and one global status fail closed',()=>{
 assert.equal(parseLiveEvent('line',JSON.stringify({...base,revision:-1})),null);
 assert.equal(parseLiveEvent('check',JSON.stringify({type:'check',documentId:'d',blockId:'b',sentence:{from:5,to:1},verdict:'differs'})),null);
 assert.deepEqual(parseLiveEvent('status','{"model":"loading","paused":"ASR pressure"}'),{type:'status',model:'loading',paused:'ASR pressure'});
 const store=new SurfaceStore();store.apply({...base,state:'answered',revision:2,text:'new',sources:[{kind:'meeting',title:'private quote'}]});store.apply({...base,revision:1});assert.equal(store.line('d',block)?.revision,2);
 store.purge('d');assert.deepEqual(store.line('d',block)?.sources,[]);assert.equal(store.line('d',block)?.reason,'Sources faded with the transcript');store.apply({...base,revision:3,sources:[{kind:'meeting',title:'late private quote'}]});assert.deepEqual(store.line('d',block)?.sources,[]);
 assert.equal(surfaceStatus({model:'missing',paused:'Model unavailable'},true),'Recording · Model missing · Paused · Model unavailable');
});
test('structured blocks reconcile identities across ordinary edits; reduced motion is explicit',()=>{
 const text='```sketch\nA -> B\n```\n\n| A | B |\n|---|---|\n| x | y |';let i=0;const blocks=reconcile(text,[],0,undefined,()=>String(i++));assert.deepEqual(parseBlocks(text).map(b=>b.surface),['fence','table']);
 const change=ChangeSet.of({from:0,insert:'intro\n\n'},text.length),next=reconcile('intro\n\n'+text,blocks,0,change);assert.equal(next[1].id,blocks[0].id);assert.equal(next[2].id,blocks[1].id);
 const css=readFileSync('styles.css','utf8');assert.match(css,/@media \(prefers-reduced-motion:reduce\)[\s\S]*animation:none!important;transition:none!important/);assert.match(css,/ws-surface-revision 1\.2s/);
});


test('nested list blocks remain anchors but never mount automatic AI lines',()=>{
 const blocks=reconcile('- top\n  - child',[],0,undefined,(()=>{let n=0;return ()=>String(n++);})());
 assert.equal(blocks[1].nested,true);
 const store=new SurfaceStore();store.apply({...base,blockId:blocks[1].id,state:'answered',text:'No nested line'});
 const host:SurfaceHost={store,recording:()=>true,elapsed:()=>100,sources:()=>{},own:()=>{},rewrite:()=>{},openSources:()=>{},preview:()=>undefined,pending:()=>false,make:()=>{},discard:()=>{},insert:()=>{},renderMermaid:()=>{}};
 assert.equal(surfaceDecorations(host,'d',blocks,()=>false).length,0);
});
