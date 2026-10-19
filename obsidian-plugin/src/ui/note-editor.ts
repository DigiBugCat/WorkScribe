import { insertDiagram } from './surfaces/make';
import { renderSurfaceSources } from './surfaces/sources';
import type { SurfaceHost } from './surfaces';
import type { SurfaceSource } from '../lib/types';
import { noteName, vaultRelative } from "../lib/format";
import { editorInfoField, MarkdownView, MarkdownRenderer, Menu, Modal, normalizePath, Notice, TFile } from 'obsidian';
import { EditorView } from '@codemirror/view';
import { Transaction, type EditorState } from '@codemirror/state';
import { aiRefresh, inkLines, clearOwnedIndents, rememberOwnedIndent, meetingEditor, ownBlock, setDocument, type EditorSession } from '../lib/editor-extension';
import { reconcile, type Block } from '../lib/anchors';
import { imageInsertion, placeImage, imageBytes } from '../lib/image-insert';
import type WorkScribePlugin from '../main';
import type { Note } from '../lib/types';
import { continuation, fadeCountdown } from '../lib/care';
import { renderTrace } from './trace';
import { LIVE_VIEW, LiveView } from './live-view';
import { isolateHistory } from '@codemirror/commands';

/** One serialized sync lane per meeting. The Markdown file is always the user's source of truth. */
export class NoteEditor {
  private sessions = new Map<string, EditorSession>();
  private views = new Set<EditorView>();
  private bars = new Map<EditorView,HTMLElement>();
  private timers = new Map<string, ReturnType<typeof setTimeout>>();
  private refreshTimers = new Map<EditorView, ReturnType<typeof setTimeout>>();
  private typingTimers = new Map<EditorView, ReturnType<typeof setTimeout>>();
  private lanes = new Map<string, Promise<void>>();
  private opening = new Map<string, Promise<TFile | null>>();
  private dirty = new Set<string>();
  private stopped = false;
  private finalizing = new Set<string>();
  private dismissed = new Set<string>();
  private headers = new Map<MarkdownView,HTMLElement>();
  private confirmDelete=false;
  private rings = new WeakMap<HTMLElement, SVGSVGElement>();
  private headerObservers = new Map<MarkdownView, ResizeObserver>();
  private elapsedByMeeting=new Map<string,number>();
  private actionMenu?: Menu;
  private evidenceModal?: Modal;
  private evidenceId?: string;
  private focusedSources:SurfaceSource[]=[];
  private saveTimer?: ReturnType<typeof setTimeout>;
  private makes = new Map<string,{requestId?:string;token:object;source:string}>();
  readonly editor;
  constructor(private p: WorkScribePlugin) {
    for (const [id, document] of Object.entries(p.documentLedgers)) this.sessions.set(id, { id, document, notes: new Map() });
    p.registerDomEvent(window.document,'keydown',event=>{if(event.key==='Escape'&&this.confirmDelete){this.confirmDelete=false;this.renderHeaders();}});
    this.editor = meetingEditor({
      surfaces: state => this.surfaceHost(state),
      session: state => this.session(state), elapsed: () => p.elapsed(), paused:()=>p.connState.kind!=="online", recording:()=>p.recording,
      changed: (view, blocks) => this.changed(view, blocks),
      mounted: view => {this.views.add(view);this.p.registerDomEvent(view.dom,'keydown',event=>{
        if(event.key==='Enter' && (event.metaKey||event.ctrlKey) && !this.p.recording && this.session(view.state)?.id===this.p.live.meetingId && !this.session(view.state)?.document.finalized && this.bars.has(view)) {event.preventDefault();void this.finalize().catch(e=>this.p.showError(e));}
      });}, unmounted: view => { this.bars.get(view)?.remove();this.bars.delete(view);clearTimeout(this.typingTimers.get(view));this.typingTimers.delete(view);this.views.delete(view); clearTimeout(this.refreshTimers.get(view)); this.refreshTimers.delete(view); },
      takeOver: (view, block, text, offset) => this.takeOver(view, block, text, offset),
      why: (view, block, note) => this.why(view, block, note),
      replaceDocument: (state, document) => {const s=this.session(state);if(s)s.document=document;queueMicrotask(()=>this.p.notify(new Set(["notes"])));},
      action: (view, block) => { void this.handBack(view,block); },
    });
    p.register(p.subscribe(changes => {
      if(changes.has('tick')){if(this.p.live.meetingId&&this.p.recording)this.elapsedByMeeting.set(this.p.live.meetingId,this.p.elapsed());this.renderHeaders();for(const view of this.views)if(!view.composing)view.dispatch(aiRefresh());}
      if (changes.has('notes')||changes.has('status'))this.adaptLoadedNotes();
      if (changes.has('notes') || changes.has('meeting') || changes.has('conn') || changes.has('status')) this.refresh();
      if (changes.has('conn') && p.connState.kind === 'online') for (const id of this.dirty) this.queue(id);
    }));
    p.registerEvent(p.app.vault.on('modify', file => {
      if (file instanceof TFile) { void this.diskChanged(file); this.imageChanged(file); }
    }));
    p.registerEvent(p.app.vault.on('create', file => { if (file instanceof TFile) this.imageChanged(file); }));
    p.registerEvent(p.app.vault.on('delete', file => { if (file instanceof TFile) this.imageChanged(file); }));
    p.registerEvent(p.app.vault.on('rename', (file, oldPath) => {
      if (!(file instanceof TFile)) return;
      for (const [id,s] of this.sessions) if (p.meetingIdOf(file) === id || s.document.path === p.absolutePath(oldPath)) {
        s.document.path = p.absolutePath(file.path) ?? s.document.path; this.queue(id);
      }
    }));
    p.registerInterval(window.setInterval(() => {
      if (!p.recording && p.connState.kind === 'online') void this.checkFinalized();
    }, 2000));
  }
  dispose(): void {
    this.stopped = true;clearOwnedIndents();
    this.headerObservers.forEach(o=>o.disconnect());this.headerObservers.clear();
    this.actionMenu?.hide(); this.evidenceModal?.close();
    this.actionMenu = undefined; this.evidenceModal = undefined; this.evidenceId = undefined;
    clearTimeout(this.saveTimer);
    void this.p.saveSettings();
    for(const view of this.views)view.dom.closest('.workspace-leaf-content')?.querySelector('.ws-paused-header')?.remove();
    this.bars.forEach(bar=>bar.remove());this.bars.clear();this.headers.forEach(el=>el.remove());this.headers.clear();
    this.timers.forEach(clearTimeout); this.refreshTimers.forEach(clearTimeout);this.typingTimers.forEach(clearTimeout);
  }
  private session(state: EditorState): EditorSession | null {
    const file = state.field(editorInfoField, false)?.file;
    if (!file) return null;
    const path = this.p.absolutePath(file.path);
    const matches=[...this.sessions.values()].filter(s => s.document.path === path);
    const existing=matches.find(s=>s.id===this.p.live.meetingId)??matches[0];
    if(existing)return existing;
    if(!path)return null;
    const document={path,source:state.doc.toString(),revision:0,blocks:reconcile(state.doc.toString(),[],this.p.recording?this.p.elapsed():undefined)};
    const session={id:path,document,notes:new Map<string,Note>()};this.sessions.set(path,session);return session;
  }
  private adaptLoadedNotes(): void {
    for(const note of this.p.live.notes.values())if(note.line)this.p.surfaces.apply(note.line);
  }
  private surfaceHost(state:EditorState):SurfaceHost {
    const session=this.session(state),id=session?.id??'';
    const key=(b:Block)=>id+'/'+b.id;
    return {store:this.p.surfaces,focusSources:sources=>{const panel=this.p.app.workspace.getLeavesOfType(LIVE_VIEW)[0]?.view;if(panel instanceof LiveView)panel.showSurfaceSources(sources);},recording:()=>this.p.recording,elapsed:()=>this.p.elapsed(),
      sources:line=>this.openSources(line.sources),openSources:sources=>this.openSources(sources),
      own:(view,block,text,offset)=>this.takeOver(view,block,text,offset),rewrite:(view,block)=>void this.handBack(view,block),
      make:(view,block)=>void this.make(view,block),discard:block=>{this.makes.delete(key(block));this.refresh(true);},
      insert:(view,block,preview)=>{insertDiagram(view,block,preview);this.makes.delete(key(block));this.refresh(true);},
      preview:block=>{const request=this.makes.get(key(block));return request?.source===block.text&&request.requestId?this.p.surfaces.previews.get(request.requestId):undefined;},
      pending:block=>{const request=this.makes.get(key(block));return !!request&&request.source===block.text&&(!request.requestId||!this.p.surfaces.previews.has(request.requestId));},
      renderMermaid:async(code,container)=>{const fence='`'.repeat(Math.max(3,...Array.from(code.matchAll(/`+/g),m=>m[0].length+1)));try{await MarkdownRenderer.render(this.p.app,fence+'mermaid\n'+code+'\n'+fence,container,session?.document.path??'',this.p);}catch(error){this.p.surfaces.status={...this.p.surfaces.status,paused:'Diagram preview unavailable'};this.p.notify(new Set(['status']));throw error;}},
    };
  }
  private async make(view:EditorView,block:Block):Promise<void> {
    const session=this.session(view.state);if(!session||block.surface!=='fence')return;
    const key=session.id+'/'+block.id,request={token:{},source:block.text} as {token:object;source:string;requestId?:string};
    this.makes.set(key,request);this.refresh(true);
    try{const result=await this.p.client.makeDiagram(session.id,block.id);if(this.makes.get(key)===request)request.requestId=result.requestId;}
    catch{if(this.makes.get(key)===request)this.makes.delete(key);this.p.surfaces.status={...this.p.surfaces.status,paused:'Diagram unavailable'};}
    this.p.notify(new Set(['status']));this.refresh(true);
  }
  private async handBack(view:EditorView,block:Block):Promise<void> {
    const session=this.session(view.state);if(!session||!block.owned)return;
    try{await this.p.client.rewriteLine(session.id,block.id);}
    catch{try{await this.p.client.patchNote(session.id,block.id,{rewrite:true});}catch{this.p.surfaces.status={...this.p.surfaces.status,paused:'Rewrite unavailable'};this.p.notify(new Set(['status']));return;}}
    // Explicitly requested handback is one normal undoable edit.
    view.dispatch({changes:{from:block.owned.from-1,to:block.owned.to,insert:''},effects:ownBlock.of({id:block.id,owned:undefined}),annotations:isolateHistory.of('full'),userEvent:'input.rewrite'});
  }
  openSources(sources:SurfaceSource[]):void {
    sources=sources.filter(s=>!this.p.surfaces.isPurged(s.meetingId??(s.kind==='meeting'?this.p.live.meetingId??'':'')));
    this.focusedSources=sources;this.evidenceId=this.p.live.meetingId??undefined;
    const panel=this.p.app.workspace.getLeavesOfType(LIVE_VIEW)[0]?.view;
    if(panel instanceof LiveView){panel.showSurfaceSources(sources);return;}
    this.evidenceModal?.close();const modal=new Modal(this.p.app);this.evidenceModal=modal;modal.titleEl.setText('Why?');
    renderSurfaceSources(modal.contentEl,sources,source=>this.p.openMoment({kind:source.kind==='meeting'?'meeting':'note',title:source.title,meetingId:source.meetingId??this.p.live.meetingId??undefined,start:source.at,path:source.path,link:source.link,snippet:source.quote}));modal.open();
  }
  command(action:'why'|'own'|'rewrite'|'make'|'jump',checking:boolean):boolean {
    const view=[...this.views].find(v=>v.hasFocus||v.dom.contains(document.activeElement));if(!view)return false;
    const session=this.session(view.state);if(!session)return false;
    const active=document.activeElement?.closest<HTMLElement>('[data-ws-block]')?.dataset.wsBlock;
    const block=session.document.blocks.find(b=>b.id===active)||session.document.blocks.find(b=>view.state.selection.main.head>=b.from&&view.state.selection.main.head<=b.to||!!b.owned&&view.state.selection.main.head>=b.owned.from&&view.state.selection.main.head<=b.owned.to);
    if(!block)return false;const line=this.p.surfaces.line(session.id,block);
    if(action==='make'||action==='own'&&!line?.text||action==='rewrite'&&!block.owned)return false;
    const sources=line?.sources??[...this.p.surfaces.pins.values(),...this.p.surfaces.checks.values()].filter(e=>e.documentId===session.id&&e.blockId===block.id).flatMap(e=>e.sources);
    if(checking)return true;
    if(action==='rewrite')void this.handBack(view,block);else if(action==='own')this.takeOver(view,block,line!.text!);else this.openSources(sources);return true;
  }
  private relative(path: string): string | null {
    const base = this.p.linkContext().vaultBase;
    return vaultRelative(path, base);
  }
  private refresh(immediate=false): void {
    const id=this.p.live.meetingId;
    if(id&&this.p.recording){this.elapsedByMeeting.set(id,this.p.elapsed());}
    this.renderHeaders();
    for (const s of this.sessions.values()) if (s.id === this.p.live.meetingId) s.notes = this.p.live.notes;
    for (const view of this.views) {
      this.renderBar(view);
      const parent=view.dom.closest('.workspace-leaf-content')?.querySelector('.view-actions');
      const busyMessage=this.p.recording && /still recording/.test(this.p.live.status?.message??'') ? this.p.live.status?.message : undefined;
      // Only a real pause: WorkScribe says it is catching up, or it can't be reached. A jot waiting a few
      // seconds for its answer is normal and shows on the jot itself.
      const paused=!!busyMessage || this.p.connState.kind!=="online" || !!this.p.surfaces.status.paused;
      const existing=parent?.querySelector('.ws-paused-header');
      if(paused && !existing && this.session(view.state) && !this.session(view.state)?.document.finalized) parent?.createDiv({cls:'ws-paused-header',text:busyMessage??'AI lines paused · your notes are saving'});
      if(existing && paused)existing.textContent=busyMessage??'AI lines paused · your notes are saving';
      if(!paused||this.session(view.state)?.document.finalized)existing?.remove();
      clearTimeout(this.refreshTimers.get(view));
      const update = () => {
        if (this.stopped || !this.views.has(view)) return;
        if (view.composing) { this.refreshTimers.set(view, setTimeout(update, 300)); return; }
        const selection = view.state.selection, doc = view.state.doc;
        const anchor = view.hasFocus ? view.lineBlockAt(selection.main.head).top-view.scrollDOM.scrollTop : null;
        view.dispatch(aiRefresh());
        if(anchor!==null){
          let frames=18;const stabilize=()=>{
            if(!this.views.has(view)||view.state.doc!==doc||!view.state.selection.eq(selection)||!view.hasFocus)return;
            view.requestMeasure({read:()=>view.lineBlockAt(selection.main.head).top-view.scrollDOM.scrollTop-anchor,write:delta=>{view.scrollDOM.scrollTop+=delta;if(--frames>0)requestAnimationFrame(stabilize);}});
          };requestAnimationFrame(stabilize);
        }
        if (anchor !== null) view.requestMeasure({
          read: v => v.lineBlockAt(selection.main.head).top-v.scrollDOM.scrollTop - anchor,
          write: (delta, v) => {
            if (v.hasFocus && !v.composing && v.state.doc === doc && v.state.selection.eq(selection))
              v.scrollDOM.scrollTop += delta;
          },
        });
      };
      // Streaming updates wait for a typing pause; the caret and IME belong to the user.
      this.refreshTimers.set(view, setTimeout(update, immediate || this.session(view.state)?.document.finalized ? 0 : view.hasFocus ? 2100 : 0));
    }
  }
  private duration(): number {return this.elapsedByMeeting.get(this.p.live.meetingId??'')??this.p.elapsed();}
  private renderHeaders(): void {
    for(const [view,el] of this.headers)if(this.p.meetingIdOf(view.file)!==this.p.live.meetingId||this.p.live.retention==='purged'){el.remove();this.headers.delete(view);this.headerObservers.get(view)?.disconnect();this.headerObservers.delete(view);view.containerEl.querySelector(".view-header")?.classList.remove("ws-has-pill");}
    for(const leaf of this.p.app.workspace.getLeavesOfType('markdown')){
      const view=leaf.view;if(!(view instanceof MarkdownView)||!this.p.live.meetingId||this.p.meetingIdOf(view.file)!==this.p.live.meetingId||this.p.live.retention==='purged')continue;
      let pill=this.headers.get(view);if(!pill){pill=document.createElement('div');pill.className='ws-rec-pill';view.containerEl.querySelector('.view-actions')?.prepend(pill);this.headers.set(view,pill);
        const header=view.containerEl.querySelector<HTMLElement>('.view-header');
        if(header){view.containerEl.classList.add('ws-native-note');header.classList.add('ws-has-pill');const observer=new ResizeObserver(()=>this.sizeHeader(view));observer.observe(header);this.headerObservers.set(view,observer);}
      }
      if(this.p.recording&&pill.classList.contains('is-rec')&&pill.querySelector('.ws-rec-clock')){pill.querySelector('.ws-rec-clock')!.setText(this.p.clockText);pill.querySelector('.ws-rec-source')!.setText(this.p.live.status?.sources.system?'Mic + system':'Mic only');this.sizeHeader(view);continue;}
      pill.replaceChildren();pill.classList.toggle('is-rec',this.p.recording);
      if(this.p.recording){
        pill.createSpan({cls:'ws-rec-dot'});pill.createSpan({cls:'ws-rec-clock',text:this.p.clockText});pill.createSpan({cls:'ws-rec-source',text:this.p.live.status?.sources.system?'Mic + system':'Mic only'});
        pill.createEl('button',{cls:'ws-rec-stop',text:'■ Stop'}).onclick=()=>void this.p.stopRecording();
      }else if(!this.isFinalized()){
        const notes=[...this.p.live.notes.values()];
        const finishing=this.p.live.status?.phase==='finalizing'||notes.some(n=>n.state==='found');
        const progress=finishing?(this.p.live.status?.finalizationProgress??notes.filter(n=>n.state!=='found').length/Math.max(1,notes.length)):1;
        this.progressRing(pill,progress,finishing?'Final pass in progress':'Final pass complete');
        const label=finishing?(this.p.live.status?.message==='Polishing the transcript…'?'Polishing the transcript…':'Finishing your notes…'):'Ready to finalize';
        pill.createEl('button',{cls:'ws-tbtn ws-rec-state',text:label}).onclick=()=>this.showFinalize();
        const ended=this.p.live.endedAt?Date.parse(this.p.live.endedAt):NaN;
        if(Number.isFinite(ended)&&Date.now()>=ended&&Date.now()-ended<600000){
          const resume=pill.createEl('button',{cls:'ws-rec-resume',text:'▶ Resume'});
          resume.onclick=()=>{resume.disabled=true;void this.p.resumeRecording().finally(()=>{resume.disabled=false;});};
        }
      }else if(this.confirmDelete){
        const n=this.p.live.screens.length,parts=['the transcript','audio',...(n?[`${n} screen moment${n===1?'':'s'}`]:[])];
        pill.createSpan({text:`Delete ${parts.slice(0,-1).join(', ')} and ${parts.at(-1)} now? The note stays.`});
        pill.createEl('button',{text:'Keep'}).onclick=()=>{this.confirmDelete=false;this.renderHeaders();};
        pill.createEl('button',{cls:'mod-warning',text:'Delete now'}).onclick=()=>void this.p.client.done(this.p.live.meetingId!).catch(e=>this.p.showError(e));
        pill.onkeydown=e=>{if(e.key==='Escape'){this.confirmDelete=false;this.renderHeaders();}};
      }else{
        this.progressRing(pill,this.p.live.purgeAt?Math.max(0,Math.min(1,(Date.parse(this.p.live.purgeAt)-Date.now())/86400000)):0,'Transcript retention remaining');
        pill.createSpan({text:this.p.live.purgeAt?fadeCountdown(this.p.live.purgeAt):'Note saved'});
        pill.createEl('button',{cls:'ws-tbtn',text:'Done now'}).onclick=()=>{this.confirmDelete=true;this.renderHeaders();};
      }
      this.sizeHeader(view);
    }
  }
  private progressRing(parent: HTMLElement, progress: number, label: string): void {
    const ns='http://www.w3.org/2000/svg',ring=this.rings.get(parent)??document.createElementNS(ns,'svg');this.rings.set(parent,ring);
    ring.classList.add('ws-progress-ring');ring.setAttribute('viewBox','0 0 12 12');
    ring.setAttribute('role','progressbar');ring.setAttribute('aria-label',label);
    ring.setAttribute('aria-valuemin','0');ring.setAttribute('aria-valuemax','100');ring.setAttribute('aria-valuenow',String(Math.round(progress*100)));
    for(const cls of ['track','value']){const circle=ring.querySelector<SVGCircleElement>('.'+cls)??document.createElementNS(ns,'circle');circle.setAttribute('cx','6');circle.setAttribute('cy','6');circle.setAttribute('r','4.5');circle.classList.add(cls);if(cls==='value'){circle.style.strokeDasharray=String(2*Math.PI*4.5);circle.style.strokeDashoffset=String(2*Math.PI*4.5*(1-progress));}ring.append(circle);}
    parent.append(ring);
  }
  private sizeHeader(view: MarkdownView): void {
    const pill=this.headers.get(view),header=view.containerEl.querySelector<HTMLElement>('.view-header');if(!pill||!header)return;
    const width=header.clientWidth;
    // Reserve a useful breadcrumb before reducing the recording details. All children remain non-shrinking.
    header.classList.toggle('ws-header-narrow',width<700);
    header.classList.toggle('ws-header-compact',width<480);
    header.classList.toggle('ws-header-stacked',width<360);
    const clock=pill.querySelector<HTMLElement>('.ws-rec-clock');
    if(clock){clock.title=this.p.clockText;clock.setText(width<480?this.p.clockText.replace(/^0(?=\d:)/,''):this.p.clockText);}
  }
  private renderBar(view: EditorView): void {
    const s=this.session(view.state);
    if(this.p.recording&&s)this.dismissed.delete(s.id);
    if(!s || s.id!==this.p.live.meetingId || s.document.finalized || this.p.recording || this.dismissed.has(s.id)) {this.bars.get(view)?.remove();this.bars.delete(view);view.contentDOM.style.paddingBottom=s?`${view.scrollDOM.clientHeight/2}px`:'';return;}
    let bar=this.bars.get(view);
    if(!bar) {bar=document.createElement('div');bar.className='ws-native-finalize';view.dom.parentElement?.append(bar);this.bars.set(view,bar);}
    bar.replaceChildren();
    const copy=bar.createDiv();copy.createEl('strong',{text:`Finished listening · ${Math.max(1,Math.round(this.duration()/60))} min`});
    const count=[...s.notes.values()].filter(n=>n.enhanced&&!n.userEdited).length;
    const parts=[count?`${count} AI line${count===1?'':'s'}`:'','a brief',this.p.live.actionItems.length?`${this.p.live.actionItems.length} action item${this.p.live.actionItems.length===1?'':'s'}`:'',this.p.live.missedTopics.length?`${this.p.live.missedTopics.length} more topic${this.p.live.missedTopics.length===1?'':'s'}`:''].filter(Boolean);
    const list=parts.length>1?parts.slice(0,-1).join(', ')+' and '+parts.at(-1):parts[0];
    const deadline=this.p.live.purgeAt?new Date(Date.parse(this.p.live.purgeAt)-3600000):null;
    const when=deadline?deadline.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})+(deadline.toDateString()===new Date().toDateString()?' today':' tomorrow'):'an hour before the transcript fades';
    copy.createEl('div',{text:`Write ${list} into this note? Lines you edited stay as you wrote them. If you don’t, it happens on its own at ${when}, an hour before the transcript fades.`});
    const actions=bar.createDiv({cls:'ws-finalize-actions'});
    actions.createEl('button',{text:'Not yet'}).onclick=()=>{this.dismissed.add(s.id);this.renderBar(view);};
    const button=actions.createEl('button',{text:'Finalize ⌘↩',cls:'mod-cta'});
    button.onclick=()=>{button.disabled=true;void this.finalize().catch(e=>{button.disabled=false;this.p.showError(e);});};
    view.requestMeasure({read:()=>bar!.offsetHeight,write:height=>{view.contentDOM.style.paddingBottom=`${height+24}px`;}});
  }
  showFinalize(): void {if(this.p.live.meetingId)this.dismissed.delete(this.p.live.meetingId);this.refresh();}

  async open(id: string, reveal = true): Promise<TFile | null> {
    const running = this.opening.get(id);
    if (running) return running;
    const op = this.openInner(id, reveal).finally(() => this.opening.delete(id));
    this.opening.set(id, op); return op;
  }
  private async openInner(id: string, reveal: boolean): Promise<TFile | null> {
    const document = await this.p.client.openDocument(id);
    const relative = this.relative(document.path);
    if (!relative) { new Notice('Choose this Obsidian vault in WorkScribe’s Notes vault settings.'); return null; }
    let file = this.p.app.vault.getAbstractFileByPath(relative);
    // Obsidian's file watcher may still be processing the app's atomic create.
    for (let i = 0; !(file instanceof TFile) && i < 20; i++) {
      await new Promise(r => setTimeout(r, 50)); file = this.p.app.vault.getAbstractFileByPath(relative);
    }
    if (!(file instanceof TFile)) throw new Error('Waiting for Obsidian to discover the meeting note. Try Open meeting note again.');
    const local = this.p.documentLedgers[id];
    const old = local && local.revision === document.revision && !document.finalized ? local : document;
    const source = await this.p.app.vault.read(file);
    const blocks = document.finalized ? [] : reconcile(source, old.blocks, this.p.recording ? this.p.elapsed() : undefined);
    this.sessions.set(id, { id, document: { ...document, source, blocks }, notes: this.p.live.notes });
    if (!document.finalized) this.queue(id);
    if (reveal) {
      const leaf = this.p.app.workspace.getLeavesOfType('markdown').find(l => (l.view as MarkdownView).file?.path === file.path)
        ?? this.p.app.workspace.getLeaf('tab');
      await leaf.openFile(file); await this.p.app.workspace.revealLeaf(leaf);
      if(source.endsWith('\n- ')&&leaf.view instanceof MarkdownView){leaf.view.editor.setCursor(leaf.view.editor.offsetToPos(source.length));if(window.document.hasFocus())leaf.view.editor.focus();}
    }
    this.refresh(); return file;
  }
  private changed(view: EditorView, blocks: Block[]): void {
    const s = this.session(view.state);
    if (!s || s.document.finalized) return;
    s.document = { ...s.document, source: view.state.doc.toString(), blocks };
    if(s.id!==s.document.path)this.queue(s.id);
    this.refresh();
    clearTimeout(this.typingTimers.get(view));
    this.typingTimers.set(view,setTimeout(()=>{if(!this.stopped)this.refresh(true);},4100));
  }
  private queue(id: string): void {
    this.dirty.add(id);
    clearTimeout(this.timers.get(id));
    this.timers.set(id, setTimeout(() => void this.flush(id).catch(e => this.p.showError(e)), 650));
    // Persist IDs/timestamps before network, for restart while WorkScribe is down.
    const d = this.sessions.get(id)?.document;
    if (d) {
      this.p.documentLedgers[id] = d;
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => void this.p.saveSettings(), 250);
    }
  }
  async flush(id = this.p.live.meetingId ?? ''): Promise<void> {
    clearTimeout(this.timers.get(id));
    const prior = this.lanes.get(id) ?? Promise.resolve();
    const op = prior.catch(() => {}).then(async () => {
      if (this.stopped || !this.dirty.has(id)) return;
      const s = this.sessions.get(id); if (!s || s.document.finalized) return;
      if ([...this.views].some(v => this.session(v.state) === s && v.composing)) return;
      const before = s.document;
      // Save through Obsidian, so its editor state and file watcher agree.
      for (const leaf of this.p.app.workspace.getLeavesOfType('markdown')) {
        const v = leaf.view as MarkdownView;
        if (v.file && this.p.absolutePath(v.file.path) === before.path) await v.save();
      }
      if (this.p.connState.kind !== 'online') return;
      try {
        const relative = this.relative(before.path) ?? '';
        const resolved = { ...before, blocks: before.blocks.map(b => ({ ...b, images: b.images?.map(image => {
          const file = this.p.app.metadataCache.getFirstLinkpathDest(image.target, relative);
          return { target: image.target, ...(file ? { path: this.p.absolutePath(file.path) ?? undefined } : {}) };
        }) })) };
        const next = await this.p.client.syncDocument(id, resolved);
        if (s.document === before) { s.document = next; this.dirty.delete(id); }
        else s.document = { ...s.document, revision: next.revision };
        this.p.documentLedgers[id] = s.document; await this.p.saveSettings();
      } catch (e) {
        // A second editor may have advanced the server. Keep our local source, adopt the revision, and retry.
        if (e instanceof Error && e.message.includes('(409)')) {
          const remote = await this.p.client.openDocument(id);
          if (remote.finalized) { s.document = remote; this.dirty.delete(id); this.refresh(); return; }
          s.document = { ...s.document, revision: remote.revision };
        }
        throw e;
      }
    });
    this.lanes.set(id, op);
    await op;
    if (this.dirty.has(id) && this.p.connState.kind === 'online') this.queue(id);
  }
  private imageChanged(file: TFile): void {
    if (!/^(png|jpe?g|gif|webp|heic|bmp|tiff?)$/i.test(file.extension)) return;
    const path = this.p.absolutePath(file.path);
    for (const [id,s] of this.sessions) if (!s.document.finalized && s.document.blocks.some(b => b.images?.some(i => i.path === path || i.target === file.name || i.target === file.path))) this.queue(id);
  }
  private async diskChanged(file: TFile): Promise<void> {
    const path = this.p.absolutePath(file.path);
    const s = [...this.sessions.values()].find(s => s.document.path === path);
    if (!s || s.document.finalized) return;
    const source = await this.p.app.vault.read(file);
    if (source === s.document.source) return;
    // Open editor transactions are authoritative; the disk event can be an older autosave.
    const open = [...this.views].find(v => this.session(v.state) === s);
    if (open) return;
    s.document = { ...s.document, source, blocks: reconcile(source, s.document.blocks, this.p.recording ? this.p.elapsed() : undefined) };
    this.queue(s.id);
  }
  private async checkFinalized(): Promise<void> {
    for (const [id,s] of this.sessions) if (!s.document.finalized && !this.dirty.has(id) && !this.finalizing.has(id)) {
      try {
        const m = await this.p.client.meeting(id);
        await this.retitle(id, m.title, m.status);
        if (m.document?.finalized) {
          s.document = m.document; delete this.p.documentLedgers[id]; await this.p.saveSettings(); this.refresh();
        }
      } catch { /* Normal offline state: the vault remains editable. */ }
    }
  }
  /** Once a meeting has stopped, its note takes WorkScribe's title in place of the placeholder
   *  ("2026-10-18 Zoom meeting · …"), and a later, better title replaces one WorkScribe gave earlier.
   *  A name you chose is never touched. Renaming through Obsidian keeps open tabs and links on it. */
  private async retitle(id: string, title: string, status: string): Promise<void> {
    if (status === 'recording' || !title || /^(Zoom meeting|Recording) · /.test(title)) return;
    const file = this.p.app.vault.getMarkdownFiles().find(f => this.p.meetingIdOf(f) === id);
    const day = file?.basename.match(/^(\d{4}-\d{2}-\d{2}) /)?.[1];
    if (!file || !day) return;
    const ours = /^\d{4}-\d{2}-\d{2} (?:Zoom meeting|Recording) · /.test(file.basename) || file.basename === this.p.meetingNames[id];
    const name = `${day} ${noteName(title)}`;
    if (!ours || file.basename === name) return;
    const folder = file.parent?.path ?? '';
    let path = normalizePath(`${folder}/${name}.md`);
    for (let n = 2; this.p.app.vault.getAbstractFileByPath(path); n++) path = normalizePath(`${folder}/${name} ${n}.md`);
    await this.p.app.fileManager.renameFile(file, path);
    this.p.meetingNames[id] = file.basename; await this.p.saveSettings();
  }
  markFinalized(id: string): void {
    if(this.finalizing.has(id))return;
    const s = this.sessions.get(id); if (!s) return;
    s.document = { ...s.document, finalized: true };
    this.dirty.delete(id); clearTimeout(this.timers.get(id));
    delete this.p.documentLedgers[id]; void this.p.saveSettings();
    this.refresh();
  }
  isFinalized(): boolean { return !!this.sessions.get(this.p.live.meetingId ?? "")?.document.finalized; }
  async finalize(): Promise<void> {
    const id = this.p.live.meetingId; if (!id) return;
    await this.flush(id);
    const session=this.sessions.get(id); if(!session)return;
    const before={...session.document};
    const view=[...this.views].find(v=>this.session(v.state)?.id===id);
    const selection=view?.state.selection, savedScroll=view?.scrollDOM.scrollTop;
    this.finalizing.add(id);
    let d;
    try { d=await this.p.client.finalizeDocument(id); } finally { this.finalizing.delete(id); }
    const relative=this.relative(d.path),file=relative?this.p.app.vault.getAbstractFileByPath(relative):null;
    const source=file instanceof TFile?await this.p.app.vault.adapter.read(file.path):d.source;
    if(d.path!==before.path) {
      session.document={...d,source};
      if(file instanceof TFile) await this.p.app.workspace.getLeaf('tab').openFile(file);
      new Notice('Your note changed. The finalized version is beside it: '+(relative ?? d.path));
      this.refresh();return;
    }
    if(view) {
      // A disk watcher can deliver our own atomic write before the API response.
      // Restore the known preimage without history, then commit the same insertions once.
      if(view.state.doc.toString()===source && source!==before.source){
        view.dispatch({changes:{from:0,to:view.state.doc.length,insert:before.source},selection:selection?{anchor:Math.min(selection.main.anchor,before.source.length),head:Math.min(selection.main.head,before.source.length)}:undefined,annotations:Transaction.addToHistory.of(false)});
      }
      // One isolated transaction includes text and pencil ownership; inverse restores both.
      const old=view.state.doc.toString();let from=0,end=old.length,nextEnd=source.length;
      while(from<end&&from<nextEnd&&old[from]===source[from])from++;
      while(end>from&&nextEnd>from&&old[end-1]===source[nextEnd-1]){end--;nextEnd--;}
      const scroll=savedScroll??view.scrollDOM.scrollTop;
      const insertions=d.insertions;let check=old;if(insertions)for(const i of [...insertions].sort((a,b)=>b.at-a.at))check=check.slice(0,i.at)+i.text+check.slice(i.at);
      view.dispatch({changes:insertions&&check===source?insertions.map(i=>({from:i.at,insert:i.text})):{from,to:end,insert:source.slice(from,nextEnd)},
        effects:setDocument.of({document:{...d,source},previous:before}),
        annotations:isolateHistory.of('full'),userEvent:'input.finalize'});
      view.requestMeasure({read:()=>scroll,write:y=>{view.scrollDOM.scrollTop=y;}});
      const rows:number[]=[];for(let i=from;i<=Math.min(view.state.doc.length,source.length);){const line=view.state.doc.lineAt(i);rows.push(line.from);if(line.to>=view.state.doc.length)break;i=line.to+1;}
      view.dispatch({effects:inkLines.of(rows)});
      window.setTimeout(()=>{if(this.views.has(view))view.dispatch({effects:inkLines.of([])});},300+rows.length*45);
    } else session.document={...d,source};
    for(const leaf of this.p.app.workspace.getLeavesOfType('markdown'))if(leaf.view instanceof MarkdownView&&this.p.absolutePath(leaf.view.file?.path??'')===d.path)await leaf.view.save();
    this.dirty.delete(id);clearTimeout(this.timers.get(id));
    this.p.notify(new Set(["notes"]));
    this.refresh();
    if(view&&savedScroll!==undefined){
      let active=true;const stop=()=>{active=false;};view.scrollDOM.addEventListener('wheel',stop,{once:true,passive:true});
      for(const delay of [0,60,200])window.setTimeout(()=>{if(active&&this.views.has(view))view.scrollDOM.scrollTop=savedScroll;},delay);
      window.setTimeout(()=>view.scrollDOM.removeEventListener('wheel',stop),250);
    }
  }
  private takeOver(view: EditorView, block: Block, text: string, offset=text.length): void {
    if(block.owned)return;
    const row=view.dom.querySelector<HTMLElement>(`.ws-editor-ai[data-ws-block="${block.id}"]`);
    const top=row?.getBoundingClientRect().top;
    if(row)rememberOwnedIndent(block.id,(row.querySelector('.ws-editor-ai-button')?.getBoundingClientRect().left??row.getBoundingClientRect().left)-row.getBoundingClientRect().left);
    const value=continuation(text,block.text,true);
    const from=block.to+1;
    view.dispatch({changes:{from:block.to,insert:'\n'+value},
      effects:ownBlock.of({id:block.id,owned:{from,to:from+value.length,text:value}}),
      selection:{anchor:from+continuation(text.slice(0,offset),block.text,true).length},annotations:isolateHistory.of('full'),userEvent:'input'});
    view.focus();
    if(top!==undefined){let frames=12;const stabilize=()=>view.requestMeasure({read:()=>view.dom.querySelector<HTMLElement>(`.ws-owned-line[data-ws-block="${block.id}"]`)?.getBoundingClientRect().top,write:y=>{if(y!==undefined)view.scrollDOM.scrollTop+=y-top;if(--frames>0)requestAnimationFrame(stabilize);}});requestAnimationFrame(stabilize);}
  }
  private why(view: EditorView, block: Block, note: Note): void {
    const panel=this.p.app.workspace.getLeavesOfType(LIVE_VIEW)[0]?.view;
    if(panel instanceof LiveView){panel.showEvidence(note);return;}
    this.evidenceModal?.close();
    const modal=new Modal(this.p.app);this.evidenceModal=modal;this.evidenceId=this.session(view.state)?.id;
    modal.titleEl.setText('What informed this line');
    renderTrace(modal.contentEl,note.trace,{open:true,excerpts:note.excerpts,onSource:(m,event)=>this.p.openMoment(m,event),
      onExcerpt:(e,event)=>this.p.openMoment({kind:'meeting',title:e.speaker,meetingId:this.evidenceId,start:e.start,snippet:e.quote},event)});
    modal.contentEl.createEl('p',{cls:'ws-trace-retention',text:'The transcript, evidence and revision history fade with this meeting. Only your note remains.'});
    modal.open();
  }

  async grabMoment(target?: TFile | null, cursor?: { line: number; ch: number }): Promise<void> {
    const candidates = [...this.views].filter(v => target ? this.session(v.state)?.document.path === this.p.absolutePath(target.path) : v.hasFocus);
    const view = candidates.find(v => v.hasFocus) ?? candidates.find(v => cursor && v.state.selection.main.head === v.state.doc.line(cursor.line + 1).from + cursor.ch) ?? candidates[0];
    const session = view && this.session(view.state);
    const file = view?.state.field(editorInfoField, false)?.file;
    if (!view || !session || !file || session.document.finalized) throw new Error('Open the live meeting note to grab this moment.');
    if (view.state.field(imageInsertion)) return;
    const id = crypto.randomUUID();
    view.dispatch({ effects: placeImage.of({ id, at: view.state.selection.main.head }) });
    try {
      const image = imageBytes(await this.p.client.grabMoment(session.id));
      if (!this.views.has(view) || this.session(view.state) !== session || session.document.finalized) return;
      const point = view.state.field(imageInsertion);
      if (!point || point.id !== id) return;
      // Obsidian owns attachment location, relative-link style, and name collisions.
      const path = await this.p.app.fileManager.getAvailablePathForAttachment(image.filename, file.path);
      const attachment = await this.p.app.vault.createBinary(path, image.data);
      const current = view.state.field(imageInsertion);
      if (!current || current.id !== id) { new Notice(`Saved screen image: ${path}`); return; }
      const link = this.p.app.fileManager.generateMarkdownLink(attachment, file.path);
      const embed = link.startsWith('!') ? link : '!' + link;
      view.dispatch({ changes: { from: current.at, insert: '\n\n' + embed + '\n\n' }, effects: placeImage.of(null), userEvent: 'input.paste' });
    } finally { if (this.views.has(view)) view.dispatch({ effects: placeImage.of(null) }); }
  }
  async append(text: string, atCursor=false): Promise<boolean> {
    const id = this.p.live.meetingId; if (!id) return false;
    const file = await this.open(id, false); if (!file) return false;
    const view = [...this.views].find(v => this.session(v.state)?.id === id);
    const suffix = '\n\n' + text + '\n';
    if (view) view.dispatch({ changes: { from: atCursor?view.state.selection.main.head:view.state.doc.length, insert: suffix }, userEvent: 'input' });
    else await this.p.app.vault.process(file, source => source + suffix);
    await this.diskChanged(file); return true;
  }
  purge(id: string): void {
    this.actionMenu?.hide(); this.actionMenu = undefined;
    if (this.evidenceId === id || this.focusedSources.some(s=>s.meetingId===id)) {this.focusedSources=[]; this.evidenceModal?.close(); this.evidenceModal = undefined; this.evidenceId = undefined; }
    this.sessions.delete(id); delete this.p.documentLedgers[id]; this.dirty.delete(id); for(const key of this.makes.keys())if(key.startsWith(id+"/"))this.makes.delete(key); this.refresh(true); void this.p.saveSettings();
  }

}

