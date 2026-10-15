# Can EmbeddingGemma 2 identify speakers?

Experiment run 2026-10-13. Question: can `google/embeddinggemma-2` (EG2, audio encoder only) do WorkScribe's voice matching, and how does it compare to the WeSpeaker v2 model we ship?

**Short answer: no, not as a replacement.** EG2's output vector describes *what was said*, not *who said it*. Its early audio-encoder layers do carry real voice information, and with a cheap trained head they reach about 8–9% EER. WeSpeaker gets 0.65% EER on the same test while running about 5× faster at roughly 1/200th the size. Fusing the two adds nothing measurable. Keep WeSpeaker.

## Setup

- **Data:** LibriSpeech test-clean, 40 speakers. The eval set is 20 clips per speaker (800 clips). Clips are 3–10 s, 16 kHz mono, and anything over 10 s is center-cropped to 10 s, as `VoiceEngine.readSamples` does; 267 of the 800 are crops. Selection uses seed 0. The other 1,429 utterances of 3 s or more are a **training-only** pool for the adaptations.
- **Splits:** 2-fold over speakers: train on 20, test on the other 20, then swap and average. No speaker appears in both train and test. All numbers below come from test halves only, for every method including the raw baselines.
- **WeSpeaker v2:** the exact `.runtime/models/wespeaker_v2.mlmodelc` WorkScribe bundles, run through coremltools `CompiledMLModel` (compute units ALL). It is fed the way FluidAudio's `EmbeddingExtractor` feeds it: waveform `[3,160000]` with the clip repeat-padded to 10 s in row 0, and mask `[3,589]` with row 0 all ones (VoiceEngine passes 589 ones).
- **EG2:** sentence-transformers with `config_kwargs={"vision_config": None}`, fp32, MPS. Audio is passed as `{"array", "sampling_rate": 16000}` with no prefix. Besides the final 768-d vector, I hooked the audio tower's conv front end, all 12 conformer layers and `output_proj`, and pooled each into a frame **mean+std** vector (x-vector-style statistics pooling, 2048-d).
- **Metrics:**
  - EER and TPR at 1% FPR over all same/different pairs within the test half.
  - **ID:** closed-set top-1 with 3 enrollment clips per speaker. The profile score is the max cosine over its clips, as in `VoiceMatching.suggest`. 10 random enrollments.
  - **Rule:** WorkScribe's literal accept rule (best ≥ 0.65 and lead ≥ 0.12), run open-set with 10 speakers enrolled and 10 acting as impostors. "ok" means a genuine query was accepted with the right name, "wrong" means it was accepted with the wrong name, and "FA" means an impostor was accepted.

## Results (test speakers, 2-fold average)

| Representation | Adaptation | EER | TPR@1%FPR | ID top-1 | Rule ok / wrong / impostor FA |
|---|---|---|---|---|---|
| **WeSpeaker v2 (shipped)** | none | **0.65%** | **99.4%** | **99.9%** | **96.1 / 0.0 / 0.0** |
| WeSpeaker v2 | PCA-whiten + LDA | 3.8% | 90.8% | 98.3% | 93.8 / 0.2 / 9.3 |
| EG2 final 768 | none | 39.9% | 6.7% | 26.0% | 0.2 / 0.0 / 0.0 |
| EG2 final 512 / 256 / 128 (Matryoshka) | none | 39.8 / 39.9 / 41.4% | 6.4 / 6.3 / 4.8% | 26 / 25 / 20% | ≈0 |
| EG2 final 768 | mean-centered | 38.6% | 10.7% | 28.6% | 0 |
| EG2 final 768 | PCA-whiten / +LDA | 41.5 / 40.2% | 8.4 / 5.0% | 23.5 / 17.6% | — |
| EG2 final 768 | linear / MLP AAM-softmax projection | 43.0 / 42.0% | 4.1 / 4.7% | 14.4 / 16.4% | — |
| EG2 final 768 | logistic head on enrollment clips (Reflex-2 style) | — | — | 29.9% | — |
| EG2 audio layer 0 (mean+std) | centered only | 9.0% | 70.5% | 93.6% | 80.8 / 0.2 / 5.5 |
| EG2 audio layer 0 (mean+std) | PCA-whiten + LDA | 8.5% | 76.1% | 93.6% | 85.8 / 0.4 / 12.6 |
| EG2 audio layer 0 (mean only) | PCA-whiten + LDA | 8.7% | 78.2% | 94.4% | 86.9 / 0.5 / 13.8 |
| EG2 audio layer 0 | linear AAM, 256-d | 9.6% | 70.3% | 93.4% | 76.5 / 0.6 / 17.0 |
| EG2 audio layer 0 | logistic head on enrollment clips | — | — | 92.6% | — |
| **EG2 conv + layers 0–3 concat** | PCA-whiten + LDA | **7.8%** | **79.9%** | **94.1%** | 86.7 / 0.4 / 19.3 |
| EG2 audio layer 5 / 8 / 11 | PCA-whiten + LDA | 16.5 / 23.1 / 25.5% | 40 / 28 / 20% | 71 / 55 / 48% | — |
| Fusion: WeSpeaker + EG2 layer 0 LDA | z-norm; weight tuned on an inner train split (0.93 to WeSpeaker) | 0.58% | 99.5% | 99.9% | — |
| Fusion: WeSpeaker + EG2 final LDA | (0.85 to WeSpeaker) | 0.68% | 99.4% | 99.9% | — |

