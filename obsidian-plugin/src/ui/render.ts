// Shared renderers: moment rows, cited answers (Markdown with numbered citation
// chips and hover previews), collapsible source lists, evidence rows.

import { App, Component, MarkdownRenderer, ToggleComponent, setIcon, setTooltip } from "obsidian";
import { fileUrl, momentTarget, momentWhere, splitCitations, type LinkContext } from "../lib/format";
import type { Excerpt, Moment, MomentKind } from "../lib/types";

const KIND_ICON: Record<MomentKind, string> = {
  meeting: "messages-square",
  note: "file-text",
  clip: "scissors",
  pdf: "file-type",
  document: "file",
  audio: "audio-lines",
  video: "film",
  image: "image",
  screen: "monitor",
};

const KIND_LABEL: Record<MomentKind, string> = {
  meeting: "Meeting",
  note: "Note",
  clip: "Clip",
  pdf: "PDF",
  document: "File",
  audio: "Audio",
  video: "Video",
  image: "Image",
  screen: "Screen",
};

/** Open a moment: vault files in Obsidian, meetings via workscribe://, everything else by macOS. */
export async function openMoment(app: App, m: Moment, ctx: LinkContext, newLeaf = false): Promise<void> {
  const t = momentTarget(m, ctx);
  if (!t) return;
  if (t.kind === "vault") {
    await app.workspace.openLinkText(t.path + (t.subpath ?? ""), "", newLeaf);
    return;
  }
  openExternal(t.url);
}

/** Hand a URL to macOS (workscribe://, file://, https://). */
export function openExternal(url: string): void {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { shell } = require("electron") as { shell?: { openExternal(u: string): Promise<void> } };
    if (shell?.openExternal) {
      void shell.openExternal(url);
      return;
    }
  } catch {
    /* fall through */
  }
  window.open(url, "_blank");
}

export type OpenMoment = (m: Moment, evt: MouseEvent) => void;

export interface MomentRowOpts {
  index?: number;
  onOpen: OpenMoment;
  /** One line, snippet truncated (source lists). Otherwise the snippet wraps below (search, previews). */
  compact?: boolean;
}

function thumbSrc(m: Moment): string | null {
  if (!m.thumbnail || !(m.kind === "screen" || m.kind === "image" || m.kind === "video")) return null;
  return m.thumbnail.startsWith("/") ? fileUrl(m.thumbnail) : m.thumbnail;
}

/** A moment as one quiet row: icon, title, where, snippet. */
export function renderMoment(parent: HTMLElement, m: Moment, opts: MomentRowOpts): HTMLElement {
  const row = parent.createDiv({ cls: `ws-moment ws-kind-${m.kind}${opts.compact ? " is-compact" : ""}` });
  row.setAttr("role", "button");
  row.setAttr("tabindex", "0");
  if (opts.index !== undefined) row.createSpan({ cls: "ws-cite is-static", text: String(opts.index) });
  const src = thumbSrc(m);
  if (src && !opts.compact) {
    const img = row.createEl("img", { cls: "ws-thumb", attr: { alt: "", src, loading: "lazy" } });
    img.draggable = false;
  } else setIcon(row.createSpan({ cls: "ws-moment-icon" }), KIND_ICON[m.kind]);
  const body = row.createDiv({ cls: "ws-moment-body" });
  const top = body.createDiv({ cls: "ws-moment-top" });
  top.createSpan({ cls: "ws-moment-title", text: m.title || KIND_LABEL[m.kind] });
  const where = momentWhere(m);
  if (where) top.createSpan({ cls: "ws-moment-where", text: where });
  if (m.snippet) {
    if (opts.compact) top.createSpan({ cls: "ws-moment-snippet", text: m.snippet });
    else body.createDiv({ cls: "ws-moment-snippet", text: m.snippet });
  }
  const open = (evt: MouseEvent) => opts.onOpen(m, evt);
  row.addEventListener("click", open);
  row.addEventListener("keydown", (e) => {
    if (e.key === "Enter") opts.onOpen(m, e as unknown as MouseEvent);
  });
  return row;
}

// ------------------------------------------------------------ citation chips + preview

let previewEl: HTMLElement | null = null;
let previewTimer = 0;

function hidePreview(): void {
  window.clearTimeout(previewTimer);
  previewEl?.remove();
  previewEl = null;
}

