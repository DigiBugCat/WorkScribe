import { fadeCountdown } from './lib/care';
import { imageInsertion } from './lib/image-insert';
import { NoteEditor } from "./ui/note-editor";
import type { NoteDocument } from "./lib/anchors";
import { Editor, FileSystemAdapter, MarkdownView, Notice, Platform, Plugin, TFile, WorkspaceLeaf, setIcon, setTooltip, type Hotkey } from "obsidian";
import { ApiError, WorkScribeClient } from "./lib/client";
import { EventsConnection, type ConnState } from "./lib/connection";
import { defaultApiJsonPath, expandHome, readDiscovery } from "./lib/discovery";
import { canonicalPath, clock, type LinkContext } from "./lib/format";
import { applyEvent, confirmJot, emptyLive, failJot, liveElapsed, loadMeeting, type Change, type LiveState } from "./lib/live";
import { matchesHotkey } from "./lib/hotkeys";
import type { Enhancement, LiveEvent, Moment, Note } from "./lib/types";
import { DEFAULT_SETTINGS, WorkScribeSettingTab, type WorkScribeSettings } from "./settings";
import { AskView, ASK_VIEW } from "./ui/ask-view";
import { EnhancedNotesView, ENHANCED_VIEW } from "./ui/enhanced-view";
import { LiveView, LIVE_VIEW } from "./ui/live-view";
import { registerMeetingBlock } from "./ui/meeting-block";
import { QuickAskModal } from "./ui/quick-ask";
import { openMoment } from "./ui/render";
import { SearchMomentsModal } from "./ui/search-modal";
import { obsidianTransport } from "./ui/transport";

/** "context": the note you were last in changed (composers show it). */
export type LiveChange = "purged" | Change | "conn" | "tick" | "context";
export type LiveListener = (changes: Set<LiveChange>) => void;

export default class WorkScribePlugin extends Plugin {
  override settings: WorkScribeSettings = { ...DEFAULT_SETTINGS };
  client!: WorkScribeClient;
  live: LiveState = emptyLive();
  connState: ConnState = { kind: "connecting" };
  noteEditor!: NoteEditor;
  documentLedgers: Record<string, NoteDocument> = {};
  lastPurgedMeetingId: string | null = null;
  clockText = "00:00";
  private statusReceivedAt = Date.now();
  private conn!: EventsConnection;
  private listeners = new Set<LiveListener>();
  private statusEl!: HTMLElement;
  private ribbonEl!: HTMLElement;
  private jotSeq = 0;
  private loadingMeeting: string | null = null;

  override async onload(): Promise<void> {
    await this.loadSettings();
    this.client = new WorkScribeClient(obsidianTransport(), () => readDiscovery(this.apiJsonPath()));
    this.noteEditor = new NoteEditor(this);
    this.registerEditorExtension([this.noteEditor.editor.extension, imageInsertion]);
    this.conn = new EventsConnection(
      this.client,
      (ev) => this.handleEvent(ev),
      (s) => {
        this.connState = s;
        this.renderStatusBar();
        this.notify(new Set(["conn"]));
      },
    );

    this.registerView(LIVE_VIEW, (leaf) => new LiveView(leaf, this));
    this.registerView(ASK_VIEW, (leaf) => new AskView(leaf, this));
    this.registerView(ENHANCED_VIEW, (leaf) => new EnhancedNotesView(leaf, this));

    this.ribbonEl = this.addRibbonIcon("mic", "WorkScribe: start recording", () => void this.toggleRecording());
    this.addRibbonIcon("message-circle-question", "WorkScribe: Ask", () => void this.activateAskView());

    this.statusEl = this.addStatusBarItem();
    this.statusEl.addClass("ws-statusbar", "mod-clickable");
    this.statusEl.addEventListener("click", () => void this.toggleRecording());
    this.renderStatusBar();
    this.registerInterval(
      window.setInterval(() => {
        if (this.live.status?.recording || this.live.purgeAt) {
          this.clockText=clock(this.elapsed());
          this.renderStatusBar();
          this.notify(new Set(["tick"]));
        }
      }, 1000),
    );

    this.addCommands();
    this.addSettingTab(new WorkScribeSettingTab(this.app, this));
    registerMeetingBlock(this);
    this.registerWorkscribeLinks();

    this.app.workspace.onLayoutReady(() => {
      this.conn.start();
      this.refreshNoteActions();
    });
    this.registerEvent(this.app.workspace.on("layout-change", () => this.refreshNoteActions()));
    this.registerEvent(
      this.app.workspace.on("active-leaf-change", (leaf) => {
        if (leaf?.view instanceof MarkdownView && leaf.view !== this.lastMd) {
          this.lastMd = leaf.view;
          this.notify(new Set(["context"]));
        }
      }),
    );
    this.registerEvent(this.app.workspace.on("file-open", () => this.refreshNoteActions()));
    this.registerEvent(this.app.metadataCache.on("changed", () => this.refreshNoteActions()));
  }

