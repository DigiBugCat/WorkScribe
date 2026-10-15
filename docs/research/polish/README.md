# Ink and Pencil implementation

No Swift image capture or vision pipeline files changed. The native-editor fixture uses only
`<test-vault>` and its own Obsidian profile/CDP port 9249.

## What changed

The native Markdown editor keeps suggestions in decorations. Typing into a suggestion
immediately inserts an owned roman continuation. Why? is a right-margin button with a
native disclosure trace: matching transcript excerpts, model/location/time and revision
word diffs. Shared trace disclosures appear above Ask, Quick ask and Live Q&A answers.
Native Quick ask also displays the trace. These are DOM/SwiftUI controls, with no React or
Tailwind dependency.

The ten priority details are implemented: a ten-second channel check; withholding the
active line until Return/pause; caret scroll compensation; word-level rewrites; 2.4-second
ink drying including reduced motion; no automatic Q&A focus/tab changes; isolated
undoable Finalize; roman owned text; hour/minute fade rounding; and hour-23 automatic
finalization. The actual microphone/system check and automatic start tick require a real
call to hear/verify; the isolated tests never capture the user's audio.

Stop now finishes transcription/enhancement without committing native pencil lines.
Finalize has an editor bar and ⌘↩. Generated Markdown has a brief under properties,
indented italic AI continuations without topic labels, `Also discussed`, then action items.
Conflict writes preserve the current original and create a sibling. Deadline recovery keeps
conservative unique-anchor rebasing; a deleted note is not recreated. Section markers
are stripped at purge. The quick-ask default global shortcut is unchanged.

Trace data records observable operations and evidence, not private model reasoning.
Generation fallback reports the provider actually used. The parser, native API, mock and
UI share optional trace fields. Purge removes revision/source traces from disk and open
UI, including an uncited raw source present only in an answer's trace.

## Deliberate differences and remaining work

- Why? uses Obsidian's accessible modal instead of an anchored popover. It has nested
  native disclosures and dismisses with Escape. This avoids clipping at editor boundaries.
- The semantic model still supplies its full revised line. DOM LCS changes only changed
  words; the existing planner and previous-output prompt suppress no-new-evidence
  rephrasing. There is no independent factual-equivalence classifier.
- Trace has model/source provenance and revisions. The parser adapts the parallel `images` branch’s `APINote.images` fields (target, OCR, caption and method) into clickable trace sources. Producing that image evidence still belongs to the `images` branch; this branch does not invent it.
- Legacy region-based notes keep their existing structure. The new final form applies to
  bound native meeting documents. Migration of old notes is not included.
- Automatic start uses the system Tink sound at the default volume; a bespoke soft sound
  and a settings toggle remain. The native audio check is covered structurally, not by a
  recorded physical call.
- Height changes use native CodeMirror layout and scroll compensation; exact 140/180/220ms
  choreography and a 45ms-per-line Finalize sweep are not fully reproduced. Removed-word
  ghosts fade in 140ms and new words dry over 2.4 seconds. The actual commit stays atomic.
- Calendar onboarding/first-meeting permission flow, pre-call preparation, automatic titles
  beyond the existing title generator, ten-minute same-meeting Resume, named-question
  ranking, copy-across-decorations, cursor-local Add to note, missed-topic removal before
  commitment, clipper copy/timing, and catch-up elapsed copy remain.
- Menu-bar inventory/quit/update details remain as before. Existing startup/permission,
  source retrieval and fallback behavior are preserved; they were not all redesigned.

## Verification

See `native-metrics.json` for native behavior assertions and the PNGs for the real editor:
`live-mid-rewrite.png`, `line-why-trace.png`, `ask-answer-trace.png`, `finalize-bar.png`,
`finalized-light.png`, and `finalized-dark.png`.

The harness records frames for motion review but ignores them, its video, and its ephemeral
API token in Git. It checks that it is attached to the isolated vault before any mutation.
The scripted provider is labeled **Scripted fixture · Test server** in trace UI.

Automated gate results for this revision: **144 Swift tests passed**; plugin **77/77** with
the real API enabled (**75 passed, 2 opt-in skips** without it); strict TypeScript build,
smoke load, `--verify-api`, and `--verify-purge` passed. The opt-in API test checks trace
stream events and final metadata, snapshot ownership, safe conflict copies and cleanup.
New tests cover fade rounding, word diffs, emphasis escaping, roman ownership, one-undo
pencil restoration, hour-23 timing, marker removal, and uncited trace-source purging.

The final native run additionally exercises direct **Let AI rewrite** followed by Undo;
hand-back requires one click. The image-source adapter is unit tested using the parallel
lane's published wire fields. It does not claim a physical image-model run on this branch.
The motion review and its limitations are in [watchcat-observation.md](watchcat-observation.md).
