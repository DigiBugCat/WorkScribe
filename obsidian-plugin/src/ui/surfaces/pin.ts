import { WidgetType } from '@codemirror/view';
import type { Block } from '../../lib/anchors';
import type { PinEvent, SurfaceSource } from '../../lib/types';
import { button, sourceLabel } from './common';
export interface AnchorRange { from: number; to: number }
export function pinRange(block: Block, anchor: PinEvent['anchor']): AnchorRange | null {
  const lines=block.text.split('\n');
  if(anchor.kind==='task')return /^\s*[-+*]\s+\[[ xX]\]/.test(block.text) ? {from:block.from,to:block.to}:null;
  if(anchor.kind==='sentence'){const [from,to]=anchor.path;return from>=0&&to>from&&to<=block.text.length?{from:block.from+from,to:block.from+to}:null;}
  const row=anchor.path[0];if(!Number.isInteger(row)||row<0||row>=lines.length)return null;
  const start=block.from+lines.slice(0,row).reduce((n,line)=>n+line.length+1,0),line=lines[row];
  if(anchor.kind==='line')return {from:start,to:start+line.length};
  const cells: AnchorRange[]=[];let from=line.startsWith('|')?1:0,escaped=false,code=false;
  for(let i=from;i<=line.length;i++){
    if(line[i]==='`'&&!escaped)code=!code;
    if(i===line.length||(line[i]==='|'&&!escaped&&!code)){
      if(i>from||i<line.length){const text=line.slice(from,i),lead=text.length-text.trimStart().length,tail=text.length-text.trimEnd().length;cells.push({from:start+from+lead,to:start+i-tail});}from=i+1;
    }
    escaped=line[i]==='\\'&&!escaped;
  }
  return cells[anchor.path[1]]??null;
}
export class PinWidget extends WidgetType {
  constructor(readonly sources: SurfaceSource[],readonly open:(sources:SurfaceSource[])=>void,readonly focus?: (sources:SurfaceSource[])=>void){super();}
  override eq(other:PinWidget):boolean{return this.sources===other.sources;}
  override toDOM():HTMLElement {const el=button('Jump to moment: '+sourceLabel(this.sources),()=>this.open(this.sources),'ws-surface-pin');el.textContent='●';el.onfocus=()=>this.focus?.(this.sources);return el;}
  override ignoreEvent():boolean{return true;}
}
