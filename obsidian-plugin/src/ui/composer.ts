// The Claudian-style composer: a thin-bordered, 10px-rounded box that grows
// with multiline input. Removable context chips sit above the text (attached
// files, "N lines selected", pasted text), `@` suggests vault files, and a muted
// info row sits below (scope, the note you were in). Enter sends, Shift+Enter
// adds a line, Esc closes the menu or cancels the running answer.

import { MarkdownView, Menu, Notice, TFile, normalizePath, prepareFuzzySearch, setIcon, setTooltip } from "obsidian";
import type WorkScribePlugin from "../main";
import type { Scope } from "../settings";
import { collectDropped, pathOfFile, textAttachment, vaultFileAttachment, type NamedAttachment } from "./attachments";
import { iconButton } from "./render";

export interface ComposerOptions {
  placeholder: string;
  /** Called with the question and the context to send. Return false to keep the text. */
  onSubmit(text: string, attachments: NamedAttachment[]): boolean | void;
  onCancel(): void;
  busy(): boolean;
  /** Show the scope picker in the info row. */
  scope?: { get(): Scope; set(s: Scope): void };
  /** Accept attachments (chips, @ mentions, drop, paste). */
  attachments?: boolean;
  /** Element that accepts drops (defaults to the composer). */
  dropTarget?: HTMLElement;
  /** Extra class on the root. */
  cls?: string;
  /** Rows of text before scrolling. */
  maxRows?: number;
}

interface SelectionCtx {
  text: string;
  file: string;
  lines: number;
}

const LONG_PASTE = 400;

export class Composer {
  readonly el: HTMLElement;
  readonly input: HTMLTextAreaElement;
  private box: HTMLElement;
  private chipsEl: HTMLElement;
  private infoEl: HTMLElement;
  private actionEl: HTMLElement;
  private menuEl: HTMLElement | null = null;
  private menuItems: TFile[] = [];
  private menuIndex = 0;
  private attachments: NamedAttachment[] = [];
  private selection: SelectionCtx | null = null;
  private dismissedSelection = "";

  constructor(
    parent: HTMLElement,
    private readonly plugin: WorkScribePlugin,
    private readonly opts: ComposerOptions,
  ) {
    this.el = parent.createDiv({ cls: `ws-composer ${opts.cls ?? ""}`.trim() });
    this.box = this.el.createDiv({ cls: "ws-composer-box" });
    this.chipsEl = this.box.createDiv({ cls: "ws-context-row" });
    this.input = this.box.createEl("textarea", {
      cls: "ws-composer-input",
      attr: { rows: "1", placeholder: opts.placeholder, "aria-label": "Message", spellcheck: "true" },
    });
    const tools = this.box.createDiv({ cls: "ws-composer-tools" });
    if (opts.attachments !== false) iconButton(tools, "paperclip", "Add context", (e) => this.attachMenu(e), "ws-attach-btn");
    tools.createDiv({ cls: "ws-spacer" });
    this.actionEl = tools.createDiv({ cls: "ws-composer-action" });
    this.infoEl = this.el.createDiv({ cls: "ws-composer-info" });

    this.input.addEventListener("input", () => {
      this.autosize();
      this.updateMention();
      this.renderAction();
    });
    this.input.addEventListener("keydown", (e) => this.onKey(e));
    this.input.addEventListener("focus", () => this.captureSelection());
    this.input.addEventListener("blur", () => window.setTimeout(() => this.closeMenu(), 150));
    this.input.addEventListener("paste", (e) => void this.onPaste(e));
    this.box.addEventListener("click", (e) => {
      if (e.target === this.box) this.input.focus();
    });

    if (opts.attachments !== false) {
      const drop = opts.dropTarget ?? this.el;
      drop.addEventListener("dragover", (e) => {
        e.preventDefault();
        this.box.addClass("is-drop");
      });
      drop.addEventListener("dragleave", (e) => {
        if (!drop.contains(e.relatedTarget as Node | null)) this.box.removeClass("is-drop");
      });
      drop.addEventListener("drop", (e) => {
        e.preventDefault();
        this.box.removeClass("is-drop");
        const atts = collectDropped(this.plugin, e);
        atts.forEach((a) => this.addAttachment(a));
        if (!atts.length) new Notice("Nothing to attach from that drop");
        this.input.focus();
      });
    }
    this.renderChips();
    this.renderInfo();
    this.renderAction();
  }

