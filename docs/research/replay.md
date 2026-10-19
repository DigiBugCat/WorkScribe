# Timeline replay (stage 1)

`WorkScribe --replay` drives the production `Find` / `Enrich` / `Line` checks through
`CurrentNoteEngine`. Lines use one prompt, stable query-scoped evidence IDs, a current-line section,
and a 96-token output cap. Apply guards protect the query revision, line revision and user ownership.
The adapter retains the existing meeting scheduler and cancellation boundary; Stage 5 replaces it.
First-line requests bypass the update throttle. There is no quoted-transcript fallback. The Stage 4 candidate is not qualified for promotion; see [its report](replay-stage4.md).

## Run

From this checkout, with the existing pinned local models available:

```sh
python3 scripts/replay.py convert \
  /private/tmp/claude-501/ws-intel/.artifacts/eval/takeover/reviewed/cases.v3.jsonl \
  fixtures/retrieval-vault.jsonl --out .artifacts/replay-cases.jsonl

/private/tmp/claude-501/handoffs/gpu-lock .build/debug/WorkScribe \
  --replay .artifacts/replay-cases.jsonl --models real --export-pairs \
  --out .artifacts/replay-real

.build/debug/WorkScribe --replay .artifacts/replay-cases.jsonl --models cached \
  --cache .artifacts/replay-real/models.json --out .artifacts/replay-cached

/private/tmp/claude-501/handoffs/gpu-lock .build/debug/WorkScribe \
  --replay .artifacts/replay-cases.jsonl --models real --audio \
  --audio-fixture /private/tmp/claude-501/fixtures/tts-offline-sync \
  --out .artifacts/replay-audio
```

`--case ID` selects one case. `--embed-cache FILE` imports the existing exact-key embedding cache;
real mode fills missing inputs locally. The corpus baseline can seed this cache explicitly; its
embedding timing then describes cache misses, not a fresh-ANE first-keystroke benchmark. `--arm FILE` merges partial `EngineConstants` overrides
onto the application baseline. The type is `EngineConstants`; arms never change production defaults. Cached mode never invokes Core ML or the text engine. It fails on an absent
vector, generation or timing and writes observed hashed keys to `misses.json`; it never substitutes
lexical retrieval or invented text. The generation key contains pinned model identity, the full
chat-template/prompt hash and sampling settings. Repeated identical prompts keep ordered receipts,
so different measured durations do not overwrite one another.

The converter merges vault additions by case ID and preserves source status and prose gold.
`fixtures/replay-anchors.json` supplies explicit final regex anchors for all 99 jots, checked against
the supplied references in the test suite. Each becomes a milestone at its last supporting evidence
frontier; `fixtures/replay-milestones.json` adds earlier checkpoints. Unknown/custom prose-only
requirements remain marked `review_required`; the converter never interprets arbitrary prose as a
regex. No source is silently promoted from disputed to reviewed. Gold is decoded only by reporting
and pair-label export, not by the engine's `ReplayCase` input type.

## Artifacts and judging

* `timeline.jsonl`: visible state/text/evidence changes, with virtual times and causes.
* `calls.jsonl`: every pass and every text call, prompt hash, exact backend token counts, TTFT and duration;
  embedding model calls and exact-cache hits are separate.
* `funnel.jsonl`: actual pre-budget candidates, after-gate evidence, and evidence for attempted text calls.
* `report.json` / `report.md`: per-jot latency, recall, revisions, cosmetic-anchor changes, flaps,
  milestones and explicit measured/unmeasured budget rows. The Markdown includes each jot's timeline.
* `models.json`: private replay outputs/timings and exact-key vectors. Do not publish it as product data.
* `pairs.jsonl` with `--export-pairs`: current retrieved candidates and production feature definitions,
  labelled only after inference; there is no injected-gold candidate shortcut. Speaker-change
  features use the full transcript order; answerability uses the budgeted, pre-gate pack. Missing
  feature vectors fail the export rather than dropping or misaligning pairs.
* `packets/<case>/packet.md` and `judgment.todo.json`: the judge kit's blind folder/slot envelope,
  adapted to `judge-faithfulness-v1`. Each revision contains only the transcript actually available
  then, plus the background supplied. When no meeting exists, supplied vault passages are evidence. Numeric support flags require semantic review (e.g. arithmetic).
  Model identity, raw rejected generations and performance receipts are absent.

The orchestrator follows the generated `packets/JUDGE.md`, saves each `judgment.json`, then runs:

```sh
python3 scripts/replay.py report .artifacts/replay-cases.jsonl .artifacts/replay-real \
  --judgments .artifacts/replay-real/packets
# Or replay again with --judgments DIR; no judge is called by either command.
python3 scripts/train-decision-head.py --pairs .artifacts/replay-real/pairs.jsonl \
  --embedding-model 'MODEL_ID_FROM_MANIFEST' --out .artifacts/head
python3 scripts/fit-engine.py baseline=.artifacts/replay-real/report.json \
  candidate=.artifacts/arm/report.json --out .artifacts/held-out.json
```

Judgment import checks protocol, the current packet/content hash, exact slot set, allowed labels,
and verbatim source quotes at that revision's horizon. Unsupported/contradicted revisions count once
per jot. The case-macro headline and seeded bootstrap interval remain null with missing judgments or
unreviewed final anchors. Arm selection is leave-one-case-out and refuses incomplete evidence;
the retained decision trainer uses nested case-held-out calibration.

## Real audio and measurement limits

Audio uses `FileCapture → AudioTrack → SpeechRuntime/Nemotron → AppModel`, the actual note scheduler,
local E4B and live index. The input WAVs are read only. State, index, notes and voice profiles live under
the requested output root and are cleaned after the run. No captured audio is written. The report
includes all lag samples and those overlapping **backend-measured generation intervals**, excluding
load/queue time, plus footprint and thermal samples. The supplied WAV length is reported; `--duration`
can shorten it but does not stretch it into a 60-minute meeting. `audio-timeline.jsonl` observes actual
note notifications; `finalized.md` exercises the existing Finalize path.

The virtual adapter freezes inputs for a pass, schedules its completion after the measured service
time, and delivers intervening speech/edits first. Apply-time guards are the same as the app. It does
not emulate token-by-token cancellation: a pass superseded by Stop is discarded as a unit, while the
current app may retain already-finished lines from a cancelled pass. Exact cancellation/crash-resume
parity belongs with stage 5's injected event scheduler. Audio directly exercises the current scheduler.

The report labels the Find selection frontier; separate per-query queue timing awaits Stage 5.
Optional after-Stop topics/actions remain included as separate call jobs. `Line` state and acceptance
are shared, but the adapter still has the old Stop cancellation boundary. Native `loadMs` excludes CLI asset hashing/setup and OS cache state. Energy, 60-minute growth,
post-Done memory recovery and KV snapshot occupancy are not inferred
from short replay or token counts. Stage 8 must supply those measurements before budget qualification.

## Removed entry points

The former note/retrieval/decision/model-measurement/finalize/live-session evaluation CLIs and their
separate scoring/sweep scripts are retired. Their remaining useful seams are the exact embedding cache,
CPU tokenizer, nested decision fitting, temporal judging envelope, and retention tests. Documented
scene/vector benchmarks and product verification unrelated to this harness remain.
