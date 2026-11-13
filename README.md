# WorkScribe

Inspired by [Google AI Edge Foresight](https://developers.google.com/edge/foresight), built for Obsidian. WorkScribe is an independent project, not affiliated with Google.

WorkScribe is an Obsidian-first note enrichment engine. It captures streaming speech with speaker labels and enriches your jots with supported meeting and vault context. An Obsidian plugin puts live notes, cited answers, and meeting search in your vault; the app also works on its own.

Speech recognition, speaker labels, search and screen reading run on your Mac, with models downloaded during setup. The text WorkScribe writes (AI lines, titles, briefs, answers and image captions) comes from [Codex](https://developers.openai.com/codex), through the `codex app-server` already on your Mac and the Codex sign-in you already have. See [What leaves this Mac](#what-leaves-this-mac).

## Build from source

### Requirements

- **Apple Silicon Mac, macOS 26 or newer.** Intel Macs are not supported by the pinned native runtime.
- **Full Xcode 26 or newer with Swift 6.2+**. Command Line Tools alone do not provide the Core ML compiler. Open Xcode once to finish installation and accept its license, then select it if needed:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **Python 3.12+**, **Node.js 22+ with npm**, and Git on your shell's `PATH`. For example, with [Homebrew](https://brew.sh/): `brew install python node git`.
- **Codex CLI** (`brew install --cask codex`), signed in (`codex login`). AI lines, titles, briefs, answers and image captions need it; without it WorkScribe still records, transcribes and searches.
- **10 GiB free disk space minimum for a fresh setup; 13 GiB recommended**, plus room for notes and captured images. Setup checks the remaining download and build space. **16 GB memory recommended** for simultaneous speech, search, and image models; this is guidance, not a measured minimum.
- Internet access to GitHub, Hugging Face and npm during setup. Setup's downloads need no account or model token.
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

`bootstrap.sh` checks prerequisites, downloads and SHA-256-verifies **all pinned models**, prepares the native runtime and Core ML models, and runs `npm ci` for the plugin. Pinned model files already on the Mac (for example an earlier Hugging Face download) are reused from folders named in `WORKSCRIBE_MODEL_SOURCES` (or `runtime-doctor.py --model-source DIR`) when their SHA-256 matches. It does not install Xcode, change your system Python, or require `sudo`. Run it again after an interruption: verified files are reused, incomplete downloads resume when the server supports byte ranges, and replacements are published only after verification. `scripts/bootstrap.sh --check` checks prerequisites and space without downloading. Runtime repairs alone: `python3 scripts/runtime-doctor.py`. Setup remembers that Python executable for repairs launched from Finder; `WORKSCRIBE_PYTHON` can override it.

The debug executable is `.build/debug/WorkScribe`. The build script creates a signed release app at `dist/WorkScribe.app`; models stay outside the app. To install somewhere else:

```sh
WORKSCRIBE_OUTPUT_DIR="$HOME/Applications" scripts/build-app.sh
open "$HOME/Applications/WorkScribe.app"
```

Look for WorkScribe **in the menu bar**, not the Dock. Its popover has two rows at the top, one for each thing that is always on: **Screen** (what is being read, with **Pause**) and **Calls** (with **Record**). Below them is one box to ask of everything, then your day: meetings and the apps you used, newest first, or the list of meetings alone. Allow the first model warm-up to finish, then choose **Record**, or press **⌥⌘R**. Stop saves the transcript and notes; audio is never stored. Auto-record calls is enabled by default; turn it off in Settings if you prefer to start each recording yourself. Use headphones to keep the other side of a call out of your microphone track. This is a development build, not a notarized release.

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

The [machine-readable inventory](Resources/runtime-downloads.json) records every runtime/model URL, immutable revision, exact byte size and SHA-256. Total pinned runtime/model transfer is **2,343,447,681 bytes (2.34 GB; 2.18 GiB)**. Dependencies, build products and generated Core ML artifacts need additional space.

| Download | Transfer size (decimal) | Purpose |
| --- | ---: | --- |
| NeMo-Speech.cpp 0.2.0, macOS arm64 Metal archive | 5.03 MB | Native speech libraries |
| Nemotron 3.5 ASR 0.6B Q8_0 | 741.55 MB | Speech recognition |
| Nemotron 3 Diarization Q8_0 | 107.01 MB | Per-recording speaker labels |
| EmbeddingGemma 2 Core ML text, audio, vision + tables/tokenizer | 1.48 GB | Semantic search |
| WeSpeaker v2 Core ML | 7.95 MB | Optional remembered-speaker matching |

Setup also fetches Swift packages from `Package.resolved` and npm packages from `obsidian-plugin/package-lock.json`. Python model-conversion packages are not needed: Xcode compiles the published Core ML packages.

### Signing and permissions

The build script selects an **Apple Development** signing identity from your Keychain if one exists, and otherwise signs **ad hoc**. No Apple developer account is needed. Override with `WORKSCRIBE_SIGN_IDENTITY="identity name"`; `WORKSCRIBE_SIGN_IDENTITY=-` forces ad-hoc signing.

A stable development identity helps macOS retain privacy grants between builds. An ad-hoc rebuild can invalidate them: if recording stops working after rebuilding, quit WorkScribe, remove/re-enable its entry in **System Settings → Privacy & Security**, then reopen it. Grant permissions to the app bundle you actually launch.

WorkScribe asks for:

- **Microphone** to record your voice.
- **Screen & System Audio Recording** to capture the other side of calls, screen context and browser call titles. Without it, microphone-only recording remains available.
- **Accessibility**, to read the text of the window you are in when **Read the screen** is on, and for **Zoom captions** as the transcript source (Settings › Transcript from; turn captions on in Zoom under More › Show captions). Without it, screen reading falls back to pictures of the window, which needs Screen Recording.
- **Notifications**, optionally, for recording status.
- Access to folders you select for vault notes or indexing. Pick only folders you want searchable.
- **Bluetooth / Keychain** only in a build with the optional Plaud integration.

The global recording shortcut uses Carbon hot keys and does not require Accessibility permission. Model downloads contact their publishers. The Obsidian integration starts an authenticated HTTP API on `127.0.0.1` with a random port. The optional browser clipper uses a local socket. If you connect the read-only MCP interface to a cloud AI client, that client may send retrieved text to its provider.

### What leaves this Mac

Audio never does, and neither does a whole transcript, your vault, or anything from the screen that was not retrieved for a specific line or question. The day's screen history is used only for a question you ask (Ask, search, the local API, the MCP interface): AI lines written during a meeting draw on that meeting, your notes and your indexed files, not on it. Speech recognition, speaker labels, voice matching, search (keyword and semantic) and screen reading all run here.

Generated text is written by Codex. For each AI line, title, brief or answer, WorkScribe sends one prompt: the note or question, and the excerpts retrieved for it (transcript sentences, screen text, passages from indexed notes and files). For a picture pasted into a note it sends a reduced JPEG copy of that picture. These go to OpenAI under your Codex sign-in and its data terms. WorkScribe itself opens no network connection and holds no API key; the one way out is the `codex app-server` child process (`Tests/WorkScribeCoreTests/EgressTests.swift` checks this on the source).

Codex is run in a home of its own (`~/Library/Application Support/WorkScribe/Codex`), not your `~/.codex`. A thread started from an everyday Codex home carries that home's tool servers, plugins, instruction files and a shell, and a meeting transcript is untrusted text. WorkScribe's home has none of those, every tool Codex ships with is switched off at launch, and the connection is ended for good if a thread shows a tool, an approval request, a tool server or a loaded instruction file. Only the sign-in is shared: that home's `auth.json` is a link to `~/.codex/auth.json`. **Settings › AI lines, titles and answers** shows who is signed in; **Stop using Codex** removes the link and leaves your Codex signed in. Without Codex, AI lines stay off and Ask lists the matching moments instead of writing an answer.

`.build/debug/WorkScribe --verify-codex` runs a title, a note line, a streamed answer, a cancel and a tool canary against the real Codex and prints what came back.

Live microphone and system audio stream through bounded memory buffers into Nemotron ASR and
live voice extraction. WorkScribe does not save captured audio, screen video, or automatic
screenshots. Stop drains streaming recognition and finishes pending notes, actions, discussion,
and the brief; it never transcribes the meeting again. A meeting's transcript and screen text expire at
Done or 24 hours after Stop. Screen history outside meetings is kept for as many days as you choose
(seven unless changed). Images explicitly grabbed into an Obsidian note remain user content.

### Screen reading

**Settings › Screen › Read the screen** has three settings: **All day**, **During meetings**, and **Off**. It is **All day** from the start when the Mac already lets WorkScribe read windows (Accessibility, or Screen Recording), and Off otherwise.

All day, WorkScribe keeps the text of the window you are in, organised by application: which app was in front and for how long, its window titles, the page or document it had open when the app says, and the text. **Screen history…** shows a day that way, and Ask and search can find it ("what was that pricing page I had open in Safari this morning"). It looks when something changes (you switch app or window, or stop typing for a moment) and otherwise every twenty seconds, not at a frame rate. It reads the window's own text through Accessibility; when a window exposes too little (a video call, a canvas), it takes a picture of that one window, reads it with Vision, and discards the picture. The text never waits more than a second for the picture's search vector: while the vision model is still loading, the text is kept at once and the vector follows on the next look at the same window. Nothing is recorded as video and no picture is stored.

When Screen Recording is allowed, each window also gets an image embedding: a vector from EmbeddingGemma's vision model, computed on this Mac from one picture of the window when it comes up (and again only when it has visibly changed). The vector is kept with the moment and the picture is not, so a chart or a video call with no readable words can still be found by what it showed. Images in indexed folders, in vault notes and in attachments are embedded the same way; none of that goes to Codex.

Each look is at one app's window, never the whole display. Some apps are never read: password managers, Keychain Access, Passwords and Messages to begin with, and any app you add (right-click it in Screen history › **Never read**; the same list allows one again). Such an app leaves no trace in the day, not even its name or how long it was open, and neither does a browser window whose title says it is private. **Pause** on the popover's Screen row (for fifteen minutes, an hour, or until you resume) stops reading at once, including a read already under way; the same menu has **Never read** and **Forget what was read today** for the app you were just in. The Mac's own dialogs (a permission alert, a password prompt) are neither read nor listed as applications. That last part, and the case where a private app comes forward while a read is in progress, are what `formal/tla/ScreenWatch.tla` checks. The private-window rule relies on the title the browser shows.

What is read while a meeting is being recorded belongs to that meeting: it is kept with it, used for its notes, and deleted with it after a day. The day's history keeps only which app was in front during the meeting. Everything else read during the day goes to the day's history, in `Meetings/.screen/<date>.jsonl`, which is kept for the number of days you choose (**Keep screen history**: today only, 7 days, 30 days, or until you delete it). Screen history can be deleted a day at a time or all at once, and one app's part of a day can be forgotten on its own; deleted history leaves the search index at once.

Reading all day costs little: text comes from Accessibility, which is cheap. A picture of a window is only taken when its text cannot be read, plus one per window for the image embedding, and that extra one is skipped in Low Power Mode, when the Mac is hot, and while speech recognition is behind.

### Where things live

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/WorkScribe/Runtime` | Native runtime, models, compiled Core ML graphs, checksum receipts |
| `~/Library/Caches/WorkScribe/Runtime` | Downloaded native runtime archive |
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

`--render-ui FOLDER` draws the popover in each of its states from made-up data and writes them as pictures, without reading the library or the screen; it is for looking at a change to the popover. `--verify-api` checks the actual local HTTP server and authentication using a temporary library. `--verify-purge` checks final-note preservation, raw/index deletion and idempotent cleanup using fixtures. Neither records your microphone. `--verify-codex` talks to the real Codex (see above), and `--verify-screen 20` watches the real screen for twenty seconds into a throwaway meeting; it needs Accessibility or Screen Recording for the Terminal you run it from.

The state machines behind recording, retention, note lines, the Codex connection and screen reading have models and proofs in [`formal/`](formal/README.md), with the commands to re-run them and a plain statement of what each does and does not establish. `npm run smoke` loads the real plugin bundle against a mock server under Node; it is not an Obsidian UI test.

The test suite uses no model. One test runs a day of screen history through the real EmbeddingGemma 2 model (every stretch of text gets a vector; a question finds the right window by meaning, with none of its words) and is off unless asked for:

```sh
WORKSCRIBE_REAL_MODELS=1 swift test --filter ScreenDayEmbeddingTests
```

For actual model inference with a speech WAV, without live audio permissions:

```sh
.build/debug/WorkScribe --verify-audio /path/to/speech.wav
.build/debug/WorkScribe --verify-warm /path/to/speech.wav
```

These checks do not substitute for testing a real call, sleep/wake, device changes or your macOS permission flow. See [the verification report](docs/BUILDING-verification.md) for precisely what was run.

### Troubleshooting

- **`coremlcompiler` missing / wrong Swift version:** select the full Xcode installation above, open it once, and rerun bootstrap. `xcrun --find coremlcompiler` and `swift --version` should succeed.
- **Download interrupted / wrong hash / model missing:** rerun bootstrap. Use `python3 scripts/runtime-doctor.py --check` to inspect assets; omit `--check` to repair. A failed replacement leaves the previous model intact. Keep enough disk space for temporary downloads.
- **`library not found for -lnemo_speech_asr_c`:** run bootstrap before `swift build`, using the same runtime-home environment. Do not copy random native libraries into the checkout.
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