  // ------------------------------------------------------------ public

  focus(): void {
    window.setTimeout(() => this.input.focus(), 10);
  }

  get value(): string {
    return this.input.value;
  }

  setValue(v: string): void {
    this.input.value = v;
    this.autosize();
    this.renderAction();
  }

  addAttachment(a: NamedAttachment): void {
    const key = "path" in a ? a.path : a.text;
    if (this.attachments.some((x) => ("path" in x ? x.path : x.text) === key)) return;
    this.attachments.push(a);
    this.renderChips();
  }

  attachVaultFile(f: TFile): void {
    const a = vaultFileAttachment(this.plugin, f);
    if (a) this.addAttachment(a);
  }

  clearContext(): void {
    this.attachments = [];
    this.selection = null;
    this.renderChips();
  }

  /** Re-render the action button and info row (busy state, scope, current note). */
  refresh(): void {
    this.renderAction();
    this.renderInfo();
  }

  submit(): void {
    const text = this.input.value.trim();
    if (!text || this.opts.busy()) return;
    const atts = [...this.attachments];
    if (this.selection) atts.push({ text: this.selection.text, name: `${this.selection.lines} line${this.selection.lines === 1 ? "" : "s"} from ${this.selection.file}` });
    if (this.opts.onSubmit(text, atts) === false) return;
    if (this.selection) this.dismissedSelection = this.selection.text;
    this.attachments = [];
    this.selection = null;
    this.setValue("");
    this.renderChips();
  }

  // ------------------------------------------------------------ keys

