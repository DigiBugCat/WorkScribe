# WorkScribe

A native macOS menu bar recorder with embedded NVIDIA speech recognition,
speaker diarization, local transcripts, and a read-only MCP server.

## Run

Open `~/Applications/WorkScribe.app` (the installed build), or `dist/WorkScribe.app`
after a default build. Start a recording from its window or menu bar icon.
The microphone is always included; optionally include system audio for calls
and media. macOS requests microphone and screen/system-audio permissions.
Press **Start recording**, or enable **Settings → Auto-record calls**. Stop finalizes
and saves the transcript and audio tracks. No title is required upfront.

The shipped app includes the models and native libraries. It does not start
an HTTP service, open a local port, invoke a model subprocess, or upload audio.
It can run offline. This is a local, ad-hoc-signed development build, not a
notarized distribution release.

## Transcript

The menu-bar popover shows the full live transcript with colored speaker
labels and Mic/System audio sources. Clicking the icon opens it directly;
there is no separate transcript window or launcher menu. Words without
reliable speaker attribution show **Identifying speaker…** until finalized.
The gear-shaped **Settings** menu contains Auto-record calls, Include system
audio, and Follow live transcript. Disable following to read earlier passages.

## Automatic recording and titles

Call detection watches CoreAudio microphone activity for Zoom, Teams, Webex,
FaceTime, Slack, and Discord. Chrome, Safari, Edge, Firefox, Brave, and Arc also
need a visible meeting-window title (Meet, Teams, Zoom, Webex, or a Slack
huddle). Browser-title detection needs macOS Screen Recording permission.
The detector doesn't record or inspect audio itself.

A call must be detected for three seconds before recording starts. An
automatically started recording ends after two minutes without detected call
microphone activity. Brief mutes are tolerated. Manual Stop suppresses
automatic starts until call activity has been absent for two minutes.
Manually started recordings never auto-stop. Disable the toggle to keep only
one-click recording. WorkScribe must be running; login startup is not enabled.

Detection is a heuristic, not a conferencing-app integration: a long mute,
an unsupported app, hidden browser meeting, or missing permission can prevent
detection or end an auto recording. The UI shows detector status and always
offers manual recording.

Titles are generated on this Mac from finalized transcript text. A first title
can appear after 45 words; the final title uses excerpts from across the
recording. Short clips need at least six words. Rename with the pencil or More
menu; manual and legacy titles are never replaced automatically. The title
model loads on demand and releases its model/context after generation.

## Models

| Purpose | Embedded model | Format |
| --- | --- | --- |
| Streaming ASR | `nvidia/nemotron-3.5-asr-streaming-0.6b` | Q8_0 GGUF, about 707 MiB |
| Speaker diarization | `nvidia/Nemotron-3-Diarization` | Q8_0 GGUF, about 102 MiB |

The models run through NeMo-Speech.cpp 0.2.0's stable C API on Apple Metal.
One recognizer owns both models; each audio source gets its own streaming
state. Speech weights and inference kernels are warmed in the background at
app launch and retained between recordings. Stop clears recording streams,
not the model; quitting releases the engine. Start is enabled once the
one-time launch warm-up is ready. Inference runs off the UI thread. The language prompt currently uses
`en-US`. Speaker identities are scoped to each track and each recording;
speaker numbers are not people's names. Use headphones to reduce a call's
audio being picked up again by the microphone.

The initial 11-second public speech fixture used 1.32 GB peak memory footprint
and 1.36 seconds of inference on this Mac. That is a short single-track test,
not a long-meeting or maximum-memory benchmark. Apple Silicon uses unified
memory. The speech-only bundle occupies about 822 MiB. The selected title
model adds its model-file size. No general chat interface is included.

The default title model is Qwen3.5 2B Q4_K_M (1.28 GB file). Gemma 4 E2B
QAT Q4_0 (3.35 GB file) is an alternative build option. These are file sizes, not measured working memory.
Both run through the already-embedded llama.cpp library with short contexts
and thinking disabled. Only the selected title model is shipped.

## Ask an LLM through MCP

Choose **Copy MCP config** and add the configuration to your MCP-capable LLM
client. It runs the same app executable with `--mcp` using standard input and
output. No localhost URL is involved. The MCP process reads saved snapshots;
it does not load speech models or start recording.

Available tools:

- `list_meetings`: the 100 most recent recordings.
- `get_live_transcript`: finalized text plus separately marked provisional text.
- `get_transcript`: paginated finalized segments from a selected meeting.
- `search_transcripts`: case-insensitive literal search with timestamped evidence.

