# Core merge and deletion — stage 1

Scope: merge `e4b-noaudio`, `e4b-vault`, `e4b-retrieval`, then `e4b-decision` into `core`; remove retired implementations without redesigning the planner, chunkers, or scheduler. Product direction is on-device, Obsidian-first jot enrichment with resident Gemma 4 E4B generation, EmbeddingGemma 2 retrieval, and streaming Nemotron/WeSpeaker. No audio retention or re-transcription.

## Seams for the rebuild specification

- **Generator naming versus responsibility.** `TitleModel`, `TitleGenerator`, and `TextModels.llama` describe a title model, but the same resident E4B performs notes, answers, briefs, and titles. `TextJob` still models per-job routing although there is one production generator.
- **Several enrichment passes.** Live enrichment, finalization, missed-topic discovery, action rephrasing, and briefing are separate prompt families and acceptance paths. The merged behavior is retained; stage 2 must decide how these fit short, evolving user-owned jots.
- **Evidence selection and generation are distinct gates.** Retrieval can select evidence that the decision stage or output validation later rejects. Retrieval metrics do not measure accepted note content or note quality.
- **Multiple chunking and indexing concepts.** Meeting evidence chunks, live transcript indexing, folder/Markdown sections, and vault indexing have different identities and admission rules. The selected vault can overlap folder indexing; merged guards must remain until a single ownership policy replaces them.
- **Background evidence cache lifetime.** `NoteEnhancer` caches vault/background snippets by meeting, note, and shorthand. New vault evidence can become stale within that lifetime; this is separate from transcript evidence evolution.
- **Application defaults versus evaluation defaults.** `RetrievalConfig()` describes the legacy lexical defaults while `RetrievalConfig.application()` selects the hybrid funnel. Fixtures must choose deliberately. Two cache-miss CLI spellings (`--list-embed-misses` and `--retrieval-cache-misses`) survive because both merged branches use them.
- **Global dependency hooks.** Embedder and background providers are mutable static hooks as well as instance dependencies. Their setup order matters, including in the eval CLIs. Do not interpret passing fixture tests as proof of the running app's hookup.
- **Live/final evidence horizons.** The eval cases can use completed-turn or started-turn horizons; final evaluation starts from original jots. That is different from replaying the running scheduler's evolving accepted lines. The live-union retrieval option preserves historical selections independently of generated lines.
- **Token budgets in more than one layer.** Retrieval limits, prompt construction, output token limits, and context size each bound different things. Full-template counts now use llama.cpp, including exactly one explicit BOS in budget measurements. The cap is applied to transcript evidence before background snippets and image observations are appended; those additions and the topics/actions/brief calls have separate limits. The decision gate runs on the budgeted transcript plan before background is attached.
- **Recording names after audio removal.** Recording sessions, capture controls, and historical audio fields remain for compatibility even though new capture retains only bounded in-memory audio and streaming text. Older artifacts/fixtures may still contain WAV paths.
- **Screen evidence and text generation lifecycles.** Screen OCR, embedding-based frame selection, image captioning, and note writing have separate model/loading paths. E4B image helper execution is still separate from the resident text session; stage 1 does not redesign that lifecycle.
- **Retention has several stores.** Meeting raw material, index rows, vault notes, image evidence, and conversation history have separate storage and purge rules. Preserve provenance and user content while clarifying final-note ownership in stage 2.
- **Single-entry compatibility APIs.** Model/backend/job enums and some measurement arguments still describe selection, although only E4B/llama is implemented. Kept as small compatibility seams instead of redesigning call sites.
- **Experimental decision contracts.** The merged decision stage adds gates, scores, evaluation fixtures, and model-policy variants. Its classifier research and failure semantics need to be reconciled with the single-generator product specification before promotion or redesign.

## Deliberately retained / uncertain deletion boundaries

- Plaud SDK integration: README documents an off-by-default `WORKSCRIBE_PLAUD=1` fork/integration path. Kept with its conditional tests; proprietary SDK execution is not part of the default build verification.
- Documented benchmark CLIs: `ScreenSceneBenchmark`/`--bench-scenes` are used by `docs/research/screen-scenes.md`; `EmbeddingVectorBenchmark`/`--bench-real-vectors` and `WorkScribeVectorBench` are used by `docs/research/vector-store-benchmark.md`. Kept under the explicit test/doc exception.
- The merged decision benchmark and optional classifier heads: retained with their tests as part of the requested merge; their eventual product role is a stage-2 decision.
- Model-backed verification CLIs and fixture evaluation: retained because they exercise application code and expose regressions. They are not alternative product generators.
- Historical research and measured artifacts: retained where they explain product behavior or a surviving test/tool. They are evidence of their original runs, not current performance claims.
- Audio-file replay/import verification and old recording metadata: kept where needed to feed streaming verification or the documented Plaud option; not a license for new production audio storage.

## Verification and commits