  override onunload(): void {
    this.conn?.stop();
    this.noteEditor?.dispose();
    for (const leaf of this.app.workspace.getLeavesOfType("markdown")) {
      this.noteActions.get(leaf.view)?.el.remove();
      leaf.view.containerEl.removeClass("ws-meeting-note");
    }
  }

  // ------------------------------------------------------------ context for composers

  private lastMd: MarkdownView | null = null;

  /** The markdown view you were last in (still open), so sidebar composers can offer its note and selection. */
  lastMarkdownView(): MarkdownView | null {
    const active = this.app.workspace.getActiveViewOfType(MarkdownView);
    if (active) return (this.lastMd = active);
    if (this.lastMd?.file && this.lastMd.containerEl.isConnected) return this.lastMd;
    const leaf = this.app.workspace.getLeavesOfType("markdown").find((l) => (l.view as MarkdownView).file);
    return (this.lastMd = (leaf?.view as MarkdownView | undefined) ?? null);
  }

  async editAILine(meetingId: string, note: Note, e: Enhancement): Promise<Note> {
    const updated = await this.client.patchNote(meetingId, note.id, { enhanced: e });
    if (this.live.meetingId === meetingId) this.live.notes.set(note.id, updated);
    this.notify(new Set(["notes"]));
    return updated;
  }
  async rewriteLine(meetingId: string, note: Note): Promise<Note> {
    const updated = await this.client.patchNote(meetingId, note.id, { rewrite: true });
    if (this.live.meetingId === meetingId) this.live.notes.set(note.id, updated);
    this.notify(new Set(["notes"]));
    return updated;
  }

  // ------------------------------------------------------------ quick ask

  private quickAskOpen = false;

  openQuickAsk(): void {
    if (this.quickAskOpen) return;
    const m = new QuickAskModal(this.app, this);
    m.onClosed = () => (this.quickAskOpen = false);
    this.quickAskOpen = true;
    m.open();
  }

  /**
   * Plugin hotkeys that must work while focus is in our own text fields (the
   * shorthand line swallows keys Obsidian would otherwise route). Returns true when handled.
   */
  handleViewHotkey(e: KeyboardEvent): boolean {
    if (!this.quickAskHotkeys().some((h) => matchesHotkey(e, h, Platform.isMacOS))) return false;
    e.preventDefault();
    e.stopPropagation();
    this.openQuickAsk();
    return true;
  }

  private quickAskHotkeys(): Hotkey[] {
    const id = `${this.manifest.id}:quick-ask`;
    const hm = (this.app as unknown as { hotkeyManager?: { getHotkeys?(id: string): Hotkey[] | undefined; getDefaultHotkeys?(id: string): Hotkey[] | undefined } }).hotkeyManager;
    return hm?.getHotkeys?.(id) ?? hm?.getDefaultHotkeys?.(id) ?? [{ modifiers: ["Mod", "Shift"], key: "k" }];
  }

  // ------------------------------------------------------------ meeting notes

  private noteActions = new WeakMap<object, { id: string; el: HTMLElement }>();

  /** The meeting id of a vault note written by WorkScribe (`workscribe_id` in its properties). */
  meetingIdOf(file: TFile | null | undefined): string | null {
    if (!file) return null;
    const fm=this.app.metadataCache.getFileCache(file)?.frontmatter;
    const v=(fm?.workscribe ?? fm?.workscribe_id) as unknown;
    return typeof v === "string" && v.trim() ? v.trim() : typeof v === "number" ? String(v) : null;
  }

