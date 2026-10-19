import {EditorState,Transaction} from '@codemirror/state';
import {EditorView,keymap} from '@codemirror/view';
import {history,historyKeymap,undo,redo} from '@codemirror/commands';
import mermaid from 'mermaid';
import {meetingEditor,aiRefresh,ownBlock} from '../src/lib/editor-extension';
import {reconcile,quoteAI} from '../src/lib/anchors';
import {SurfaceStore} from '../src/lib/surface-store';
import {insertDiagram} from '../src/ui/surfaces/make';
import {renderSurfaceSources} from '../src/ui/surfaces/sources';
import {surfaceStatus} from '../src/ui/surfaces/status';
import {surfaceFixture,surfaceFrames} from './surface-replay.mjs';
const store=new SurfaceStore();let recording=true,sequence=0,requestId:string|undefined;
const blocks=reconcile(surfaceFixture.source,[],0,undefined,()=>surfaceFixture.blockIds[sequence++]);
const session={id:surfaceFixture.documentId,document:{path:'test.md',source:surfaceFixture.source,revision:0,blocks},notes:new Map()};
const status=document.querySelector<HTMLElement>('#status')!;
function show(sources:any[]){
 renderSurfaceSources(document.querySelector('#sources')!,sources,s=>focusSource(s));
 document.querySelectorAll('.transcript-row').forEach(el=>el.classList.remove('is-evidence'));
 for(const source of sources)focusSource(source);
}
function focusSource(source:any){const row=document.querySelector<HTMLElement>(`[data-segment="${source.segmentId}"]`);row?.classList.add('is-evidence');row?.scrollIntoView({block:'nearest'});}
const host:any={store,canMake:true,recording:()=>recording,elapsed:()=>100,sources:(line:any)=>show(line.sources),openSources:show,
 own:(view:EditorView,block:any,text:string)=>{const quote=quoteAI(text);view.dispatch({changes:{from:block.to,insert:'\n\n'+quote},effects:ownBlock.of({id:block.id,owned:{from:block.to+2,to:block.to+2+quote.length,text:quote}}),userEvent:'input.own'});},
 rewrite:()=>{},pending:()=>!!requestId&&!store.previews.has(requestId),preview:()=>requestId?store.previews.get(requestId):undefined,
 make:async()=>{requestId=undefined;const r=await fetch('/v1/documents/surface-demo/blocks/sketch/make',{method:'POST',body:JSON.stringify({kind:'diagram'}),headers:{'Content-Type':'application/json'}});requestId=(await r.json()).requestId;refresh();},
 discard:()=>{requestId=undefined;refresh();},insert:(view:EditorView,block:any,preview:any)=>{insertDiagram(view,block,preview);requestId=undefined;refresh();},
 renderMermaid:async(code:string,container:HTMLElement)=>{mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:document.body.classList.contains('theme-dark')?'dark':'neutral',themeVariables:{fontFamily:'system-ui'}});const {svg}=await mermaid.render('diagram-'+(++sequence),code);container.innerHTML=svg;},
};
const extension=meetingEditor({session:()=>session,surfaces:()=>host,elapsed:()=>100,recording:()=>recording,changed:(view,blocks)=>{session.document={...session.document,source:view.state.doc.toString(),blocks};},mounted:()=>{},unmounted:()=>{},takeOver:host.own,why:()=>{},action:()=>{},replaceDocument:(_state,document)=>{session.document=document;}});
const view=new EditorView({state:EditorState.create({doc:surfaceFixture.source,extensions:[history(),keymap.of(historyKeymap),extension.extension,EditorView.lineWrapping,EditorView.theme({'.cm-content':{padding:'24px 32px'},'&':{height:'100%'},'.cm-scroller':{overflow:'auto',fontFamily:'inherit'},'.cm-line':{lineHeight:'1.75'}})]}),parent:document.querySelector('#editor')!});
function refresh(){view.dispatch(aiRefresh());status.textContent=surfaceStatus(store.status,recording);}
function apply(event:any){if(event.type==='status')store.status=event;else store.apply(event);refresh();}
const transcript=document.querySelector('#transcript')!;const seen=new Set();
for(const {event} of surfaceFrames)for(const source of event.sources??[])if(!seen.has(source.segmentId)){seen.add(source.segmentId);const row=document.createElement('div');row.className='transcript-row';row.dataset.segment=source.segmentId;row.textContent=`${Math.floor(source.at/60)}:${String(source.at%60).padStart(2,'0')} · ${source.speaker}\n${source.quote}`;transcript.append(row);}
const stream=new EventSource('/v1/events');for(const name of ['line','pin','check','preview'])stream.addEventListener(name,(event:any)=>apply(JSON.parse(event.data)));
(window as any).qa={view,store,blocks,apply,refresh,frames:surfaceFrames,source:surfaceFixture.source,
 all:()=>{for(const f of surfaceFrames)apply(f.event);recording=false;refresh();},
 revision:()=>{const rev=store.lines.get('surface-demo/ship')!.revision;apply({...surfaceFrames.find(f=>f.event.blockId==='ship'&&f.event.revision===1)!.event,revision:rev+1});requestAnimationFrame(()=>apply({...surfaceFrames.find(f=>f.event.blockId==='ship'&&f.event.revision===2)!.event,revision:rev+2}));},
 undo:()=>undo(view),redo:()=>redo(view),
 theme:(dark:boolean)=>{document.body.className=dark?'theme-dark':'theme-light';refresh();},
};
refresh();
