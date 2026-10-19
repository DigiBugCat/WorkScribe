import { WidgetType, type EditorView } from '@codemirror/view';
import { isolateHistory } from '@codemirror/commands';
import type { Block } from '../../lib/anchors';
import type { PreviewEvent } from '../../lib/types';
import { button, sourceLabel } from './common';
export interface MakeActions {
  make(view: EditorView,block:Block): void;
  discard(block:Block): void;
  insert(view:EditorView,block:Block,preview:PreviewEvent):void;
  renderMermaid(code:string,container:HTMLElement):void | Promise<void>;
}
export function diagramInsertion(block:Block,mermaid:string): {from:number;insert:string} {
  // A model cannot close the outer fence and inject Markdown outside it.
  const longest=Math.max(2,...Array.from(mermaid.matchAll(/`+/g),m=>m[0].length));
  const fence='`'.repeat(longest+1);
  return {from:block.to,insert:`\n\n${fence}mermaid\n${mermaid.trim()}\n${fence}\n`};
}
export function insertDiagram(view:EditorView,block:Block,preview:PreviewEvent):void {
  view.dispatch({changes:diagramInsertion(block,preview.mermaid),annotations:isolateHistory.of('full'),userEvent:'input.make-diagram'});
}
export class MakeWidget extends WidgetType {
  constructor(readonly block:Block,readonly preview:PreviewEvent|undefined,readonly pending:boolean,readonly actions:MakeActions){super();}
  override eq(other:MakeWidget):boolean{return this.block.to===other.block.to&&this.preview===other.preview&&this.pending===other.pending;}
  override toDOM(view:EditorView):HTMLElement {
    const el=document.createElement('div');el.className='ws-surface-make';
    if(!this.preview){const make=button(this.pending?'Making diagram…':'Make diagram',()=>this.actions.make(view,this.block));make.disabled=this.pending;el.append(make);return el;}
    el.classList.add('ws-make-preview');
    const header=document.createElement('div');header.className='ws-preview-header';header.textContent='From your sketch'+(this.preview.sources.length?' + '+sourceLabel(this.preview.sources):'');el.append(header);
    const diagram=document.createElement('div');diagram.className='ws-preview-diagram';diagram.setAttribute('aria-label','Diagram preview');el.append(diagram);
    void Promise.resolve(this.actions.renderMermaid(this.preview.mermaid,diagram)).catch(()=>{diagram.replaceChildren();});
    const actions=document.createElement('div');actions.className='ws-preview-actions';
    actions.append(button('Insert below sketch',()=>this.actions.insert(view,this.block,this.preview!)),button('Discard',()=>this.actions.discard(this.block)),button('Remake',()=>this.actions.make(view,this.block)));el.append(actions);return el;
  }
  override ignoreEvent():boolean{return true;}
}
