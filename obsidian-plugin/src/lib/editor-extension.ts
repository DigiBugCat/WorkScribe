import { StateEffect, StateField, Transaction, type EditorState, type Extension } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, type DecorationSet } from '@codemirror/view';
import { invertedEffects } from '@codemirror/commands';
import { reconcile, type Block, type NoteDocument } from './anchors';
import type { Note } from './types';
import { SurfaceStore } from './surface-store';
import { surfaceDecorations, type SurfaceHost } from '../ui/surfaces';

export interface EditorSession { id: string; document: NoteDocument; notes: Map<string, Note> }
export interface EditorHost {
  surfaces?(state: EditorState): SurfaceHost;
  session(state: EditorState): EditorSession | null;
  elapsed(): number;
  paused?(): boolean;
  recording?(): boolean;
  changed(view: EditorView, blocks: Block[]): void;
  mounted(view: EditorView): void;
  unmounted(view: EditorView): void;
  takeOver(view: EditorView, block: Block, text: string, offset?: number): void;
  why(view: EditorView, block: Block, note: Note): void;
  replaceDocument(state: EditorState, document: NoteDocument): void;
  action(view: EditorView, block: Block, note: Note, event: MouseEvent): void;
}
export const setDocument = StateEffect.define<{document: NoteDocument; previous: NoteDocument}>();
export const inkLines = StateEffect.define<number[]>();
export const refreshAI = StateEffect.define<void>();
export const ownBlock = StateEffect.define<{ id: string; owned: Block['owned'] }>({
  map: (value, changes) => ({ ...value, owned: value.owned ? { ...value.owned,
    from: changes.mapPos(value.owned.from, 1), to: changes.mapPos(value.owned.to, -1) } : undefined }),
});
interface Ledger { id: string | null; blocks: Block[]; graves: Block[]; cut: Block[]; decorations: DecorationSet }

const ownedIndents=new Map<string,number>();
export function rememberOwnedIndent(id: string,indent: number): void {
 ownedIndents.set(id,indent);
 let style=document.getElementById('ws-owned-indents');if(!style){style=document.createElement('style');style.id='ws-owned-indents';document.head.append(style);}
 style.textContent=[...ownedIndents].map(([key,value])=>`.markdown-source-view.mod-cm6 .cm-content>.ws-owner-${key.replace(/[^a-zA-Z0-9-]/g,'')} {padding-inline-start:${value}px!important;}`).join('\n');
}
export function clearOwnedIndents(): void {ownedIndents.clear();document.getElementById('ws-owned-indents')?.remove();}
const margins=new WeakMap<EditorView,HTMLElement>();
function showMargin(view: EditorView,row: HTMLElement,block: Block,note: Note | undefined,host: EditorHost): void {
 let margin=margins.get(view);
 if(!margin){margin=document.createElement('div');margin.className='ws-ai-margin';view.scrollDOM.append(margin);margins.set(view,margin);}
 margin.replaceChildren();margin.onmouseleave=()=>margin!.classList.remove('is-visible');
 row.onmouseleave=()=>window.setTimeout(()=>{if(!margin!.matches(':hover')&&!row.matches(':hover')&&!row.matches(':focus-within'))margin!.classList.remove('is-visible');},150);
 if(block.owned)margin.append('Yours · ');
 const b=margin.appendChild(document.createElement('button'));b.className=block.owned?'ws-ai-handback':'ws-ai-why';b.textContent=block.owned?'Let AI rewrite':'Why?';b.onmousedown=e=>e.preventDefault();b.setAttribute('aria-label',b.textContent);b.onclick=e=>{const surface=host.surfaces?.(view.state);if(block.owned&&surface)surface.rewrite(view,block);else if(note){if(block.owned)host.action(view,block,note,e);else host.why(view,block,note);}};
 if(!block.owned&&note?.trace?.revisions.length){const r=note.trace.revisions.at(-1)!;const age=Math.max(0,Math.floor((Date.now()-Date.parse(r.at))/60000));margin.append(` · v${r.version} · ${age<1?'just now':age+' min ago'}`);}
 view.requestMeasure({read:()=>({r:row.getBoundingClientRect(),s:view.scrollDOM.getBoundingClientRect(),c:view.contentDOM.getBoundingClientRect()}),write:({r,s,c})=>{
 margin!.style.left=`${Math.min(c.right-s.left+12,Math.max(0,s.width-margin!.offsetWidth-8))}px`;margin!.style.top=`${r.top-s.top+view.scrollDOM.scrollTop+1}px`;margin!.classList.add('is-visible');}});
}
function measureOwned(view: EditorView,blocks: Block[]): void {
 view.requestMeasure({key:measureOwned,read:()=>[...view.dom.querySelectorAll<HTMLElement>('.ws-owned-line')].flatMap(el=>{
  const block=blocks.find(b=>b.id===el.dataset.wsBlock);if(!block||block.from>view.state.doc.length)return [];
  const line=view.state.doc.lineAt(block.from),prefix=/^\s*(?:[-+*]|\d+[.)])\s+(?:\[.\]\s+)?/.exec(line.text)?.[0].length??0;
  const measured=(view.coordsAtPos(line.from+prefix)?.left??el.getBoundingClientRect().left)-el.getBoundingClientRect().left;
  return [{el,x:ownedIndents.get(block.id)??measured}];
 }),write:rows=>{for(const {el,x} of rows)el.style.setProperty('padding-inline-start',`${x}px`,'important');}});
}
function measureIndent(view: EditorView,el: HTMLElement,block: Block): void {
 view.requestMeasure({key:el,read:()=>{
 if(!el.isConnected||block.from>view.state.doc.length)return null;
 const line=view.state.doc.lineAt(block.from),prefix=/^\s*(?:[-+*]|\d+[.)])\s+(?:\[.\]\s+)?/.exec(line.text)?.[0].length??0;
 const pos=view.coordsAtPos(Math.min(line.to,line.from+prefix));return pos?{indent:pos.left-el.getBoundingClientRect().left,caret:view.lineBlockAt(view.state.selection.main.head).top,doc:view.state.doc,selection:view.state.selection}:null;
 },write:x=>{if(x!==null&&el.style.getPropertyValue('--ws-indent')!==`${x.indent}px`){el.style.setProperty('--ws-indent',`${x.indent}px`);view.requestMeasure({read:()=>view.lineBlockAt(view.state.selection.main.head).top-x.caret,write:delta=>{if(view.hasFocus&&view.state.doc===x.doc&&view.state.selection.eq(x.selection))view.scrollDOM.scrollTop+=delta;}});}}});
}

