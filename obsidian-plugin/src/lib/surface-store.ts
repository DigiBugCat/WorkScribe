import type { ChangeSet } from '@codemirror/state';
import { pinRange } from '../ui/surfaces/pin';
import type { Block } from './anchors';
import type { CheckEvent, EngineStatus, LineEvent, PinEvent, PreviewEvent, SurfaceEvent } from './types';

export class SurfaceStore {
  lines = new Map<string, LineEvent>();
  pins = new Map<string, PinEvent>();
  checks = new Map<string, CheckEvent>();
  previews = new Map<string, PreviewEvent>();
  status: EngineStatus = {model:'ready'};
  private purged = new Set<string>();
  private since = new Map<string, number>();
  static key(documentId: string, blockId: string): string { return documentId + '/' + blockId; }
  apply(event: SurfaceEvent, now = Date.now()): void {
    if (event.type === 'preview') { if(!event.sources.some(s=>s.meetingId&&this.purged.has(s.meetingId)))this.previews.set(event.requestId,event); return; }
    if(this.purged.has(event.documentId))return;
    const key = SurfaceStore.key(event.documentId,event.blockId);
    if (event.type === 'line') {
      const old = this.lines.get(key);
      if (old && event.revision < old.revision) return;
      if (old?.state !== event.state) this.since.set(key,now);
      this.lines.set(key,event);
    } else if (event.type === 'pin') this.pins.set(key + '/' + event.anchor.kind + '/' + event.anchor.path.join(':'),event);
    else this.checks.set(key + '/' + event.sentence.from,event);
  }
  line(id: string, block: Block): LineEvent | undefined { return this.lines.get(SurfaceStore.key(id,block.id)); }
  age(id: string, block: Block, now = Date.now()): number { return now - (this.since.get(SurfaceStore.key(id,block.id)) ?? now); }
  mapEdits(id: string, blocks: Block[], changes: ChangeSet): void {
    const touched=(from:number,to:number)=>{let hit=false;changes.iterChangedRanges((a,b)=>{if(a<to&&b>from || a===b&&a>from&&a<to)hit=true;});return hit;};
    for(const [key,event] of this.checks)if(event.documentId===id){const block=blocks.find(b=>b.id===event.blockId);if(!block)continue;
      const from=block.from+event.sentence.from,to=block.from+event.sentence.to;
      if(touched(from,to)){this.checks.delete(key);continue;}
      const base=changes.mapPos(block.from,1);this.checks.set(key,{...event,sentence:{from:changes.mapPos(from,1)-base,to:changes.mapPos(to,-1)-base}});
    }
    for(const [key,event] of this.pins)if(event.documentId===id){const block=blocks.find(b=>b.id===event.blockId);if(!block)continue;const range=pinRange(block,event.anchor);if(!range)continue;
      if(touched(range.from,range.to)){this.pins.delete(key);continue;}
      const base=changes.mapPos(block.from,1);this.pins.set(key,{...event,anchor:{kind:'sentence',path:[changes.mapPos(range.from,1)-base,changes.mapPos(range.to,-1)-base]}});
    }
  }
  isPurged(id:string):boolean {return this.purged.has(id);}
  purge(id: string): void {
    this.purged.add(id);
    for (const [key,line] of this.lines) if (line.documentId === id) this.lines.set(key,{...line,sources:[],reason:'Sources faded with the transcript'});
    for (const [key,event] of this.pins) if (event.documentId === id) this.pins.delete(key);
    for (const [key,event] of this.checks) if (event.documentId === id) this.checks.delete(key);
    this.previews.clear();
  }
}
