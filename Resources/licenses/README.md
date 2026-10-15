# Third-party notices

These notices cover third-party software and downloaded model assets, **not a
license grant for WorkScribe itself**. Reviewed against upstream on 2026-10-15.
Models remain in the runtime home; they are not bundled into WorkScribe.app.

| Component | Terms / retained evidence |
| --- | --- |
| NeMo-Speech.cpp 0.2.0, native headers and runtime | Apache-2.0; `nemo-speech/` preserves LICENSE, NOTICE and the complete license directory from the checksum-pinned official macOS archive, including MIT/BSD/Apache dependencies. [Upstream](https://github.com/NVIDIA/NeMo-Speech.cpp/tree/v0.2.0). |
| NVIDIA ASR and diarization models | OpenMDW-1.1; `nvidia-models/` contains full terms, exact-revision model cards and attribution. Redistributable with agreement and applicable notices. |
| Qwen3.5-2B, Gemma 4 E2B (title and vision) | Apache-2.0; full text in `apache-2.0/LICENSE`, provenance in `Sources/CTextGeneration/vendor/MODEL-NOTICE.txt` and `image-understanding/`. [Qwen](https://huggingface.co/Qwen/Qwen3.5-2B), [Gemma 4](https://ai.google.dev/gemma/docs/gemma_4_license). |
| llama.cpp / ggml / image helper | MIT; `llama.cpp/LICENSE`, native archive notices and vendored header license. Image-helper commit `e467e5b5e5ba43071d6151b3d881deb9300d000e`. |
| EmbeddingGemma 2, Core ML conversions, FluidUse | Apache-2.0; `embeddinggemma2/` records revisions, SHA-256, converter attribution and FluidUse license. |
| FluidAudio 0.17.5 | Apache-2.0; `fluidaudio/FluidAudio-LICENSE`. The existing CC-BY-4.0 file covers only the named Community-1 artifacts, not every model in that repository. |
| FluidAudio transitive code/resources | `fluidaudio/ThirdPartyLicenses/` retains fastcluster, VBx, Japanese and Spanish/French G2P notices. `nemo-text-processing/` retains the Apache-2.0 v0.3.1 native text-normalization engine and its Rust/FST transitive notices (also pulled through FluidUse). |
| Legacy `wespeaker_v2.mlmodelc` | **Unresolved weight provenance.** `wespeaker/` retains the upstream Apache implementation license and publisher README; `fluidaudio/NOTICE.md` explicitly excludes this legacy conversion from its current license-scope confirmation. Obtain clarification before redistributing its weights. |
| DigUp-derived search code | MIT; `digup/` identifies ported files and retains the license. |
| Obsidian plugin packages and build tools | `npm/packages.json` inventories every installed direct/transitive package at the lockfile versions; adjacent files retain their actual license texts. The plugin bundles Lezer Markdown/common/highlight (MIT); `obsidian-plugin/THIRD_PARTY_NOTICES.txt` travels with plugin installation. Obsidian and CodeMirror are host-provided externals. |
| CMake (only when no system CMake exists) | BSD-3-Clause; `cmake/LICENSE`. Downloaded build tool, not included in the application. |
| Optional Plaud SDK | Proprietary and **not distributed by this project**. Supply your own authorized frameworks and follow the vendor's SDK agreement. Do not redistribute them based on WorkScribe's notices. |

No inspected public runtime/model license expressly prohibits redistribution.
That does not resolve the legacy WeSpeaker provenance gap, grant rights to the
private Plaud SDK, or license WorkScribe. NeMo's broad source notice mentions
LGPL KenLM; this ASR archive's shipped dependency directory is retained as-is.
Any different runtime build must preserve its own notices and meet its own
linking/source obligations.
