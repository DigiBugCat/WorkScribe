// The few browser globals src/ui/*.ts touches when it is constructed outside Obsidian. Imported before them.
import { inert } from './obsidian';

const g = globalThis as Record<string, unknown>;
g.window ??= globalThis;
g.document ??= inert();
g.requestAnimationFrame ??= (f: () => void) => setTimeout(f, 0);
g.ResizeObserver ??= class { observe(): void {} disconnect(): void {} };
