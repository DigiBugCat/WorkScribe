// Quick ask: a slim floating composer (Claudian's box), the cited answer
// streaming in under it, and three quiet actions.

import { App, Component, MarkdownView, Modal, Notice, type Editor } from "obsidian";
import { renderTrace } from "./trace";
import { ApiError } from "../lib/client";
import { citationsToMarkdown } from "../lib/format";
import type { Moment } from "../lib/types";
import type WorkScribePlugin from "../main";
import type { Scope } from "../settings";
import type { Conversation } from "./chat";
import { Composer } from "./composer";
import { renderCitedMarkdown, renderSources, textButton } from "./render";

export class QuickAskModal extends Modal {
  /** Set by the plugin to learn when the modal closes (single-instance guard). */
  onClosed: (() => void) | null = null;
  private abort: AbortController | null = null;
  private question = "";
  private trace?: import("../lib/types").AITrace;
  private static draft?: {text:string;at:number};
  private answer = "";
  private citations: Moment[] = [];
  private conversationId: string | undefined;
  private error = "";
  private streaming = false;
  private askScope: Scope;
  private outEl!: HTMLElement;
  private actsEl!: HTMLElement;
  private composer!: Composer;
  private frame = 0;
  private readonly owner = new Component();
  private readonly editor: Editor | null;

  constructor(
    app: App,
    private readonly plugin: WorkScribePlugin,
  ) {
    super(app);
    this.editor = app.workspace.getActiveViewOfType(MarkdownView)?.editor ?? plugin.lastMarkdownView()?.editor ?? null;
    this.askScope = plugin.recording ? "meeting" : plugin.settings.defaultScope;
    this.owner.register(plugin.subscribe(changes=>{
      if(!changes.has('purged'))return;
      const id=plugin.lastPurgedMeetingId;
      if(!id || !(this.askScope==='meeting' && plugin.live.meetingId===id) && !this.citations.some(c=>c.meetingId===id) && !this.trace?.sources?.some(s=>s.link.includes(id)))return;
      this.abort?.abort();this.answer='The transcript and its traces have faded. Your note is what remains.';
      this.trace=undefined;this.citations=[];this.streaming=false;this.render();
    }));
  }

  override onOpen(): void {
    this.owner.load();
    this.modalEl.addClass("ws-quick");
    this.containerEl.addClass("ws-quick-container");
    const { contentEl } = this;
    contentEl.empty();
    this.composer = new Composer(contentEl, this.plugin, {
      placeholder: this.plugin.recording ? `Ask about “${this.plugin.live.title}” or anything else…` : "Ask WorkScribe…",
      onSubmit: (text) => {
        void this.run(text);
        return false; // keep the question in the box, like a search field
      },
      onCancel: () => this.abort?.abort(),
      busy: () => this.streaming,
      scope: { get: () => this.askScope, set: (s) => (this.askScope = s) },
      attachments: false,
      maxRows: 6,
      cls: "is-quick",
    });
    this.outEl = contentEl.createDiv({ cls: "ws-quick-out" });
    this.actsEl = contentEl.createDiv({ cls: "ws-quick-acts" });
    const draft=QuickAskModal.draft;
    if(draft && Date.now()-draft.at<600000) this.composer.setValue(draft.text);
    this.composer.focus();
    this.render();
  }

  override onClose(): void {
    QuickAskModal.draft={text:this.composer.value,at:Date.now()};
    this.abort?.abort();
    if (this.frame) cancelAnimationFrame(this.frame);
    this.owner.unload();
    this.onClosed?.();
  }

