// Drives the real NoteEditor (src/ui/note-editor.ts) without Obsidian: a real CodeMirror EditorState with the
// plugin's own editor extension, a vault that is a Map, and a double of the WorkScribe app whose answers the
// test can hold back. Time is node:test's mock clock, so a test decides what happens between two awaits.
//
// What is real: NoteEditor, the editor extension and its ledger, anchors, the client's error shapes.
// What is not: Obsidian (test/support/obsidian.ts), the DOM (absorbed), the HTTP transport (AppDouble).
import './dom-globals';
import { mock } from 'node:test';
import { EditorState, Transaction, type Extension, type TransactionSpec } from '@codemirror/state';
import { ViewPlugin } from '@codemirror/view';
import { history } from '@codemirror/commands';
import { editorInfoField, inert, MarkdownView, notices, TFile } from './obsidian';
import { NoteEditor } from '../../src/ui/note-editor';
import { SurfaceStore } from '../../src/lib/surface-store';
import { ApiError } from '../../src/lib/client';
import { emptyLive } from '../../src/lib/live';
import type { NoteDocument } from '../../src/lib/anchors';

export const VAULT = '/ws-test-vault';
export const MEETING = 'meeting-1';

interface Gate { promise: Promise<void>; release: () => void }
function gate(): Gate { let release!: () => void; const promise = new Promise<void>(r => { release = r; }); return { promise, release }; }

function httpError(status: number, what: string, message: string): ApiError {
  return new ApiError('http', `${what} failed (${status}): ${message}`, status);   // the shape of client.ts httpError
}

/** Let every promise continuation that is ready run. */
export async function settle(): Promise<void> { for (let i = 0; i < 8; i++) await new Promise<void>(r => setImmediate(r)); }

/**
 * The other party: the document routes of Sources/WorkScribe/LocalAPI.swift, as far as the plugin can tell.
 * `hold(kind)` keeps the next request of that kind from reaching the app until released; `holdAnswer(kind)` lets
 * the app act on it and keeps the answer back. `failNext(kind, status)` answers the next one with an error.
 */
export class AppDouble {
  document: NoteDocument | undefined;
  retention: 'live' | 'finalized' | 'purged' = 'live';
  finishing = false;                         // NoteEnhancementScheduler.finish is running for a finalize request
  finalizeRuns = 0;                          // how many finalize requests the app started work on
  readonly calls: string[] = [];             // every request the plugin sent, in order
  readonly patches: NoteDocument[] = [];     // every PATCH body, as received
  private arrive = new Map<string, Gate[]>();
  private answer = new Map<string, Gate[]>();
  private failures = new Map<string, { status: number; message: string }[]>();
  constructor(private h: Harness, readonly id: string, readonly path: string) {}

  hold(kind: string): () => void { const g = gate(); (this.arrive.get(kind) ?? this.arrive.set(kind, []).get(kind)!).push(g); return g.release; }
  holdAnswer(kind: string): () => void { const g = gate(); (this.answer.get(kind) ?? this.answer.set(kind, []).get(kind)!).push(g); return g.release; }
  failNext(kind: string, status: number, message = 'unavailable'): void { (this.failures.get(kind) ?? this.failures.set(kind, []).get(kind)!).push({ status, message }); }
  private async before(kind: string, what: string): Promise<void> {
    this.calls.push(what);
    await this.arrive.get(kind)?.shift()?.promise;
    const failure = this.failures.get(kind)?.shift();
    if (failure) throw failure.status ? httpError(failure.status, what, failure.message) : new ApiError('offline', `WorkScribe isn't running (${failure.message})`);
  }
  private async after(kind: string): Promise<void> { await this.answer.get(kind)?.shift()?.promise; }

  /** The text Finalize writes: one AI continuation under the first list item, and a tail. */
  insertions(source: string): { at: number; text: string }[] {
    const item = source.indexOf('- '), end = item < 0 ? -1 : source.indexOf('\n', item);
    const first = end < 0 ? source.length : end;
    return [{ at: first, text: '\n*AI: what was said about it.*' }, { at: source.length, text: '\n## Action items\n\n- [ ] Follow up\n' }];
  }
  finalizedText(source: string): string {
    let text = source;
    for (const i of [...this.insertions(source)].sort((a, b) => b.at - a.at)) text = text.slice(0, i.at) + i.text + text.slice(i.at);
    return text;
  }

