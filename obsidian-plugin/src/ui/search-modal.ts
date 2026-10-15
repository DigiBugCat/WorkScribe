// Search moments: query → moments; Enter inserts a link into the current note,
// Mod+Enter (or Enter with no note open) opens the moment.

import { App, MarkdownView, SuggestModal, type Editor } from "obsidian";
import { ApiError } from "../lib/client";
import { momentMarkdown } from "../lib/format";
import type { Moment } from "../lib/types";
import type WorkScribePlugin from "../main";
import { renderMoment } from "./render";

const DEBOUNCE_MS = 220;

export class SearchMomentsModal extends SuggestModal<Moment> {
  private readonly editor: Editor | null;
  private seq = 0;
  private last: Moment[] = [];

  constructor(
    app: App,
    private readonly plugin: WorkScribePlugin,
  ) {
    super(app);
    this.editor = app.workspace.getActiveViewOfType(MarkdownView)?.editor ?? null;
    this.modalEl.addClass("ws-search");
    this.setPlaceholder("Search moments in meetings, notes, clips and files");
    this.limit = 30;
    this.emptyStateText = "Type to search moments";
    this.setInstructions([
      { command: "↵", purpose: this.editor ? "insert link" : "open" },
      { command: "mod ↵", purpose: "open" },
      { command: "esc", purpose: "dismiss" },
    ]);
    this.scope.register(["Mod"], "Enter", (evt) => {
      // Let the modal choose the highlighted item; onChooseSuggestion reads the modifier.
      (this as unknown as { chooser?: { useSelectedItem(e: KeyboardEvent): void } }).chooser?.useSelectedItem(evt);
      return false;
    });
  }

  async getSuggestions(query: string): Promise<Moment[]> {
    const q = query.trim();
    const my = ++this.seq;
    if (!q) return [];
    await new Promise((r) => window.setTimeout(r, DEBOUNCE_MS));
    if (my !== this.seq) return this.last; // superseded by newer typing
    try {
      const res = await this.plugin.client.search(q, undefined, 30);
      if (my === this.seq) {
        this.last = res;
        this.emptyStateText = "No moments match";
      }
      return res;
    } catch (e) {
      this.emptyStateText = e instanceof ApiError ? e.message : String(e);
      return [];
    }
  }

  renderSuggestion(m: Moment, el: HTMLElement): void {
    el.addClass("ws-search-item");
    renderMoment(el, m, { onOpen: () => undefined });
  }

  onChooseSuggestion(m: Moment, evt: MouseEvent | KeyboardEvent): void {
    const open = evt.metaKey || evt.ctrlKey || !this.editor;
    if (open) {
      this.plugin.openMoment(m);
      return;
    }
    this.editor!.replaceSelection(momentMarkdown(m, this.plugin.linkContext()));
  }
}