  /** A sparkles button at the top of every open meeting note. */
  private refreshNoteActions(): void {
    for (const leaf of this.app.workspace.getLeavesOfType("markdown")) {
      const view = leaf.view;
      if (!(view instanceof MarkdownView)) continue;
      const id = this.meetingIdOf(view.file);
      const native=!!(view.file&&this.app.metadataCache.getFileCache(view.file)?.frontmatter?.workscribe);
      // A styling hook for vault notes; all Markdown remains visible to the editor.
      view.containerEl.toggleClass("ws-meeting-note", !!id);
      const cur = this.noteActions.get(view);
      if (cur && cur.id === id && !native && !this.documentLedgers[id] && id!==this.live.meetingId) continue;
      cur?.el.remove();
      this.noteActions.delete(view);
      if (!id || native || this.documentLedgers[id] || id===this.live.meetingId) continue;
      const el = view.addAction("sparkles", "Open enhanced notes for this meeting", () => void this.openEnhancedNotes(id, view.file));
      el.addClass("ws-note-action");
      this.noteActions.set(view, { id, el });
    }
  }

  async openEnhancedNotes(meetingId: string, file?: TFile | null): Promise<void> {
    // Native meetings have one editor; the old renderer is only a legacy fallback.
    const meeting = await this.client.meeting(meetingId).catch(() => null);
    if (meeting?.document) { await this.noteEditor.open(meetingId); return; }
    const { workspace } = this.app;
    const existing = workspace.getLeavesOfType(ENHANCED_VIEW).find((l) => (l.view as EnhancedNotesView).currentMeetingId === meetingId);
    const leaf = existing ?? workspace.getLeaf("split", "vertical");
    if (!existing) {
      const state: Record<string, string> = { meetingId };
      if (file) state.file = file.path;
      await leaf.setViewState({ type: ENHANCED_VIEW, active: true, state });
    }
    await workspace.revealLeaf(leaf);
  }

  // ------------------------------------------------------------ settings

  async loadSettings(): Promise<void> {
    const old = ((await this.loadData()) ?? {}) as Record<string, unknown>;
    delete old.decisions;
    delete old.liveViewPlacement; delete old.livePanelOpen; delete old.liveEnhance;
    this.documentLedgers = (old.documentLedgers ?? {}) as Record<string, NoteDocument>;
    delete old.documentLedgers;
    this.settings = { ...DEFAULT_SETTINGS, ...old };
    await this.saveSettings();
  }

  async saveSettings(): Promise<void> {
    await this.saveData({ ...this.settings, documentLedgers: this.documentLedgers });
  }

  apiJsonPath(): string {
    return expandHome(this.settings.apiJsonPath || defaultApiJsonPath());
  }

  reconnect(): void {
    this.conn.restart();
  }

  // ------------------------------------------------------------ state

