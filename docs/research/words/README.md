# Transcript preservation and final quality

This work is isolated to `words`. The original meeting library was read-only throughout. The real replay uses the saved 16 kHz mono s16 system track; no microphone, screen capture, or live library mutation is required.

## What the evidence establishes

- The omissions already occur in NeMo's streaming recognition. On the 440–480 s replay, completed-event text and the word list agree, and the app's disk queue delivers all 640,000 samples exactly once. A burst with 40 seconds queued produces the same recognized text as real-time delivery, despite throttled partial presentation.
- The parser did have an independent preservation bug: incomplete word timestamps discarded text whenever *some* words had timestamps. It now treats the transcript text as authoritative, aligns the timing metadata, and interpolates missing times. Timestamp-less word arrays also survive.
- Partial throttling now lives in the same reducer exercised by the replay. It keeps the newest hypothesis even when presentation is throttled; an empty final or missing final at Stop cannot erase that hypothesis. A nonempty final still replaces a provisional hypothesis, rather than blindly concatenating stale guesses.
- The shipped 160 ms / right-context 1 setting is the upstream latency default. The tested model supports right-context 3 (320 ms). This reduces decode work and changes boundary recognition, but does not eliminate ASR errors. Endpoint thresholds 1600/3200 ms and disabled endpointing produced identical text at right-context 3 on this clip: endpointing is **not a demonstrated cause** of these particular omissions. The independent upstream issue below is a reason to avoid over-aggressive endpointing, not proof of our root cause.

