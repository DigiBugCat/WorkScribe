# Obsidian mounting points

This is the stage-6 plugin contract for engine.md §2.8/§3. The existing meeting
API and companion remain available. All automatic enrichment is ephemeral CM6
state: no document edits, filesystem writes or undo entries. A user action is
required to insert a diagram or turn an AI line into Markdown.

## Events

`GET /v1/events` uses the event name as SSE `event:` and these objects as `data:`.
The common source is `{kind, title, at?, quote?, speaker?, segmentId?, meetingId?,
path?, link?}`. `at` is seconds into a meeting; `quote` is the supporting excerpt.
Vault sources use `path`/`link`. Omit optional fields rather than inventing values.

```ts
line { documentId, blockId, state, text?, revision,
       changed?: [number, number][], sources, reason? }
status { model: 'ready' | 'loading' | 'missing', paused?: string }
pin { documentId, blockId, anchor: {
        kind: 'cell' | 'line' | 'task' | 'sentence', path: number[] }, sources }
check { documentId, blockId, sentence: {from, to},
        verdict: 'supported' | 'differs', note?, sources }
preview { requestId, kind: 'diagram', mermaid, sources }
```

`line.state` is `listening | found | answered | settled | quiet | yours`.
Revision is nonnegative and monotonically increasing per block. Older revisions
are ignored. `changed` indexes the new line text in UTF-16; without it, the
plugin computes a word diff. Unknown or malformed events are ignored. Status is
independent of the legacy recording-status object and never resets a recording.

Block IDs are the identities from `lib/anchors.ts`'s `reconcile`, not text hashes
or positions. Blocks now include tables and fenced blocks (`surface: 'table' |
'fence'`), alongside existing prose/list/image units. Structured blocks are
mounting points, not ordinary AI-line jots. No block IDs are written into Markdown.

All offsets are UTF-16. `check.sentence` and sentence paths are relative to the
block. Pin paths are zero-based:

| Kind | Path | Meaning |
| --- | --- | --- |
| cell | `[row, column]` | Markdown table source row, including header and separator |
| line | `[line]` | Source line within a fenced block, including its opening fence |
| task | `[]` | The task/list block |
| sentence | `[from, to]` | Relative text range |

Pins/checks map untouched ranges through CM6 changes while block IDs reconcile.
A reference whose text is edited disappears until fresh evidence arrives. Deleted
blocks cannot render. Internally a mapped pin becomes a relative sentence range;
this prevents a newly inserted table row from acquiring another row's evidence.
This is conservative: deleted evidence is not resurrected merely by Undo.

## Surfaces

- **Line:** silent for the first eight meeting seconds; outside meetings listening
  is always silent. Found shows only a nib after 1.5 seconds. Answered text has a
  1.2-second word highlight on revision bumps; settled has no animation. Quiet
  questions show `Not discussed` after Stop. Yours is ordinary owned Markdown.
  Click/Why opens supporting quotes; Make it mine or the first input produces one
  normal undoable ownership edit. Composition and focused AI text defer updates.
- **Pin:** a keyboard-reachable dot at a table cell, code/sketch line, or task.
  It opens evidence; it never changes the containing text.
- **Check:** dotted underline plus time for support; wavy underline and one quiet
  paragraph note for disagreement. The sentence is never rewritten. Underlines
  and timestamp buttons open evidence with mouse or Enter/Space.
- **Make:** every fenced block offers Make diagram. Preview renders through
  Obsidian's MarkdownRenderer/mermaid, with source attribution and Insert below
  sketch / Discard / Remake. Insert creates a separately undoable fenced Mermaid
  block. Neither request nor preview edits the sketch. A response only renders
  for its request ID and unchanged sketch. Markdown fencing is lengthened if the
  generated text contains backticks.
- **Sources:** focus opens the companion transcript and highlights/scrolls its
  supporting turns; vault sources offer their note link. A modal provides the
  same quotes when the companion is closed. Purge clears references and previews;
  remaining AI text reports `Sources faded with the transcript`.
- **Status:** recording/model/paused appear in one status-bar item. No per-line
  engine failures. Reduced Motion disables surface animation and transitions.
  Product styles use Obsidian CSS variables only.

Commands (no default keys; bind through Obsidian Hotkeys): **Why?**, **Make it
mine**, **Let AI rewrite**, **Make diagram from sketch**, **Jump to moment**.
Command targeting uses the focused AI widget or the block containing the caret.

## Explicit requests

```http
POST /v1/documents/:documentId/blocks/:blockId/make
Content-Type: application/json

{"kind":"diagram"}
```

Return `202 {"requestId":"..."}`, then publish the matching preview. A preview
can arrive before the response; the plugin retains it until the ID is known.
The engine owns prompt construction, evidence selection and local generation.
The plugin does not run inference or send note content to a cloud service.

Handback calls `POST /v1/documents/:documentId/blocks/:blockId/rewrite {}`; until
stage 6, the existing `PATCH /v1/meetings/:id/notes/:blockId {rewrite:true}` is the
compatibility fallback. A failed request preserves owned text and reports one
status. Successful handback removes the owned quote in one undoable edit.

## Native engine integration

The app publishes native `line` events and the separate model `status` payload.
`APINote.line` carries the same line shape for opening a note or reconnecting;
the plugin never reconstructs lifecycle state or revisions from legacy strings.
The document ID for a meeting note is its meeting ID; block IDs come from the
registered document ledger. The first input still transfers ownership through
one ordinary CM6 transaction, and the document block rewrite endpoint hands it
back explicitly.

Pin/check/preview renderers are retained, but this release has no producer for
them. Make diagram is hidden in the product until that producer exists; the
mock harness explicitly enables its scripted preview. The engine excludes table
and fence mounting points from automatic line generation.

Ordinary notes can mount supplied native events under their absolute path ID.
Opening an ordinary note does not trigger retrieval: its registration handshake
remains outside this release. Meeting registration uses the existing document API.

## Reproduction

```sh
cd obsidian-plugin
npm ci
npm run build
npm test
npm run smoke
# The mock has no model dependency. --surfaces replays on SSE connection.
node dev/mock-server.mjs --surfaces --speed 1 --vault ./dev-vault
# Requires a Playwright browser (the QA script defaults to installed Chrome).
node dev/surface-check.mjs /private/tmp/claude-501/handoffs/e4b/ui-8
```

The browser harness opens all four supplied reference tabs, then mounts the real
CM6 extension/surface modules and real Mermaid renderer. It checks light/dark
surfaces, source focus, no automatic edits, the 1.2-second mid-fade, Reduce Motion,
preview insertion/Undo and first-input ownership/Undo. The harness theme tokens
are fixture values, not product CSS. It is a CM6 development page, not an installed
Obsidian theme screenshot or a native capture/inference test.

`dev/surface-replay.mjs` supplies the time-indexed spoken fixture (lww, ship date,
beta accounts, photo cap, Android, pricing, sketch/table/task, and contradictory
write-up). `/v1/dev/surfaces` exposes the fixture; `POST /v1/dev/replay` replays it.
The mock supplies a scripted preview for the production-shaped Make request.