  // POST /v1/meetings/:id/document — LocalAPI.swift 130-136
  async openDocument(id: string): Promise<NoteDocument> {
    await this.before('open', `POST /v1/meetings/${id}/document`);
    if (id !== this.id) throw httpError(404, 'POST document', 'No such meeting');
    if (this.retention === 'purged') throw httpError(409, 'POST document', 'Meeting raw data was deleted');
    this.document ??= { path: this.path, source: this.h.disk(this.path), revision: 0, blocks: [], finalized: false };
    const result = structuredClone(this.document);
    await this.after('open');
    return result;
  }
  // PATCH /v1/meetings/:id/document — LocalAPI.swift 137-159
  async syncDocument(id: string, body: NoteDocument): Promise<NoteDocument> {
    await this.before('sync', `PATCH /v1/meetings/${id}/document`);
    this.patches.push(structuredClone(body));
    if (id !== this.id || !this.document) throw httpError(404, 'PATCH document', 'Open the meeting note first');
    if (this.document.finalized || body.revision !== this.document.revision || body.finalized) throw httpError(409, 'PATCH document', 'Stale or finalized document');
    this.document = { ...structuredClone(body), revision: body.revision + 1, finalized: false };
    const result = structuredClone(this.document);
    await this.after('sync');
    return result;
  }
  // POST /v1/meetings/:id/finalize — LocalAPI.swift 160-167, MeetingRetention.finalize, VaultStore.finalizeDocument
  async finalizeDocument(id: string): Promise<NoteDocument> {
    await this.before('finalize', `POST /v1/meetings/${id}/finalize`);
    if (id !== this.id) throw httpError(404, 'POST finalize', 'No such meeting');
    if (this.finishing) throw httpError(409, 'POST finalize', 'Final notes could not finish; the streaming transcript is saved');
    this.finishing = true; this.finalizeRuns++;
    await this.after('finalize:pass');                    // the final pass
    this.finishing = false;
    this.commit();
    const result = structuredClone(this.document!);
    await this.after('finalize');                         // indexing the note, then the answer
    return result;
  }
  /** What the app does when it finalizes: compare-and-swap the file, mark the document. Also the 23-hour path. */
  commit(): void {
    const d = this.document; if (!d || this.retention === 'purged') throw httpError(409, 'POST finalize', 'Meeting raw data was deleted');
    if (!d.finalized) {
      const text = this.finalizedText(d.source), disk = this.h.disk(this.path);
      if (disk === d.source) this.h.write(this.path, text);
      else if (disk !== text) { d.path = this.path.replace(/\.md$/, ' (WorkScribe).md'); this.h.write(d.path, text); }
      d.insertions = this.insertions(d.source); d.finalized = true; this.retention = 'finalized';
    }
  }
  purge(): void { this.document = undefined; this.retention = 'purged'; }
  // GET /v1/meetings/:id
  async meeting(id: string): Promise<unknown> {
    await this.before('meeting', `GET /v1/meetings/${id}`);
    if (id !== this.id) throw httpError(404, 'GET meeting', 'No such meeting');
    return { id, title: '', status: 'complete', retention: this.retention, document: this.document ? structuredClone(this.document) : undefined,
      notes: [], segments: [], answers: [], missedTopics: [], actionItems: [], speakers: [] };
  }
}

/** One editor on one file: a CodeMirror state with the plugin's extension, updated the way a view would. */
export class EditorDouble {
  state: EditorState;
  composing = false; hasFocus = false;
  readonly dom = inert(); readonly scrollDOM = inert(); readonly contentDOM = inert();
  private readonly observer: { update(u: unknown): void; destroy(): void };
  constructor(extension: Extension, readonly file: TFile, text: string) {
    this.state = EditorState.create({ doc: text, extensions: [history(), editorInfoField.init(() => ({ file })), extension] });
    // The extension's own ViewPlugin (editor-extension.ts 133-153), given this object as its view: it is what
    // tells NoteEditor that an editor exists and that its text changed.
    const plugin = (extension as unknown[]).find(e => e instanceof ViewPlugin) as unknown as { create(view: unknown): EditorDouble['observer'] };
    this.observer = plugin.create(this);
  }
  dispatch(...specs: (Transaction | TransactionSpec)[]): void {
    const tr = specs[0] instanceof Transaction ? specs[0] : this.state.update(...(specs as TransactionSpec[]));
    const startState = this.state;
    this.state = tr.state;
    this.observer.update({ view: this, state: this.state, startState, transactions: [tr], docChanged: tr.docChanged, geometryChanged: false, changes: tr.changes });
  }
  requestMeasure(): void {}
  lineBlockAt(): { top: number } { return { top: 0 }; }
  coordsAtPos(): null { return null; }
  focus(): void {}
  get text(): string { return this.state.doc.toString(); }
  /** The person types. */
  type(text: string, at = this.state.doc.length): void { this.dispatch({ changes: { from: at, insert: text }, userEvent: 'input.type' }); }
  close(): void { this.observer.destroy(); }
}

