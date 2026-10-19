// Pure formatting + link helpers (unit-tested; no `obsidian` import).

import { realpathSync } from "node:fs";
import { dirname, basename, join, resolve, isAbsolute } from "node:path";
import type { Moment } from "./types";

/** 492 → "08:12"; 3723 → "1:02:03". */
export function clock(sec: number | undefined): string {
  if (sec === undefined || !Number.isFinite(sec) || sec < 0) sec = 0;
  const s = Math.floor(sec);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  const mm = String(m).padStart(2, "0");
  const ss = String(r).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

/** 1920 → "32 min"; 45 → "45 s"; 4500 → "1 h 15 min". */
export function duration(sec: number): string {
  if (sec < 60) return `${Math.round(sec)} s`;
  const m = Math.round(sec / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
}

export function meetingUrl(meetingId: string, at?: number): string {
  const base = `workscribe://meeting/${encodeURIComponent(meetingId)}`;
  return at !== undefined && Number.isFinite(at) ? `${base}?t=${Math.floor(at)}` : base;
}

export function obsidianOpenUrl(vault: string, file: string): string {
  return `obsidian://open?vault=${encodeURIComponent(vault)}&file=${encodeURIComponent(file)}`;
}

/** Resolve existing parents too: a new document and any symlinked vault share an identity. */
export function canonicalPath(p: string): string {
  let ancestor = isAbsolute(p) ? p : resolve(p);
  const tail: string[] = [];
  while (true) {
    try { return join(realpathSync.native(ancestor), ...tail.reverse()); }
    catch {
      const parent = dirname(ancestor);
      if (parent === ancestor) return resolve(p);
      tail.push(basename(ancestor)); ancestor = parent;
    }
  }
}

/** Absolute path → vault-relative path, or null when outside the vault. Handles trailing slashes. */
export function vaultRelative(absPath: string, vaultBase: string | null | undefined): string | null {
  if (!vaultBase) return null;
  absPath = canonicalPath(absPath);
  const base = canonicalPath(vaultBase).replace(/\/+$/, "");
  if (absPath === base) return null;
  if (!absPath.startsWith(base + "/")) return null;
  return absPath.slice(base.length + 1);
}

export function fileUrl(absPath: string): string {
  return "file://" + absPath.split("/").map(encodeURIComponent).join("/");
}

export interface LinkContext {
  vaultName: string;
  /** Absolute path of the vault root, or null when unknown. */
  vaultBase: string | null;
}

/** Where clicking a moment goes: a vault file opened in Obsidian, or an external URL handed to macOS. */
export type MomentTarget =
  | { kind: "vault"; path: string; subpath?: string }
  | { kind: "external"; url: string };

export function momentTarget(m: Moment, ctx: LinkContext): MomentTarget | null {
  if (m.path) {
    const rel = vaultRelative(m.path, ctx.vaultBase);
    if (rel) {
      const t: MomentTarget = { kind: "vault", path: rel };
      if (m.page !== undefined && /\.pdf$/i.test(rel)) t.subpath = `#page=${m.page}`;
      return t;
    }
  }

  if (m.link) {
    // obsidian://open links into this vault are handled in-app too.
    const vf = parseObsidianOpen(m.link);
    if (vf && vf.vault === ctx.vaultName) return { kind: "vault", path: vf.file };
    return { kind: "external", url: m.link };
  }
  if (m.meetingId) return { kind: "external", url: meetingUrl(m.meetingId, m.start) };
  if (m.path) {
    let url = fileUrl(m.path);
    if (m.page !== undefined && /\.pdf$/i.test(m.path)) url += `#page=${m.page}`;
    return { kind: "external", url };
  }
  return null;
}

export function parseObsidianOpen(url: string): { vault: string; file: string } | null {
  if (!url.startsWith("obsidian://open")) return null;
  const q = url.indexOf("?");
  if (q < 0) return null;
  const params = new URLSearchParams(url.slice(q + 1));
  const vault = params.get("vault");
  const file = params.get("file") ?? params.get("path");
  return vault !== null && file ? { vault, file } : null;
}

/** "Marcus · 08:12", "p. 6", "at 03:05", "clip". */
export function momentWhere(m: Moment): string {
  const parts: string[] = [];
  if (m.speaker) parts.push(m.speaker);
  if (m.page !== undefined) parts.push(`p. ${m.page}`);
  if (m.start !== undefined) parts.push(m.kind === "meeting" ? clock(m.start) : `at ${clock(m.start)}`);
  return parts.join(" · ");
}

const escapeLinkText = (s: string) => s.replace(/([[\]|])/g, "\\$1");

/** Markdown to insert into a note for a moment. Vault files become wikilinks so Obsidian tracks renames. */
export function momentMarkdown(m: Moment, ctx: LinkContext): string {
  const t = momentTarget(m, ctx);
  const where = momentWhere(m);
  const label = where ? `${m.title} · ${where}` : m.title;
  if (!t) return label;
  if (t.kind === "vault") {
    const target = t.path.replace(/\.md$/i, "") + (t.subpath ?? "");
    return `[[${target}|${label.replace(/[|\]]/g, " ")}]]`;
  }
  return `[${escapeLinkText(label)}](${t.url.replace(/ /g, "%20").replace(/\)/g, "%29")})`;
}

export type CitedPart = { text: string } | { cite: number };

/**
 * Split answer text on citation markers: [1], [1, 2], [1][2], [Source:1], [Source: 1, 2].
 * Numbers are 1-based indexes into the citations list.
 */
export function splitCitations(text: string): CitedPart[] {
  const out: CitedPart[] = [];
  const re = /\[(?:Source:\s*)?(\d+(?:\s*,\s*(?:Source:\s*)?\d+)*)\]/g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) out.push({ text: text.slice(last, m.index) });
    for (const n of m[1]!.split(",")) out.push({ cite: Number(n.replace(/\D/g, "")) });
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push({ text: text.slice(last) });
  return out;
}

/** Answer as Markdown: markers normalised to "[1]", followed by a numbered list of linked sources. */
export function citationsToMarkdown(text: string, citations: Moment[], ctx: LinkContext): string {
  const body = splitCitations(text)
    .map((p) => ("text" in p ? p.text : `[${p.cite}]`))
    .join("");
  if (!citations.length) return body;
  const list = citations.map((c, i) => `${i + 1}. ${momentMarkdown(c, ctx)}`).join("\n");
  return `${body}\n\n${list}`;
}

/** A safe-ish note filename from a title. */
export function safeFilename(s: string): string {
  return s.replace(/[\\/:*?"<>|#^[\]]/g, " ").replace(/\s+/g, " ").trim().slice(0, 120) || "Untitled";
}

/** ```workscribe-meeting``` body: `id=…`, `id: …`, or a bare id. */
export function parseBlockId(source: string): string | null {
  const m = /(?:^|\s)id\s*[=:]\s*["']?([^\s"']+)/.exec(source);
  if (m) return m[1]!;
  const bare = source.trim();
  return bare && !/\s/.test(bare) ? bare : null;
}

/** "14 s before you typed", "5 min after". */
export function relativeToTyping(excerptStart: number, typedAt: number): string {
  const d = Math.round(excerptStart - typedAt);
  const abs = Math.abs(d);
  const amount = abs < 90 ? `${abs} s` : `${Math.round(abs / 60)} min`;
  return d <= 0 ? `${amount} before you typed` : `${amount} after`;
}

/** A note name Obsidian and the filesystem both accept; matches VaultPaths.fileName in the app. */
export function noteName(title: string): string {
  let name = title.replace(/[/\\:*?"<>|#^[\]\n\r\t]/g, ' ').replace(/\s+/g, ' ').replace(/^[\s.]+|[\s.]+$/g, '');
  if (name.length > 120) name = name.slice(0, 120).trim();
  return name || 'Untitled';
}
