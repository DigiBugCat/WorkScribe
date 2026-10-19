import { WidgetType } from '@codemirror/view';
import type { SurfaceSource } from '../../lib/types';
import { button, time } from './common';
export class CheckTime extends WidgetType {
  constructor(readonly sources: SurfaceSource[],readonly open:(sources:SurfaceSource[])=>void,readonly focus?: (sources:SurfaceSource[])=>void){super();}
  override eq(other:CheckTime):boolean{return this.sources===other.sources;}
  override toDOM():HTMLElement {const el=button(time(this.sources[0]?.at)||'Source',()=>this.open(this.sources),'ws-check-time');el.onfocus=()=>this.focus?.(this.sources);return el;}
  override ignoreEvent():boolean{return true;}
}
export class CheckNote extends WidgetType {
  constructor(readonly note:string,readonly open:()=>void){super();}
  override eq(other:CheckNote):boolean{return this.note===other.note;}
  override toDOM():HTMLElement {return button('Heard differently: '+this.note,this.open,'ws-check-note');}
  override ignoreEvent():boolean{return true;}
}