  private onKey(e: KeyboardEvent): void {
    if (this.menuEl) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const n = this.menuItems.length;
        this.menuIndex = (this.menuIndex + (e.key === "ArrowDown" ? 1 : n - 1)) % n;
        this.renderMenu();
        return;
      }
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault();
        const f = this.menuItems[this.menuIndex];
        if (f) this.chooseMention(f);
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        this.closeMenu();
        return;
      }
    }
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      this.submit();
      return;
    }
    if (e.key === "Escape" && this.opts.busy()) {
      e.preventDefault();
      e.stopPropagation();
      this.opts.onCancel();
    }
  }

  private autosize(): void {
    const el = this.input;
    el.style.height = "auto";
    const max = (this.opts.maxRows ?? 10) * 22 + 8;
    el.style.height = `${Math.min(el.scrollHeight, max)}px`;
    el.style.overflowY = el.scrollHeight > max ? "auto" : "hidden";
  }

  // ------------------------------------------------------------ context

  private captureSelection(): void {
    if (this.opts.attachments === false) return;
    const view = this.plugin.lastMarkdownView();
    const text = view?.editor?.getSelection() ?? "";
    if (!view?.file || !text.trim() || text === this.dismissedSelection) {
      if (this.selection && this.selection.text !== text) {
        this.selection = null;
        this.renderChips();
      }
      return;
    }
    this.selection = { text, file: view.file.basename, lines: text.split(/\r?\n/).length };
    this.renderChips();
  }

  private renderChips(): void {
    const row = this.chipsEl;
    row.empty();
    const chip = (icon: string, label: string, tip: string, remove: () => void, cls = "") => {
      const c = row.createDiv({ cls: `ws-chip ${cls}`.trim() });
      setIcon(c.createSpan({ cls: "ws-chip-icon" }), icon);
      c.createSpan({ cls: "ws-chip-label", text: label });
      setTooltip(c, tip);
      const x = c.createEl("button", { cls: "ws-chip-x", attr: { "aria-label": `Remove ${label}` } });
      setIcon(x, "x");
      x.addEventListener("click", (e) => {
        e.stopPropagation();
        remove();
        this.renderChips();
        this.input.focus();
      });
    };
    if (this.selection) {
      const s = this.selection;
      chip("text-select", `${s.lines} line${s.lines === 1 ? "" : "s"} selected`, `From ${s.file}`, () => {
        this.dismissedSelection = s.text;
        this.selection = null;
      });
    }
    this.attachments.forEach((a, i) =>
      chip("path" in a ? "file-text" : "text", a.name, "path" in a ? a.path : "Pasted text", () => this.attachments.splice(i, 1)),
    );
    row.toggleClass("is-empty", !row.childElementCount);
    this.renderInfo();
  }

  private renderInfo(): void {
    const info = this.infoEl;
    info.empty();
    const p = this.plugin;
    if (p.connState.kind === "offline") {
      const off = info.createSpan({ cls: "ws-info-item is-off", text: "WorkScribe isn't running" });
      setTooltip(off, p.connState.reason);
    }
    const scope = this.opts.scope;
    if (scope) {
      const cur = scope.get() === "meeting" && p.recording ? "meeting" : "everything";
      const s = info.createSpan({ cls: "ws-info-item is-clickable" });
      setIcon(s.createSpan({ cls: "ws-info-icon" }), cur === "meeting" ? "mic" : "library");
      s.createSpan({ text: cur === "meeting" ? `This meeting` : "Everything" });
      setIcon(s.createSpan({ cls: "ws-info-chev" }), "chevron-down");
      setTooltip(s, "What answers draw on");
      s.addEventListener("click", (e) => {
        const m = new Menu();
        m.addItem((i) => i.setTitle("Everything").setIcon("library").setChecked(cur === "everything").onClick(() => {
          scope.set("everything");
          this.renderInfo();
        }));
        m.addItem((i) =>
          i
            .setTitle(p.recording ? `This meeting · ${p.live.title || "live"}` : "This meeting (while recording)")
            .setIcon("mic")
            .setDisabled(!p.recording)
            .setChecked(cur === "meeting")
            .onClick(() => {
              scope.set("meeting");
              this.renderInfo();
            }),
        );
        m.showAtMouseEvent(e);
      });
    }
    const file = this.opts.attachments !== false ? p.lastMarkdownView()?.file ?? null : null;
    if (file) {
      const attached = this.attachments.some((a) => "path" in a && a.path === p.absolutePath(file.path));
      const f = info.createSpan({ cls: `ws-info-item is-clickable ws-info-note${attached ? " is-attached" : ""}` });
      setIcon(f.createSpan({ cls: "ws-info-icon" }), attached ? "check" : "file-text");
      f.createSpan({ cls: "ws-info-note-name", text: file.basename });
      setTooltip(f, attached ? "Attached" : "Attach this note");
      f.addEventListener("click", () => {
        if (!attached) this.attachVaultFile(file);
        this.input.focus();
      });
    }
  }

  private renderAction(): void {
    const el = this.actionEl;
    el.empty();
    if (this.opts.busy()) {
      iconButton(el, "square", "Stop (Esc)", () => this.opts.onCancel(), "ws-stop-btn");
      return;
    }
    const b = iconButton(el, "arrow-up", "Send (Enter)", () => this.submit(), "ws-send-btn");
    b.toggleClass("is-ready", !!this.input.value.trim());
  }

  private attachMenu(e: MouseEvent): void {
    const m = new Menu();
    const active = this.plugin.lastMarkdownView()?.file ?? null;
    m.addItem((i) =>
      i
        .setTitle(active ? `Current note (${active.basename})` : "Current note")
        .setIcon("file-text")
        .setDisabled(!active)
        .onClick(() => active && this.attachVaultFile(active)),
    );
    m.addItem((i) =>
      i
        .setTitle("A file from this vault…")
        .setIcon("at-sign")
        .onClick(() => {
          const v = this.input.value;
          this.setValue(v + (v && !/\s$/.test(v) ? " @" : "@"));
          this.input.focus();
          this.updateMention();
        }),
    );
    m.addItem((i) =>
      i
        .setTitle("Clipboard text")
        .setIcon("clipboard-paste")
        .onClick(async () => {
          const text = await navigator.clipboard.readText().catch(() => "");
          if (text.trim()) this.addAttachment(textAttachment(text));
          else new Notice("Clipboard has no text");
        }),
    );
    m.showAtMouseEvent(e);
  }

  // ------------------------------------------------------------ paste

  private async onPaste(e: ClipboardEvent): Promise<void> {
    if (this.opts.attachments === false) return;
    const files = Array.from(e.clipboardData?.files ?? []);
    if (files.length) {
      e.preventDefault();
      for (const f of files) await this.attachPastedFile(f);
      return;
    }
    // Long pastes become a text attachment instead of flooding the question.
    const text = e.clipboardData?.getData("text/plain") ?? "";
    if (text.length > LONG_PASTE) {
      e.preventDefault();
      this.addAttachment(textAttachment(text));
    }
  }

  /** Pasted images have no path: save them next to saved conversations, like Obsidian does with pasted images. */
  private async attachPastedFile(f: File): Promise<void> {
    const onDisk = pathOfFile(f);
    if (onDisk) {
      this.addAttachment({ path: onDisk, name: f.name });
      return;
    }
    try {
      const folder = normalizePath(`${this.plugin.settings.conversationsFolder}/Attachments`);
      if (!this.plugin.app.vault.getAbstractFileByPath(folder)) await this.plugin.app.vault.createFolder(folder).catch(() => undefined);
      const ext = (f.type.split("/")[1] ?? "png").replace("jpeg", "jpg");
      const path = normalizePath(`${folder}/Pasted ${window.moment().format("YYYY-MM-DD HHmmss")}.${ext}`);
      const file = await this.plugin.app.vault.createBinary(path, await f.arrayBuffer());
      this.attachVaultFile(file);
    } catch (err) {
      this.plugin.showError(err);
    }
  }

  // ------------------------------------------------------------ @ mentions

  private mentionQuery(): { start: number; query: string } | null {
    const caret = this.input.selectionStart ?? 0;
    const before = this.input.value.slice(0, caret);
    const m = /(?:^|\s)@([^\s@]{0,60})$/.exec(before);
    return m ? { start: caret - m[1]!.length - 1, query: m[1]! } : null;
  }

  private updateMention(): void {
    if (this.opts.attachments === false) return;
    const q = this.mentionQuery();
    if (!q) {
      this.closeMenu();
      return;
    }
    const files = this.plugin.app.vault.getFiles();
    let items: TFile[];
    if (!q.query) {
      const recent = this.plugin.app.workspace.getLastOpenFiles();
      items = recent.map((p) => this.plugin.app.vault.getAbstractFileByPath(p)).filter((f): f is TFile => f instanceof TFile);
      if (items.length < 8) items.push(...files.filter((f) => !items.includes(f)).slice(0, 8 - items.length));
    } else {
      const match = prepareFuzzySearch(q.query);
      items = files
        .map((f) => ({ f, r: match(f.path) }))
        .filter((x) => x.r)
        .sort((a, b) => b.r!.score - a.r!.score)
        .map((x) => x.f);
    }
    this.menuItems = items.slice(0, 8);
    this.menuIndex = 0;
    if (!this.menuItems.length) {
      this.closeMenu();
      return;
    }
    this.renderMenu();
  }

  private renderMenu(): void {
    if (!this.menuEl) this.menuEl = this.el.createDiv({ cls: "ws-mention-menu", attr: { role: "listbox" } });
    const menu = this.menuEl;
    menu.empty();
    this.menuItems.forEach((f, i) => {
      const it = menu.createDiv({ cls: `ws-mention-item${i === this.menuIndex ? " is-selected" : ""}`, attr: { role: "option" } });
      setIcon(it.createSpan({ cls: "ws-mention-icon" }), f.extension === "md" ? "file-text" : f.extension === "pdf" ? "file-type" : "file");
      it.createSpan({ cls: "ws-mention-name", text: f.basename });
      const dir = f.parent && f.parent.path !== "/" ? f.parent.path : "";
      if (dir) it.createSpan({ cls: "ws-mention-dir", text: dir });
      it.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this.chooseMention(f);
      });
    });
  }

  private chooseMention(f: TFile): void {
    const q = this.mentionQuery();
    if (q) {
      const v = this.input.value;
      const caret = this.input.selectionStart ?? v.length;
      const insert = `@${f.basename} `;
      this.input.value = v.slice(0, q.start) + insert + v.slice(caret);
      const pos = q.start + insert.length;
      this.input.setSelectionRange(pos, pos);
      this.autosize();
    }
    this.attachVaultFile(f);
    this.closeMenu();
    this.renderAction();
  }

  private closeMenu(): void {
    this.menuEl?.remove();
    this.menuEl = null;
  }
}

/** Remember the markdown view the user was last in, so a sidebar composer can offer its selection and note. */
export function isMarkdownView(v: unknown): v is MarkdownView {
  return v instanceof MarkdownView;
}
