// User lines stay verbatim, with live AI text underneath and temporary evidence.

import { ItemView, MarkdownRenderer, Notice, TFile, setIcon, setTooltip, type ViewStateResult, type WorkspaceLeaf } from "obsidian";
import { mapBlockIds } from "../lib/blocks";
import { clock, duration, meetingUrl, parseObsidianOpen, vaultRelative } from "../lib/format";
import type { Row } from "../lib/live";
import type { Excerpt, Meeting, MissedTopic, Note, Segment } from "../lib/types";
import type WorkScribePlugin from "../main";
import { renderLine, type LineHost } from "./lines";
import { openExternal, textButton } from "./render";

export const ENHANCED_VIEW = "workscribe-enhanced";

interface State {
  meetingId?: string;
  file?: string;
}


export class EnhancedNotesView extends ItemView {
  private meetingId: string | null = null;
  private filePath: string | null = null;
  private meeting: Meeting | null = null;
  private blockIds = new Map<string, string>();
  private error = "";
  private loading = false;
  private lineUi = { why: new Set<string>(), editing: null as string | null };

  constructor(
    leaf: WorkspaceLeaf,
    private readonly plugin: WorkScribePlugin,
  ) {
    super(leaf);
  }

  getViewType(): string {
    return ENHANCED_VIEW;
  }
  getDisplayText(): string {
    return this.meeting ? this.meeting.title : "Meeting notes";
  }
  override getIcon(): string {
    return "sparkles";
  }

  override getState(): Record<string, unknown> {
    const s: State = {};
    if (this.meetingId) s.meetingId = this.meetingId;
    if (this.filePath) s.file = this.filePath;
    return s as Record<string, unknown>;
  }

  override async setState(state: unknown, result: ViewStateResult): Promise<void> {
    const s = (state ?? {}) as State;
    const changed = s.meetingId !== this.meetingId;
    this.meetingId = s.meetingId ?? null;
    this.filePath = s.file ?? null;
    if (changed) {
      this.meeting = null;
      this.lineUi.why.clear();
      this.lineUi.editing = null;
      await this.fetchMeeting();
    }
    await super.setState(state, result);
  }

  override async onOpen(): Promise<void> {
    this.contentEl.addClass("ws-past");
    this.addAction("external-link", "Open in WorkScribe", () => this.meetingId && openExternal(meetingUrl(this.meetingId)));
    this.addAction("refresh-cw", "Reload from WorkScribe", () => void this.fetchMeeting());
    this.registerEvent(
      this.app.vault.on("modify", (f) => {
        if (f.path === this.noteFile()?.path && this.meeting) void this.mapBlocks().then(() => this.render());
      }),
    );
    this.render();
  }

  get currentMeetingId(): string | null {
    return this.meetingId;
  }

  async fetchMeeting(): Promise<void> {
    if (!this.meetingId) {
      this.render();
      return;
    }
    this.loading = true;
    this.error = "";
    this.render();
    try {
      this.meeting = await this.plugin.client.meeting(this.meetingId);
      await this.mapBlocks();
    } catch (e) {
      this.error = e instanceof Error ? e.message : String(e);
    }
    this.loading = false;
    this.render();
    (this.leaf as unknown as { updateHeader?: () => void }).updateHeader?.();
  }

  private noteFile(): TFile | null {
    const f = this.filePath ? this.app.vault.getAbstractFileByPath(this.filePath) : null;
    if (f instanceof TFile) return f;
    const path = this.meeting?.vaultPath;
    const linked = this.meeting?.obsidianLink ? parseObsidianOpen(this.meeting.obsidianLink) : null;
    const vp = path ? vaultRelative(path, this.plugin.linkContext().vaultBase) ?? (path.startsWith("/") ? null : path) :
      linked?.vault === this.app.vault.getName() ? linked.file : null;
    const g = vp ? this.app.vault.getAbstractFileByPath(vp) : null;
    return g instanceof TFile ? g : null;
  }

  private async mapBlocks(): Promise<void> {
    const f = this.noteFile();
    this.blockIds = f && this.meeting ? mapBlockIds(await this.app.vault.cachedRead(f), this.meeting.notes) : new Map();
  }