function showPreview(anchor: HTMLElement, m: Moment, index: number): void {
  hidePreview();
  const pop = document.body.createDiv({ cls: "ws-cite-pop" });
  const head = pop.createDiv({ cls: "ws-cite-pop-head" });
  head.createSpan({ cls: "ws-cite is-static", text: String(index) });
  setIcon(head.createSpan({ cls: "ws-moment-icon" }), KIND_ICON[m.kind]);
  head.createSpan({ cls: "ws-cite-pop-kind", text: KIND_LABEL[m.kind] });
  const where = momentWhere(m);
  if (where) head.createSpan({ cls: "ws-moment-where", text: where });
  pop.createDiv({ cls: "ws-cite-pop-title", text: m.title });
  const src = thumbSrc(m);
  if (src) pop.createEl("img", { cls: "ws-cite-pop-thumb", attr: { alt: "", src } });
  if (m.snippet) pop.createDiv({ cls: "ws-cite-pop-snippet", text: m.snippet });
  pop.createDiv({ cls: "ws-cite-pop-hint", text: "Click to open" });
  const r = anchor.getBoundingClientRect();
  const w = Math.min(320, window.innerWidth - 16);
  pop.style.width = `${w}px`;
  pop.style.left = `${Math.max(8, Math.min(r.left - 16, window.innerWidth - w - 8))}px`;
  const below = r.bottom + 6;
  pop.style.top = `${below}px`;
  previewEl = pop;
  // Flip above when it would run off the bottom.
  const h = pop.getBoundingClientRect().height;
  if (below + h > window.innerHeight - 8) pop.style.top = `${Math.max(8, r.top - h - 6)}px`;
}

/** A small numbered chip; hover previews the source, click opens it. */
export function citeChip(parent: HTMLElement, n: number, m: Moment | undefined, onCite: OpenMoment, sourcesEl?: HTMLElement): HTMLElement {
  const chip = parent.createSpan({ cls: "ws-cite", text: String(n) });
  if (!m) {
    chip.addClass("is-pending");
    return chip;
  }
  chip.setAttr("role", "button");
  chip.setAttr("aria-label", `Source ${n}: ${m.title}`);
  const rows = () => sourcesEl?.querySelectorAll<HTMLElement>(`[data-cite="${n}"]`) ?? [];
  chip.addEventListener("mouseenter", () => {
    window.clearTimeout(previewTimer);
    previewTimer = window.setTimeout(() => showPreview(chip, m, n), 180);
    rows().forEach((r) => r.addClass("is-hot"));
  });
  chip.addEventListener("mouseleave", () => {
    hidePreview();
    rows().forEach((r) => r.removeClass("is-hot"));
  });
  chip.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    hidePreview();
    onCite(m, e);
  });
  return chip;
}

/** Plain-text answer with citation chips (fallback when Markdown isn't wanted). */
export function renderCitedText(el: HTMLElement, text: string, citations: Moment[], onCite: OpenMoment, sourcesEl?: HTMLElement): void {
  el.empty();
  for (const part of splitCitations(text)) {
    if ("text" in part) el.appendText(part.text);
    else citeChip(el, part.cite, citations[part.cite - 1], onCite, sourcesEl);
  }
}

const OPEN = "⟦";
const CLOSE = "⟧";
const MARK_RE = new RegExp(`${OPEN}(\\d+)${CLOSE}`, "g");

/**
 * Render an answer as Markdown (Obsidian's renderer: lists, bold, links, code),
 * with [n] markers turned into citation chips. Resolves when rendered; stale
 * renders into the same element are dropped.
 */
