import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { canonicalPath, vaultRelative } from '../src/lib/format';
import { transcriptTurns } from '../src/lib/transcript-turns';
import { parseSegment, parseStatus } from '../src/lib/parse';

test('vault and documents resolve arbitrary symlink chains and reject links outside the vault', () => {
  const root = mkdtempSync(join(tmpdir(), 'ws-path-'));
  try {
    const actual = join(root, 'actual'), alias = join(root, 'alias'), chain = join(root, 'chain');
    mkdirSync(actual); symlinkSync(actual, alias); symlinkSync(alias, chain);
    writeFileSync(join(actual, 'note.md'), 'words');
    assert.equal(canonicalPath(join(chain, 'note.md')), canonicalPath(join(actual, 'note.md')));
    assert.equal(vaultRelative(join(chain, 'note.md'), actual), 'note.md');
    assert.equal(vaultRelative(join(actual, 'future', 'note.md'), chain), 'future/note.md');
    assert.equal(vaultRelative(join(actual, 'note.md'), chain + '/'), 'note.md');
    mkdirSync(join(root, 'elsewhere')); symlinkSync(join(root, 'elsewhere'), join(actual, 'escape'));
    writeFileSync(join(root, 'elsewhere', 'private.md'), 'outside');
    assert.equal(vaultRelative(join(actual, 'escape', 'private.md'), alias), null);
    assert.equal(vaultRelative(join(root, 'actual-sibling', 'note.md'), actual), null);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('realistic transcript fixture reads as five turns without changing underlying segments', () => {
  const raw = JSON.parse(readFileSync(resolve('../Tests/WorkScribeCoreTests/Golden/realrun-fragments.json'), 'utf8'));
  const segments = raw.map((s: Record<string, unknown>) => parseSegment({ ...s, speakerKey: s.speaker }));
  const before = JSON.stringify(segments);
  const turns = transcriptTurns(segments);
  assert.equal(turns.length, 5);
  assert.equal(turns.map(t => t.text.split(/\s+/).length).sort((a, b) => a - b)[2], 15);
  assert.equal(turns.map(t => t.text).join(' '), segments.map((s: { text: string }) => s.text).join(' '));
  assert.equal(turns[0]!.start, segments[0]!.start);
  assert.equal(turns[0]!.end, segments[4]!.end);
  assert.equal(JSON.stringify(segments), before);
});

test('turns preserve source, speaker identity, overrides, pauses and provisional text', () => {
  const a = parseSegment({ id: 'a', source: 'system', speakerKey: 'system:speaker-1', speaker: 'You', start: 0, end: 1, text: 'first' });
  const b = { ...a, id: 'b', start: 1.2, end: 2, text: 'second' };
  assert.equal(transcriptTurns([a, b]).length, 1);
  for (const change of [{ source: 'microphone' }, { speakerId: 'system:speaker-2' }, { speaker: 'Other' }, { start: 5 }, { final: false }]) {
    assert.equal(transcriptTurns([a, { ...b, ...change }]).length, 2);
  }
  assert.equal(transcriptTurns([{ ...a, speakerId: 'system:unknown' }, { ...b, speakerId: 'system:unknown' }]).length, 2);
});

test('busy recording notice survives status parsing', () => {
  const message = 'Your Mac is busy · still recording, the transcript will catch up';
  assert.equal(parseStatus({ recording: true, message }).message, message);
});