  private async run(q: string): Promise<void> {
    q = q.trim();
    if (!q) return;
    this.abort?.abort();
    const ac = new AbortController();
    this.abort = ac;
    this.question = q;
    this.answer = "";
    this.citations = []; this.trace=undefined;
    this.error = "";
    this.streaming = true;
    this.composer.refresh();
    this.render();
    const req: { question: string; meetingId?: string } = { question: q };
    if (this.plugin.recording && this.plugin.live.meetingId && this.askScope === "meeting") req.meetingId = this.plugin.live.meetingId;
    try {
      await this.plugin.client.ask(
        req,
        (ev) => {
          if (ac !== this.abort) return;
          if (ev.type === "token") this.answer += ev.text;
          else if (ev.type === "trace") this.trace=ev.trace;
          else if (ev.type === "citations") {
            this.citations = ev.citations; this.trace=ev.trace;
            if (ev.answer !== undefined) this.answer = ev.answer;
            if (ev.conversationId) this.conversationId = ev.conversationId;
          } else if (ev.type === "done") this.conversationId = ev.conversationId ?? this.conversationId;
          else if (ev.type === "error") this.error = ev.message;
          this.schedule();
        },
        ac.signal,
      );
    } catch (e) {
      if (!(e instanceof ApiError && e.kind === "aborted")) this.error = e instanceof Error ? e.message : String(e);
    }
    if (ac === this.abort) {
      this.streaming = false;
      this.abort = null;
      this.composer.refresh();
      this.render();
    }
  }

  private schedule(): void {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.render();
    });
  }

  private render(): void {
    const out = this.outEl;
    this.actsEl.empty();
    if (!this.question) {
      out.empty();
      out.toggleClass("is-empty", true);
      if (this.plugin.connState.kind === "offline") out.createDiv({ cls: "ws-msg-error", text: this.plugin.connState.reason });
      return;
    }
    out.toggleClass("is-empty", false);
    const open = (m: Moment, e: MouseEvent) => {
      this.close();
      this.plugin.openMoment(m, e);
    };
    let body = out.querySelector<HTMLElement>(".ws-msg-content");
    if (!body || !this.streaming) {
      const wasOpen=out.querySelector<HTMLDetailsElement>(".ws-trace")?.open;
      out.empty();
      renderTrace(out,this.trace,{open:wasOpen,running:this.streaming,sources:this.citations,onSource:open});
      body = out.createDiv({ cls: "ws-msg-content" });
    }
    const hasMarkers = /\[(?:Source:\s*)?\d/.test(this.answer);
    const sources = this.citations.length && !this.streaming ? renderSources(out, this.citations, open, { open: !hasMarkers }) : undefined;
    if (!this.answer && this.streaming) {
      body.empty();
      body.createSpan({ cls: "ws-thinking", text: "Thinking…" });
    } else {
      const b = body;
      void renderCitedMarkdown(this.app, this.owner, b, this.answer, this.citations, open, sources).then(() => {
        if (this.streaming) (b.lastElementChild ?? b).createSpan({ cls: "ws-caret" });
      });
    }
    out.querySelector(".ws-msg-error")?.remove();
    if (this.error) out.createDiv({ cls: "ws-msg-error", text: this.error });
    if (this.streaming) return;

    const acts = this.actsEl;
    textButton(acts, "Open in Ask", () => void this.openInAsk(), "is-primary");
    if (this.editor && this.answer) {
      textButton(acts, "Insert into note", () => {
        this.editor!.replaceSelection(citationsToMarkdown(this.answer, this.citations, this.plugin.linkContext()) + "\n");
        this.close();
      });
    }
    if (this.answer)
      textButton(acts, "Copy", async () => {
        await navigator.clipboard.writeText(citationsToMarkdown(this.answer, this.citations, this.plugin.linkContext()));
        new Notice("Copied answer with sources");
      });
    acts.createDiv({ cls: "ws-spacer" });
    acts.createSpan({ cls: "ws-quick-hint", text: "esc to close" });
  }

  private async openInAsk(): Promise<void> {
    const view = await this.plugin.activateAskView();
    const conv: Conversation = {
      messages: [
        { role: "user", text: this.question },
        { role: "assistant", text: this.answer, citations: this.citations },
      ],
    };
    if (this.conversationId) conv.id = this.conversationId;
    view?.seed(conv);
    this.close();
    view?.focusInput();
  }
}