export class Harness {
  readonly files = new Map<string, { file: TFile; text: string; meetingId?: string }>();   // by vault-relative path
  readonly errors: string[] = [];
  readonly notices = notices;
  readonly leaves: { view: MarkdownView; openFile(): Promise<void> }[] = [];
  readonly ledgers: Record<string, NoteDocument> = {};
  readonly app: AppDouble;
  readonly notes: NoteEditor;
  readonly plugin: Record<string, unknown>;
  online = true;
  saves = 0;
  private vaultHandlers = new Map<string, ((...args: unknown[]) => void)[]>();
  private domHandlers: { el: unknown; type: string; fn: (event: unknown) => void }[] = [];
  private listeners = new Set<(changes: Set<string>) => void>();
  private saveGate: Gate | undefined;

  constructor(readonly notePath = 'Meetings/2026-11-12 Planning.md') {
    mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
    notices.length = 0;
    this.app = new AppDouble(this, MEETING, VAULT + '/' + notePath);
    const live = emptyLive(); live.meetingId = MEETING;
    const h = this;
    this.plugin = {
      documentLedgers: this.ledgers, meetingNames: {}, settings: {}, clockText: '00:00',
      surfaces: new SurfaceStore(), live,
      get connState() { return h.online ? { kind: 'online' } : { kind: 'offline', reason: 'test' }; },
      get recording() { return false; },
      elapsed: () => 0,
      register() {}, registerEvent() {},
      registerInterval(id: ReturnType<typeof setInterval>) { clearInterval(id); return id; },
      registerDomEvent(el: unknown, type: string, fn: (event: unknown) => void) { h.domHandlers.push({ el, type, fn }); },
      subscribe(fn: (changes: Set<string>) => void) { h.listeners.add(fn); return () => h.listeners.delete(fn); },
      notify(changes: Set<string>) { for (const fn of h.listeners) fn(changes); },
      showError(e: unknown) { h.errors.push(e instanceof Error ? e.message : String(e)); },
      saveSettings: async () => { h.saves++; },
      absolutePath: (path: string) => VAULT + '/' + path,
      meetingIdOf: (file: TFile | null | undefined) => (file ? this.files.get(file.path)?.meetingId ?? null : null),
      linkContext: () => ({ vaultName: 'Test', vaultBase: VAULT }),
      meetingPurged: (id: string) => { if (id === MEETING) h.purgedEvent(); },
      client: this.app,
      app: {
        vault: {
          on: (name: string, fn: (...args: unknown[]) => void) => { (this.vaultHandlers.get(name) ?? this.vaultHandlers.set(name, []).get(name)!).push(fn); return {}; },
          getAbstractFileByPath: (path: string) => this.files.get(path)?.file ?? null,
          read: async (file: TFile) => this.files.get(file.path)!.text,
          adapter: { read: async (path: string) => this.files.get(path)!.text },
          getMarkdownFiles: () => [...this.files.values()].map(f => f.file),
          getName: () => 'Test',
        },
        workspace: {
          getLeavesOfType: (type: string) => (type === 'markdown' ? this.leaves : []),
          getLeaf: () => ({ openFile: async () => {} }),
          revealLeaf: async () => {},
        },
        metadataCache: { getFirstLinkpathDest: () => null, getFileCache: () => null },
        fileManager: {},
      },
    };
    this.notes = new NoteEditor(this.plugin as never);
  }