  subscribe(fn: LiveListener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  notify(changes: Set<LiveChange>): void {
    for (const fn of this.listeners) {
      try {
        fn(changes);
      } catch (e) {
        console.error("WorkScribe view update failed", e);
      }
    }
  }

  get recording(): boolean {
    return !!this.live.status?.recording;
  }

  /** Seconds into the live meeting, now. */
  elapsed(): number {
    return liveElapsed(this.live.status, this.statusReceivedAt, Date.now());
  }

  private handleEvent(ev: LiveEvent): void {
    if (ev.type === "notes" && ev.documentFinalized) this.noteEditor.markFinalized(ev.meetingId);
    if (ev.type === "purged") {
      this.lastPurgedMeetingId=ev.meetingId;
      this.noteEditor.purge(ev.meetingId);
      if (this.live.meetingId === ev.meetingId) {
        this.live.retention="purged"; this.live.purgeAt=undefined; this.live.notes.clear(); this.live.segments = []; this.live.answer = null; this.live.screens = []; this.live.pending = [];
      }
      for (const leaf of this.app.workspace.getLeavesOfType(ENHANCED_VIEW)) {
        const view = leaf.view as EnhancedNotesView;
        if (view.currentMeetingId === ev.meetingId) void view.fetchMeeting();
      }
      this.notify(new Set(["purged","meeting","notes","segments","answer"]));
      return;
    }
    if (ev.type === "clip") {
      new Notice(`Saved clip: ${ev.clip.title}`);
      return;
    }
    if (ev.type === "ask_request") {
      void this.activateAskView().then((view) => view?.offerClip(ev.clip, ev.question));
      return;
    }
    if (ev.type === "continue") {
      void this.activateAskView().then((view) => view?.seed({ id: ev.conversationId,
        messages: ev.markdown ? [{ role: "assistant", text: ev.markdown }] : [] }));
      return;
    }
    const wasRecording = this.recording;
    if (ev.type === "status") this.statusReceivedAt = Date.now();
    const changes = applyEvent(this.live, ev);
    if (!changes.size) return;
    if (changes.has("status")) {this.clockText=clock(this.elapsed());this.renderStatusBar();changes.add("tick" as Change);}
    if (changes.has("meeting") || (changes.has("status") && (!this.recording || this.recording !== wasRecording))) {
      void this.ensureMeetingLoaded();
      if (this.recording && !wasRecording) {
        if (this.settings.autoOpenLiveView) void this.activateLiveView(false);
        else if (this.live.meetingId) void this.noteEditor.open(this.live.meetingId, false).catch(e => this.showError(e));
      }
    }
    this.notify(changes);
  }

  /** Fill the live state from GET /v1/meetings/:id (opening mid-call, or reconnecting). */
  async ensureMeetingLoaded(): Promise<void> {
    const id = this.live.meetingId ?? this.live.status?.meetingId;
    if (!id || this.loadingMeeting === id) return;
    this.loadingMeeting = id;
    try {
      const m = await this.client.meeting(id);
      if ((this.live.meetingId ?? id) !== id) return;
      const pending = this.live.pending;
      const status = this.live.status;
      const answer = this.live.answer;
      loadMeeting(this.live, m);
      this.live.pending = pending;
      this.live.status = status;
      if (answer && (!this.live.answer || answer.at >= this.live.answer.at)) this.live.answer = answer;
      this.notify(new Set(["meeting", "notes", "segments", "answer"]));
    } catch (e) {
      console.warn("WorkScribe: couldn't load meeting", e);
    } finally {
      this.loadingMeeting = null;
    }
  }

  // ------------------------------------------------------------ actions

  async toggleRecording(): Promise<void> {
    if (this.connState.kind !== "online") {
      try {
        await this.client.status();
      } catch (e) {
        this.showError(e);
        return;
      }
    }
    if (this.recording) await this.stopRecording();
    else await this.startRecording();
  }

  async startRecording(title?: string): Promise<void> {
    try {
      const s = await this.client.startRecording(title);
      if (s) this.handleEvent({ type: "status", status: s });
      if (this.recording && this.settings.autoOpenLiveView) await this.activateLiveView(true);
    } catch (e) {
      this.showError(e);
    }
  }

  async resumeRecording(): Promise<void> {
    const id = this.live.meetingId;
    if (!id) return;
    try {
      await this.noteEditor.flush();
      const status = await this.client.resumeRecording(id);
      this.handleEvent({type:'status',status});
    } catch (e) { this.showError(e); }
  }

  async stopRecording(): Promise<void> {
    try {
      await this.noteEditor.flush();
      const s = await this.client.stopRecording();
      if (s) this.handleEvent({ type: "status", status: s });

    } catch (e) {
      this.showError(e);
    }
  }

  /** Send a shorthand line to the live meeting, optimistically. */
  async jot(text: string, extra?: Record<string, unknown>): Promise<boolean> {
    if (!text.trim()) return false;
    const mid = this.live.meetingId;
    if (!this.recording || !mid) {
      new Notice("WorkScribe: start recording to jot into a meeting.");
      return false;
    }
    if (this.noteEditor) return this.noteEditor.append(text);
    const at = this.elapsed();
    const clientId = `jot-${++this.jotSeq}`;
    this.live.pending.push({ clientId, text, at });
    this.notify(new Set(["notes"]));
    try {
      const note = await this.client.addNote(mid, text, at, extra);
      confirmJot(this.live, clientId, note);
    } catch (e) {
      failJot(this.live, clientId, e instanceof Error ? e.message : String(e));
      this.showError(e);
    }
    this.notify(new Set(["notes"]));
    return true;
  }

  async retryJot(clientId: string): Promise<void> {
    const p = this.live.pending.find((x) => x.clientId === clientId);
    if (!p) return;
    this.live.pending = this.live.pending.filter((x) => x !== p);
    await this.jot(p.text);
  }

  showError(e: unknown): void {
    const msg = e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e);
    new Notice(`WorkScribe: ${msg}`, 6000);
  }

