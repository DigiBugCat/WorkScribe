import { WidgetType, type EditorView } from '@codemirror/view';
import type { Block } from '../../lib/anchors';
import type { LineEvent, SurfaceSource } from '../../lib/types';
import { wordDiff } from '../../lib/care';
import { button, reducedMotion } from './common';
export interface LineActions {
  focusSources?(sources:SurfaceSource[]):void;
  sources(line: LineEvent): void;
  own(view: EditorView, block: Block, text: string, offset?: number): void;
  rewrite(view: EditorView, block: Block): void;
}
export function linePresentation(line: LineEvent, block: Block, recording: boolean, elapsed: number, stateAge: number): string | null {
  if (line.state === 'yours' || block.owned) return null;
  if (line.state === 'listening') return recording && elapsed-(block.at??elapsed)>=8 ? '' : null;
  if (line.state === 'found') return stateAge>=1500 ? '' : null;
  if (line.state === 'quiet') return !recording && /\?\s*$/.test(block.text) ? 'Not discussed' : null;
  return line.text || null;
}
export class LineWidget extends WidgetType {
  constructor(readonly line: LineEvent, readonly block: Block, readonly label: string, readonly actions: LineActions) {super();}
  override eq(other: LineWidget): boolean {return this.line===other.line && this.block.from===other.block.from && this.block.to===other.block.to && this.label===other.label;}
  private view?: EditorView;
  private bind(el:HTMLElement):void {
    const body=el.querySelector<HTMLElement>('.ws-editor-ai-button');if(!body||this.line.state==='quiet')return;
    body.onclick=()=>this.actions.sources(this.line);
    body.onfocus=()=>this.actions.focusSources?.(this.line.sources);
    body.onkeydown=e=>e.stopPropagation();
    body.oninput=()=>{
      if(body.dataset.composing)return;
      const s=window.getSelection();let offset=(body.textContent??'').length;
      if(s?.anchorNode&&body.contains(s.anchorNode)){const r=document.createRange();r.selectNodeContents(body);r.setEnd(s.anchorNode,s.anchorOffset);offset=r.toString().length;}
      this.actions.own(this.view!,this.block,body.textContent??'',offset);
    };
    if(!body.dataset.bound){body.dataset.bound='true';body.addEventListener('compositionstart',()=>{body.dataset.composing='true';});body.addEventListener('compositionend',()=>{delete body.dataset.composing;body.dispatchEvent(new Event('input'));});}
    const controls=el.querySelectorAll<HTMLButtonElement>('.ws-surface-actions button');
    if(controls[0])controls[0].onclick=()=>this.actions.sources(this.line);
    if(controls[1])controls[1].onclick=()=>this.actions.own(this.view!,this.block,body.textContent??this.label);
  }
  private paint(el: HTMLElement): void {
    const oldRevision=Number(el.dataset.revision??0), before=el.querySelector('.ws-editor-ai-button')?.textContent??'';
    el.dataset.state=this.line.state; el.dataset.revision=String(this.line.revision); el.dataset.wsBlock=this.block.id;
    el.className='ws-editor-ai ws-surface-line';el.replaceChildren();
    const nib=document.createElement('span'); nib.className='ws-ai-nib'; nib.setAttribute('aria-hidden','true'); el.append(nib);
    if (!this.label) {el.setAttribute('aria-label',this.line.state==='found'?'Relevant moment found':'Listening for this jot'); return;}
    const body=document.createElement('span'); body.className='ws-editor-ai-button'; body.textContent=this.label; el.append(body);
    if(this.line.state==='quiet') return;
    if(this.line.state==='answered' && this.line.revision>oldRevision && oldRevision>0 && !reducedMotion()) {
      body.replaceChildren();let offset=0;
      for(const part of wordDiff(before,this.label)) {
        if(part.kind==='removed')continue;
        const word=document.createElement('span');word.textContent=part.text;
        const changed=this.line.changed?.some(([from,to])=>offset<to&&offset+part.text.length>from) ?? part.kind==='added';
        if(changed)word.className='ws-surface-change';body.append(word);offset+=part.text.length;
      }
    }
    body.contentEditable='true';body.spellcheck=false;body.tabIndex=0;body.setAttribute('role','textbox');body.setAttribute('aria-label','AI line. Type to make it yours');
    const actions=document.createElement('span');actions.className='ws-surface-actions';
    actions.append(button('Why?',()=>{}),button('Make it mine',()=>{}));el.append(actions);this.bind(el);
  }
  override toDOM(view: EditorView): HTMLElement {this.view=view;const el=document.createElement('div');this.paint(el);return el;}
  override updateDOM(el: HTMLElement, view: EditorView): boolean {
    this.view=view;const body=el.querySelector<HTMLElement>('.ws-editor-ai-button');
    // Composition and the first user keystroke must win over any arriving line.
    if(body?.dataset.composing||body===el.ownerDocument.activeElement){this.bind(el);return true;}
    if(el.dataset.revision!==String(this.line.revision)||el.dataset.state!==this.line.state||body?.textContent!==this.label)this.paint(el);
    else this.bind(el);return true;
  }
  override ignoreEvent(): boolean {return true;}
}
