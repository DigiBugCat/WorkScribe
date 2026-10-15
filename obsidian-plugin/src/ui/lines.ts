import { Notice, setIcon, setTooltip } from "obsidian";
import { clock, relativeToTyping } from "../lib/format";
import type { Row } from "../lib/live";
import { lineState, type LineState } from "../lib/suggestions";
import type { Enhancement, Excerpt, Note, Segment } from "../lib/types";
import { evidenceDot, iconButton, textButton } from "./render";

export interface LineHost {
  /** Show AI lines and hints; manually edited lines remain visible. */
  showSuggestions: boolean;
  editAI(note: Note, e: Enhancement): Promise<void>;
  rewrite(note: Note): Promise<void>;
  /** Edit what you typed (PATCH {text}); omitted when not editable. */
  editShorthand?(note: Note, text: string): Promise<void>;
  retry?(clientId: string): void;
  /** Click on an evidence row. */
  openExcerpt(e: Excerpt, note: Note, evt: MouseEvent): void;
  /** Turns around an excerpt, for context (past meetings). */
  context?(e: Excerpt): Segment[];
  /** Open this line in the meeting's vault note, when it has one. */
  showInNote?(note: Note): (() => void) | null;
  /** View-local UI state, owned by the view. */
  ui: { why: Set<string>; editing: string | null };
  rerender(): void;
}

export function renderLine(parent: HTMLElement, host: LineHost, row: Row): HTMLElement {
  const n = row.note;
  const state: LineState = row.pending
    ? { kind: "sending", ...(row.pending.error ? { error: row.pending.error } : {}) }
    : lineState(n!);
  const line = parent.createDiv({ cls: `ws-line is-${state.kind}` });
  line.dataset.key = row.key;
  const why = !!n && host.ui.why.has(n.id);
  line.toggleClass("is-open", why);

  // ---- your line
  const main = line.createDiv({ cls: "ws-line-main" });
  const textEl = main.createDiv({ cls: "ws-line-text" });
  textEl.setText(row.text);

  if (n?.fromAnswer) {
    line.addClass("is-from-answer");
    const who = n.fromAnswer.askedBy ? ` · ${n.fromAnswer.askedBy.split(" ")[0]} asked` : "";
    line.createDiv({ cls: "ws-line-meta", text: `From a live answer${who}` });
  }

  if (state.kind === "sending") {
    const meta = line.createDiv({ cls: "ws-line-meta" });
    if (state.error) {
      meta.addClass("is-error");
      meta.appendText("Not sent · ");
      if (host.retry) textButton(meta, "Retry", () => host.retry!(row.pending!.clientId), "is-inline");
    } else meta.createSpan({ cls: "ws-breath", text: "Saving…" });
    return line;
  }
  const note = n!;

  // ---- separate, editable AI line
  if (host.ui.editing === note.id && note.enhanced) {
    renderEditor(line, host, note, note.enhanced);
  } else if ((state.kind === "ai" || state.kind === "owned") && (host.showSuggestions || state.kind === "owned") && !note.fromAnswer) {
    const sg = line.createDiv({ cls: "ws-sugg", attr: { tabindex: "0", "aria-label": state.kind === "owned" ? "Your edited line" : "AI line" } });
    setIcon(sg.createSpan({ cls: "ws-sugg-icon" }), "sparkles");
    const body = sg.createDiv({ cls: "ws-sugg-body" });
    if (state.enhanced.topic) body.createSpan({ cls: "ws-sugg-topic", text: state.enhanced.topic.trim() + " " });
    body.appendText(state.enhanced.text);

  } else if (!note.fromAnswer && host.showSuggestions && (state.kind === "none" || state.kind === "waiting")) {
    const meta = line.createDiv({ cls: "ws-line-meta" });
    if (state.kind === "none") meta.setText(state.hint);
    else meta.createSpan({ cls: "ws-breath", text: state.drafting ? "Updating AI line…" : "Listening for this…" });
  }

  // ---- hover toolbar
  if (host.ui.editing !== note.id) renderToolbar(line, host, note, state, why, row.at);

  // ---- evidence, on demand
  if (why) renderWhy(line, host, note);

  // Click the line for its evidence; double-click your words to edit them.
  line.addEventListener("click", (e) => {
    if ((e.target as HTMLElement).closest("button, a, input, textarea, .ws-why, .ws-sugg-editor, .ws-line-toolbar")) return;
    if (window.getSelection()?.toString()) return;
    toggleWhy(host, note);
  });
  if (host.editShorthand && !note.fromAnswer) {
    textEl.addEventListener("dblclick", (e) => {
      e.stopPropagation();
      editShorthand(textEl, host, note);
    });
  }
  return line;
}

function toggleWhy(host: LineHost, note: Note): void {
  if (host.ui.why.has(note.id)) host.ui.why.delete(note.id);
  else host.ui.why.add(note.id);
  host.rerender();
}

function renderToolbar(line: HTMLElement, host: LineHost, note: Note, state: LineState, why: boolean, at: number): void {
  const bar = line.createDiv({ cls: "ws-line-toolbar" });
  const time = bar.createSpan({ cls: "ws-line-time", text: clock(at) });
  setTooltip(time, "When you typed this");
  const edit = () => {
    host.ui.editing = note.id;
    host.rerender();
  };
  if ((state.kind === "ai" || state.kind === "owned") && !note.fromAnswer) {
    iconButton(bar, "pencil", "Edit AI line (makes it yours)", (e) => { e.stopPropagation(); edit(); });
    if (state.kind === "owned") textButton(bar, "Let AI rewrite", () => void host.rewrite(note).catch(err => new Notice(String(err))));
  }
  if (note.excerpts.length) {
  const w = iconButton(bar, "text-quote", why ? "Hide evidence" : "Why? Show what was said", (e) => {
    e.stopPropagation();
    toggleWhy(host, note);
  });
  w.toggleClass("is-active", why);
  }
  const show = host.showInNote?.(note);
  if (show) iconButton(bar, "file-symlink", "Show in the meeting note", (e) => {
    e.stopPropagation();
    show();
  });
}

