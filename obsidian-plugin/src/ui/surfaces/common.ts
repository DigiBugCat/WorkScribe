import type { SurfaceSource } from '../../lib/types';
export function button(label: string, action: () => void, cls = ''): HTMLButtonElement {
  const el = document.createElement('button'); el.type='button'; el.className=cls;
  el.textContent=label; el.setAttribute('aria-label',label); el.onclick=e=>{e.preventDefault();action();}; return el;
}
export const reducedMotion = (): boolean => typeof window !== 'undefined' && !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
export const time = (at?: number): string => at === undefined ? '' : `${Math.floor(at/60)}:${String(Math.floor(at%60)).padStart(2,'0')}`;
export function sourceLabel(sources: SurfaceSource[]): string { const s=sources[0]; return s ? [s.title,time(s.at)].filter(Boolean).join(' · ') : ''; }
