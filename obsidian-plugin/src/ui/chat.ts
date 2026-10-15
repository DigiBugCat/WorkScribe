// A Claudian-style chat: no avatars; your messages are small right-aligned
// bubbles, answers are full-width text (Markdown, with numbered citation chips
// that preview their source on hover), sources are a compact collapsible list,
// and the composer sits at the bottom. Used by the Ask view and by the live
// view's side panel.

import { Component, Notice, TFile, normalizePath, setIcon, type App } from "obsidian";
import { renderTrace } from "./trace";
import { ApiError } from "../lib/client";
import { citationsToMarkdown, safeFilename } from "../lib/format";
import type { Clip, Moment } from "../lib/types";
import type WorkScribePlugin from "../main";
import type { Scope } from "../settings";
import { vaultFileAttachment, type NamedAttachment } from "./attachments";
import { Composer } from "./composer";
import { iconButton, renderCitedMarkdown, renderSources } from "./render";

export interface ChatMessage {
  role: "user" | "assistant";
  meetingId?: string;
  text: string;
  citations?: Moment[];
  attachments?: NamedAttachment[];
  streaming?: boolean;
  error?: string;
  trace?: import("../lib/types").AITrace;
}

export interface Conversation {
  id?: string;
  messages: ChatMessage[];
}

export interface ChatOptions {
  scope: Scope;
  placeholder?: string;
  suggestions?: string[];
  emptyTitle?: string;
  emptyText?: string;
}

export class ChatPanel extends Component {
  conv: Conversation = { messages: [] };
  readonly el: HTMLElement;
  readonly composer: Composer;
  private scope: Scope;
  private abort: AbortController | null = null;
  private listEl: HTMLElement;
  private navEl: HTMLElement;
  private msgEls = new Map<ChatMessage, HTMLElement>();
  private frame = 0;
  private stick = true;

  constructor(
    parent: HTMLElement,
    private readonly app: App,
    private readonly plugin: WorkScribePlugin,
    private readonly opts: ChatOptions,
  ) {
    super();
    this.scope = opts.scope;
    this.el = parent.createDiv({ cls: "ws-chat" });
    this.listEl = this.el.createDiv({ cls: "ws-chat-messages" });
    this.listEl.addEventListener("scroll", () => {
      const l = this.listEl;
      this.stick = l.scrollHeight - l.scrollTop - l.clientHeight < 32;
    });
    this.navEl = this.el.createDiv({ cls: "ws-chat-nav" });
    const tabs=this.el.closest('.ws-live-companion')?.querySelector('.ws-tabs');if(tabs)tabs.append(this.navEl);
    this.composer = new Composer(this.el, plugin, {
      placeholder: opts.placeholder ?? "Ask about your meetings, notes and files…  @ to add a file",
      onSubmit: (text, atts) => {
        void this.send(text, atts);
      },
      onCancel: () => this.stop(),
      busy: () => !!this.abort,
      scope: { get: () => this.scope, set: (s) => (this.scope = s) },
      dropTarget: this.el,
    });
    this.register(plugin.subscribe(changes=>{
      if(!changes.has('purged'))return;
      const id=plugin.lastPurgedMeetingId;
      if(!id || !this.conv.messages.some(m=>m.meetingId===id || m.citations?.some(c=>c.meetingId===id) || m.trace?.sources?.some(s=>s.link.includes(id))))return;
      this.abort?.abort();
      this.conv={messages:[]};this.renderAll();
      this.listEl.createDiv({cls:'ws-panel-empty',text:'The transcript and its traces have faded. Your note is what remains.'});
    }));
    this.renderAll();
  }

  override onunload(): void {
    this.navEl.remove();
    this.abort?.abort();
    if (this.frame) cancelAnimationFrame(this.frame);
  }

  focus(): void {
    this.composer.focus();
  }

  /** Status/connection changed: refresh the info row and the empty state. */
  refresh(): void {
    this.composer.refresh();
    if (!this.conv.messages.length) this.renderAll();
  }

  get busy(): boolean {
    return !!this.abort;
  }

  // ------------------------------------------------------------ public API

  seed(conv: Conversation): void {
    this.abort?.abort();
    this.conv = conv;
    this.renderAll();
  }

  reset(): void {
    this.abort?.abort();
    this.conv = { messages: [] };
    this.composer.clearContext();
    this.renderAll();
    this.composer.focus();
  }

  attachVaultFile(f: TFile): void {
    this.composer.attachVaultFile(f);
  }

  /** Offer untrusted page content for an explicit user send; never auto-submit it. */
  offerClip(clip: Clip, question?: string): void {
    const file = this.app.vault.getAbstractFileByPath(clip.path);
    const a = file instanceof TFile ? vaultFileAttachment(this.plugin, file) : null;
    this.composer.addAttachment(a ?? { text: `Clipped page: ${clip.title}\n${clip.url ?? ""}`, name: clip.title });
    this.composer.setValue(question ?? `What should I know about ${clip.title}?`);
    this.composer.focus();
  }