**Speaker information drops layer by layer.** Layer-wise LDA EER for conv, then layers 0 through 11, then proj: 8.8, 8.5, 9.4, 9.9, 10.1, 14.7, 16.5, 15.6, 17.6, 23.1, 22.7, 24.9, 25.5, 28.5%. The encoder throws voice identity away as it builds toward language.

**EER by clip length** (only pairs where both clips fall in the bucket; 314 / 219 / 267 clips):

| | 3–6 s | 6–10 s | 10 s (cropped) |
|---|---|---|---|
| WeSpeaker | 0.9% | 0.0% | 0.0% |
| EG2 final | 41.5% | 39.4% | 34.8% |
| EG2 layer 0 + AAM | 13.2% | 7.3% | 5.2% |

Longer windows help EG2 a lot, and the 10 s window FluidInference's Core ML port uses is the best case. Even at 10 s, the gap to WeSpeaker stays large.

**Runtime per clip** (M-series Mac): WeSpeaker Core ML takes **14 ms**. EG2 takes **~70 ms** on MPS in fp32 (190 ms on the first small batch), and that is the full audio tower plus the 24-layer text stack. A layer-0-only path would be far cheaper, but I didn't measure it. Size: WeSpeaker `.mlmodelc` is 7.6 MB; EG2 is 1.4 GB in bf16 safetensors (audio tower alone is ~300M parameters).

## Why: EG2 encodes content, not voice

- **Real speech:** EG2's audio vector retrieves *its own transcript* (embedded as text by EG2) out of 800 candidates **99.5%** of the time (chance 0.1%). Its nearest *audio* neighbour is the same speaker only 35% of the time.
- **Same sentence, different voices:** 8 macOS `say` voices each spoke the same 10 sentences. EG2's final vector puts each clip's nearest neighbour on **the same sentence by a different voice 89%** of the time and on the same voice only 11%. Cosine for same text with a different voice is 0.87; for the same voice with different text it is 0.69. WeSpeaker does the opposite: same voice 100%, cosine 0.88 vs 0.17. EG2 audio layer 2 also finds the same voice 99% of the time; by layer 11 it is back to 12%. This is synthetic TTS, so treat it as directional.

So the near-chance raw result is not a calibration problem that whitening can fix. The final vector is built to be invariant to the speaker, the same way a good text embedding is invariant to font. Trained projections on it can't recover what was pooled away; they overfit and get worse (43% EER).

## What was tried, in order

1. Raw EG2 vectors and Matryoshka truncations: near chance (~40% EER).
2. Mean-centering, PCA-whitening and LDA fitted on disjoint speakers: no help on the final vector.
3. Small trained projections on frozen embeddings (linear and 2-layer MLP, AAM-softmax, trained on 20 speakers with about 1,100 clips and tested on 20 others): no help on the final vector. On early layers they land around 8–10% EER, no better than LDA; 1,100 clips is too little to train a speaker head.
4. Per-frame audio-encoder hidden states with mean+std statistics pooling: this is where EG2's voice information is (8–9% EER). Concatenating the early layers gives the best EG2 result, 7.8% EER.
5. Score fusion with WeSpeaker: 0.58–0.68% vs 0.65% alone. That difference is noise on 40 speakers, and the tuned weight stays at 0.85–0.95 on WeSpeaker. EG2 adds nothing WeSpeaker doesn't already have.
6. Logistic-regression heads on 3 enrollment clips (the Reflex-2 frozen-probe recipe): 30% on the final vector and 93% on layer 0. Both are well below WeSpeaker's 99.9% cosine.

## Recommendation for WorkScribe

- **Keep WeSpeaker v2 for voice matching and keep the 0.65 / 0.12 rule.** On clean speech the rule accepted 96% of genuine queries, made no wrong-name suggestions, and accepted no impostors in this test. The best EG2 variant would need its own thresholds and still let through 13–19% of impostors at comparable acceptance.
- **Don't fuse.** It costs 70 ms and 1.4 GB per clip for no measurable gain.
- **Use EG2 for what it is good at:** what was said. The audio vector matches its own transcript with 99.5% accuracy, so EG2 fits spoken-content search over recordings (find the part where someone talked about X, without depending on ASR text), meeting/topic clustering, and audio↔text retrieval. Those are the uses in `embeddinggemma-2-uses.md`. It is not a voice-identity model.
- If EG2 is already loaded for search and a second opinion on voice is ever wanted, tap audio layer 0 (mean-pooled) plus an LDA fitted on a public speaker corpus. Expect about 9% EER, roughly 13× worse than WeSpeaker. It isn't worth building now.

## Caveats

- LibriSpeech is read audiobook speech: clean, one mic per speaker. Meeting audio (far-field, overlap, codec) will hurt both models. WeSpeaker's 0.65% will rise there, but nothing here suggests EG2 would close the gap.
- There are only 40 speakers. Differences under about 0.3% EER between WeSpeaker variants are noise.
- The adaptations were trained on 20 speakers. A head trained on VoxCeleb-scale data over EG2's early layers would do better than 8%, but at that point it is a WeSpeaker-style model built on a weaker front end.

## Scripts and artifacts


- `scripts/make_libri.py`, `scripts/make_extra.py`: clip selection (eval set and training-only pool)
- `scripts/embed.py`: WeSpeaker Core ML + EG2 final vectors + per-layer mean/std taps, cached to `emb/*.npy`, with timing
- `scripts/evaluate.py`: all metrics, adaptations, fusion and duration breakdown; results in `emb/results.txt` and `emb/results.json`
- `scripts/make_say.py`, `scripts/probe_say.py`: same-text/different-voice TTS probe (`emb/say_probe.txt`)
- `scripts/content_probe.py`: audio→transcript retrieval (`emb/content_probe.txt`)
