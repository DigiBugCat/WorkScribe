// Turning drops (Finder files, Obsidian file-explorer items, text) into attachments.

import { TFile, TFolder, type TAbstractFile } from "obsidian";
import { parseObsidianOpen } from "../lib/format";
import type { Attachment } from "../lib/types";
import type WorkScribePlugin from "../main";

export type NamedAttachment = Attachment & { name: string };

interface DragManagerLike {
  draggable?: { type?: string; file?: TAbstractFile; files?: TAbstractFile[] } | null;
}

/** Absolute filesystem path of a dropped Finder file (Electron ≥ 32 removed File.path). */
export function pathOfFile(f: File): string | null {
  const legacy = (f as File & { path?: string }).path;
  if (legacy) return legacy;
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const electron = require("electron") as { webUtils?: { getPathForFile(f: File): string } };
    const p = electron.webUtils?.getPathForFile(f);
    return p || null;
  } catch {
    return null;
  }
}

export function vaultFileAttachment(plugin: WorkScribePlugin, f: TAbstractFile): NamedAttachment | null {
  if (!(f instanceof TFile)) return null;
  const abs = plugin.absolutePath(f.path);
  return abs ? { path: abs, name: f.basename } : null;
}

function expand(f: TAbstractFile): TAbstractFile[] {
  return f instanceof TFolder ? f.children.flatMap(expand) : [f];
}

export function collectDropped(plugin: WorkScribePlugin, e: DragEvent): NamedAttachment[] {
  const out: NamedAttachment[] = [];
  const seen = new Set<string>();
  const add = (a: NamedAttachment | null) => {
    if (!a) return;
    const key = "path" in a ? a.path : a.text;
    if (seen.has(key)) return;
    seen.add(key);
    out.push(a);
  };

  // 1. Items dragged from Obsidian's own file explorer / tabs.
  const dm = (plugin.app as unknown as { dragManager?: DragManagerLike }).dragManager;
  const d = dm?.draggable;
  if (d?.file) expand(d.file).forEach((f) => add(vaultFileAttachment(plugin, f)));
  if (d?.files) d.files.flatMap(expand).forEach((f) => add(vaultFileAttachment(plugin, f)));

  const dt = e.dataTransfer;
  if (!dt) return out;

  // 2. Files from Finder.
  for (const f of Array.from(dt.files)) {
    const p = pathOfFile(f);
    if (p) add({ path: p, name: f.name });
  }
  if (out.length) return out;

  // 3. obsidian://open links (another vault window, or a link drag) or plain text.
  const text = dt.getData("text/plain");
  if (!text) return out;
  const lines = text.split(/\r?\n/).filter(Boolean);
  const links = lines.map(parseObsidianOpen);
  if (links.length && links.every((l) => l)) {
    for (const l of links) {
      const f = plugin.app.metadataCache.getFirstLinkpathDest(l!.file, "") ?? plugin.app.vault.getAbstractFileByPath(l!.file);
      if (f) add(vaultFileAttachment(plugin, f));
    }
    return out;
  }
  const wikis = [...text.matchAll(/\[\[([^\]|#]+)/g)].map((m) => m[1]!);
  if (wikis.length && text.replace(/!?\[\[[^\]]+\]\]/g, "").trim() === "") {
    for (const w of wikis) {
      const f = plugin.app.metadataCache.getFirstLinkpathDest(w, "");
      if (f) add(vaultFileAttachment(plugin, f));
    }
    if (out.length) return out;
  }
  add(textAttachment(text));
  return out;
}

export function textAttachment(text: string): NamedAttachment {
  const first = text.trim().split(/\n/)[0]!.slice(0, 40);
  return { text, name: `“${first}${text.length > 40 ? "…" : ""}”` };
}