  linkContext(): LinkContext {
    const a = this.app.vault.adapter;
    return { vaultName: this.app.vault.getName(), vaultBase: a instanceof FileSystemAdapter ? canonicalPath(a.getBasePath()) : null };
  }

  /** Absolute path of a vault file (for attachments). */
  absolutePath(vaultPath: string): string | null {
    const a = this.app.vault.adapter;
    return a instanceof FileSystemAdapter ? canonicalPath(a.getFullPath(vaultPath)) : null;
  }

  openMoment(m: Moment, evt?: MouseEvent | KeyboardEvent): void {
    const newLeaf = !!evt && (evt.metaKey || evt.ctrlKey);
    void openMoment(this.app, m, this.linkContext(), newLeaf);
  }

  // ------------------------------------------------------------ views

  async activateLiveView(focus = true): Promise<void> {
    const { workspace } = this.app;
    const id = this.live.meetingId ?? this.live.status?.meetingId;
    if (id) {
      try { await this.noteEditor.open(id, focus || this.settings.autoOpenLiveView); }
      catch (e) { this.showError(e); }
    }
    let leaf = workspace.getLeavesOfType(LIVE_VIEW)[0] ?? workspace.getRightLeaf(false);
    if (!leaf) return;
    if (!(leaf.view instanceof LiveView)) await leaf.setViewState({ type: LIVE_VIEW, active: false });
    await workspace.revealLeaf(leaf);
    if (focus && id) {
      const note = workspace.getLeavesOfType("markdown").find(l => this.meetingIdOf((l.view as MarkdownView).file) === id);
      if (note) { await workspace.revealLeaf(note); (note.view as MarkdownView).editor.focus(); }
    }
  }

  async activateAskView(): Promise<AskView | null> {
    const { workspace } = this.app;
    let leaf: WorkspaceLeaf | null = workspace.getLeavesOfType(ASK_VIEW)[0] ?? null;
    if (!leaf) {
      leaf = workspace.getRightLeaf(false);
      if (!leaf) return null;
      await leaf.setViewState({ type: ASK_VIEW, active: true });
    }
    await workspace.revealLeaf(leaf);
    return leaf.view instanceof AskView ? leaf.view : null;
  }

  // ------------------------------------------------------------ chrome

  private renderStatusBar(): void {
    const el = this.statusEl;
    if (!el) return;
    el.empty();
    const st = this.live.status;
    if (this.connState.kind === "offline") {
      el.createSpan({ cls: "ws-sb-dot is-off" });
      el.createSpan({ text: "WorkScribe off" });
      setTooltip(el, `${this.connState.reason}. Click to retry.`);
      this.setRibbon(false);
      return;
    }
    if (st?.recording) {
      el.createSpan({ cls: "ws-sb-dot is-rec" });
      el.createSpan({ cls: "ws-sb-time", text: this.clockText });
      setTooltip(el, `Recording “${this.live.title || st.title || "meeting"}”. Click to stop.`);
      this.setRibbon(true);
    } else {
      if(st?.warming)el.createSpan({cls:"ws-sb-dot is-warming"});
      el.createSpan({ text: st?.warming ? "WorkScribe warming up" : this.live.purgeAt?fadeCountdown(this.live.purgeAt):"WorkScribe" });
      setTooltip(el, "Click to start recording");
      this.setRibbon(false);
    }
  }

