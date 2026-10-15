# Ink and Pencil — finish pass

No push or merge. Native tests use disposable vaults and Obsidian profiles under this
worktree's `.artifacts/`; the wrapper starts with an isolated discovery path before
connecting to its fixture server. No user vault or Obsidian profile is modified.

## P0

All six P0 changes are implemented and have regression coverage:

| Item | Change | Evidence |
| --- | --- | --- |
| N1 | New notes have one filename title and start on an empty bullet. The brief is below Properties. Legacy body headings remain. | `NoteDocumentTests`, `finalized-light.png`, `finalized-dark.png` |
| N2 | Final-pass, transcript-referenced commitments replace regex extraction from the user's own tasks. Normalize and deduplicate against existing tasks; retain owner and due date. | `NoteTests`, `NoteDocumentTests`, fixture formatting test |
| L1 | Measure text indentation for each anchor. Use padding; keep hover controls outside the text flow. Parse nested items independently. | `native-metrics.json` → `listAlignment`: 9 flat/nested/numbered/task cases, ±0.5 px |
| L2 | No widget exists for an empty label or an empty bullet. Typing and IME deferral remain. | `native-metrics.json` → `activeLine`; parser regression |
| O1 | Owned text stays real Markdown, using the same measured indent, font, wrapping and spacing as pencil. | `glyphsBefore` / `glyphsAfter`, `owned-line.png` |
| F1 | ⌘↩ is handled only in the stopped, bound meeting note with its Finalize bar visible. | `unrelatedShortcut`: actual keypress in another note |

`native-metrics.json` also checks the 7 px line gap, unchanged caret/source during a
rewrite, unique AI text in the three-bullet scenario, Finalize scroll within 1 px,
no body H1, brief spacing and one-Undo restoration. The takeover scenario also inserts text before the anchors first, to catch stale widget positions.

## P1

Implemented: N3, N4, L3, L4, L6, F2–F5, S2–S5, W1–W4, C1 and H1.

- New property names/order and local date/time; stopped notes receive duration and named attendees.
- Also discussed uses escaped italic text. Rewrites separate punctuation and whitespace, use colour without a wash, and do not diff placeholders against real text.
- Finalize returns UTF-16 insertions, applies one editor transaction and paints a temporary ink sweep. A disk-watcher echo is reconciled so it cannot consume the Undo boundary.
- The dismissible Finalize bar reserves reading space, has concrete counts/time, and is the only Finalize control.
- The recording pill lives in the note header and shares the status-bar clock. Its dot animates once. The sidebar has a conditional open-note link and a pinned composer.
- Why? uses the open companion's Transcript tab with trace/evidence and revision history; a closed companion retains the modal fallback. Expanded source disclosures survive new transcript events, and purge clears the open companion trace. Answers precede sources and a collapsed receipt footer. Citation runs keep adjacent punctuation with the cited word.
- Conversation actions sit beside tabs; answer actions sit in their footer. New native notes keep no permanent sparkles action.
- Fixture formatting mirrors the native insertion rules, uses human filenames, includes real fixture brief/topics/tasks, and deletes old frame files before recording.

Two P1 items remain partial:

- **S1:** header placement, recording/ready/fading states and deletion confirmation are implemented. The ten-minute **Resume** path and the animated finishing/fade rings are not. Resume requires preserving and joining the existing audio and screen recording; the present native start path replaces those files, so it is not exposed as a cosmetic button.
- **L5:** one outside-content hover control, quiet provenance, keyboard focus and tooltip removal are implemented. The exact **inline-after-the-last-word fallback in very narrow panes** remains; the current overlay is clamped to the pane. It does not reserve column width.

## P2

Implemented: O2 (restore the last pencil immediately), O3 (remove the alternate ownership
menu), C2 (no green idle status dot), C3 (paused copy in the header), C4 (initial bullet
cursor), C5 (faded timestamp), M1 (measured height transition), M3 (ink sweep), M4 (remove
legacy editor CSS), and A1 (one native recording bounce; neutral idle indicator).

W5 is partial: the count reflects the retained question list and Add to note inserts at
the meeting cursor with attribution/source links. The API does not yet identify the
addressee, so **Asked of you ranking** is not guessed from the asker's identity.
M2 is partial: the prompt and fixture preserve existing clauses more strictly, but there
is **no factual-equivalence post-check** for a model's clause rewrite.

The seven stronger existing choices are retained: no live topic lead, immediate real
ownership, full provenance, text question count, Escape to keep raw data, conservative
conflict recovery and typing/IME deferral. The reference pages now match the no-wash,
no-empty-listening-row and no-live-topic-lead choices.

## Verification and artifacts

See `verification.txt` for final command results. Fresh native captures:

- `recording-header.png`, `live-mid-rewrite.png`, `owned-line.png`, `list-indent.png`
- `line-why-trace.png`, `integrated-image-why.png`, `ask-answer-trace.png`
- `finalize-bar.png`, `finalized-light.png`, `finalized-dark.png`
- `native-metrics.json`, `integrated-native-metrics.json`

Images and model replies in the native harness are explicitly **Scripted fixture / Test
server**. They demonstrate the editor and provenance flow, not a new physical recording
or a model-quality benchmark. The recorder glyph change is compiled, not physically
recorded. Frame JPEGs, recording videos and ephemeral discovery credentials remain local
and ignored. `watchcat-observation.txt` records the independent motion review.

The independent motion review observed the first details appearing without moving the active
line, inline editing, the companion trace, the Stop bar, Finalize, one Undo, re-finalization,
and the light/dark and nested-list checks. Its quoted UI copy is not used as an exact-text
assertion; the structured native checks and screenshots supply that evidence. The brief tab
switch at 0:23 is the intentional unrelated-note shortcut test.

## Deliberate implementation choices

The existing ⌘↩ shortcut remains, with the strict meeting/bar scope requested in F1,
rather than introducing a new unbound command. Original body headings and user-authored
blank lines are preserved; new generated spacing is controlled. Owned-line indentation
uses a measured, per-anchor CSS rule because Obsidian can replace a CodeMirror line's
inline styles. Position changes rebind widget handlers, so editing earlier text cannot
leave a takeover handler pointing at an old offset.
