import {setIcon} from 'obsidian';
import {renderMoment} from './render';
import type { AITrace, Excerpt, Moment } from '../lib/types';
import { clock } from '../lib/format';
import { wordDiff } from '../lib/care';

/** Native disclosure controls: keyboard accessible, nested, and quiet by default. */
export function renderTrace(parent: HTMLElement, trace: AITrace | undefined, options: {
  open?: boolean; running?: boolean; excerpts?: Excerpt[]; onExcerpt?: (e: Excerpt, event: MouseEvent) => void;
  sources?: Moment[]; onSource?: (m: Moment, event: MouseEvent) => void;
} = {}): HTMLDetailsElement {
  const box = parent.createEl('details', {cls:'ws-trace'}); box.open=!!options.open;
  const summary=box.createEl('summary');
  summary.textContent = options.running ? 'Looking through your sources' : trace?.model
    ? [trace.model, trace.location, trace.durationMs === undefined ? '' : (trace.durationMs/1000).toFixed(1)+' s'].filter(Boolean).join(' · ')
    : 'How this was made';
  if(options.running) summary.classList.add('is-running');
  for(const step of trace?.steps ?? []) {
    if(options.excerpts?.length&&step.title==='Matched transcript')continue;
    const row=box.createEl('details',{cls:'ws-trace-step'});
    const label=row.createEl('summary',{text:step.title});
    label.classList.toggle('is-running',step.status==='running');
    if(step.status==='error') label.append(' · Couldn’t complete');
    if(step.status==='pending') label.append(' · Waiting');
    if(step.detail) row.createEl('p',{text:step.detail});
  }
  if(!trace?.model && !trace?.steps.length && !options.running) box.createEl('p',{text:'This older result did not record its model or steps.'});
  if(options.excerpts?.length) {
    const heard=box.createEl('details'); heard.open=true; heard.createEl('summary',{text:'What it heard'});
    for(const e of options.excerpts) {
      const b=heard.createEl('button',{cls:'ws-trace-source',text:`${e.speaker} · ${clock(e.start)}`});
      b.onclick=ev=>options.onExcerpt?.(e,ev);
      heard.createEl('p',{text:e.quote});
    }
  }
  const sources=trace?.sources?.length?trace.sources.map(s=>({kind:s.kind,title:s.title,snippet:s.text,link:s.link,thumbnail:s.thumbnail,start:s.start,end:s.end} as Moment)):options.sources;
  if(sources?.length) {
    const read=box.createEl('details');read.createEl('summary',{text:'What else it read'});
    for(const m of sources) {
      if(m.kind==='screen'){renderMoment(read,m,{onOpen:(moment,event)=>options.onSource?.(moment,event)});continue;}
      const b=read.createEl('button',{cls:'ws-trace-source',text:m.title});
      b.onclick=e=>options.onSource?.(m,e);
      if(m.snippet) read.createEl('p',{text:m.snippet});
    }
  }
  const history=trace?.revisions ?? [];
  if(history.length) {
    const revisions=box.createEl('details');revisions.createEl('summary',{text:`Revision history · v${history[history.length-1].version}`});
    history.forEach((revision,i)=>{
      const row=revisions.createEl('details');row.createEl('summary',{text:`v${revision.version} · ${revision.reason}`});
      const text=row.createEl('p');
      for(const part of wordDiff(history[i-1]?.text ?? '',revision.text))
        text.createEl(part.kind==='added'?'ins':part.kind==='removed'?'del':'span',{text:part.text});
    });
  }
  for(const label of box.querySelectorAll('summary')){const icon=document.createElement('span');icon.className='ws-trace-chevron';setIcon(icon,'chevron-right');label.prepend(icon);}
  return box;
}
