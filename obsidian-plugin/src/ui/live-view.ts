import { askedOfYou, rankQuestions } from '../lib/questions';
import { transcriptTurns } from "../lib/transcript-turns";
// Companion panel. All note editing lives in Obsidian's ordinary MarkdownView.
import { ItemView, Notice, setIcon, type WorkspaceLeaf } from 'obsidian';
import { fadeCountdown } from '../lib/care';
import { renderTrace } from './trace';
import { clock } from '../lib/format';
import type WorkScribePlugin from '../main';
import type { LiveChange } from '../main';
import { ChatPanel } from './chat';
import { renderCitedMarkdown, renderSources } from './render';
import type { Note } from '../lib/types';
import type { LivePanelTab } from '../settings';

export const LIVE_VIEW = 'workscribe-live';
export class LiveView extends ItemView {
  private unsub?: () => void;
  private pill!: HTMLElement;
  private clockEl!: HTMLElement;
  private recordButton!: HTMLButtonElement;
  private finishButton!: HTMLButtonElement;
  private confirmDone = false;
  private noteStatus!: HTMLElement;
  private contentSignature = '';
  private tabButtons = new Map<LivePanelTab, HTMLButtonElement>();
  private tabs!: HTMLElement;
  private body!: HTMLElement;
  private chat?: ChatPanel;
  private frame = 0;
  private active: LivePanelTab | null = null;
  private evidence?: Note;
  private renderedEvidenceId?: string;
  constructor(leaf: WorkspaceLeaf, private p: WorkScribePlugin) { super(leaf); }
  getViewType(): string { return LIVE_VIEW; }
  getDisplayText(): string { return 'WorkScribe'; }
  override getIcon(): string { return 'mic'; }
  override async onOpen(): Promise<void> {
    this.contentEl.empty(); this.contentEl.addClass('ws-live-companion');
    this.pill = document.createElement('div');
    this.pill.createSpan({ cls: 'ws-rec-dot' });
    this.clockEl = this.pill.createSpan();
    this.recordButton = this.pill.createEl('button');
    this.recordButton.addEventListener('click', () => void this.p.toggleRecording());
    this.finishButton = this.pill.createEl('button', { cls: 'ws-finalize-control' });
    this.noteStatus=document.createElement('div');
    this.finishButton.addEventListener('click', () => {
      if(this.p.noteEditor.isFinalized() && !this.confirmDone) {
        this.confirmDone=true;this.renderPill();return;
      }
      this.finishButton.disabled=true;
      const action = this.p.noteEditor.isFinalized() ? this.p.client.done(this.p.live.meetingId!) : this.p.noteEditor.finalize();
      void action.then(() => this.render()).catch(e => this.p.showError(e));
    });
    this.contentEl.addEventListener('keydown',event=>{
      if(event.key==='Escape' && this.confirmDone) {this.confirmDone=false;this.renderPill();}
      if(event.key==='Enter' && (event.metaKey || event.ctrlKey) && !this.p.recording && !this.p.noteEditor.isFinalized()) {
        event.preventDefault();this.finishButton.click();
      }
    });
    const open = this.contentEl.createEl('button', { text: 'Open the meeting note', cls: 'ws-open-meeting ws-tbtn' });
    open.addEventListener('click', () => {
      const id = this.p.live.meetingId;
      if (id) void this.p.noteEditor.open(id).catch(e => this.p.showError(e));
      else new Notice('Start recording to create a meeting note.');
    });
    const updateOpen=()=>{open.hidden=this.app.workspace.getLeavesOfType('markdown').some(l=>this.p.meetingIdOf((l.view as import('obsidian').MarkdownView).file)===this.p.live.meetingId);};
    this.registerEvent(this.app.workspace.on('layout-change',updateOpen));updateOpen();
    this.tabs = this.contentEl.createDiv({ cls: 'ws-tabs', attr: { role: 'tablist', 'aria-label': 'Meeting companion' } });
    for (const [id,label] of [['ask','Ask'],['qa','Live Q&A'],['transcript','Transcript']] as const) {
      const b = this.tabs.createEl('button', { cls:'ws-tab', text:label, attr:{role:'tab'} });
      this.tabButtons.set(id,b);
      b.addEventListener('click', () => { this.p.settings.livePanelTab=id; void this.p.saveSettings(); this.render(); });
      b.addEventListener('keydown', event => {
        const ids: LivePanelTab[] = ['ask','qa','transcript'];
        if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
          event.preventDefault();
          const next = ids[(ids.indexOf(id) + (event.key === 'ArrowRight' ? 1 : 2)) % 3];
          this.p.settings.livePanelTab=next; void this.p.saveSettings(); this.render(); this.tabButtons.get(next)?.focus();
        }
      });
    }
    this.body = this.contentEl.createDiv({ cls: 'ws-companion-body', attr:{role:'tabpanel'} });
    this.unsub = this.p.subscribe(changes => {
      if(changes.has('purged')){this.evidence=undefined;this.renderedEvidenceId=undefined;this.contentSignature='';}
      if (changes.has('tick')) {this.renderPill();updateOpen();}
      if ((['meeting','notes','segments','answer','status','conn'] as LiveChange[]).some(x => changes.has(x))) {updateOpen();this.schedule();}
    });
    this.render();
  }
  override async onClose(): Promise<void> { this.chat?.unload();this.unsub?.(); if (this.frame) cancelAnimationFrame(this.frame); }
  private schedule(): void {
    if (!this.frame) this.frame = requestAnimationFrame(() => { this.frame = 0; this.render(); });
  }
  private renderPill(): void {
    this.pill.toggleClass('is-rec', this.p.recording);
    this.clockEl.setText(this.p.connState.kind === 'offline' ? 'AI lines paused · your notes are saving' : this.p.recording ? clock(this.p.elapsed()) + ' · ' + (this.p.live.status?.sources.system ? 'Mic + system' : 'Mic') : this.p.live.purgeAt ? fadeCountdown(this.p.live.purgeAt) : 'Ready');
    this.recordButton.setAttribute('aria-label', this.p.recording ? 'Stop recording' : 'Start recording');
    const icon = this.p.recording ? 'square' : 'mic';
    if (this.recordButton.dataset.icon !== icon) { setIcon(this.recordButton,icon); this.recordButton.dataset.icon=icon; }
    this.finishButton.style.display = this.p.recording || !this.p.live.meetingId ? 'none' : '';
    this.finishButton.disabled = this.p.recording || !this.p.live.meetingId;
    this.finishButton.setText(this.p.noteEditor.isFinalized() ? (this.confirmDone?'Delete now':'Done now') : 'Finalize ⌘↩');
    this.noteStatus.setText(this.p.recording ? '' : this.confirmDone
      ? `Delete the transcript, audio and ${this.p.live.screens.length} screen moments now? The note stays. Esc cancels.`
      : this.p.noteEditor.isFinalized() ? 'Your note is saved. Only the raw meeting data will fade.'
      : `AI lines and a brief will be written into your note. Your edits stay as you wrote them.`);
    this.tabButtons.get('qa')?.setText(this.p.live.answers.length?`Live Q&A · ${this.p.live.answers.length}`:'Live Q&A');
    this.finishButton.setAttribute('aria-label', this.p.noteEditor.isFinalized() ? 'Delete raw meeting data now. The note remains.' : 'Finalize this meeting note');
  }
  showEvidence(note: Note): void {
    this.evidence=note;this.p.settings.livePanelTab='transcript';this.contentSignature='';this.render();
    const first=this.body.querySelector<HTMLElement>('.ws-turn.is-evidence');first?.scrollIntoView({block:'nearest'});
    window.setTimeout(()=>this.body.querySelectorAll('.is-evidence').forEach(el=>el.classList.remove('is-evidence')),2400);
  }
  private render(): void {
    this.renderPill();
    const tab = this.p.settings.livePanelTab;
    for (const [id,button] of this.tabButtons) {
      button.setAttribute('aria-selected',String(tab===id)); button.tabIndex=tab===id?0:-1;
      button.toggleClass('is-active',tab===id);
    }
    const signature = tab + JSON.stringify(tab === 'transcript' ? this.p.live.segments : tab === 'qa' ? this.p.live.answers : null);
    if (signature === this.contentSignature && tab !== 'ask') return;
    this.contentSignature = signature;
    if (tab === 'ask' && this.active === tab) { this.chat?.refresh(); return; }
    const evidenceOpen=this.renderedEvidenceId===this.evidence?.id?[...this.body.querySelectorAll<HTMLDetailsElement>('.ws-evidence-header details')].map(d=>d.open):[];
    const scroll = this.body.scrollTop;
    const follow = this.body.scrollHeight - scroll - this.body.clientHeight < 40;
    this.chat?.unload(); this.chat=undefined; this.body.empty(); this.active=tab;
    if (tab === 'ask') {
      this.chat = this.addChild(new ChatPanel(this.body, this.app, this.p, { scope: 'meeting', placeholder:'Ask about this meeting…',
        emptyTitle:'Ask while you listen', emptyText:'Answers use this meeting, your notes and files.', suggestions:['What have we decided so far?'] }));
    } else if (tab === 'transcript') {
      if(this.evidence){
        const header=this.body.createDiv({cls:'ws-evidence-header'});header.createEl('strong',{text:'What informed this line'});
        renderTrace(header,this.evidence.trace,{open:true,excerpts:this.evidence.excerpts,onSource:(m,e)=>this.p.openMoment(m,e)});
        [...header.querySelectorAll<HTMLDetailsElement>('details')].forEach((d,i)=>{if(evidenceOpen[i]!==undefined)d.open=evidenceOpen[i];});this.renderedEvidenceId=this.evidence.id;
        header.createEl('p',{cls:'ws-trace-retention',text:'The transcript, evidence and revision history fade with this meeting. Only your note remains.'});
      }
      if (!this.p.live.segments.length) this.body.createDiv({ cls:'ws-panel-empty', text: this.p.recording ? 'Listening…' : this.p.live.retention==='purged' ? `This transcript faded${this.p.live.purgeAt?' on '+new Date(this.p.live.purgeAt).toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'numeric',minute:'2-digit'}):''}. Your note is what remains. Ask and search use it now.` : 'Transcript appears here during a meeting and fades after 24 hours.' });
      for (const s of transcriptTurns(this.p.live.segments)) {
        const hit=this.evidence?.excerpts.some(e=>s.start<=e.start&&(s.end??s.start)>=e.start);
        const turn=this.body.createDiv({cls:hit?'ws-turn is-evidence ws-evidence-turn':'ws-turn'});
        turn.createDiv({cls:'ws-turn-head',text:`${s.speaker} · ${clock(s.start)}`});
        turn.createDiv({cls:'ws-turn-text',text:s.text});
      }
      this.body.scrollTop=follow?this.body.scrollHeight:scroll;
    } else {
      const answers=rankQuestions(this.p.live.answers,this.p.settings.yourName);
      if (!answers.length) { this.body.createDiv({cls:'ws-panel-empty',text:'Questions from the call appear here. You decide what enters your note.'}); return; }
      for(const a of answers){
      if(askedOfYou(a,this.p.settings.yourName))this.body.createDiv({cls:'ws-asked-of-you',text:'Asked of you'});
      this.body.createDiv({cls:'ws-qa-q',text:a.question});

      const content=this.body.createDiv({cls:'ws-msg-content'});
      const open=(m: import('../lib/types').Moment,e: MouseEvent) => this.p.openMoment(m,e);
      void renderCitedMarkdown(this.app,this,content,a.answer,a.citations,open);
      renderSources(this.body,a.citations,open);
      renderTrace(this.body,a.trace,{running:!a.done,sources:a.citations,onSource:(m,e)=>this.p.openMoment(m,e)});
      const add=this.body.createEl('button',{text:'Add to note'}); add.disabled=!a.done || this.p.noteEditor.isFinalized();
      add.addEventListener('click', () => void this.p.noteEditor.append(a.answer.replace(/\s*\[\d+\]/g,'')+(a.askedBy?' — '+a.askedBy:'')+(a.citations.length?', '+a.citations.map(c=>'[['+c.title+']]').join(', '):''),true).catch(e=>this.p.showError(e)));
      }
    }
  }
}