  stop(): void {
    this.abort?.abort();
  }

  async send(question: string, attachments: NamedAttachment[] = []): Promise<void> {
    const q = question.trim();
    if (!q || this.abort) return;
    this.conv.messages.push({ role: "user", text: q, attachments });
    const reply: ChatMessage = { meetingId: this.scope==="meeting" ? this.plugin.live.meetingId ?? undefined : undefined, role: "assistant", text: "", citations: [], streaming: true };
    this.conv.messages.push(reply);
    this.stick = true;
    this.renderAll();

    const ac = new AbortController();
    this.abort = ac;
    this.composer.refresh();
    const req: Parameters<typeof this.plugin.client.ask>[0] = { question: q };
    if (this.scope === "meeting" && this.plugin.live.meetingId && this.plugin.recording) req.meetingId = this.plugin.live.meetingId;
    if (this.conv.id) req.conversationId = this.conv.id;
    if (attachments.length) req.attachments = attachments.map(({ name: _n, ...a }) => a);
    try {
      await this.plugin.client.ask(
        req,
        (ev) => {
          if (ev.type === "token") reply.text += ev.text;
          else if (ev.type === "trace") reply.trace=ev.trace;
          else if (ev.type === "citations") {
            reply.citations = ev.citations; reply.trace = ev.trace;
            if (ev.answer !== undefined) reply.text = ev.answer;
            if (ev.conversationId) this.conv.id = ev.conversationId;
          } else if (ev.type === "done" && ev.conversationId) this.conv.id = ev.conversationId;
          else if (ev.type === "error") reply.error = ev.message;
          this.scheduleMessage(reply);
        },
        ac.signal,
      );
    } catch (e) {
      if (!(e instanceof ApiError && e.kind === "aborted")) reply.error = e instanceof Error ? e.message : String(e);
    } finally {
      reply.streaming = false;
      if (ac.signal.aborted && !reply.text) reply.error = "Stopped";
      this.abort = null;
      this.composer.refresh();
      this.renderMessage(reply);
      this.renderNav();
    }
  }

  // ------------------------------------------------------------ render

