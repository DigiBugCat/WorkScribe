// A stand-in for the `obsidian` module, which exists only inside Obsidian. The test build aliases `obsidian`
// to this file (esbuild.config.mjs) so that tests can load src/ui/*.ts and drive the real classes.
// It holds only what those modules need to be imported and constructed; nothing here draws anything.
import { StateField } from '@codemirror/state';

/** Absorbs every property read, call and assignment: the DOM the plugin decorates but tests do not look at. */
export function inert(): any {
  return new Proxy(function () {}, {
    get: (_t, p) => (p === 'then' ? undefined : p === Symbol.toPrimitive ? () => '' : inert()),
    apply: () => inert(),
    construct: () => inert(),
    set: () => true,
  });
}

export class Component {
  register(): void {}
  registerEvent(): void {}
  registerDomEvent(): void {}
  registerInterval(id: number): number { clearInterval(id); return id; }
  addChild<T>(c: T): T { return c; }
  load(): void {}
  unload(): void {}
}
export class Plugin extends Component {}
export class ItemView extends Component { contentEl = inert(); containerEl = inert(); constructor(public leaf?: unknown) { super(); } }
export class MarkdownView extends ItemView { file: TFile | null = null; editor = inert(); async save(): Promise<void> {} }
export class Modal extends Component { contentEl = inert(); titleEl = inert(); constructor(public app?: unknown) { super(); } open(): void {} close(): void {} }
export class SuggestModal extends Modal {}
export class FuzzySuggestModal extends Modal {}
export class PluginSettingTab {}
export class Setting {}
export class ToggleComponent {}
export class Menu { hide(): void {} }
export class MarkdownRenderChild extends Component {}
export class App {}
export class Editor {}
export class WorkspaceLeaf {}
export class TAbstractFile { path = ''; name = ''; parent: unknown = null; }
export class TFile extends TAbstractFile { basename = ''; extension = 'md'; }
export class TFolder extends TAbstractFile {}
export class FileSystemAdapter {}
export const notices: string[] = [];
export class Notice { constructor(message: string) { notices.push(String(message)); } }
export const MarkdownRenderer = { render: async (): Promise<void> => {} };
export const Platform = { isMacOS: true };
export const normalizePath = (p: string): string => p.replace(/\/+/g, '/').replace(/^\/|\/$/g, '');
export const prepareFuzzySearch = () => () => null;
export const setIcon = (): void => {};
export const setTooltip = (): void => {};
export const requestUrl = async (): Promise<never> => { throw new Error('requestUrl is not available in tests'); };
/** Obsidian's own field telling an editor state which file it shows. */
export const editorInfoField = StateField.define<{ file: TFile | null }>({ create: () => ({ file: null }), update: v => v });
