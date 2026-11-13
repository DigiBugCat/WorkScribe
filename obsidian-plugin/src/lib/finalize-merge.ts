// Putting the app's finalize insertions into the editor without taking anything out of it.
//
// Finalize is a request: between sending it and reading the answer the person can keep typing, and Obsidian
// can load the app's own write of the file into the editor. So when the answer arrives the editor holds one of
//   the text the app finalized ("pencil"),
//   that text with the insertions already in it ("finalized"),
//   either of them with something typed since.
// The answer says exactly what was inserted and where (offsets in the pencil text). This works out where those
// places are in what the editor holds now. It only ever adds the insertions, or leaves them where they are.
// Pure: no editor, no Obsidian.

export interface Insertion { at: number; text: string }

export interface FinalizeMerge {
  /** Which known text the editor was closest to. */
  base: 'pencil' | 'finalized';
  /**
   * Ranges of the current text to take out first, outside undo history: insertions the editor already shows.
   * Taking them out and putting them back in one undoable change is what makes Undo restore the pencil note.
   * Ascending, not overlapping. Empty when the editor does not show them yet.
   */
  restore: { from: number; to: number }[];
  /** The insertions as one change. Positions are in the text after `restore`. Ascending. */
  insert: { from: number; insert: string }[];
  /** The text the editor holds afterwards. Every character of `current` is in it, in order. */
  text: string;
}

/** The one stretch that differs between two texts: a[from, to) became b[from, end). */
export function changedRegion(a: string, b: string): { from: number; to: number; end: number } {
  let from = 0, to = a.length, end = b.length;
  while (from < to && from < end && a.charCodeAt(from) === b.charCodeAt(from)) from++;
  while (to > from && end > from && a.charCodeAt(to - 1) === b.charCodeAt(end - 1)) { to--; end--; }
  return { from, to, end };
}

export function mergeFinalized(current: string, pencil: string, insertions: readonly Insertion[]): FinalizeMerge {
  // Same order as the app writes them: ascending, and as listed where two share a place.
  const sorted = insertions.map((i, n) => ({ ...i, at: Math.max(0, Math.min(pencil.length, i.at)), n })).sort((a, b) => a.at - b.at || a.n - b.n);
  // The finalized text, and where each insertion sits in it.
  let finalized = '', cursor = 0;
  const placed: { from: number; to: number; text: string }[] = [];
  for (const i of sorted) {
    finalized += pencil.slice(cursor, i.at); cursor = i.at;
    placed.push({ from: finalized.length, to: finalized.length + i.text.length, text: i.text });
    finalized += i.text;
  }
  finalized += pencil.slice(cursor);

  const fromPencil = changedRegion(pencil, current), fromFinalized = changedRegion(finalized, current);
  const size = (r: { from: number; to: number; end: number }) => (r.to - r.from) + (r.end - r.from);
  if (sorted.length && size(fromFinalized) < size(fromPencil)) {
    // The editor already shows the finalized text, perhaps with something typed since. An insertion the typing
    // touched is left as the person made it; the others are found where they are now.
    const r = fromFinalized, shift = r.end - r.to;
    const there = placed
      .filter(p => p.to <= r.from || p.from >= r.to)
      .map(p => (p.from >= r.to ? { from: p.from + shift, to: p.to + shift, text: p.text } : p))
      .filter(p => p.to > p.from && current.slice(p.from, p.to) === p.text);
    let removed = 0;
    const insert = there.map(p => { const at = p.from - removed; removed += p.to - p.from; return { from: at, insert: p.text }; });
    return { base: 'finalized', restore: there.map(p => ({ from: p.from, to: p.to })), insert, text: current };
  }
  // The editor shows the pencil text, perhaps with something typed since. A place before the typing stays where
  // it was; a place after it moves with the text; a place the typing replaced goes right after what was typed.
  const r = fromPencil, shift = r.end - r.to;
  const insert = sorted.map(i => ({ from: i.at < r.from ? i.at : i.at >= r.to ? i.at + shift : r.end, insert: i.text }));
  let text = '', at = 0;
  for (const i of insert) { text += current.slice(at, i.from) + i.insert; at = i.from; }
  text += current.slice(at);
  return { base: 'pencil', restore: [], insert, text };
}