  private scheduleMessage(m: ChatMessage): void {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.renderMessage(m);
    });
  }

  private renderAll(): void {
    this.listEl.empty();
    this.msgEls.clear();
    this.renderNav();
    if (!this.conv.messages.length) {
      this.renderEmpty();
      return;
    }
    for (const m of this.conv.messages) this.renderMessage(m);
  }

  private renderEmpty(): void {
    const e = this.listEl.createDiv({ cls: "ws-chat-empty" });
    e.createDiv({ cls: "ws-chat-empty-title", text: this.opts.emptyTitle ?? "Ask anything you've said, heard or saved" });
    e.createDiv({
      cls: "ws-chat-empty-text",
      text: this.opts.emptyText ?? "Answers cite the moment they came from — a turn in a meeting, a page, a clip. Type @ to add a file, or drop one here.",
    });
    if (this.plugin.connState.kind === "offline") e.createDiv({ cls: "ws-chat-empty-warn", text: this.plugin.connState.reason });
    const sugg = this.opts.suggestions ?? ["What did we decide about conflict handling?", "What does the Halvorsen contract say about offline?"];
    const list = e.createDiv({ cls: "ws-chat-suggestions" });
    for (const s of sugg) {
      const b = list.createDiv({ cls: "ws-chat-suggestion", attr: { role: "button", tabindex: "0" } });
      setIcon(b.createSpan({ cls: "ws-chat-suggestion-icon" }), "corner-down-right");
      b.createSpan({ text: s });
      b.addEventListener("click", () => void this.send(s));
      b.addEventListener("keydown", (ev) => ev.key === "Enter" && void this.send(s));
    }
  }

  private renderNav(): void {
    const nav = this.navEl;
    nav.empty();
    nav.toggleClass("is-empty", !this.conv.messages.length);
    if (!this.conv.messages.length) return;
    nav.createDiv({ cls: "ws-spacer" });
    iconButton(nav, "save", "Save conversation as a note", () => void this.saveAsNote());
    iconButton(nav, "square-pen", "New conversation", () => this.reset());
  }

  private renderMessage(m: ChatMessage): void {
    const prev = this.msgEls.get(m);
    const traceOpen = prev?.querySelector<HTMLDetailsElement>(".ws-trace")?.open;
    // While streaming, update the answer in place (the Markdown swap is atomic, so no flicker).
    const liveBody = prev && m.streaming && m.text ? prev.querySelector<HTMLElement>(".ws-msg-content") : null;
    if (liveBody) {
      const open = (mo: Moment, e: MouseEvent) => this.plugin.openMoment(mo, e);
      void renderCitedMarkdown(this.app, this, liveBody, m.text, m.citations ?? [], open).then(() => {
        (liveBody.lastElementChild ?? liveBody).createSpan({ cls: "ws-caret" });
        this.scrollDown();
      });
      return;
    }
    const el = createDiv({ cls: `ws-msg ws-msg-${m.role}` });
    if (prev) prev.replaceWith(el);
    else this.listEl.append(el);
    this.msgEls.set(m, el);

    if (m.role === "user") {
      el.createDiv({ cls: "ws-msg-bubble", text: m.text });
      if (m.attachments?.length) {
        const atts = el.createDiv({ cls: "ws-msg-atts" });
        for (const a of m.attachments) {
          const c = atts.createSpan({ cls: "ws-chip is-small" });
          setIcon(c.createSpan({ cls: "ws-chip-icon" }), "path" in a ? "file-text" : "text");
          c.createSpan({ cls: "ws-chip-label", text: a.name });
        }
      }
      this.scrollDown();
      return;
    }

    const open = (mo: Moment, e: MouseEvent) => this.plugin.openMoment(mo, e);
    const body = el.createDiv({ cls: "ws-msg-content" });
    const cites = m.citations ?? [];
    const hasMarkers = /\[(?:Source:\s*)?\d/.test(m.text);
    const sources = cites.length && !m.streaming ? renderSources(el, cites, open, { open: !hasMarkers }) : undefined;
    if (m.text) {
      void renderCitedMarkdown(this.app, this, body, m.text, cites, open, sources).then(() => {
        if (m.streaming) (body.lastElementChild ?? body).createSpan({ cls: "ws-caret" });
        this.scrollDown();
      });
    }
    const footer=el.createDiv({cls:'ws-answer-footer'});
    renderTrace(footer, m.trace, {open:traceOpen, running:m.streaming, sources:m.citations, onSource:open});
    if (m.error) el.createDiv({ cls: "ws-msg-error", text: m.error });
    if (!m.streaming && m.text) {
      const acts = footer.createDiv({ cls: "ws-msg-actions" });
      iconButton(acts, "copy", "Copy with sources", async () => {
        await navigator.clipboard.writeText(citationsToMarkdown(m.text, cites, this.plugin.linkContext()));
        new Notice("Copied");
      });
      const view = this.plugin.lastMarkdownView();
      if (view) {
        iconButton(acts, "file-input", `Insert into ${view.file?.basename ?? "note"}`, () => {
          view.editor.replaceSelection(citationsToMarkdown(m.text, cites, this.plugin.linkContext()) + "\n");
          new Notice(`Inserted into ${view.file?.basename ?? "note"}`);
        });
      }
    }
    this.scrollDown();
  }

  private scrollDown(): void {
    if (this.stick) this.listEl.scrollTop = this.listEl.scrollHeight;
  }

  // ------------------------------------------------------------ save

  async saveAsNote(): Promise<void> {
    const msgs = this.conv.messages.filter((m) => !m.streaming);
    if (!msgs.length) {
      new Notice("Nothing to save yet");
      return;
    }
    const ctx = this.plugin.linkContext();
    const first = msgs.find((m) => m.role === "user")?.text ?? "Conversation";
    const date = window.moment().format("YYYY-MM-DD");
    const folder = normalizePath(this.plugin.settings.conversationsFolder);
    const lines = [
      "---",
      "type: workscribe-chat",
      `date: ${window.moment().format("YYYY-MM-DDTHH:mm")}`,
      ...(this.conv.id ? [`workscribe_id: ${this.conv.id}`] : []),
      "tags:",
      "  - workscribe",
      "---",
      "",
    ];
    for (const m of msgs) {
      if (m.role === "user") {
        lines.push(`## ${m.text.replace(/\n+/g, " ")}`, "");
        if (m.attachments?.length) {
          lines.push(
            "Attached: " +
              m.attachments
                .map((a) => {
                  if (!("path" in a)) return a.name;
                  const rel = ctx.vaultBase && a.path.startsWith(ctx.vaultBase + "/") ? a.path.slice(ctx.vaultBase.length + 1) : null;
                  return rel ? `[[${rel.replace(/\.md$/i, "")}]]` : `\`${a.path}\``;
                })
                .join(", "),
            "",
          );
        }
      } else {
        lines.push(citationsToMarkdown(m.text, m.citations ?? [], ctx), "");
    if (m.error) lines.push(`> [!warning] ${m.error}`, "");
      }
    }
    if (!this.app.vault.getAbstractFileByPath(folder)) await this.app.vault.createFolder(folder).catch(() => undefined);
    let path = normalizePath(`${folder}/${date} ${safeFilename(first).slice(0, 60)}.md`);
    for (let i = 2; this.app.vault.getAbstractFileByPath(path); i++) path = path.replace(/( \d+)?\.md$/, ` ${i}.md`);
    const file = await this.app.vault.create(path, lines.join("\n"));
    await this.app.workspace.getLeaf("tab").openFile(file);
    new Notice(`Saved to ${path}`);
  }
}