Upstream references: [configuration](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/v0.2.0/docs/asr/configuration.md), [native API](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/v0.2.0/include/nemo_speech/asr.h), [endpointing investigation](https://github.com/NVIDIA/NeMo-Speech.cpp/issues/40). The locally installed SDK headers and v0.2.0 runner source were also inspected. The native batch API, rather than a shell subprocess, powers the app's backstop.

## Note matching and synthesis

The stored first two notes match their transcript when replayed with the available segments. The 90-second lookback covers the stated times; meaning matching also searches the whole current meeting, with no speaker/source exclusion. The diagnostic previously counted *references attached after usable model output*, so an omitted model bullet could incorrectly report “Matched transcript · 0 excerpts.” Matching and generation are now reported independently.

The matching view already removed ordinary list markers on this branch; normalization now also handles task boxes, quotes, headings, emphasis, links, inline code and block IDs without editing the user's Markdown or offsets. Final selection favors content over a potentially late file-sync timestamp, and includes adjacent answers/context. A delayed live transcript keeps an unmatched note pending rather than sending evidence-free reformatting work to the model.

The final prompt previously encouraged reformatting, could retain a previous weak answer, and sampled only a small evenly spaced portion of a long meeting. Final generation starts from corrected evidence. A configured cloud writer handles each note separately and visits every eligible passage in bounded requests. The local fallback selects cited source passages across five-minute chapters, prioritizing explicit requirements and decisions. It explicitly distinguishes jokes, uncertain recognition and exaggerated counts from factual answers. User-edited AI lines remain protected. Evidence from another meeting is not silently used to enhance the current note.

## Backstop and lifecycle

After capture drains, “Polishing the transcript…” performs native batch recognition in 60-second ownership windows with four seconds of context on each side. Only the center owns output, so overlap audio is not appended twice. Word timing aligns the corrected text to the live diarization timeline. On the real 30-minute recording, 354/362 original segment IDs survived directly; the other eight have redirects. Typed notes are unchanged.

The corrected transcript is saved before final notes run. A per-ending stamp makes successful polishing idempotent. Resume fences old work before waiting for inference; both batch and notes recheck ownership before committing. A failed pass preserves the live transcript and exposes failure. Raw audio is not copied into a second archive. Derived transcript and aliases remain in the existing ephemeral meeting ledger, covered by its purge. Optional polishing cannot extend raw-data retention or veto an explicit Done/disposal request.

Only tracks with a recorded source clock are eligible. This recording also contained a long unused, zero-valued microphone file with no source clock; it is excluded. Resumed tracks use their own files, offsets and speaker namespaces.

## Reproduction

All raw evaluation outputs belong in ignored `.artifacts/words/`, not in Git. Set `AUDIO` and `MEETING_JSON` to the original source files. The tools read them; the polishing CLI writes only to stdout and its throwaway store.

```sh
swift build --disable-sandbox --jobs 4
# Make a 440–480 s WAV with Python's wave module, read-only from AUDIO.
WORKSCRIBE_SPEECH_CPU=1 WORKSCRIBE_ASR_RIGHT_CONTEXT=1 WORKSCRIBE_ASR_ENDPOINT_MS=800 \
  .build/debug/WorkScribe --replay-transcript .artifacts/words/clip.wav --pace 1
# --pace 0 queues the entire clip immediately and exercises load shedding.
WORKSCRIBE_SPEECH_CPU=1 .build/debug/WorkScribe \
  --replay-transcript .artifacts/words/clip.wav --pace 0
WORKSCRIBE_SPEECH_CPU=1 .build/debug/WorkScribe \
  --verify-batch-audio .artifacts/words/clip.wav
WORKSCRIBE_SPEECH_CPU=1 .build/debug/WorkScribe \
  --polish-transcript "$MEETING_JSON" > .artifacts/words/batch-final.json
WORKSCRIBE_TEXT_CPU=1 .build/debug/WorkScribe \
  --verify-notes .artifacts/words/batch-final.json --title-model gemma4
python3 scripts/score-transcript-replay.py --reference .artifacts/words/reported-offline.txt \
  .artifacts/words/before-real.json .artifacts/words/before-stress.json \
  .artifacts/words/after-real.json .artifacts/words/after-stress.json
```

CPU overrides were necessary because this tool environment cannot create a Metal command queue. These measurements do not establish normal GPU latency or reproduce the original machine's exact compute load. The offline reference is ASR output, not a human-labelled transcript. A 40-second cut removes surrounding context, so we separately inspect the real full-recording pass.

## Measured word preservation

Normalize case and punctuation; align words with Levenshtein distance. Recall is correctly aligned reference words / reference words; WER is (substitutions + deletions + insertions) / reference words. The primary reference below is the **57-word offline text supplied with the bug report**.

| Path | Word recall | WER | PCM delivered exactly once |
| --- | ---: | ---: | --- |
| Prior settings, real time | 80.7% | 33.3% | yes |
| Prior settings, immediate 40 s backlog | 80.7% | 33.3% | yes |
| Model-max context, real time | 80.7% | 29.8% | yes |
| Model-max context, immediate 40 s backlog | 80.7% | 29.8% | yes |
| Batch on isolated 40 s cut | 77.2% | 22.8% | n/a: one batch |
| Batch with the actual final-pass window context | 87.7% | 22.8% | n/a: one batch |

The last row decodes the real 416–484 s window used by the 420–480 s ownership window, then scores only word midpoints in 440–480 s. This is reproducible with `--verify-batch-window "$AUDIO" --start 416 --duration 68`. It recovers `out`, `that was`, `you don't say that`, and `okay Sam`. `Oh` is still absent: this is an improvement, not perfect recognition.

The new live setting improves WER against the supplied reference but **does not improve recall on this cut**. There were zero event-text/word-list disagreements in these native replays. Both stressed runs queued 40 seconds; six prior-setting partials and twelve new-setting partials were presentation-throttled. No finalized words or PCM were skipped.

A fresh CPU CLI offline run yields a different 49-word hypothesis from the original report. Against that reference, the prior/new live WERs are 28.6%/36.7%, and isolated batch is an exact match. Thus the live tuning is not a universal accuracy win. CPU and cut-boundary differences are material; the original GPU run has not been reproduced here. Full-pass context and explicit preservation, rather than a claim of perfect streaming recognition, are the backstop.

Ignored evidence files: `before-real.json`, `before-stress.json`, `after-real.json`, `after-stress.json`, `offline-cli.json`, `batch-clip.json`, `batch-context.json`, `batch-context-scored.json`, `metrics.json`, `batch-final.json`. The replay JSON includes native events, parser output, byte counts, hashes, backlog and throttling counters. Production does not persist these diagnostic copies.

## Model quality gate

Real-data testing did **not** justify treating either bundled 2B model as a reliable final writer:

- Qwen's first full-recording draft confused “two to three hours” with a count of cutscenes and mixed the unrelated food-hunt rules into the supplies note.
- Gemma's first full-recording draft invented a causal connection between getting food and the number of cutscenes. After stricter retrieval and focused prompting, it still described food as conditional on obtaining the compass, which the evidence does not establish.
- Both initially missed the requested early topics in the final recap. Citation recovery fixes omitted citation tags; time-balanced selection prevents a long later cruise chapter from crowding out an earlier challenge. Additional verbatim requirement passages preserve short constraints even when the model skips them.
- Apple's Foundation Model reports available, but actual generation failed here with `ModelManagerServices.ModelManagerError` code 1008. Availability alone is not a working model test.

Consequently, local final output uses **quoted transcript evidence**, not the small model's unsupported paraphrases. Its provenance is “Transcript excerpts · local fallback.” The local final pass does not run a 2B model: final text comes directly from cited passages, with ellipses for bounded quotations. This removes the unnecessary local generation load as well as unsupported paraphrases. This removes invented causal links and count/unit conversions. The original shorthand stays untouched, and the car question remains unmatched in this meeting.

A stronger configured cloud provider is used only when the existing “Use cloud models” setting is enabled and a key is present; it receives bounded text excerpts, not audio. Cloud failure returns to local evidence. No cloud request was made during this investigation. Cloud quality has **not** been measured here; using that provider is the next test for fluent summaries. The local fallback is deliberately faithful rather than pretending the 2B model passed a quality gate it failed.

The earlier car statement was verified in recording `2AF629C6-8CB5-4CE9-AD0A-D3B475E4A4F8` at 23.7 and 35.1 seconds, preceding this recording. The later car-rental discussion in the current recording is not evidence that the car was broken.

## Final local result on the real recording

- `how many cutscenes left?` → **“Probably a couple cutscenes”**, replacing the unsupported “1 billion left.”
- `needs compass + food` → **“I need my compass” “unless I get more food”**, preserving the two independent source statements rather than inventing a relationship.
- `car broken earlier?` → remains plain and unmatched in this meeting; the earlier recording was verified separately.
- Also discussed: **8 cited passages**, including Hokkaido reservations at 07:40 and the Japan food-hunt rules at 07:56. The latter preserves six of eight items, one hour, no phone, and the restriction against buying from the same store. Later passages cover the Hawaiian cruise, its rules and amenities, dining, and the volcano.

The local final-note pass took **0.12 seconds** after batch ASR and required no text-model inference. That is distinct from the 85–137-second CPU-only experimental model passes, whose unsupported rewrites were rejected. The source ASR still has imperfections (including food-name spellings), so excerpts are shown as source wording, not polished factual prose. Fluent cloud output remains a separate quality test when permitted and configured.

Reproduce the local fallback without cloud or a text model:

```sh
.build/debug/WorkScribe --verify-notes .artifacts/words/batch-final.json --note-provider local-final
```

## Final checks

All passed on the `words` worktree:

- `swift test --disable-sandbox --jobs 4`: **199 tests**, no failures. The extra flag is required because this execution environment disallows SwiftPM's nested `sandbox-exec`; it does not change which tests run.
- `.build/debug/WorkScribe --verify-api`
- `.build/debug/WorkScribe --verify-purge`
- `cd obsidian-plugin && npm install` completed before plugin checks.
- Plugin `npm test`: **88 passed, 2 opt-in skips**; `npm run build`; `npm run smoke`.
- `WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test`: **90 passed, no skips**.
- Original `system.wav` SHA-256 before/after matched.

The tests cover missing timestamps, missing word metadata, repeated-word alignment, empty partial/final handoff, load-shedding preservation, the exact notes plus unrelated later car/ship distractors, full-topic coverage, source-quote fallback, provider data boundaries/provenance, batch-before-notes ordering, idempotence, Resume/purge fences, and preventing live enhancement from racing batch finalization. The API publishes polishing-message changes as well as progress; native and Obsidian labels use the design's wording. No physical capture or visual-motion claim is made by these checks.

No changes were made to the original meeting library, `ws-verify`, or the main checkout. The copied replay and evaluation artifacts remain ignored in this worktree.

## Commit handoff

The implementation and checks are complete, but the requested Git commit could not be created: the managed filesystem denied `<local-workspace>` with `Operation not permitted`. All changes remain in the `words` worktree, unstaged. No alternate executor or permission bypass was used.

A complete tracked-plus-new-file patch is in `.artifacts/words/words.patch`, with its base revision and checksum beside it. From this existing worktree, the remaining user/coordinator action after Git writes are permitted is:

```sh
git add Sources Tests/WorkScribeCoreTests/TranscriptQualityTests.swift \
  Tests/WorkScribeTests/TranscriptPolisherTests.swift \
  obsidian-plugin/src/ui/note-editor.ts docs/research/words/README.md \
  scripts/score-transcript-replay.py
git commit -m "Preserve transcript words and add batch-backed final notes"
```

The patch is for applying to a clean checkout of its recorded base; do not apply it over this already-modified worktree.