  // ---- the vault
  addFile(path: string, text: string, meetingId?: string): TFile {
    const file = Object.assign(new TFile(), { path, name: path.split('/').pop()!, basename: path.split('/').pop()!.replace(/\.md$/, ''), extension: 'md' });
    this.files.set(path, { file, text, meetingId });
    return file;
  }
  private relative(path: string): string { return path.startsWith(VAULT + '/') ? path.slice(VAULT.length + 1) : path; }
  disk(path: string): string { return this.files.get(this.relative(path))?.text ?? ''; }
  /** Something writes the file: the app's atomic replace, another program. Obsidian tells the plugin. */
  write(path: string, text: string): void {
    const relative = this.relative(path);
    if (!this.files.has(relative)) this.addFile(relative, text); else this.files.get(relative)!.text = text;
    for (const fn of this.vaultHandlers.get('modify') ?? []) fn(this.files.get(relative)!.file);
  }
  rename(file: TFile, path: string): void {
    const entry = this.files.get(file.path)!, old = file.path;
    this.files.delete(old); file.path = path; file.name = path.split('/').pop()!; file.basename = file.name.replace(/\.md$/, '');
    this.files.set(path, entry);
    for (const fn of this.vaultHandlers.get('rename') ?? []) fn(file, old);
  }

  // ---- editors
  /** Open an editor on a file, as Obsidian does: the extension's field is created against the file's text. */
  edit(file: TFile): EditorDouble {
    const editor = new EditorDouble(this.notes.editor.extension, file, this.files.get(file.path)!.text);
    const view = Object.assign(new MarkdownView(), { file, save: async () => {
      // MarkdownView.save(): the editor's text goes to the file, and the vault reports the change.
      const text = editor.text;
      await this.saveGate?.promise;
      this.write(file.path, text);
    } });
    this.leaves.push({ view, openFile: async () => {} });
    // Any event redraws the chrome (refresh), which is where the Finalize bar for a stopped meeting appears.
    (this.plugin.notify as (c: Set<string>) => void)(new Set(['meeting']));
    return editor;
  }
  /** Keep `view.save()` from finishing until released. */
  holdSaves(): () => void { const g = gate(); this.saveGate = g; return () => { this.saveGate = undefined; g.release(); }; }
  /** Obsidian's own save, about two seconds after an edit. */
  autosave(editor: EditorDouble): void { this.write(editor.file.path, editor.text); }
  /** Obsidian reloading a file that changed on disk into an editor with nothing unsaved. */
  reload(editor: EditorDouble): void { editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: this.disk(editor.file.path) } }); }

  // ---- the person
  /** Cmd+Return in an editor: the keydown handler NoteEditor registered when the editor was mounted. */
  pressFinalize(editor: EditorDouble): void {
    for (const h of this.domHandlers) if (h.el === editor.dom && h.type === 'keydown') h.fn({ key: 'Enter', metaKey: true, ctrlKey: false, preventDefault() {} });
  }

  // ---- time and events
  async tick(ms: number): Promise<void> { mock.timers.tick(ms); await settle(); }
  /** The events connection comes back or goes away (main.ts 56-60). */
  async connection(online: boolean): Promise<void> { this.online = online; (this.plugin.notify as (c: Set<string>) => void)(new Set(['conn'])); await settle(); }
  /** `notes{documentFinalized}` arrives (main.ts 278). */
  finalizedEvent(): void { this.notes.markFinalized(MEETING); }
  /** `meeting.purged` arrives (main.ts 279-292). */
  purgedEvent(): void {
    (this.plugin.surfaces as SurfaceStore).purge(MEETING);
    this.notes.purge(MEETING);
    (this.plugin.live as { retention?: string }).retention = 'purged';
  }
  /** The two-second poll (note-editor.ts constructor). */
  async poll(): Promise<void> { await (this.notes as unknown as { checkFinalized(): Promise<void> }).checkFinalized(); await settle(); }
  /** Requests the plugin made since `from`, optionally only those whose text matches. */
  sent(pattern?: RegExp, from = 0): string[] { return this.app.calls.slice(from).filter(c => !pattern || pattern.test(c)); }
  dispose(): void { this.notes.dispose(); mock.timers.reset(); }
}

/** A meeting note that is open in an editor and in step with the app: the usual starting point. */
export async function openMeetingNote(text = '---\nworkscribe: meeting-1\n---\n\n- ship date\n'): Promise<{ h: Harness; file: TFile; editor: EditorDouble }> {
  const h = new Harness();
  const file = h.addFile(h.notePath, text, MEETING);
  await h.notes.open(MEETING, false);
  const editor = h.edit(file);
  await h.tick(650); await h.tick(250);        // the first sync that open() queues, and the saved ledger
  return { h, file, editor };
}