  // ------------------------------------------------------------ render

  private render(): void {
    const root = this.contentEl;
    const prevScroll = root.querySelector(".ws-doc")?.scrollTop ?? 0;
    root.empty();
    const doc = root.createDiv({ cls: "ws-doc" });
    const inner = doc.createDiv({ cls: "ws-doc-inner" });
    if (!this.meetingId) {
      this.empty(inner, "No meeting selected", "Open a meeting note (one with workscribe_id in its properties) and click ✨ in its header.");
      return;
    }
    if (this.loading && !this.meeting) {
      inner.createDiv({ cls: "ws-state-text", text: "Loading meeting…" });
      return;
    }
    if (!this.meeting) {
      this.empty(inner, "Couldn't load this meeting", this.error);
      textButton(inner, "Retry", () => void this.fetchMeeting(), "is-primary");
      return;
    }
    const m = this.meeting;
    const show = this.plugin.settings.showSuggestions;

    // Title and meta
    const head = inner.createDiv({ cls: "ws-doc-head" });
    head.createDiv({ cls: "ws-doc-title", text: m.title });
    const meta = head.createDiv({ cls: "ws-doc-meta" });
    if (m.startedAt) meta.createSpan({ text: window.moment(m.startedAt).format("ddd D MMM YYYY · HH:mm") });
    if (m.duration) meta.createSpan({ text: duration(m.duration) });
    if (m.speakers.length) meta.createSpan({ text: m.speakers.join(", ") });
    const file = this.noteFile();
    if (file) {
      const a = meta.createEl("a", { cls: "ws-meta-link", href: "#" });
      setIcon(a.createSpan({ cls: "ws-meta-icon" }), "file-text");
      a.appendText(file.basename);
      setTooltip(a, "Open the meeting note");
      a.addEventListener("click", (e) => {
        e.preventDefault();
        void this.app.workspace.openLinkText(file.path, "", false);
      });
    }
    if (m.brief) inner.createDiv({ cls: "ws-brief", text: m.brief });

    if (m.retention === "purged" || m.retention === "purging") {
      inner.createDiv({ cls: "ws-state-text", text: "Only your vault note remains." });
      if (file) {
        textButton(inner, "Open note", () => void this.app.workspace.openLinkText(file.path, "", false));
        const content = inner.createDiv({ cls: "markdown-rendered ws-final-note" });
        void this.app.vault.cachedRead(file).then(text => MarkdownRenderer.render(this.app, text, content, file.path, this));
      }
      return;
    }
    if (m.purgeAt) {
      const hours = Math.max(0, Math.ceil((Date.parse(m.purgeAt) - Date.now()) / 3_600_000));
      const retention = inner.createDiv({ cls: "ws-retention" });
      retention.appendText(`Transcript and recording are deleted in ${hours} h · `);
      textButton(retention, "Done now", async () => {
        try { await this.plugin.client.done(m.id); await this.fetchMeeting(); }
        catch (e) { this.plugin.showError(e); }
      });
    }
    const notes = m.notes;
    // Your lines
    const lines = inner.createDiv({ cls: "ws-lines" });
    if (!notes.length) lines.createDiv({ cls: "ws-state-text", text: "No notes were typed in this meeting." });
    const host = this.lineHost(m);
    for (const n of notes) {
      const row: Row = { key: n.id, at: n.at, text: n.fromAnswer ? n.text : n.text, note: n };
      renderLine(lines, host, row);
    }

    // Discussed, not in your notes
    const missed = m.missedTopics;
    if (show && missed.length) this.renderMissed(inner, missed);

    doc.scrollTop = prevScroll;
  }

  private empty(root: HTMLElement, title: string, text: string): void {
    const box = root.createDiv({ cls: "ws-doc-state" });
    box.createDiv({ cls: "ws-state-title", text: title });
    if (text) box.createDiv({ cls: "ws-state-text", text });
  }

  private async accept(n: Note, e: { topic: string; text: string }): Promise<void> {
    const m = this.meeting!;
    const updated = await this.plugin.editAILine(m.id, n, e);
    const i = m.notes.findIndex((x) => x.id === n.id);
    if (i >= 0) m.notes[i] = updated;
    this.render();
  }