Example prompts: “What have we decided in the current meeting?”, “Find where
we discussed the Friday release”, “List the action items with timestamps.”
The answering LLM is supplied by your client. For entirely local Q&A, use a
local LLM in an MCP-capable client. Connecting a cloud LLM lets that client
send retrieved transcript text to its provider; the recorder itself makes
no such connection.

## Storage

`~/Library/Application Support/WorkScribe/Meetings/<meeting-id>/` contains:

- `transcript.json`: atomic snapshots with finalized segments and live drafts.
- `microphone.wav`: 16 kHz mono PCM16.
- `system.wav`: optional separate 16 kHz mono PCM16 track.

Files remain local with owner-only permissions. The More menu opens the
recordings directory and exports a readable text transcript. Failed or
interrupted sessions retain their captured data and are marked accordingly.
The app does not encrypt files separately from macOS/FileVault.

## Build and verify

Requires Apple Silicon, macOS 14+, Swift 5.10+ and the NVIDIA 0.2.0 Metal SDK.
SwiftPM builds into the repository's `.build`, not Xcode DerivedData.

Install the NVIDIA runtime to `.runtime/nemo` using its reviewed official
installer, then fetch the two indexed models:

```sh
curl -fL https://raw.githubusercontent.com/NVIDIA/NeMo-Speech.cpp/v0.2.0/scripts/install.sh -o /tmp/workscribe-nemo-install.sh
# Inspect the installer before executing it.
sh /tmp/workscribe-nemo-install.sh --version 0.2.0 --binary-only --no-modify-path --prefix "$PWD/.runtime/nemo"
.runtime/nemo/bin/nemo-speech pull nemotron-3.5
.runtime/nemo/bin/nemo-speech pull nemotron-3-diarization
bash scripts/download-title-model.sh qwen35
bash scripts/build-app.sh
# To build directly into the local Applications folder:
WORKSCRIBE_OUTPUT_DIR="$HOME/Applications" bash scripts/build-app.sh
# To use Gemma 4 instead:
bash scripts/download-title-model.sh gemma4
WORKSCRIBE_TITLE_MODEL=gemma4 WORKSCRIBE_OUTPUT_DIR="$HOME/Applications" bash scripts/build-app.sh
swift test
uv run --with mcp python scripts/verify-mcp.py
```

`build-app.sh` embeds the SDK dylibs, the two speech models, and the selected
title model, then ad-hoc signs the resulting app. Downloads are pinned and
checksum-verified. It stages the app outside synced Documents folders before
signing to avoid file-provider metadata interfering with code signing.
The source copy of `asr.h` is from the NVIDIA 0.2.0 SDK. NVIDIA and upstream
licenses are retained in the bundle under `Contents/Resources/licenses`.
Model terms are linked from the model cards below.

To exercise the actual bundled inference bridge without audio permissions or
adding test data to your library:

```sh
dist/WorkScribe.app/Contents/MacOS/WorkScribe --verify-audio /path/to/speech.wav
```

This emits streaming events and elapsed inference time as JSON. Diagnostics
go to stderr. The test drains and destroys streams before freeing the Metal
model so resources are released before process exit.

## Sources