The completion record below identifies the commands, counts, merge conflict resolutions, deletion areas, and commit IDs. Logs are written to `/private/tmp/claude-501/handoffs/core/`. Every model-loading test command is serialized with `/private/tmp/claude-501/handoffs/gpu-lock`. Application test state is redirected to that handoff directory; temporary fixtures and build/cache state stay in this clone.

### Ordered commits

Each merge was built and tested before committing. Counts below compare each commit with its first parent; they include changed documentation and tests.

| Commit | Area | Added lines | Removed lines |
| --- | --- | ---: | ---: |
| `c612965` | Merge e4b-noaudio into core | 499 | 749 |
| `27b5e44` | Merge e4b-vault into core | 891 | 66 |
| `0090c13` | Merge e4b-retrieval into core | 531 | 35 |
| `b1a76cb` | Merge e4b-decision into core | 1,344 | 48 |
| `acbb737` | Remove superseded raw-prompt benchmark harness | 13 | 41,076 |
| `ef74001` | Remove MLX and alternate generator runtimes | 106 | 1,902 |
| `e58890d` | Remove Dory evaluation adapter and benchmark preparation | 16 | 1,274 |
| `3dfc93c` | Limit runtime repair and packaging to product assets | 75 | 52 |

A final documentation-only commit records this report; its own lines are not included in the table above. No commits were pushed.

### Verification counts

All rows include a successful default `swift build`, the full default Swift suite under `gpu-lock`, Python script tests, and all 91 plugin tests with both real Swift API contract tests enabled. The plugin TypeScript/build and smoke checks passed at each merge and after each source-cleanup area. The raw-harness deletion required only its affected Python tests; source tests were rerun for subsequent areas.

| Tree / area | Swift tests | Swift skips | Python script tests | Python skips | Legacy harness tests | Plugin tests |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline `282c8ca` | 269 | 3 | 27 | 1 | 10 | 91 |
| noaudio merge | 270 | 3 | 27 | 1 | 10 | 91 |
| vault merge | 281 | 3 | 27 | 1 | 10 | 91 |
| retrieval merge | 285 | 3 | 27 | 1 | 10 | 91 |
| decision merge | 291 | 3 | 29 | 1 | 10 | 91 |
| Remove generator alternatives | 284 | 0 | 29 | 1 | removed | 91 |
| Remove Dory | 280 | 0 | 24 | 0 | removed | 91 |
| Final runtime cleanup | 280 | 0 | 27 | 0 | removed | 91 |

Counts are discovered/executed totals; skips are included in those totals. Baseline/merge Swift skips were the unavailable Qwen tokenizer and two MLX integration checks. The decision scoring integration was explicitly enabled in the successful decision-merge run and later runs. `WORKSCRIBE_TEST_E4B=1` and `WORKSCRIBE_TEXT_MODEL` enabled real E4B prefix checks throughout. Removing retired implementations removes their tests; the native vocabulary now has an 11-row independent reference-count check and is compared with actual generator prompt counts.

The legacy harness tests lived outside `scripts/tests` discovery. Their exact three source files were extracted for each baseline/merge revision into clone-local scratch and all ten tests passed for every revision. The original decision-merge Python attempt exposed missing SciPy; its successful rerun used a clone-local virtual environment with the pinned CPU test requirements. The retrieval suite's first real EmbeddingGemma load required an ANE compile; the completed run passed. No note-quality score is asserted.

Additional checks: `git diff --check`; shell syntax for bootstrap/build packaging; isolated `bootstrap.sh --check`; and executing the eight-file packaged repair payload with `--check` against an empty handoff runtime. That payload reported missing product assets without downloading or importing evaluation dependencies. Runtime tests confirm old receipts do not trigger validation and product-only migration leaves retired source files intact.

### Conflict resolutions

- Vault: use the protocol-based `Embedder` provider while preserving the no-audio streaming-drain warm-up description.
- Retrieval: preserve vault snippets, background-source attribution, both cache-miss interfaces and vault exclusion; combine them with rank-cutoff metrics, native-count support, query expansions and prompt budgets. Rank-cost diagnostics include background text too.
- Decision: retain query-expansion inputs when filling embeddings, both injected background and decision providers, and every CLI dispatch. Apply the existing transcript budget before decision filtering so the gate sees the bounded plan the generator will receive.

### Boundaries

This verifies the default build and test configuration, including real E4B and EmbeddingGemma activity. It does not certify a live microphone/call, native UI behavior, signed release packaging, or the opt-in proprietary Plaud SDK build. The planner, chunkers, scheduler, and decision policy were not redesigned after the four merges. Existing shared model files, installed apps, other clones and the user's meeting library were not modified. Scratch/build outputs in this clone are removed after verification; logs and the check harness remain under `/private/tmp/claude-501/handoffs/core/`.

Net tree diff from starting `core` (`282c8ca`), including this report: **3,516 added / 45,158 removed lines** across 226 files.