  private lineHost(m: Meeting): LineHost {
    const p = this.plugin;
    return {
      showSuggestions: p.settings.showSuggestions,
      editAI: (n, e) => this.accept(n, e),
      rewrite: async (n) => {
        const updated = await p.rewriteLine(m.id, n);
        m.notes[m.notes.findIndex(x => x.id === n.id)] = updated;
        this.render();
      },
      editShorthand: async (n, text) => {
        const updated = await p.client.editNote(m.id, n.id, text);
        const i = m.notes.findIndex((x) => x.id === n.id);
        if (i >= 0) m.notes[i] = { ...updated, excerpts: updated.excerpts.length ? updated.excerpts : n.excerpts };
      },
      openExcerpt: (e: Excerpt) => openExternal(meetingUrl(m.id, e.start)),
      context: (e) => context(m.segments, e),
      showInNote: (n) => {
        const block = this.blockIds.get(n.id);
        const file = this.noteFile();
        return block && file ? () => void this.app.workspace.openLinkText(`${file.path}#^${block}`, "", false) : null;
      },
      ui: this.lineUi,
      rerender: () => this.render(),
    };
  }

  private renderMissed(parent: HTMLElement, topics: MissedTopic[]): void {
    const m = this.meeting!;
    const sec = parent.createDiv({ cls: "ws-missed" });
    sec.createDiv({ cls: "ws-missed-label", text: "Discussed but not in your notes" });
    for (const t of topics) {
      const card = sec.createDiv({ cls: "ws-missed-card" });
      setIcon(card.createSpan({ cls: "ws-sugg-icon" }), "sparkles");
      const body = card.createDiv({ cls: "ws-missed-body" });
      const txt = body.createDiv({ cls: "ws-missed-text" });
      txt.createSpan({ cls: "ws-sugg-topic", text: t.topic.trim() + " " });
      txt.appendText(t.text);
      const meta = body.createDiv({ cls: "ws-missed-meta" });
      if (t.speaker) meta.createSpan({ text: t.speaker.split(" ")[0]! });
      if (t.start !== undefined) {
        const url = meetingUrl(m.id, t.start);
        const a = meta.createEl("a", { text: `${clock(t.start)}${t.end !== undefined ? "–" + clock(t.end) : ""}`, href: url });
        setTooltip(a, "Play from here in WorkScribe");
        a.addEventListener("click", (e) => {
          e.preventDefault();
          openExternal(url);
        });
      }
      const acts = body.createDiv({ cls: "ws-missed-acts" });
      const add = acts.createEl("button", { cls: "ws-tbtn is-primary is-add" });
      setIcon(add.createSpan({ cls: "ws-tbtn-icon" }), "plus");
      add.createSpan({ text: "Add to my notes" });
      add.addEventListener("click", async () => {
        add.disabled = true;
        try {
          const note = await this.plugin.client.addNote(m.id, `${t.topic} ${t.text}`.trim(), t.start, { fromMissedTopic: { topic: t.topic } });
          const n: Note = note.enhanced ? note : { ...note, enhanced: { topic: t.topic, text: t.text }, state: "done" };
          m.notes.push(n);
          m.missedTopics = m.missedTopics.filter((x) => x !== t);
          // You chose to add it: it's yours.
          new Notice(`Added “${t.topic.replace(/\.$/, "")}” to your notes`);
          this.render();
        } catch (e) {
          add.disabled = false;
          this.plugin.showError(e);
        }
      });

    }
  }
}

/** The excerpt's turn plus one turn either side, for context. */
function context(segs: Segment[], e: Excerpt): Segment[] {
  let i = e.segmentId ? segs.findIndex((s) => s.id === e.segmentId) : -1;
  if (i < 0 && segs.length) {
    let best = 0;
    segs.forEach((s, j) => {
      if (Math.abs(s.start - e.start) < Math.abs(segs[best]!.start - e.start)) best = j;
    });
    i = best;
  }
  return i < 0 ? [] : segs.slice(Math.max(0, i - 1), i + 2);
}
