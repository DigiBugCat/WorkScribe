**The strongest finds are a frozen-embedding audio classifier, an experimental speech-to-text conversion, calibrated decision fine-tunes, and a native Core ML audio-search implementation.**

X/Twitter searches had poor direct indexing; I recovered several posts through indexed mirrors and followed their linked artifacts. **“Verified beyond tweet” below means I inspected a model card, repository, or substantive writeup—not that I reproduced its benchmarks.** I excluded first-generation EmbeddingGemma examples.

1. **Manuel Romero / `mrm8488` — typed workflow decisions.**  
   **Method:** Embed state, question, and options separately using the `Classification` prefix. A schema-conditioned scoring head learns corrections to similarity scores. Train the head on frozen embeddings, then fine-tune encoder and head together; fit temperatures per question type. This is more than a linear probe and does not generate text.  
   **Stated results:** Accuracy rises from **67.7% frozen-encoder to 76.4% fine-tuned** on `LocalLLaMA/typed-decisions`; Brier score improves from **0.113 to 0.065**. The author explicitly says hyperparameters were selected while inspecting the test split.  
   **Verified beyond tweet:** **Yes—model card and training recipe.** Benchmark remains author-reported. [Model](https://huggingface.co/mrm8488/embeddinggemma-2-ft-typed-decision) · [Indexed X announcement](https://ww.twstalker.com/GlennCameronjr)

2. **J33.AI — calibrated decisions with an abstention threshold.**  
   **Method:** Fine-tune the text encoder plus a **0.59M scoring layer**. State, question, and options share a sequence; scores are read at option markers. Soft-label cross-entropy, shuffled options, and held-out temperature calibration.  
   **Stated results:** **75.2% accuracy, 0.019 expected calibration error**, and **33 ms median per case on the training GPU**. Under its +1 correct/−5 incorrect scoring, it handles 39.9% of decisions above the 83.3% confidence threshold. Synthetic data; four workflow domains; one training seed.  
   **Verified beyond tweet:** **Yes—model card with split, calibration, and evaluation details.** No X post verified. [Model](https://huggingface.co/J33-AI/j33-jev)

3. **Suzuki Shoten / `matu79go`, Reflex-2 — sound events, voice emotion, and video-event detection.**  
   **Method:** Keep EmbeddingGemma 2 frozen; train **logistic-regression heads on its 768-dimensional vectors**. One embedding can feed multiple classifiers. Video detection uses rolling windows.  
   **Stated results:** Ten sound classes from ESC-50: **35% zero-shot → 96.3% with a head**, using the official five folds. Eight-class voice emotion: **14% → 52% on unseen speakers**. Fall detection: **95.7% balanced accuracy with held-out people**. A separate 40-clip sound comparison reports 100% and 49 ms per judgment on NVIDIA GB10—not a Mac or phone measurement.  
   **Verified beyond tweet:** **Yes—model card, repository, and writeup.** This is the clearest concrete linear-probe example. [Model](https://huggingface.co/matu79go/Reflex-2) · [Repository](https://github.com/matu79go/reflex-2) · [Writeup](https://suzuki-shoten.dev/projects/reflex-2/)

4. **Shahir / `@TslShahir`, Haku — turn the audio encoder into speech-to-text.**  
   **Method:** Freeze the audio encoder; train a small CTC-style “reader” that maps audio slices into EmbeddingGemma’s text space, then selects among approximately **229,000 English word embeddings**. A separate small model restores punctuation and capitalization.  
   **Stated results:** **One hour in 12.6 seconds on an 8 GB M3 MacBook Air**, using the Neural Engine; approximately **5% WER**, without a clearly specified standard benchmark on the landing page. Training reportedly took under two hours on eight H100s. English-only reader.  
   **Verified beyond tweet:** **Partly—working-app download page and detailed author discussion, but no released training source found.** The author says open-sourcing is forthcoming. [X post](https://x.com/TslShahir/status/2109660368381395414) · [Project](https://eg2.haku.sh/) · [Author’s technical discussion](https://news.ycombinator.com/item?id=50069971)

5. **Alex / FluidInference — Core ML text on ANE, audio search on GPU + ANE.**  
   **Method:** Convert unchanged weights to Core ML; use fixed sequence buckets and numerically stabilized normalization. Text runs on ANE; the audio encoder runs on GPU. Ten-second, 16 kHz windows become audio tokens, then pass through the shared text model.  
   **Stated results:** On M5 Pro: **3.2 ms for 64-token text**, **644 short texts/s with packing**, and **4.5 hours of audio indexed in 38 seconds**. An earnings-call check preserved the top result for 15/15 queries versus FP32, with 95% top-five overlap.  
   **Verified beyond tweet:** **Yes—detailed model card, downloadable packages, and Swift demo targets.** These are small parity/retrieval checks, not broad audio-quality validation. [Core ML model](https://huggingface.co/FluidInference/embeddinggemma-2-coreml) · [FluidUse repository](https://github.com/FluidInference/FluidUse)

6. **VIDRAFT / FINAL-Bench — browser-based multimodal decision cards.**  
   **Method:** A decision fine-tune exported to ONNX. Embed media plus a classification question; cache option embeddings; compute **softmax(19.96 × cosine similarity)**. Runs through Transformers.js/WebGPU, with microphone decisions over two-second windows.  
   **Stated results:** Live camera/audio decision cards, confidence gates, and 18 labeled image tests. **No aggregate accuracy or latency result stated in the inspected article.**  
   **Verified beyond tweet:** **Partly—substantive implementation writeup; the linked Space could not be fetched for independent source inspection.** [Writeup](https://dev.to/ginigen_ai_010d9180cbbdb1/zero-token-decisions-in-the-browser-on-device-multimodal-classification-with-embeddinggemma-2-and-3keo) · [Demo](https://huggingface.co/spaces/FINAL-Bench/Decision-AI-Web)

7. **`sungreong` / 데이터분석뉴비 — Korean complaint routing, including a negative reranker result.**  
   **Method:** No EmbeddingGemma fine-tuning. Encode complaint summaries with `SearchQuery`; encode detailed category descriptions as documents; truncate and renormalize to 256 dimensions. Optionally rerank shortlisted categories with an existing LAYA checkpoint.  
   **Stated results:** On 81 synthetic cases across 27 categories, embedding-only routing achieves **71.6% top-one and 98.8% recall@5**. Adding LAYA reranking reduces accuracy to **50.6%**. Nine unseen categories achieve 59.3% top-one on 27 cases.  
   **Verified beyond tweet:** **Yes—detailed methods, tables, pinned model revision, and repository link.** Small synthetic evaluation; the reranker was not trained specifically on retrieval-generated candidates. [Experiment](https://data-newbie.tistory.com/m/1212) · [Repository](https://github.com/sungreong/laya-korean-eval)

8. **`unco3` — probing spoken meaning versus vocal delivery.**  
   **Method:** Generate Japanese speech with Irodori-TTS saying reassuring words in a frightened voice; compare its audio embedding against textual descriptions of content and emotional delivery. No training.  
   **Stated results:** The literal “everything is fine” description ranks first; “speaking nervously and fearfully” ranks second.  
   **Verified beyond tweet:** **Partly—experiment description, embedded audio, and reported ranking.** One constructed example, no controlled corpus, and **no speaker-identity test**. Useful evidence that semantic audio vectors can mix lexical content and vocal characteristics. [Experiment](https://note.com/unco3/n/nb2fd22b19f48)

9. **Yash Sharma / `ysharma` — find image-generation LoRAs from example imagery.**  
    **Method:** Contrastively fine-tune EmbeddingGemma 2 on image–image pairs and image–model-description pairs. Uses cached multiple-negatives ranking loss wrapped in **Matryoshka loss at 768/512/256/128 dimensions**. “LoRA finder” describes what it retrieves; it does not establish that training itself used LoRA adapters.  
    **Stated results:** Training card lists **587 image-pair examples, 1,281 image–text examples, and 29.5 minutes of training**. No held-out retrieval score found.  
    **Verified beyond tweet:** **Yes—published model and detailed training card.** [Model](https://huggingface.co/ysharma/embeddinggemma-2-lora-finder)

10. **Abdur Rahim / ARahim3, DigUp — search recordings and jump to matching moments.**  
    **Method:** Swift macOS app using quantized EmbeddingGemma 2 through llama.cpp/Metal. Index overlapping **30-second audio windows**, video frames, document passages, and images in SQLite; combine semantic matches with exact-word matches.  
    **Stated results:** Natural-language searches open recordings/videos at the matching timestamp. The README reports query embeddings in milliseconds, but gives no broad retrieval-accuracy score.  
    **Verified beyond tweet:** **Yes—repository and documented implementation; promoted by Google Gemma on X.** Useful reference for timestamp-preserving indexing and playback. [Repository](https://github.com/ARahim3/DigUp) · [Indexed X promotion](https://ww.twstalker.com/GlennCameronjr)

11. **Stevyhacker, LokalBot — embedding search inside a local meeting recorder.**  
    **Method:** Quantized EmbeddingGemma 2 text retrieval through llama.cpp, alongside separate transcription, diarization, summarization, and autocomplete components.  
    **Stated results:** On 48 authored English/Serbian/Montenegrin queries over 60 synthetic passages: **43/48 correct top-one, 48/48 top-five, 9 ms median query latency** on M4 Max. The author acknowledges the quality difference versus Harrier is within statistical noise.  
    **Verified beyond tweet:** **Yes—benchmark page and linked repository report.** Its speaker and summary results belong to other models, not EmbeddingGemma 2. [Benchmarks](https://www.lokalbot.com/benchmarks) · [Embedding report](https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/EmbeddingGemma2/2026-10-07/REPORT.md)

12. **Prince Canuma / MLX-VLM — native Apple-silicon multimodal embeddings.**  
    **Method:** Native MLX implementation with selective tower loading, mixed-media inputs, and Matryoshka truncation. Provides BF16 and quantized conversions.  
    **Stated results:** The implementation reports **minimum embedding cosine 0.99979 for BF16 versus FP32 reference**; ordinary four-bit quantization falls to **0.96716**, failing its documented parity threshold. These are numerical checks, not retrieval accuracy.  
    **Verified beyond tweet:** **Yes—implementation documentation and validation details.** The X announcement advertises approximately 1 GB RAM; I did not reproduce that footprint. [Implementation](https://github.com/Blaizzy/mlx-vlm/blob/main/mlx_vlm/models/embedding_gemma2/README.md) · [Indexed X announcement](https://w.twstalker.com/gil_n_)

13. **Tamas Piros — one browser search box for sounds, video, photos, and notes.**  
    **Method:** Unmodified embeddings via Transformers.js/WebGPU, local IndexedDB storage, segmented audio/video, and dot-product ranking. Uses smaller dimensions with renormalization.  
    **Stated results:** **15–40 ms text-query embedding** and under 1 ms ranking on a tiny sample library. A “cats sleeping” search also retrieves a meowing sound; a technology query finds a video through its soundtrack. The author explicitly did not test the microphone path with a real microphone.  
    **Verified beyond tweet:** **Yes—repository and detailed measured writeup.** [Writeup](https://tpiros.dev/blog/embeddinggemma-2-in-the-browser/) · [Repository](https://github.com/tpiros/embeddinggemma-browser-search)

## Most relevant to a local macOS meeting recorder with speaker ID, shorthand-note enhancement, and live question cards

- **Use FluidInference’s native runtime for retrieval.** FluidInference supplies the most concrete native Swift/Core ML embedding path found. Its text and audio run on different accelerators; “all on ANE” would overstate the complete pipeline.

- **Use a small decision model to gate question cards.** Romero/J33-style heads could classify transcript windows as “question,” “unresolved question,” or “needs external context,” then trigger retrieval and generation. This is a proposed application—not a published meeting-specific result. The Korean routing experiment argues for measuring a simple similarity baseline before adding a reranker.

- **Keep speaker ID as a separate capability for now.** I found **no verified EmbeddingGemma 2 speaker-verification or diarization benchmark**: no same/different-speaker error rate, enrolled-speaker identification result, or diarization error rate. Reflex-2’s unseen-speaker emotion test does not establish identity preservation.

- **For lightweight audio experiments, copy Reflex-2’s frozen-vector probe first.** It gives concrete evidence for sound-event and vocal-emotion classifiers without changing the encoder. Whether it can identify your enrolled speakers remains an experiment requiring recordings across different sessions, wording, and microphones.

- **Treat Haku’s transcription conversion as promising but provisional.** Its speed is relevant; the missing released training code and incompletely specified WER evaluation make it a weaker foundation than its headline suggests. The author also reports a separate decision-model experiment that worked in trained domains but generalized only slightly above chance. [Author discussion](https://news.ycombinator.com/item?id=50069971)