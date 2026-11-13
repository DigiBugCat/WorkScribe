import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ownedRange } from '../src/lib/anchors';

// "Let AI rewrite" removes the text a person wrote under an AI line. It asks the app first, and the note can be
// edited while the app answers; the range to remove must be found again afterwards, never remembered.

const note = 'ship date?\nmoved to Nov 4, per Dana\nbudget\n';
const owned = { from: 11, to: 35, text: 'moved to Nov 4, per Dana' };
const blocks = [{ id: 'a', owned }, { id: 'b' }];

test('the owned text and the line break before it', () => {
  assert.equal(note.slice(owned.from, owned.to), owned.text);
  assert.deepEqual(ownedRange(blocks, 'a', note), { from: 10, to: 35 });
  const range = ownedRange(blocks, 'a', note)!;
  assert.equal(note.slice(0, range.from) + note.slice(range.to), 'ship date?\nbudget\n');
});

test('a range remembered from before an edit removes nothing', () => {
  // The person typed a line above while the request was out: the old offsets now point into other text.
  const edited = 'agenda\n' + note;
  assert.notEqual(edited.slice(owned.from, owned.to), owned.text);
  assert.equal(ownedRange(blocks, 'a', edited), null, 'stale offsets must not be used');
  // With the ledger caught up, the same text is found where it now is.
  const moved = [{ id: 'a', owned: { ...owned, from: owned.from + 7, to: owned.to + 7 } }];
  const range = ownedRange(moved, 'a', edited)!;
  assert.equal(edited.slice(0, range.from) + edited.slice(range.to), 'agenda\nship date?\nbudget\n');
});

test('already handed back, unknown line, or text that no longer matches', () => {
  assert.equal(ownedRange(blocks, 'b', note), null, 'the line owns nothing');
  assert.equal(ownedRange(blocks, 'zzz', note), null);
  assert.equal(ownedRange([{ id: 'a', owned: { ...owned, text: 'something else entirely!!' } }], 'a', note), null);
  assert.equal(ownedRange([{ id: 'a', owned: { from: 30, to: 400, text: 'x' } }], 'a', note), null, 'past the end of the note');
});

test('owned text at the very start has no line break to take', () => {
  assert.deepEqual(ownedRange([{ id: 'a', owned: { from: 0, to: 4, text: 'ship' } }], 'a', note), { from: 0, to: 4 });
});
