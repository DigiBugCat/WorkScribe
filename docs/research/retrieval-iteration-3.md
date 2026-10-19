# Retrieval iteration 3

`RetrievalConfig` is shared by `NoteEnhancer` and `--eval-retrieval`. Its initializer preserves the previous lexical selector: live threshold 0.3, time weight 0.6, top 4; final threshold 0.3, time weight 0.15, local-meaning preference and 0.75 question coverage, top 4, 12-second question-following context. `WORKSCRIBE_RETRIEVAL_CONFIG=/absolute/retrieval.json` loads a JSON override in the app. Unknown keys and invalid values fail, rather than silently becoming defaults.

The prior selector was BM25. EmbeddingGemma 2 only supplied the later relevance gate for notes selected by time alone. `embeddingWeight` makes semantic ranking explicit: 0 is BM25, 1 is cosine, intermediate values blend the two normalized scores. `diversityWeight` applies MMR after thresholding. `maxPerNote` counts seeds; neighbor and answer windows can add passages. The existing character budget still applies to ranked selection; the evaluator measures actual prompt tokens including following context and final fallback.

## Evaluation

```sh
.build-codex/debug/WorkScribe --eval-retrieval cases.jsonl --out retrieval.json
.build-codex/debug/WorkScribe --eval-retrieval cases.jsonl --config config.json --embed-cache embeddings.json --out retrieval.json
```

The input is the existing cases.v3 JSONL. Gold is decoded separately from the transcript/jots and never enters retrieval. Each live snapshot uses the case's declared/existing horizon, with only jots typed by then; final sees the complete meeting. Every jot is measured, regardless of generation throttling, acceptance or abstention gates. These are retrieval metrics, not note quality.

Each row records all selected segment IDs, including grouped chunk membership and the final question's following-answer context. A chunk crossing segments carries only the segment IDs intersecting that chunk's words. Gold is intersected with available segments before scoring. Empty-gold rows have undefined recall and are excluded from recall/zero-hit denominators. Empty selections have undefined precision. F1 is `2*hits/(selected+gold)`. The report emits both micro counts and macro recall, zero-hit rate among answerable notes, and false-match rate among abstention notes with no gold evidence. Abstention notes that list evidence are exempt from the false-match penalty. The denominator is explicit in each aggregate.

Prompt-token counts use the pinned E4B tokenizer, the unchanged per-note prompt and chat template, including BOS. They include shared rules in each separate note call; `evidence_tokens` also reports selected prose alone. The tokenizer defaults to the local pinned E4B benchmark download; `--tokenizer` or `WORKSCRIBE_E4B_TOKENIZER` supplies another path. No generator is loaded.

## Cache and tuning

```sh
# Requires Core ML access; run outside the agent sandbox.
.build-codex/debug/WorkScribe --fill-embed-cache cases.jsonl embeddings.json
# Entirely CPU; no Core ML or text generation calls with this cache.
python3 scripts/tune-retrieval.py cases.jsonl --binary .build-codex/debug/WorkScribe --embed-cache embeddings.json --out tuning
```

Cache keys are model ID, query/document role and SHA-256 of the exact UTF-8 text. Role must be included because EmbeddingGemma uses different prompts. No whitespace or Unicode normalization is performed. The cache contains normalized vectors; an ID/dimension mismatch during refill fails. A missing entry stops evaluation, lists **all** missing texts and roles and writes no partial report. Cache fill covers individual segments, chunk sizes 30/60/90/120 with grouping on/off, all four query modes, and all live/final snapshots. Refill with `--config` for custom chunk sizes. The file is published atomically after successful completion.

The deterministic search first generates bounded knob candidates, then independent query-expansion, hybrid, question-following and live-union ablations. Expansions are a fixed general abbreviation dictionary and/or the user's contemporaneous jots, never gold answers. Each config is evaluated once per case; each leave-one-case-out fold selects its config **and structural idea** on the other cases only. Training scores give cases equal weight, average live/final macro recall and subtract 0.3 times empty-gold abstention false-match rate. Defaults bound mean full-prompt tokens at 1,400 per job and every prompt at 6,144. A held-out budget violation disqualifies promotion. The final recommended config is fit on all cases only after held-out evaluation. It is not an independently held-out evaluation of that one final fitted config. Twelve cases remain a small development set.

`--lexical-only` runs the non-semantic subset while the external cache is pending; its report identifies that limitation. It cannot establish a hybrid or embedding result. Reports/cache keys include binary, cases, tokenizer and cache hashes; use an immutable binary during a sweep. `result.json` includes per-fold choices, training scores, held-out job metrics, in-sample metrics and the recommended config. No script edits the app default.

`unionLive` reuses raw live segment selections during evaluation and in the app. `NoteEnhancer` keeps only the current meeting's latest selections in memory, including selections whose generated lines were rejected, and ignores saved selections after a jot edit. After an app restart, existing retained excerpt references are also eligible. This does not add scheduling work or new generation calls.