function renderEditor(line: HTMLElement, host: LineHost, note: Note, e: Enhancement): void {
  const box = line.createDiv({ cls: "ws-sugg-editor" });
  const topic = box.createEl("input", { type: "text", cls: "ws-ed-topic", attr: { placeholder: "Topic (optional)", "aria-label": "Topic" } });
  topic.value = e.topic;
  const text = box.createEl("textarea", { cls: "ws-ed-text", attr: { rows: "2", "aria-label": "Text" } });
  text.value = e.text;
  const grow = () => {
    text.style.height = "auto";
    text.style.height = `${text.scrollHeight}px`;
  };
  text.addEventListener("input", grow);
  const row = box.createDiv({ cls: "ws-ed-row" });
  row.createSpan({ cls: "ws-ed-hint", text: "⌘↵ save · Esc cancel" });
  const cancel = () => {
    host.ui.editing = null;
    host.rerender();
  };
  textButton(row, "Cancel", cancel);
  const save = row.createEl("button", { cls: "mod-cta ws-ed-save", text: "Save my edit" });
  const doSave = async () => {
    const t = text.value.trim();
    if (!t) return;
    save.disabled = true;
    try {
      await host.editAI(note, { topic: topic.value.trim(), text: t });
      host.ui.editing = null;
      host.rerender();
    } catch (err) {
      save.disabled = false;
      new Notice(`WorkScribe: couldn't save: ${err instanceof Error ? err.message : String(err)}`);
    }
  };
  save.addEventListener("click", (ev) => {
    ev.stopPropagation();
    void doSave();
  });
  for (const el of [topic, text] as HTMLElement[])
    el.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
        ev.preventDefault();
        void doSave();
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        ev.stopPropagation();
        cancel();
      }
    });
  window.setTimeout(() => {
    grow();
    text.focus();
    text.setSelectionRange(text.value.length, text.value.length);
  }, 0);
}

function editShorthand(textEl: HTMLElement, host: LineHost, note: Note): void {
  const input = createEl("input", { type: "text", cls: "ws-line-input", attr: { "aria-label": "Edit your note" } });
  input.value = note.text;
  textEl.replaceWith(input);
  input.focus();
  let done = false;
  const finish = async (save: boolean) => {
    if (done) return;
    done = true;
    const t = input.value;
    if (save && t.trim() && t !== note.text) {
      try {
        await host.editShorthand!(note, t);
      } catch (e) {
        new Notice(`WorkScribe: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    host.rerender();
  };
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      void finish(true);
    }
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      void finish(false);
    }
  });
  input.addEventListener("blur", () => void finish(true));
}

function renderWhy(line: HTMLElement, host: LineHost, note: Note): void {
  const box = line.createDiv({ cls: "ws-why" });
  if (!note.excerpts.length) {
    box.createDiv({ cls: "ws-why-head", text: "Nothing said in the meeting has been matched to this line yet." });
    return;
  }
  const near = note.excerpts.filter((e) => e.match === "time+meaning").length;
  const far = note.excerpts.length - near;
  const head = box.createDiv({ cls: "ws-why-head" });
  head.createSpan({ text: `Drawn from ${note.excerpts.length} moment${note.excerpts.length === 1 ? "" : "s"}` });
  if (near) {
    const k = head.createSpan({ cls: "ws-why-key" });
    evidenceDot(k, { match: "time+meaning" });
    k.appendText(`${near} near when you typed`);
  }
  if (far) {
    const k = head.createSpan({ cls: "ws-why-key" });
    evidenceDot(k, { match: "meaning" });
    k.appendText(`${far} by meaning only`);
  }
  for (const e of note.excerpts) {
    const ev = box.createDiv({ cls: "ws-ev", attr: { role: "button", tabindex: "0" } });
    evidenceDot(ev, e);
    const body = ev.createDiv({ cls: "ws-ev-body" });
    const h = body.createDiv({ cls: "ws-ev-head" });
    h.createSpan({ cls: "ws-ev-speaker", text: e.speaker });
    h.createSpan({ cls: "ws-ev-time", text: clock(e.start) });
    h.createSpan({ cls: "ws-ev-rel", text: relativeToTyping(e.start, note.at) });
    const ctx = host.context?.(e) ?? [];
    const focusIdx = ctx.findIndex((s) => (e.segmentId ? s.id === e.segmentId : s.start === e.start));
    if (focusIdx > 0) body.createDiv({ cls: "ws-ev-ctx", text: `${ctx[focusIdx - 1]!.speaker.split(" ")[0]}: ${ctx[focusIdx - 1]!.text}` });
    body.createDiv({ cls: "ws-ev-quote", text: e.quote });
    if (focusIdx >= 0 && focusIdx < ctx.length - 1)
      body.createDiv({ cls: "ws-ev-ctx", text: `${ctx[focusIdx + 1]!.speaker.split(" ")[0]}: ${ctx[focusIdx + 1]!.text}` });
    ev.addEventListener("click", (evt) => {
      evt.stopPropagation();
      host.openExcerpt(e, note, evt);
    });
    ev.addEventListener("keydown", (evt) => {
      if (evt.key === "Enter") host.openExcerpt(e, note, evt as unknown as MouseEvent);
    });
  }
}