- [Nemotron 3.5 ASR model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
- [Nemotron 3 Diarization model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)
- [NeMo-Speech.cpp native SDK contract](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/v0.2.0/docs/sdk.md)

## Current boundaries

This build provides recording, streaming transcription, local history,
automatic call detection and titles, export, and MCP retrieval. It does not
yet include an in-app chat interface, speaker renaming, an audio player, or a database
index for a large archive. Full recordings are retained until removed by the
user. Live recording/device validation is separate from fixture-based model
and MCP tests.

Verified on this Mac: a six-second microphone + system-audio recording,
nonempty audio on both tracks, live speaker-labeled text, clean finalization,
and no open TCP connections. A separate 30.5-second synthetic two-speaker
fixture produced two speaker labels in 4.22 seconds with a 1.36 GB peak memory
footprint. Four core tests and the official Python MCP client check passed.
Long meetings, sleep/wake, and audio-device switching have not been validated.

Title comparison (five synthetic transcripts, October 3, 2026): both models
produced useful descriptive titles. After the first load, Qwen took 0.60–0.91
seconds; Gemma took 0.83–1.13 seconds. Qwen was selected for comparable results
on this small fixture set with a smaller model file. First-use costs differ
(shader compilation, caching, and disk reads); these are not broad accuracy
or cold-start benchmarks. Run `scripts/benchmark-titles.py` to reproduce.

Automatic title lifecycle and call-trigger policies are covered by 14 tests,
including manual rename while generation is pending and mute/stop behavior.
Actual detection across every listed conferencing app has not been verified.

The updated UI was checked with a synthetic live stream: partial text gained
speaker labels on finalization, followed the latest speech, generated a title,
and retained a manually edited title. Native ASR/diarization and Qwen title
generation also passed a concurrent in-process fixture check. No network
service is started for any of these features.

`--verify-warm /path/to/speech.wav` checks concurrent warm-up requests, two
independent recording streams, a single model load across both, matching
transcripts, and complete release on shutdown. It reports warm-up and stream
creation timings without using the microphone.

Warm-engine verification: two sessions reused one model load and produced
matching transcripts. Native stream creation measured 0.05 ms and 0.08 ms
after warm-up; this excludes audio-permission and device setup time. The
measured first warm-up took 17.2 seconds and now runs at app launch.

### Remembered speakers

Click a finalized speaker label to name one segment or every segment from that
speaker. The original diarization ID is preserved. Settings → Remembered voices
lets you rename a person for future labels or forget their saved voice samples.
Settings → Undo speaker change restores the last label edit in that recording.

Confirmed names can enroll local voice profiles. After a recording finishes,
FluidAudio 0.17.5 extracts 256-dimensional embeddings from up to three clear,
non-overlapping, 3–10 second spans per speaker/identity. The bundled
`wespeaker_v2.mlmodelc` runs through Core ML in this process. No server is started,
and no audio or voice profile is sent out. NVIDIA remains responsible for
transcription and per-recording diarization. Models are bundled; the runtime does
not invoke FluidAudio's download APIs.

Future recordings show **Maybe [name] · Review** when a voice matches a previously
confirmed sample. These are suggestions, not identity claims; they never train
profiles until confirmed. This initial version performs matching after Stop (or
Settings → Check voice matches), not on provisional live text. Saved names appear
in text exports and MCP's `speaker_name`, with `speaker_name_confirmed`; MCP retains
the original `speaker` ID and never exposes embeddings. Unknown or overlapping
spans are not enrolled. Older recordings without stored source/audio alignment
can still be named but are excluded from voice learning.

Profiles live in `voices.json` beside the meeting directories with owner-only
permissions. Forget removes a profile's embeddings and future reuse, preserving
historical transcript names. A profile retains at most 12 confirmed samples;
corrections remove examples learned from that recording before rebuilding them.
The conservative similarity cutoff (0.65, with a 0.12 lead over another person)
is an initial heuristic, not a calibrated accuracy guarantee. Real calls,
microphones, background noise, and overlapping speakers still need evaluation.

Prepare the pinned voice model before building on a new machine:

```sh
python3 scripts/prepare-voice-model.py
```

The model revision and per-file SHA-256 checksums are retained under
`Resources/licenses/fluidaudio`, alongside the publisher's license-scope and
provenance notices. SwiftPM pins the FluidAudio library in `Package.resolved`.

### Note Pro handoff from the menu bar

Open **Settings → Save & release Note Pro…**. It opens its own window with four
steps: Find, Save to Mac, Release, Pair on iPhone. The window stays open while
a transfer runs, and WorkScribe won't quit mid-transfer.

**Find Note Pro** uses the saved Plaud developer session. If it has expired,
the window asks for the client ID and secret. The secret is not saved; the
24-hour session is kept in the Keychain. Sign-in reuses the Plaud user ID from
Plaud Mac Lab (`local.workscribe.plaud-lab` defaults), so the recorder keeps
the same owner. Devices appear as they are found; choosing one ends the scan.

**Save its recordings** downloads and decodes every listed recording, with
overall and per-file progress, and saves a checksum manifest under
`~/Library/Application Support/WorkScribe/Plaud Backups`. First use may
require macOS Keychain and Bluetooth approval. Another app connected to the
recorder (such as Plaud Mac Lab) must disconnect first.

Verified recordings are then added to **Recent** as ordinary recordings:
transcribed by the same local speech engine, titled automatically, dated from
the recorder's session time, and searchable through MCP. Their audio is copied
as `recorder.wav`. Imports pause while a live recording runs and resume
afterwards. The import queue is in memory: if WorkScribe quits mid-import, the
saved files remain in the backup folder but are not re-queued automatically.

Only after the backup completes does **Release Note Pro…** become
available. Confirmation rechecks the device inventory, recording state, and
local backup checksums, then performs cloud unbinding and device depairing.
This clears device storage. Local backups remain; they are not uploaded into
the official Plaud account. Finally, pair the recorder using **Add device** in
the official Plaud iPhone app. Returning to WorkScribe requires syncing and
removing the device there first.

`WorkScribe --verify-import /path/to/audio.wav` imports one file as a Note Pro
recording into a temporary library and prints the result.

The native frameworks must be prepared as described in
`experiments/plaud-macos/README.md` before building the main app. The build
embeds them in WorkScribe; it does not run a helper or local server.
