// Map meeting notes to their lines in the meeting's vault note.
// The app's vault writer emits, under "## Notes":
//   - **Topic.** enhanced text [[links]] ^e3
// with block ids assigned once per note id. The API may send `blockId` on each
// note; when it doesn't, we match by text, then fall back to order.

import type { Note } from "./types";

export interface NoteLine {
  blockId: string;
  text: string;
  line: number;
}

/** Bulleted lines carrying a `^eN` block id in the "## Notes" section (or anywhere, if there is no such heading). */
export function noteLines(markdown: string): NoteLine[] {
  const lines = markdown.split(/\r?\n/);
  const start = lines.findIndex((l) => /^##\s+Notes\s*$/i.test(l));
  const out: NoteLine[] = [];
  for (let i = start >= 0 ? start + 1 : 0; i < lines.length; i++) {
    const l = lines[i]!;
    if (start >= 0 && /^##\s/.test(l)) break;
    const m = /^\s*[-*]\s+(.*?)\s+\^(e\d+)\s*$/.exec(l);
    if (m) out.push({ blockId: m[2]!, text: m[1]!, line: i });
  }
  return out;
}

const norm = (s: string) =>
  s
    .toLowerCase()
    .replace(/\*\*|\[\[[^\]]*\]\]|\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();

/** note id → block id ("e1"). */
export function mapBlockIds(markdown: string, notes: Note[]): Map<string, string> {
  const lines = noteLines(markdown);
  const out = new Map<string, string>();
  const used = new Set<string>();
  const known = new Set(lines.map((l) => l.blockId));
  for (const n of notes) {
    if (n.blockId && known.has(n.blockId)) {
      out.set(n.id, n.blockId);
      used.add(n.blockId);
    }
  }
  // Text match: the line holds the enhanced text (or the shorthand, when not enhanced).
  for (const n of notes) {
    if (out.has(n.id)) continue;
    const probes = [n.enhanced?.text, n.enhanced?.topic && n.enhanced.text ? `${n.enhanced.topic} ${n.enhanced.text}` : undefined, n.text]
      .filter((x): x is string => !!x)
      .map((x) => norm(x).slice(0, 48))
      .filter((x) => x.length >= 4);
    const hit = lines.find((l) => !used.has(l.blockId) && probes.some((p) => norm(l.text).includes(p)));
    if (hit) {
      out.set(n.id, hit.blockId);
      used.add(hit.blockId);
    }
  }
  // Order fallback only when counts line up exactly.
  if (lines.length === notes.length) {
    notes.forEach((n, i) => {
      const l = lines[i]!;
      if (!out.has(n.id) && !used.has(l.blockId)) {
        out.set(n.id, l.blockId);
        used.add(l.blockId);
      }
    });
  }
  return out;
}
