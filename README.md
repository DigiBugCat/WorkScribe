# WorkScribe

Inspired by [Google AI Edge Foresight](https://developers.google.com/edge/foresight), built for Obsidian. WorkScribe is an independent project, not affiliated with Google.

WorkScribe is an on-device, Obsidian-first note enrichment engine. It captures streaming speech with speaker labels and enriches your jots with supported meeting and vault context. It runs speech recognition, search, and note enhancement on your Mac. An Obsidian plugin puts live notes, cited answers, and meeting search in your vault; the app also works on its own. Models download during setup. After that everything runs on your Mac: WorkScribe has no cloud features, no API keys and no cloud fallback.

## Build from source

### Requirements

- **Apple Silicon Mac, macOS 26 or newer.** Intel Macs are not supported by the pinned native runtime.
- **Full Xcode 26 or newer with Swift 6.2+**. Command Line Tools alone do not provide the Core ML compiler. Open Xcode once to finish installation and accept its license, then select it if needed:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **Python 3.12+**, **Node.js 22+ with npm**, and Git on your shell's `PATH`. For example, with [Homebrew](https://brew.sh/): `brew install python node git`.
- **16 GiB free disk space minimum for a fresh setup; 20 GiB recommended**, plus room for notes and captured images. Setup checks the remaining download and build space. **16 GB memory recommended** for simultaneous speech, search, and image models; this is guidance, not a measured minimum.
- Internet access to GitHub, Hugging Face and npm during setup (PyPI too if CMake must be installed). There is no paid service or model token in the default setup.
- [Obsidian desktop](https://obsidian.md/) if you want the vault integration.

Run these commands in Terminal:

```sh
git clone https://github.com/DigiBugCat/WorkScribe.git
cd WorkScribe
scripts/bootstrap.sh
swift build
scripts/build-app.sh
open dist/WorkScribe.app
```

`bootstrap.sh` checks prerequisites, downloads and SHA-256-verifies **all pinned models**, prepares the native runtime and Core ML models, builds the image-caption helper, and runs `npm ci` for the plugin. Pinned model files already on the Mac (for example an earlier Hugging Face download) are reused from folders named in `WORKSCRIBE_MODEL_SOURCES` (or `runtime-doctor.py --model-source DIR`) when their SHA-256 matches. It does not install Xcode, change your system Python, or require `sudo`. Run it again after an interruption: verified files are reused, incomplete downloads resume when the server supports byte ranges, and replacements are published only after verification. `scripts/bootstrap.sh --check` checks prerequisites and space without downloading. Runtime repairs alone: `python3 scripts/runtime-doctor.py`. Setup remembers that Python executable for repairs launched from Finder; `WORKSCRIBE_PYTHON` can override it.

The debug executable is `.build/debug/WorkScribe`. The build script creates a signed release app at `dist/WorkScribe.app`; models stay outside the app. To install somewhere else:

```sh
WORKSCRIBE_OUTPUT_DIR="$HOME/Applications" scripts/build-app.sh
open "$HOME/Applications/WorkScribe.app"
```

Look for WorkScribe **in the menu bar**, not the Dock. Allow its first model warm-up to finish, then choose **Start recording**, or press **⌥⌘R**. Stop saves the transcript and notes; audio is never stored. Auto-record calls is enabled by default; turn it off in Settings if you prefer to start each recording yourself. Use headphones to keep the other side of a call out of your microphone track. This is a development build, not a notarized release.

### Install the Obsidian plugin

Open your vault in Obsidian once, then:

```sh
cd obsidian-plugin
npm run build
bash scripts/install.sh "/path/to/your/vault"
```

In Obsidian, turn off Restricted mode under **Settings → Community plugins** and enable **WorkScribe**. In the WorkScribe app's settings, select the same vault. The plugin discovers the running app through its local `api.json`; it does not need a manually entered port or token. Start with a disposable vault if you want to explore the note lifecycle first. See the [plugin guide](obsidian-plugin/README.md) for controls and development commands.

During a meeting, type your own notes in the normal Obsidian editor. Enhancements appear alongside them. After Stop, finalization writes normal Markdown into the vault. **Done** (or the 24-hour retention deadline while WorkScribe is running) removes raw meeting material and keeps the final note. Quit/relaunch recovery replays pending cleanup. This is application-level deletion, not secure erasure of backups or SSD blocks.

### What setup downloads

The [machine-readable inventory](Resources/runtime-downloads.json) records every runtime/model URL, immutable revision, exact byte size and SHA-256. Total pinned runtime/model transfer is **7,494,129,889 bytes (7.49 GB; 6.98 GiB)**. Dependencies, native source/build files and generated Core ML artifacts need additional space.

| Download | Transfer size (decimal) | Purpose |
| --- | ---: | --- |
| NeMo-Speech.cpp 0.2.0, macOS arm64 Metal archive | 5.03 MB | Native speech and text-generation libraries |
| Nemotron 3.5 ASR 0.6B Q8_0 | 741.55 MB | Speech recognition |
| Nemotron 3 Diarization Q8_0 | 107.01 MB | Per-recording speaker labels |
| Gemma 4 E4B Q4_0 | 4.59 GB | All note lines, titles, answers and briefs; image-caption model |
| Gemma 4 E4B Q8 projector | 559.87 MB | Image captions with the same E4B weights |
| EmbeddingGemma 2 Core ML text, audio, vision + tables/tokenizer | 1.48 GB | Semantic search |
| WeSpeaker v2 Core ML | 7.95 MB | Optional remembered-speaker matching |

Setup also fetches the pinned llama.cpp image-helper source, Swift packages from `Package.resolved`, and npm packages from `obsidian-plugin/package-lock.json`. If CMake is absent, it installs CMake 3.31.6 in a private cache virtual environment with a pinned wheel checksum. Python model-conversion packages are not needed: Xcode compiles the published Core ML packages.

### Signing and permissions

The build script selects an **Apple Development** signing identity from your Keychain if one exists, and otherwise signs **ad hoc**. No Apple developer account is needed. Override with `WORKSCRIBE_SIGN_IDENTITY="identity name"`; `WORKSCRIBE_SIGN_IDENTITY=-` forces ad-hoc signing.

A stable development identity helps macOS retain privacy grants between builds. An ad-hoc rebuild can invalidate them: if recording stops working after rebuilding, quit WorkScribe, remove/re-enable its entry in **System Settings → Privacy & Security**, then reopen it. Grant permissions to the app bundle you actually launch.

WorkScribe asks for:

- **Microphone** to record your voice.
- **Screen & System Audio Recording** to capture the other side of calls, screen context and browser call titles. Without it, microphone-only recording remains available.
- **Accessibility**, only if you choose **Zoom captions** as the transcript source (Settings › Transcript from). Turn captions on in Zoom (More › Show captions).
- **Notifications**, optionally, for recording status.
- Access to folders you select for vault notes or indexing. Pick only folders you want searchable.
- **Bluetooth / Keychain** only in a build with the optional Plaud integration.

The global recording shortcut uses Carbon hot keys and does not require Accessibility permission. Model downloads contact their publishers. Everything after that runs on this Mac: speech recognition, AI lines, briefs, titles, answers and search. There is no cloud model, no API key setting and no network fallback. The Obsidian integration starts an authenticated HTTP API on `127.0.0.1` with a random port. The optional browser clipper uses a local socket. If you connect the read-only MCP interface to a cloud AI client, that client may send retrieved text to its provider.

Live microphone and system audio stream through bounded memory buffers into Nemotron ASR and
live voice extraction. WorkScribe does not save captured audio, screen video, or automatic
screenshots. Stop drains streaming recognition and finishes pending notes, actions, discussion,
and the brief; it never transcribes the meeting again. Transcript and OCR evidence expire at
Done or 24 hours after Stop. Images explicitly grabbed into an Obsidian note remain user content.

### Where things live

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/WorkScribe/Runtime` | Native runtime, models, compiled Core ML graphs, checksum receipts |
| `~/Library/Caches/WorkScribe/Runtime` | Download archive and image-helper source/build cache |
| `~/Library/Application Support/WorkScribe/Meetings` | Meeting transcripts, OCR text, derived voice profiles and retention journal |
| `~/Library/Application Support/WorkScribe/Notes`, `Conversations`, `Index`, `Vault` | Local notes, Q&A history, search index and vault synchronization state |
| `~/Library/Application Support/WorkScribe/api.json` | Local API discovery and authentication token; do not share it |
| Your selected Obsidian vault | Final editable Markdown notes and plugin files |

Set `WORKSCRIBE_RUNTIME_HOME` and `WORKSCRIBE_RUNTIME_CACHE` consistently for bootstrap, builds and app execution to relocate the runtime/cache. Launch the executable from that shell when using overrides; Finder does not inherit Terminal's environment. Other isolation overrides are recorded in [the verification report](docs/BUILDING-verification.md). Source checkouts and `.build` are not your meeting library. Never delete the entire support folder as a build troubleshooting step.

### Verify a build

```sh
swift test
python3 -m venv .venv-tests
.venv-tests/bin/python -m pip install -r scripts/test-requirements.txt
.venv-tests/bin/python -m unittest discover -s scripts/tests
.build/debug/WorkScribe --doctor --check
.build/debug/WorkScribe --verify-api
.build/debug/WorkScribe --verify-purge
(cd obsidian-plugin && npm ci && npm test && npm run build && npm run smoke)
```

`--verify-api` checks the actual local HTTP server and authentication using a temporary library. `--verify-purge` checks final-note preservation, raw/index deletion and idempotent cleanup using fixtures. Neither records your microphone. `npm run smoke` loads the real plugin bundle against a mock server under Node; it is not an Obsidian UI test.

For actual model inference with a speech WAV, without live audio permissions:

```sh
.build/debug/WorkScribe --verify-audio /path/to/speech.wav
.build/debug/WorkScribe --verify-warm /path/to/speech.wav
```

These checks do not substitute for testing a real call, sleep/wake, device changes or your macOS permission flow. See [the verification report](docs/BUILDING-verification.md) for precisely what was run.

### Troubleshooting

- **`coremlcompiler` missing / wrong Swift version:** select the full Xcode installation above, open it once, and rerun bootstrap. `xcrun --find coremlcompiler` and `swift --version` should succeed.
- **Download interrupted / wrong hash / model missing:** rerun bootstrap. Use `python3 scripts/runtime-doctor.py --check` to inspect assets; omit `--check` to repair. A failed replacement leaves the previous model intact. Keep enough disk space for temporary downloads.
- **`library not found for -lnemo_speech_asr_c` / `-llama`:** run bootstrap before `swift build`, using the same runtime-home environment. Do not copy random native libraries into the checkout.
- **No transcript / microphone or system track missing:** check the permissions above, use the signed app rather than a bare executable, and allow warm-up to complete. With ad-hoc builds, reset the stale privacy entry after a rebuild.
- **Plugin disconnected:** start WorkScribe, select the same vault, and leave the plugin's API override empty for the default data location. With an isolated `WORKSCRIBE_API_DIR`, point it at that directory's `api.json`.
- **`sandbox-exec: sandbox_apply: Operation not permitted`:** a restricted CI/agent runner may forbid SwiftPM's nested sandbox. Only in that environment, use `swift build --disable-sandbox`, `swift test --disable-sandbox`, and `WORKSCRIBE_SWIFT_DISABLE_SANDBOX=1 scripts/build-app.sh`. Normal Terminal builds use the sandbox.

### Optional Plaud SDK

**Off by default.** The public build contains no Plaud frameworks, menu entry or device-import tests. To use an SDK you are authorized to access, follow [the native Plaud notes](experiments/plaud-macos/README.md), then export these for every build/test command:

```sh
export WORKSCRIBE_PLAUD=1
export WORKSCRIBE_PLAUD_FRAMEWORKS="/path/to/Frameworks"
swift build
scripts/build-app.sh
```

The directory must contain `PlaudBleSDK.framework` and `PlaudDeviceBasicSDK.framework`. The existing default lookup is `~/Library/Caches/WorkScribe/PlaudNativeLab/Frameworks`. The project does not distribute the proprietary SDK or grant permission to redistribute it.

## Licensing

WorkScribe is licensed under the [Apache License 2.0](LICENSE). Fork it, change it and ship your own version; see [making your own](docs/specs/making-your-own.md) if that file is present in your checkout.

Third-party terms are separate: see [Resources/licenses](Resources/licenses/README.md). The legacy WeSpeaker conversion's weight provenance remains unresolved; do not redistribute those weights without clarification. No inspected public runtime/model license explicitly forbids redistribution; optional proprietary Plaud terms must be obtained from its vendor.
