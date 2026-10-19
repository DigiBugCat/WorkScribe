import type { SurfaceSource } from '../../lib/types';
import { button, sourceLabel } from './common';
/** Shared by the companion and fallback modal; text-only provenance, never model reasoning. */
export function renderSurfaceSources(parent:HTMLElement,sources:SurfaceSource[],open:(source:SurfaceSource)=>void):void {
  parent.replaceChildren();
  if(!sources.length){const p=document.createElement('p');p.textContent='Sources faded with the transcript';parent.append(p);return;}
  for(const source of sources){const row=document.createElement('div');row.className='ws-surface-source';
    row.append(button([source.speaker,sourceLabel([source])].filter(Boolean).join(' · '),()=>open(source)));
    const quote=document.createElement('blockquote');quote.textContent=source.quote??source.title;row.append(quote);parent.append(row);
  }
}
