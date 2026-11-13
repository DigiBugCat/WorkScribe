import { test } from 'node:test';
import assert from 'node:assert/strict';
import { changedRegion, mergeFinalized, type FinalizeMerge, type Insertion } from '../src/lib/finalize-merge';

// Finalize's answer says what the app inserted, at offsets of the text it finalized. By the time the answer is
// read the editor may hold something else. mergeFinalized adds the insertions to what the editor holds; it never
// takes a character of the editor's text away.

const pencil = '---\nworkscribe: m\n---\n\n- ship date\n- budget\n';
const body = pencil.indexOf('- ship date');            // after the properties and their blank line
const ship = pencil.indexOf('\n- budget');             // the end of "- ship date"
const insertions: Insertion[] = [
  { at: body, text: '*Brief.*\n\n' },
  { at: ship, text: '\n  *Moved to Nov 4.*' },
  { at: pencil.length, text: '\n## Action items\n\n- [ ] Follow up\n' },
];
const finalized = '---\nworkscribe: m\n---\n\n*Brief.*\n\n- ship date\n  *Moved to Nov 4.*\n- budget\n\n## Action items\n\n- [ ] Follow up\n';

/** What an editor does with the result: `restore` first, then `insert`. */
function apply(current: string, m: FinalizeMerge): { restored: string; text: string } {
  let restored = current;
  for (const r of [...m.restore].reverse()) restored = restored.slice(0, r.from) + restored.slice(r.to);
  let text = restored;
  for (const i of [...m.insert].reverse()) text = text.slice(0, i.from) + i.insert + text.slice(i.from);
  return { restored, text };
}
/** Every character of `part` appears in `whole`, in order. */
function keeps(whole: string, part: string): boolean {
  let at = 0;
  for (const ch of part) { at = whole.indexOf(ch, at); if (at < 0) return false; at++; }
  return true;
}

test('the fixture is what the app would write', () => {
  assert.equal(pencil.slice(0, body), '---\nworkscribe: m\n---\n\n');
  assert.equal(apply(pencil, mergeFinalized(pencil, pencil, insertions)).text, finalized);
});

test('nothing typed: the insertions go in where the app put them', () => {
  const m = mergeFinalized(pencil, pencil, insertions);
  assert.equal(m.base, 'pencil'); assert.deepEqual(m.restore, []);
  assert.equal(m.text, finalized);
  assert.equal(apply(pencil, m).text, m.text);
});

test('a line typed at the end while the request was out is kept, and the tail goes after it', () => {
  const current = pencil + '- one more thing\n';
  const m = mergeFinalized(current, pencil, insertions);
  assert.equal(m.base, 'pencil');
  assert.equal(m.text, '---\nworkscribe: m\n---\n\n*Brief.*\n\n- ship date\n  *Moved to Nov 4.*\n- budget\n- one more thing\n\n## Action items\n\n- [ ] Follow up\n');
  assert.equal(apply(current, m).text, m.text);
});

test('words added to the line an insertion hangs under: the insertion follows them', () => {
  const current = pencil.replace('- ship date', '- ship date, per Dana');
  const m = mergeFinalized(current, pencil, insertions);
  assert.ok(m.text.includes('- ship date, per Dana\n  *Moved to Nov 4.*\n- budget'), m.text);
  assert.ok(keeps(m.text, current));
});

test('typing in the middle moves the later insertions with the text', () => {
  const current = pencil.replace('- budget\n', '- budget\n- hiring freeze\n');
  const m = mergeFinalized(current, pencil, insertions);
  assert.equal(m.text, finalized.replace('- budget\n', '- budget\n- hiring freeze\n'));
});

test('the editor already shows the finalized file: take the insertions out, put them back as one change', () => {
  const m = mergeFinalized(finalized, pencil, insertions);
  assert.equal(m.base, 'finalized');
  const r = apply(finalized, m);
  assert.equal(r.restored, pencil, 'what Undo goes back to');
  assert.equal(r.text, finalized);
  assert.equal(m.text, finalized);
});

test('the editor shows the finalized file and a line typed after it: nothing is added twice, nothing is lost', () => {
  const current = finalized + '- typed after the reload\n';
  const m = mergeFinalized(current, pencil, insertions);
  assert.equal(m.base, 'finalized');
  const r = apply(current, m);
  assert.equal(r.text, current);
  assert.equal(r.restored, pencil + '- typed after the reload\n', 'Undo keeps the typed line');
  assert.equal(current.split('*Brief.*').length, 2);
});

test('an insertion the person edited after the reload is left as they made it', () => {
  const current = finalized.replace('*Moved to Nov 4.*', '*Moved to Nov 5, not 4.*');
  const m = mergeFinalized(current, pencil, insertions);
  assert.equal(m.base, 'finalized');
  const r = apply(current, m);
  assert.equal(r.text, current);
  assert.ok(r.restored.includes('*Moved to Nov 5, not 4.*'), 'the edited one stays in the text even after Undo');
  assert.ok(!r.restored.includes('*Brief.*'));
});

test('no insertions: the text is left exactly as it is', () => {
  const current = pencil + 'x';
  const m = mergeFinalized(current, pencil, []);
  assert.deepEqual(m.restore, []); assert.deepEqual(m.insert, []); assert.equal(m.text, current);
});

test('two insertions at the same place keep the order the app listed them in', () => {
  const m = mergeFinalized('a', 'a', [{ at: 1, text: 'X' }, { at: 1, text: 'Y' }]);
  assert.equal(m.text, 'aXY');
  assert.equal(apply('a', m).text, 'aXY');
});

test('whatever the editor holds, every character of it is still there afterwards', () => {
  // A small deterministic sweep: one edit (insert, delete or replace) anywhere in the pencil or the finalized text.
  let seed = 7; const rand = (n: number) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  for (let n = 0; n < 4000; n++) {
    const base = rand(2) ? pencil : finalized;
    const from = rand(base.length + 1), to = Math.min(base.length, from + rand(3) * rand(12));
    const typed = ['', 'x', '- new line\n', '\n', '*Brief.*', '  *Moved'][rand(6)]!;
    const current = base.slice(0, from) + typed + base.slice(to);
    const m = mergeFinalized(current, pencil, insertions);
    const r = apply(current, m);
    assert.equal(r.text, m.text, 'the changes produce the announced text');
    assert.ok(keeps(m.text, current), `lost text.\ncurrent: ${JSON.stringify(current)}\nresult: ${JSON.stringify(m.text)}`);
    assert.ok(keeps(current, r.restored), 'restore only removes');
    for (let i = 1; i < m.restore.length; i++) assert.ok(m.restore[i]!.from >= m.restore[i - 1]!.to);
    for (let i = 1; i < m.insert.length; i++) assert.ok(m.insert[i]!.from >= m.insert[i - 1]!.from);
    for (const x of m.restore) assert.ok(insertions.some(i => i.text === current.slice(x.from, x.to)), 'only an insertion, verbatim, is ever taken out');
  }
});

test('changedRegion: the one stretch that differs', () => {
  assert.deepEqual(changedRegion('abc', 'abc'), { from: 3, to: 3, end: 3 });
  assert.deepEqual(changedRegion('abc', 'abXc'), { from: 2, to: 2, end: 3 });
  assert.deepEqual(changedRegion('abXc', 'abc'), { from: 2, to: 3, end: 2 });
  assert.deepEqual(changedRegion('', 'q'), { from: 0, to: 0, end: 1 });
});