export async function renderCitedMarkdown(
  app: App,
  owner: Component,
  el: HTMLElement,
  text: string,
  citations: Moment[],
  onCite: OpenMoment,
  sourcesEl?: HTMLElement,
): Promise<void> {
  const seq = String(Number(el.dataset.renderSeq ?? "0") + 1);
  el.dataset.renderSeq = seq;
  const md = splitCitations(text)
    .map((p) => ("text" in p ? p.text : `${OPEN}${p.cite}${CLOSE}`))
    .join("");
  const tmp = createDiv();
  try {
    await MarkdownRenderer.render(app, md, tmp, "", owner);
  } catch {
    tmp.empty();
    tmp.setText(text);
  }
  if (el.dataset.renderSeq !== seq) return;
  // Swap text-node markers for chips.
  const walker = document.createTreeWalker(tmp, NodeFilter.SHOW_TEXT);
  const hits: Text[] = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) if ((n.nodeValue ?? "").includes(OPEN)) hits.push(n as Text);
  for (const node of hits) {
    const frag = document.createDocumentFragment();
    const s = node.nodeValue ?? "";
    let last = 0;
    for (const m of s.matchAll(MARK_RE)) {
      const leading=s.slice(last,m.index),word=leading.match(/\S+\s*$/)?.[0]??'';
      if(leading.length>word.length)frag.append(leading.slice(0,-word.length));
      const holder = createSpan({cls:"ws-cite-run"});
      holder.append(word.trimEnd());
      const n = Number(m[1]);
      citeChip(holder, n, citations[n - 1], onCite, sourcesEl);
      frag.append(holder);
      last = m.index! + m[0].length;
      const punctuation=s.slice(last).match(/^[.,;:!?]+/);if(punctuation){holder.append(punctuation[0]);last+=punctuation[0].length;}
    }
    if (last < s.length) frag.append(s.slice(last));
    node.replaceWith(frag);
  }
  el.empty();
  el.append(...Array.from(tmp.childNodes));
}

/** "▸ 3 sources": a collapsible list of compact moment rows (Claudian's activity rows). */
export function renderSources(
  parent: HTMLElement,
  citations: Moment[],
  onOpen: OpenMoment,
  opts: { open?: boolean; label?: string } = {},
): HTMLElement {
  const box = parent.createDiv({ cls: "ws-sources" });
  const head = box.createDiv({ cls: "ws-sources-head", attr: { role: "button", tabindex: "0" } });
  const chev = head.createSpan({ cls: "ws-chev" });
  head.createSpan({ text: opts.label ?? `${citations.length} source${citations.length === 1 ? "" : "s"}` });
  const list = box.createDiv({ cls: "ws-sources-list" });
  citations.forEach((m, i) => {
    const row = renderMoment(list, m, { index: i + 1, onOpen, compact: true });
    row.dataset.cite = String(i + 1);
  });
  const set = (open: boolean) => {
    box.toggleClass("is-open", open);
    setIcon(chev, open ? "chevron-down" : "chevron-right");
  };
  set(!!opts.open);
  const toggle = () => set(!box.hasClass("is-open"));
  head.addEventListener("click", toggle);
  head.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      toggle();
    }
  });
  return box;
}

// ------------------------------------------------------------ evidence

/** Evidence marker: filled dot = matched by time and meaning, hollow = meaning only. */
export function evidenceDot(parent: HTMLElement, e: Pick<Excerpt, "match">): HTMLElement {
  const dot = parent.createSpan({ cls: `ws-evdot${e.match === "meaning" ? " is-hollow" : ""}` });
  setTooltip(dot, e.match === "meaning" ? "Matched by meaning only" : "Matched by time and meaning");
  return dot;
}

// ------------------------------------------------------------ small controls

export function iconButton(parent: HTMLElement, icon: string, label: string, onClick: (e: MouseEvent) => void, cls = ""): HTMLElement {
  const b = parent.createEl("button", { cls: `clickable-icon ws-icon-btn ${cls}`.trim(), attr: { "aria-label": label } });
  setIcon(b, icon);
  b.addEventListener("click", onClick);
  return b;
}

/** A quiet text button. */
export function textButton(parent: HTMLElement, text: string, onClick: (e: MouseEvent) => void, cls = ""): HTMLButtonElement {
  const b = parent.createEl("button", { cls: `ws-tbtn ${cls}`.trim(), text });
  b.addEventListener("click", (e) => {
    e.stopPropagation();
    onClick(e);
  });
  return b;
}

/** Obsidian's own toggle with a label in front. */
export function switchControl(parent: HTMLElement, label: string, on: boolean, onChange: (v: boolean) => void): HTMLElement {
  const wrap = parent.createDiv({ cls: "ws-switch" });
  const l = wrap.createSpan({ cls: "ws-switch-label", text: label });
  const t = new ToggleComponent(wrap).setValue(on).onChange(onChange);
  l.addEventListener("click", () => t.setValue(!t.getValue()));
  return wrap;
}
