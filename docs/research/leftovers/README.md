# Ink and Pencil — leftovers

Note editor follow-up verification. All native editor
captures use a disposable Obsidian profile and vault under this worktree's `.artifacts/`.
Screenshots and answers are **Scripted fixture / Test server**; they are not a physical
microphone/screen capture or a model-quality benchmark.

## Changes

- Header: preserve the breadcrumb's space by dropping the source label, then abbreviating
  the clock. Stop and Resume never shrink into neighboring text. Very narrow headers wrap.
  Native checks cover the 1024 px window (380 px note header) and a 396 px note beside the
  companion, with bounds assertions for the pill and its controls.
- Resume: `POST /v1/meetings/:id/resume` continues the same document within ten minutes of
  Stop, before Finalize. Each capture owns new WAV files and a new screen movie; the session
  manifest preserves offsets, prior files, screen moments, and existing speaker assignments.
  New recognition sessions use distinct speaker keys. Voice sampling resolves the correct
  session's audio. Screen deletion covers every session movie.
- Lifecycle: Resume can interrupt the final pass once audio streams have drained. Results
  from an earlier capture cannot overwrite the resumed note. Old retention receipts cannot
  purge an active resumed capture, and the next Stop renews the 24-hour deadline. Native
  menu-bar review and finishing states expose Resume too.
- Rings: the header and native finishing indicator use completed lifecycle stages, not a
  simulated timer. The ready ring is full; the transcript ring empties with its deadline.
  SVG identity is retained between stages, and reduced motion disables the transition.
- Spacing: the generated blank line after Properties no longer doubles the visual gap.
  The native check measures 22 px from the Properties container to the first bullet,
  matching `design/care/care.css`. Source text and additional authored blank lines remain.
- Questions: explicit name-addressed questions sort first with “Asked of you”. Set “Your
  name in meeting questions” in plugin settings; comma-separated alternatives are supported.
  An asker's identity and third-person name mentions never imply an addressee.
- Rewrites: a conservative local clause check retains recognized equivalent wording while
  accepting new factual clauses. It preserves numbers, names, token order, negation and
  modality and records `Kept: no new facts` in the line trace without a revision bump.
  Unrecognized paraphrases pass through; this is deliberately not an uncalibrated semantic
  similarity threshold that could conceal a real correction. No new model is loaded.

## Evidence

- `pill-1024.png`, `pill-sidebar.png`: responsive recording header.
- `resume-ready.png`, `resumed.png`: actual Resume click, same meeting ID, document and
  transcript count before/after.
- `finishing-ring.png`: partial final-pass ring; `native-metrics.json` also checks full ready.
- `live-spacing.png`, `live-mid-rewrite.png`: live layout and caret-safe rewrite.
- Existing ownership, nesting, unrelated-note shortcut, Finalize/Undo, theme and composer
  checks rerun in the same native harness.
- `asked-of-you.png`: explicit vocative first; third-person mention second.
- `verification.txt`: final automated gates. `watchcat-observation.txt`: independent pixel
  sequence observation, interpreted alongside exact DOM assertions.

Resume tests include real synthetic WAV writes: the original recording bytes remain exact,
new samples go to a different file, and resumed sample offsets resolve to that file. The
capture hardware path is compiled; physical resumed microphone/system/screen recording is
not claimed by this harness.

The independent motion review saw the resized layout restore cleanly, then Finalize,
Undo and re-finalization respond. Its high-resolution header replay reported no overlapping
or clipped controls. Rapid Resume is established by the exact native click/state assertions;
the observer did not independently resolve that short transition. Quoted observer text is
not used as an exact-copy assertion.
