# Live meetings in the real Obsidian editor

> Historical implementation report. The `polish` follow-up supersedes the ownership menu, blockquote final form, immediate Stop finalization, timing and native harness sections below. See [Ink and Pencil implementation](polish/README.md) for current behavior and verification.

The native note editor is implemented in this tree. Tests use throwaway stores and a separate Obsidian profile
and vault under this worktree's ignored `.artifacts/`; the user's library and vault are not test fixtures.

## Decision

The meeting is a normal Markdown file from the start. Its `MarkdownView` owns editing, commands,
selection, undo, Live Preview, Source mode, tables, wikilinks, embeds and other plugins. The right leaf
is only the meeting companion: Ask, Live Q&A, transcript, recording control, Finalize / Done.
The old custom line editor is removed from the live path. The legacy past-meeting renderer remains for
older meetings; a bound native document cannot be changed through its old per-note mutation API.

One CM6 `StateField` holds block identity and direct block-widget decorations. A `ViewPlugin` sends
changed source snapshots through a separate debounced controller. No decoration text, cursor update
or enhancement transaction is written into the file. Reading mode intentionally shows only real
content. The `documentFinalized` notes-event flag removes overlays as soon as the file commit succeeds. It becomes fully enriched when finalization writes the AI lines.

## Prototypes and evidence

The executable comparison is `obsidian-plugin/test/anchor-comparison.test.ts`. It runs the same
11 edit cases through the clean-file reconciler and an inline HTML-comment anchor prototype. The
identity criterion includes attaching to the correct surviving block, not merely finding an old ID.

| Approach | Correct cases | File cost | What failed / tradeoff |
| --- | ---: | --- | --- |
| CM transaction mapping + exact content + conservative overlap matching | 11 / 11 | No anchor characters | Requires a sidecar ledger; ambiguous external edits must abstain |
| Inline `<!--ws:a-->` comments | 8 / 11 | 24 extra bytes for two short IDs; UUIDs cost more | Duplicate paste copies identity; splitting strands the marker on the second piece; deleting a comment loses identity |

Cases: typing within a block, heading insertion, paragraph insertion, identical copy before the original,
delete, split, merge, Unicode, clear-all, external unique reorder, and accidental marker deletion.
This is a bounded corpus, not a proof that arbitrary edits are unambiguous. Obsidian metadata-cache
sections were considered as parser input only: their positions do not preserve identity through edits
and their asynchronous updates cannot replace transaction mapping. They are not claimed as a third
implemented identity prototype.

Separate tests cover cut/paste, undo/redo tombstones, mirrored panes, nested list children, Markdown
fences/tables/frontmatter, unrelated offline replacements, immutable first-typed times, and a 1,000-edit
200-block corpus. The inline-comment prototype does not ship. The selected approach does.

## Block rules

A unit is a top-level paragraph or list item. A list item's indented children and continuations belong
to it. Headings supply section context, not an AI note. Fences, tables, HTML blocks, and blockquotes
are opaque: they remain fully editable in Obsidian, but do not get a speculative second interpretation
as shorthand. Owned ranges remain excluded even if the user removes their quote formatting, so their
text does not recursively become a new AI note.

The standalone Lezer Markdown/GFM parser is bundled. Obsidian does not expose `@lezer/markdown` at
runtime; the native smoke caught this despite the ordinary bundle-loader test passing. CM6 packages
remain external and use Obsidian's editor instance, avoiding duplicate StateField implementations.

For each edit, exact mapped ranges disambiguate identical copies. Unique full content recovers moves.
Overlapping mapped ranges keep normal edits and the first part of a split; a merge keeps the leftmost
identity. An explicit cut has a one-paste identity transfer. Plain copy/paste never inherits a deleted
ID. History transactions may restore bounded tombstones. Another pane adopting the same source uses
the first pane's canonical IDs. Offline matching requires unchanged content or a close edit; unrelated
replacement gets a fresh ID instead of inheriting stale evidence. Reordering indistinguishable duplicate
paragraphs outside a transaction history cannot be perfectly recovered without file anchors. That
inherent ambiguity is the reason for conservative matching and deadline abstention.

IDs and first-typed timestamps live in the ephemeral server meeting ledger and a pending plugin
ledger, never in Markdown. A new block first seen while the app was unavailable can have an unknown
time; the system does not invent the time of offline typing. Existing IDs retain their original time.

## Editor behavior and ownership

AI widgets use ordinary keyboard-accessible buttons, inherit the vault font/theme, wrap every line,
and have no nested scroll container. Clicking opens an Obsidian DOM menu with Make it mine, Why,
and (for owned content) Let AI rewrite. Why shows the current evidence, not a stale widget closure.
The full content is an accessible description; it is not repeated in a giant hover tooltip.

Updates wait 900 ms after typing and wait through composition. Synchronization also waits through
composition. Rewrites update the existing widget DOM with a brief, subdued changed-suffix highlight;
reduced-motion preference removes the animation. A measured scroll correction keeps the active
editor line at its existing screen height when a preceding AI paragraph grows. User selection and
history are unchanged. Companion tabs and record controls retain their DOM during clock updates;
transcript updates preserve the reader's scroll position unless following the end.

Make it mine inserts a real blockquote, using the same Markdown shape as finalization. The user then
edits it with Obsidian. The ownership range follows transactions and explicitly participates in history
inversion, so undo/redo restores both the file and ownership. Let AI rewrite is an explicit, undoable
removal of that owned quote; it hands the line back. Ordinary user text is never regenerated.

## Final Markdown shape

