import { Decoration } from '@codemirror/view';
import type { Range } from '@codemirror/state';
import type { Block } from '../../lib/anchors';
import type { SurfaceSource, PreviewEvent } from '../../lib/types';
import type { SurfaceStore } from '../../lib/surface-store';
import { LineWidget, linePresentation, type LineActions } from './line';
import { PinWidget, pinRange } from './pin';
import { CheckNote, CheckTime } from './check';
import { MakeWidget, type MakeActions } from './make';
export interface SurfaceHost extends LineActions, MakeActions {
  store:SurfaceStore;
  canMake?:boolean;
  recording():boolean;
  elapsed():number;
  openSources(sources:SurfaceSource[]):void;
  preview(block:Block):PreviewEvent|undefined;
  pending(block:Block):boolean;
}
export function surfaceDecorations(host:SurfaceHost,id:string,blocks:Block[],defer: (block:Block)=>boolean):Range<Decoration>[] {
  const out:Range<Decoration>[]=[];
  for(const block of blocks){
    if(defer(block))continue;
    const line=host.store.line(id,block);
    if(line&&!block.surface&&!block.nested){const label=linePresentation(line,block,host.recording(),host.elapsed(),host.store.age(id,block));if(label!==null)out.push(Decoration.widget({widget:new LineWidget(line,block,label,host),block:true,side:1}).range(block.to));}
    if(block.surface==='fence'&&(host.canMake||host.preview(block)))out.push(Decoration.widget({widget:new MakeWidget(block,host.preview(block),host.pending(block),host),block:true,side:2}).range(block.to));
    for(const pin of host.store.pins.values())if(pin.documentId===id&&pin.blockId===block.id){const range=pinRange(block,pin.anchor);if(range)out.push(Decoration.widget({widget:new PinWidget(pin.sources,s=>host.openSources(s),host.focusSources),side:1}).range(range.to));}
    const checks=[...host.store.checks.values()].filter(c=>c.documentId===id&&c.blockId===block.id&&c.sentence.from>=0&&c.sentence.to<=block.text.length&&c.sentence.to>c.sentence.from);
    for(const check of checks){const from=block.from+check.sentence.from,to=block.from+check.sentence.to;
      out.push(Decoration.mark({class:check.verdict==='supported'?'ws-check-supported':'ws-check-differs',attributes:{'data-ws-check':block.id,role:'link',tabindex:'0','aria-label':'Jump to supporting moment'}}).range(from,to));
      out.push(Decoration.widget({widget:new CheckTime(check.sources,s=>host.openSources(s),host.focusSources),side:1}).range(to));
    }
    const differs=checks.filter(c=>c.verdict==='differs');if(differs.length)out.push(Decoration.widget({widget:new CheckNote(differs.map(c=>c.note??c.sources[0]?.quote??'Open the moment').join(' '),()=>host.openSources(differs.flatMap(c=>c.sources))),block:true,side:3}).range(block.to));
  }
  return out;
}
