import { parser, GFM } from "@lezer/markdown";
import type { ChangeDesc } from "@codemirror/state";

export interface OwnedText { from: number; to: number; text: string }
export interface NoteImage { target: string; path?: string }
export interface Block { kind?: "text" | "image"; shorthand?: string; images?: NoteImage[]; id: string; from: number; to: number; text: string; at?: number; section?: string; owned?: OwnedText }
export interface NoteDocument {
  insertions?: {at:number;text:string}[]; path: string; source: string; revision: number; blocks: Block[]; finalized?: boolean }
const markdown = parser.configure(GFM);

/** UTF-16 offsets, shared by CM6 and NSString. No anchors are written into Markdown. */
export function parseBlocks(source: string): Omit<Block, "id">[] {
  const front = source.match(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/)?.[0].length ?? 0;
  const tree = markdown.parse(source.slice(0, front).replace(/[^\r\n]/g, " ") + source.slice(front));
  const out: Omit<Block, "id">[] = [];
  let section = "";
  const list=(node: import('@lezer/common').SyntaxNode)=>{
    for(let item=node.firstChild;item;item=item.nextSibling)if(item.name==='ListItem'){
      let nested:import('@lezer/common').SyntaxNode|null=null;
      for(let child=item.firstChild;child;child=child.nextSibling)if(child.name==='BulletList'||child.name==='OrderedList'){nested=child;break;}
      const lineStart=source.lastIndexOf('\n',item.from-1)+1;
      const from=/^\s*$/.test(source.slice(lineStart,item.from))?lineStart:item.from;
      let to=nested?nested.from:item.to;
      while(to>from&&/\s/.test(source[to-1]))to--;
      if(to>from&&!/^\s*(?:[-+*]|\d+[.)])(?:\s+\[.\])?\s*$/.test(source.slice(from,to)))out.push({from,to,text:source.slice(from,to),section});
      if(nested)list(nested);
    }
  };
  for(let n=tree.topNode.firstChild;n;n=n.nextSibling){
    if(/Heading[1-6]?$/.test(n.name)){section=source.slice(n.from,n.to).replace(/^#+\s*/, '');continue;}
    if(n.name==='Paragraph')out.push({from:n.from,to:n.to,text:source.slice(n.from,n.to),section});
    if(n.name==='BulletList'||n.name==='OrderedList')list(n);
  }
  return out.map(block => ({ ...block, ...imageContent(block.text, source) }));
}

/** Positions disambiguate copies; unique text survives moves; overlap preserves edits.
 * Tombstones are supplied only during undo/redo, so paste cannot resurrect an identity. */
export function reconcile(source: string, previous: Block[], at?: number, changes?: ChangeDesc,
                          makeId: () => string = () => crypto.randomUUID(), restore: Block[] = []): Block[] {
  const ownership = new Map(previous.filter(b => b.owned).map(b => {
    const old = b.owned!;
    let from = changes ? changes.mapPos(old.from, -1) : source.indexOf(old.text);
    if (!changes && (from < 0 || source.indexOf(old.text, from + 1) >= 0)) from = -1;
    const to = changes ? changes.mapPos(old.to, 1) : from < 0 ? -1 : from + old.text.length;
    return [b.id, { from, to, text: source.slice(Math.max(0,from), Math.max(0,to)) }];
  }));
  const parsed = parseBlocks(source).filter(p => ![...ownership.values()].some(o => p.from >= o.from && p.to <= o.to && o.to > o.from)).map(p => {
    const own=[...ownership.values()].find(o=>p.from<o.from && p.to>=o.to && o.to>o.from);
    if(!own)return p;
    const to=own.from-1;return {...p,to,text:source.slice(p.from,to)};
  });
  const result: (Block | undefined)[] = parsed.map(() => undefined);
  const used = new Set<string>();
  const mapped = previous.map(b => ({ ...b,
    from: changes ? changes.mapPos(b.from, 1) : b.from,
    to: changes ? changes.mapPos(b.to, -1) : b.to,
  }));
  const assign = (i: number, old: Block) => {
    if (used.has(old.id)) return;
    const next = parsed[i];
    let owned: OwnedText | undefined;
    if (old.owned) {
      const mapped = ownership.get(old.id)!;
      const from = mapped.from, to = mapped.to;
      if (from >= next.to && to > from && /^\s*$/.test(source.slice(next.to, from)))
        owned = { from, to, text: source.slice(from, to) };
    }
    result[i] = { ...next, id: old.id, at: old.at, ...(owned ? { owned } : {}) };
    used.add(old.id);
  };
  parsed.forEach((p, i) => {
    const matches = mapped.filter(b => b.from === p.from && b.to === p.to && b.text === p.text);
    if (matches.length === 1) assign(i, previous.find(b => b.id === matches[0].id)!);
  });
  parsed.forEach((p, i) => {
    if (result[i]) return;
    const matches = previous.filter(b => !used.has(b.id) && b.text === p.text);
    const targets = parsed.filter((q, j) => !result[j] && q.text === p.text);
    if (matches.length === 1 && targets.length === 1) assign(i, matches[0]);
  });
  parsed.forEach((p, i) => {
    if (result[i]) return;
    const candidates = mapped.filter(b => !used.has(b.id) && b.to > b.from && Math.max(b.from, p.from) < Math.min(b.to, p.to)
      && (changes || closeText(b.text, p.text)));
    if (candidates.length) assign(i, previous.find(b => b.id === candidates[0].id)!);
  });
  parsed.forEach((p, i) => {
    if (result[i]) return;
    const old = restore.find(b => !used.has(b.id) && b.text === p.text);
    if (old) assign(i, old); else result[i] = { ...p, id: makeId(), at };
  });
  return result as Block[];
}

export function quoteAI(text: string): string {
  return text.split(/\r?\n/).map(line => "> " + line).join("\n");
}

/** Without transactions, never attach old evidence to unrelated replacement text. */
function closeText(a: string, b: string): boolean {
  let prefix=0, suffix=0;
  while(prefix<Math.min(a.length,b.length) && a[prefix]===b[prefix]) prefix++;
  while(suffix<Math.min(a.length,b.length)-prefix && a[a.length-1-suffix]===b[b.length-1-suffix]) suffix++;
  return (prefix+suffix)/Math.max(1,Math.min(a.length,b.length)) >= .45;
}

/** Extract local raster embeds only. Never fetch remote images or interpret inline code as content. */
export function imageContent(text: string, source = text): { kind: 'text' | 'image'; shorthand: string; images: NoteImage[] } {
  const images: NoteImage[] = [];
  const ranges: { from: number; to: number }[] = [];
  const code: { from: number; to: number }[] = [];
  markdown.parse(text).iterate({ enter(node) {
    if (node.name === 'InlineCode' || node.name === 'FencedCode' || node.name === 'CodeBlock') code.push(node);
  }});
  // Markdown destinations can contain a single nested pair, spaces when angle-bracketed, and an optional title.
  const re = /!\[\[([^\]\n]+)\]\]|!\[[^\]\n]*\]\(\s*(<[^>\n]+>|(?:[^()\s]|\([^()]*\))+)\s*(?:["'][^\n]*?["']\s*)?\)/g;
  for (const match of text.matchAll(re)) {
    const from = match.index!, to = from + match[0].length;
    if (code.some(c => from >= c.from && from < c.to)) continue;
    let target = match[1] ? match[1].split('|')[0] : match[2].replace(/^<|>$/g, '');
    try { target = decodeURIComponent(target); } catch { /* unresolved literal */ }
    target = target.split('#')[0];
    if (match[1] && !/\.(png|jpe?g|gif|webp|heic|bmp|tiff?|svg)$/i.test(target)) continue;
    images.push({ target }); ranges.push({ from, to });
  }
  const definitions = new Map([...source.matchAll(/^ {0,3}\[([^\]\n]+)\]:\s*(<[^>]+>|\S+)/gm)].map(m => [m[1].toLowerCase(), m[2].replace(/^<|>$/g, '')]));
  for (const match of text.matchAll(/!\[([^\]\n]*)\]\[([^\]\n]*)\]/g)) {
    const from = match.index!, to = from + match[0].length;
    if (code.some(c => from >= c.from && from < c.to)) continue;
    const key = (match[2] || match[1]).toLowerCase();
    images.push({ target: definitions.get(key) ?? `reference:${key}` }); ranges.push({ from, to });
  }
  let shorthand = text;
  for (const r of ranges.sort((a,b) => b.from - a.from)) shorthand = shorthand.slice(0, r.from) + shorthand.slice(r.to);
  shorthand = shorthand.replace(/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/, '').trim();
  return { kind: images.length && !shorthand ? 'image' : 'text', shorthand, images };
}