| Option | Assessment |
| --- | --- |
| Blockquote with a bold short topic | Selected: distinct from the shorthand, wraps naturally, works in plain Markdown and both Obsidian modes |
| Callout per block | Too much chrome and vertical space for 200 small notes; resembles an alert |
| Indented italic line | Risks becoming a code block or changing list nesting; italics blur long explanatory text |

Example (the first line is unchanged user text):

```md
- ship nov 4

> **Ship date.** Release moves to November 4 so QA has a full week.
```

The final writer inserts only at verified block ends, from back to front. Original source code units
stay in order. Owned quotes are not inserted again. Meeting summary, named attendees, Tasks-format
`- [ ]` actions and Discussed but not in your notes follow the user's entire document. No copy step,
`^eN`, or generated transcript/evidence links. Existing user Markdown is never stripped or normalized.

## Sync, failure and recovery

`POST /document` creates/opens the note; `PATCH /document` carries the complete source, validated
UTF-16 ranges, stable IDs, first-typed times, and ownership. A revision makes stale writes return 409.
The plugin saves through Obsidian, debounces 650 ms, serializes requests, and keeps local pending
identity metadata if WorkScribe is down. Changing a block deletes/reorders/re-enhances the corresponding
server note in one snapshot. Existing jots are seeded verbatim when the native note is first created.
Per-note mutations are rejected once a document is bound, avoiding a second source of truth.

Renames follow `workscribe_id`, and paths must resolve inside the configured vault. A closed note is
still watched for file modifications. A vault mismatch reports the configuration problem instead of
creating a duplicate note. Closing the editor does not end the meeting or discard its sync lane.

Stop flushes the editor before the final pass. The writer compares the actual file and uses an atomic
compare-and-swap; unsynced changes leave the file intact and offer a Finalize retry. It also recognizes
its exact completed output after a crash between rename and the retention journal. A finalized bound
note bypasses the legacy region writer forever.

Done / the 24-hour deadline must still delete raw material if the editor stayed closed. That recovery
reconciles only unique, unchanged, line-aligned source blocks against the file now on disk; ambiguous
or edited blocks get no AI insertion. A deleted note is not recreated. Tests verify that both changed
and deleted files cannot extend raw-data retention. The purge still deletes transcripts, recordings,
Q&A, search/index material and the transient document ledger while preserving any existing final note.

## Verification

The checked-in tests exercise actual CM6 state/history, the mock transport, and the real Swift HTTP
listener with throwaway stores. The native harness is `obsidian-plugin/dev/native-editor-check.mjs`;
it refuses any vault other than `.artifacts/ui-vault`. It connects to an explicitly launched, isolated
Obsidian CDP port and records frames plus measured assertions. It never attaches to the normal profile.

Native assertions cover: two decorated blocks; no AI text in the source before ownership; caret,
selection and source unchanged during rewrite; fully wrapped long text; ownership with undo/redo;
Live Preview and Source; Reading view without live overlays; a custom font and light/dark themes;
rename acknowledged by the API; CDP IME composition/commit; 200-block transactions; and same-file
finalization with zero remaining decorations. DOM/page-error collection must be empty.

Observed on this Mac in the separate Obsidian 1.13.4 profile:

- Pure CM6 200-block transaction p95: about 1 ms; the 1,000-edit identity corpus retained all 200 IDs.
- Native Obsidian 200-block transaction p95: 1.6 ms in the final measured run (see JSON evidence for the final run).
- A deliberately extreme 600 px AI paragraph wrapped with `scrollWidth == clientWidth`; no nested scrollbar.
- A grow-above-caret rewrite kept the active line at the same measured screen height.
- CDP IME composed Japanese text and committed once without leaving provisional characters.

`watchcat` reviewed the recording independently. Its first pass identified the oversized tooltip and
visible movement when the long text grew; those observations drove the tooltip and scroll corrections.
Undo/redo and explicit theme changes naturally change document layout. Exact wording and ownership
are asserted from source/API, not inferred from the recording.

Final automated results: 141 Swift tests; 70 plugin tests with the real API enabled (68 pass and two
explicitly skipped when that opt-in is absent); strict TypeScript/bundle build and smoke pass.
All required gates are run before the commit: `swift test`, `--verify-api`, `--verify-purge`, `npm test`,
`npm run build`, `npm run smoke`, and `WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test`.
The native screenshots and metrics in this directory are synthetic test evidence, not user data.

Remaining qualification: the native run tests the supported Obsidian editor and a CDP composition
sequence, not every OS input method, community plugin, custom theme, or cross-device sync provider.
Arbitrary external moves of indistinguishable duplicate blocks remain inherently ambiguous; user text
survival does not depend on successfully recovering their AI identity.

Evidence: [anchor corpus](real-note-editor/anchor-comparison.json),
[native measurements](real-note-editor/native-metrics.json),
[Live Preview, light](real-note-editor/live-preview-light.png),
[Source mode, dark with custom font](real-note-editor/source-dark.png).

The final [recording observation](real-note-editor/watchcat-observation.txt) reports the expected large
paragraph expansion and explicit undo/theme transitions, with no lingering action menu. The active-line
position guarantee is established by the numeric before/after measurements, not visual inference.

## Image blocks

Raster wiki embeds and Markdown images (including image-only list items) now have explicit image
references. Mixed blocks keep their non-image words as shorthand. Recognition happens off the
editor thread; bare image syntax is never interpreted as shorthand. Unsupported and remote
images remain editable images without fabricated descriptions. See `image-understanding.md`
for the on-device pipeline and measured limitations. The insertion point for Grab this moment
maps through edits while IO is pending; attachment creation follows Obsidian's configured folder
and link style. Image blocks retain the same ledger identity, ownership, and finalization rules.
