# Images + Ink and Pencil integration

Integration verification for image understanding, notes and UI polish.

## Resolution

The nine conflicts were `LocalAPI.swift`, `APIRoutes.swift`, `Notes.swift`, the local API
reference, mock server, and the plugin editor extension, parser, types and note editor.
Both `Note` and `APINote` carry `trace` and `images`. The image pipeline, source/derived
boundary, grab command, indexing and retention remain intact. Document PATCH preserves
both image references and the guarded Finalize-undo path.

Why? uses polish's one `renderTrace` modal. Image target, caption, OCR text, method and
analysis seconds are adapted into its source disclosure. The separate image modal was
discarded. Image AI lines use polish's topic-free pencil, direct first-keystroke ownership,
2.4-second drying, roman owned text and atomic Finalize. Grab this moment keeps no default
hotkey and uses a quiet failure notice that says the user's notes are saving.

Two semantic conflicts required changes beyond resolving Git markers: the final pass now
keeps image evidence even without transcript excerpts, and the image-batch helper reports
its actual Gemma model and duration in provenance. A regression test covers the former.
The images branch's old blockquote assertion now expects the shared italic final form.

## Verification

- `swift test`: **150 passed**, no failures.
- `.build/debug/WorkScribe --verify-api`: passed.
- `.build/debug/WorkScribe --verify-purge`: passed.
- Plugin `npm install`, `npm test`, `npm run build`, `npm run smoke`: passed.
  Ordinary tests: 79 passed, 2 opt-in skips. Real API enabled: **81 passed**, no skips.
- `WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test`: passed.
- `node dev/native-integrated-check.mjs`: passed in a fresh, isolated Obsidian profile.
  Registered grab command, valid attachment, mapped insertion, Undo/Redo, image trace,
  direct ownership and one-Undo Finalize all asserted.
- `node dev/run-native-editor-check.mjs`: passed the full polish native editor check in
  another fresh profile. Caret and source stayed unchanged during rewrites; first-keystroke
  ownership, hand-back, Ask trace, no Q&A focus stealing, stop, Finalize and Undo passed.

The image evidence and pixels in the native check are explicitly scripted fixtures, labeled
Scripted fixture / Test server. This verifies editor integration, not another physical
ScreenCaptureKit permission test or model performance benchmark.

Screenshots: [image pencil line](integrated-image-line.png),
[shared Why? image evidence](integrated-image-why.png). Structured native results:
[integrated image metrics](integrated-native-metrics.json) and
[polish metrics](integrated-polish/native-metrics.json).

The dependency install reports the existing moderate advisory; dependencies were not
force-upgraded as part of this merge. Prior design/physical-call limitations remain as
recorded in the two branch reports.

Watchcat's [recording observation](integrated-watchcat.txt) saw image insertion, AI text,
Finalize and Undo. It flagged the existing scroll-to-top on Finalize and scroll return on
Undo. The short modal interaction was not sampled in that account; the explicit screenshot
and DOM assertions establish its contents. The recording does not establish precise timing
or a general smoothness bound.