  private setRibbon(recording: boolean): void {
    if (!this.ribbonEl) return;
    setIcon(this.ribbonEl, recording ? "square" : "mic");
    this.ribbonEl.setAttr("aria-label", recording ? "WorkScribe: stop recording" : "WorkScribe: start recording");
    this.ribbonEl.toggleClass("ws-ribbon-rec", recording);
  }

  private addCommands(): void {
    this.addCommand({
      id: "start-recording",
      name: "Start recording",
      checkCallback: (checking) => {
        if (this.recording) return false;
        if (!checking) void this.startRecording();
        return true;
      },
    });
    this.addCommand({
      id: "stop-recording",
      name: "Stop recording",
      checkCallback: (checking) => {
        if (!this.recording) return false;
        if (!checking) void this.stopRecording();
        return true;
      },
    });
    this.addCommand({ id: "toggle-recording", name: "Start or stop recording", callback: () => void this.toggleRecording() });
    this.addCommand({ id: "open-live-view", name: "Open live meeting view", callback: () => void this.activateLiveView() });
    this.addCommand({ id: "open-ask-view", name: "Open Ask view", callback: () => void this.activateAskView() });
    this.addCommand({
      id: "quick-ask",
      name: "Quick ask",
      hotkeys: [{ modifiers: ["Mod", "Shift"], key: "k" }],
      callback: () => this.openQuickAsk(),
    });
    this.addCommand({
      id: "open-enhanced-notes",
      name: "Open enhanced notes for this meeting",
      checkCallback: (checking) => {
        const file = this.app.workspace.getActiveFile();
        const id = this.meetingIdOf(file);
        if (!id) return false;
        if (!checking) void this.openEnhancedNotes(id, file);
        return true;
      },
    });
    this.addCommand({
      id: 'grab-moment', name: 'Grab this moment',
      editorCheckCallback: (checking, editor, view) => {
        if (!this.recording || this.meetingIdOf(view.file) !== this.live.meetingId) return false;
        if (!checking) void this.noteEditor.grabMoment(view.file, editor.getCursor()).catch(() => new Notice('Couldn’t save this moment. Your notes are saving. Try again when screen awareness is available.', 6000));
        return true;
      },
    });
    this.addCommand({ id: "search-moments", name: "Search moments", callback: () => new SearchMomentsModal(this.app, this).open() });
    this.addCommand({
      id: "jot-to-meeting",
      name: "Jot to current meeting",
      editorCheckCallback: (checking, editor: Editor) => {
        if (!this.recording) return false;
        if (!checking) {
          const sel = editor.getSelection();
          const text = sel || editor.getLine(editor.getCursor().line);
          const clean = text.replace(/^\s*(?:[-*+]|\d+\.)\s+(?:\[.\]\s+)?/, "").trim();
          if (!clean) new Notice("WorkScribe: nothing to jot on this line.");
          else void this.jot(clean).then((ok) => ok && new Notice(`Jotted to “${this.live.title}”`));
        }
        return true;
      },
    });
    this.addCommand({
      id: "attach-current-note",
      name: "Attach current note to Ask",
      checkCallback: (checking) => {
        const file = this.app.workspace.getActiveViewOfType(MarkdownView)?.file;
        if (!file) return false;
        if (!checking) void this.activateAskView().then((v) => v?.attachVaultFile(file));
        return true;
      },
    });
  }

  /** workscribe:// links: mark them, and let macOS open them (Obsidian would otherwise try a web view). */
  private registerWorkscribeLinks(): void {
    this.registerMarkdownPostProcessor((el) => {
      el.querySelectorAll<HTMLAnchorElement>('a[href^="workscribe://"]').forEach((a) => {
        a.addClass("ws-link");
        a.setAttr("aria-label", "Open in WorkScribe");
      });
    });
    this.registerDomEvent(
      document,
      "click",
      (evt) => {
        const a = (evt.target as HTMLElement | null)?.closest?.("a");
        const href = a?.getAttribute("href") ?? a?.getAttribute("data-href") ?? "";
        if (!href.startsWith("workscribe://")) return;
        evt.preventDefault();
        evt.stopPropagation();
        void openMoment(this.app, { kind: "meeting", title: "", link: href }, this.linkContext());
      },
      { capture: true },
    );
  }
}