export function meetingEditor(host: EditorHost): { extension: Extension; field: StateField<Ledger> } {
  const fallback = new SurfaceStore();
  const draw = (blocks: Block[], session: EditorSession | null, state: EditorState): DecorationSet => {
    if (!session || session.document.finalized) return Decoration.none;
    const surfaces = host.surfaces?.(state) ?? {
      store: fallback, recording:()=>!!host.recording?.(),elapsed:()=>host.elapsed(),
      sources:line=>{const block=blocks.find(b=>b.id===line.blockId);const note=block&&session.notes.get(block.id);if(block&&note)host.why(null as unknown as EditorView,block,note);},
      own:(view,block,text,offset)=>host.takeOver(view,block,text,offset), rewrite:()=>{},openSources:()=>{},
      make:()=>{},discard:()=>{},insert:()=>{},renderMermaid:()=>{},preview:()=>undefined,pending:()=>false,
    } satisfies SurfaceHost;
    if(!host.surfaces) for(const note of session.notes.values())if(note.line)fallback.apply(note.line);
    const rows = blocks.flatMap(block=>{
      if(!block.owned)return [];
      const owned=[];
      for(let pos=block.owned.from;pos<=block.owned.to;){const line=state.doc.lineAt(pos);owned.push(Decoration.line({class:`ws-owned-line ws-owner-${block.id.replace(/[^a-zA-Z0-9-]/g,'')}`,attributes:{'data-ws-block':block.id,style:`padding-inline-start:${ownedIndents.get(block.id)??0}px!important`}}).range(line.from));if(line.to>=block.owned.to)break;pos=line.to+1;}
      return owned;
    });
    rows.push(...surfaceDecorations(surfaces,session.id,blocks,()=>false));
    return Decoration.set(rows,true);
  };

  const field = StateField.define<Ledger>({
    create(state) {
      const s = host.session(state);
      const blocks = s && !s.document.finalized ? reconcile(state.doc.toString(), s.document.blocks, host.elapsed()) : [];
      return { id: s?.id ?? null, blocks, graves: [], cut: [], decorations: draw(blocks, s, state) };
    },
    update(value, tr) {
      for(const effect of tr.effects) if(effect.is(setDocument)) host.replaceDocument(tr.state,effect.value.document);
      const session = host.session(tr.state);
      if (!session || session.document.finalized) return { id: null, blocks: [], graves: [], cut: [], decorations: Decoration.none };
      let blocks = value.blocks, graves = value.graves, cut = value.cut;
      const changedSession = value.id !== session.id || tr.effects.some(e=>e.is(setDocument));
      if (changedSession) { blocks = reconcile(tr.newDoc.toString(), session.document.blocks, host.elapsed()); graves = []; cut = []; }
      else if (tr.docChanged) {
        host.surfaces?.(tr.startState).store.mapEdits(session.id, blocks, tr.changes);
        const source = tr.newDoc.toString();
        const restore = tr.isUserEvent('undo') || tr.isUserEvent('redo') ? graves : tr.isUserEvent('input.paste') ? cut : [];
        // Obsidian mirrors one file into multiple panes. Adopt the first pane's canonical IDs.
        const next = session.document.source === source ? session.document.blocks : reconcile(source, blocks, host.elapsed(), tr.changes, undefined, restore);
        if (tr.isUserEvent('input.paste')) cut = [];
        if (tr.isUserEvent('delete.cut')) cut = blocks.filter(b => !next.some(n => n.id === b.id));
        const ids = new Set(next.map(b => b.id));
        graves = [...graves.filter(b => !ids.has(b.id)), ...blocks.filter(b => !ids.has(b.id))].slice(-2000);
        blocks = next;
      }
      for (const effect of tr.effects) if (effect.is(ownBlock))
        blocks = blocks.map(b => {
          if(b.id!==effect.value.id)return b;
          const owned=effect.value.owned;
          const to=owned?Math.min(b.to,owned.from-1):b.to;
          return {...b,to,text:tr.newDoc.sliceString(b.from,to),owned};
        });
      const repaint = changedSession || tr.docChanged || tr.selection !== undefined || tr.effects.some(e => e.is(refreshAI) || e.is(ownBlock));
      return { id: session.id, blocks, graves, cut, decorations: repaint && !(typeof document !== "undefined" && document.activeElement?.closest(".ws-editor-ai-button") && !tr.docChanged) ? draw(blocks, session, tr.state) : value.decorations };
    },
    provide: f => EditorView.decorations.from(f, v => v.decorations),
  });
  const ink=StateField.define<DecorationSet>({
    create:()=>Decoration.none,
    update(value,tr){
      for(const e of tr.effects)if(e.is(inkLines))return Decoration.set(e.value.map((at,i)=>Decoration.line({class:'ws-inking',attributes:{style:`--i:${i}`}}).range(tr.state.doc.lineAt(Math.min(at,tr.state.doc.length)).from)),true);
      return value.map(tr.changes);
    },provide:f=>EditorView.decorations.from(f),
  });
  const observer = ViewPlugin.fromClass(class {
    constructor(readonly view: EditorView) {host.mounted(view);view.dom.addEventListener('mouseover',this.hover);view.dom.addEventListener('click',this.check);view.dom.addEventListener('keydown',this.check);}
    check=(event:Event)=>{
      if(event instanceof KeyboardEvent&&!['Enter',' '].includes(event.key))return;
      const element=(event.target as HTMLElement).closest<HTMLElement>('[data-ws-check]');if(!element)return;
      event.preventDefault();const surface=host.surfaces?.(this.view.state),session=host.session(this.view.state);
      if(surface&&session)surface.openSources([...surface.store.checks.values()].filter(c=>c.documentId===session.id&&c.blockId===element.dataset.wsCheck).flatMap(c=>c.sources));
    };
    hover=(event: MouseEvent)=>{
      const row=(event.target as HTMLElement).closest<HTMLElement>('.ws-owned-line');if(!row)return;
      const block=this.view.state.field(field).blocks.find(b=>b.id===row.dataset.wsBlock),note=block&&host.session(this.view.state)?.notes.get(block.id);
      if(block&&(note||block.owned))showMargin(this.view,row,block,note,host);
    };
    update(update: import('@codemirror/view').ViewUpdate) {
      measureOwned(update.view,update.state.field(field).blocks);
      if(update.geometryChanged)for(const el of update.view.dom.querySelectorAll<HTMLElement>('.ws-editor-ai')){const block=update.state.field(field).blocks.find(b=>b.id===el.dataset.wsBlock);if(block)measureIndent(update.view,el,block);}
      if (update.docChanged || update.transactions.some(t => t.effects.some(e => e.is(ownBlock))))
        host.changed(update.view, update.state.field(field).blocks);
    }
    destroy() {this.view.dom.removeEventListener('mouseover',this.hover);this.view.dom.removeEventListener('click',this.check);this.view.dom.removeEventListener('keydown',this.check);margins.get(this.view)?.remove();margins.delete(this.view);host.unmounted(this.view);}
  });
  return { field, extension: [field, ink, observer, invertedEffects.of(tr => [...tr.effects.filter(e=>e.is(setDocument)).map(e=>{const v=e.value as {document:NoteDocument;previous:NoteDocument};return setDocument.of({document:v.previous,previous:v.document});}), ...tr.effects.filter(e => e.is(ownBlock)).map(e => {
    const effect = e as import('@codemirror/state').StateEffect<{ id: string; owned: Block['owned'] }>;
    return ownBlock.of({ id: effect.value.id, owned: tr.startState.field(field).blocks.find(b => b.id === effect.value.id)?.owned });
  })])] };
}

export const aiRefresh = () => ({ effects: refreshAI.of(), annotations: Transaction.addToHistory.of(false) });
