# The happy path: record a call, take notes, finalize

One path, end to end, on device: a call plays on the Mac → WorkScribe records system audio and the
mic → the live note opens in Obsidian → shorthand gets grounded AI lines → Stop polishes the
transcript and writes the final lines → Finalize writes a clean note with a brief, the user's lines,
AI lines and real action items.

The evidence is a real recording made minutes before this work:
`/private/tmp/claude-501/fixtures/tts-offline-sync/` (two macOS TTS voices, seven lines, played
through the Mac's speakers with no headphones; text in `meeting.sh`). Its segments are checked in as
`Tests/WorkScribeCoreTests/Golden/tts-echo-segments.json`.

## What broke, and why

### 1. Every line was transcribed twice

The mic heard the speakers. Each of the 7 system segments had a fragmented, misheard twin on the
microphone channel: 30 microphone segments such as "offline skin", "then let's merch at the field
level", "I'll tell how this are known", "forty V" / "counts". Those twins became AI-line evidence.
`lww?` was written from the mic's "merch" ("Merchandise at the field level for checklists and keep
last.") and `ship date` from a mic fragment ("Everything else can you prototype that by Monday.").

Root cause: nothing cancelled acoustic echo on the mic, and nothing downstream knew that the two
channels can carry the same speech.

A second, independent bug made it worse: **the microphone's clock offset was never saved.** The
fixture's `sourceOffsets` holds only `system`. `startScreen()` did
`meeting?.screen = try await recorder.start(…)`. An optional-chained assignment evaluates the chain
(reads the whole `meeting` struct) *before* the `await` and writes that stale copy back after it, so
everything the audio pumps recorded during the 1.4 s screen start-up was erased, including the mic
offset. Reproduced in isolation (a `@Published` struct, an `a?.x = await f()` while `f` sets `a?.y`:
`y` is lost). Without that offset the Stop-time polish skipped the microphone track entirely, so the
live, echo-laden mic fragments stayed in the final transcript too.

### 2. Auto-start ended in `error` (AVFAudio -308)

`AudioCapture.start` started ScreenCaptureKit, then `AVAudioEngine`. Any engine error was thrown out
of `start`, and `AppModel.start` turned it into phase `error`, tearing down the system-audio stream
that was already working. -308 is raised by CoreAudio while building the aggregate device that
`AVAudioEngine` uses on macOS (the same code shows up in Apple's forums as "Error creating aggregate
audio device: -308" when the default devices are invalid). An auto-start fires exactly when a call
app is reconfiguring audio: Zoom adds its own device, Bluetooth headsets switch to their call
profile. So the trigger is transient and environmental; the bug is that a microphone failure was
fatal to the whole recording. I could not reproduce -308 on demand.

### 3. The brief was note lines glued together

`MeetingRetention.finalize` set `brief = notes.prefix(3).map { enhanced ?? text }.joined(" ")`:
three AI lines with their `**Topic:**` markup plus a raw shorthand line, which
`NoteDocument.escapeEmphasis` then escaped into one italic line:
`*\*\*Cutscenes remaining:\*\* 1 billion left. \*\*Resources needed:\*\* Compass and food. - car broken earlier?*`.
With no notes it used the first two transcript segments, which is not a summary either.

### 4. Cloud capabilities

An OpenAI Responses provider, `CloudSettings` (toggle and model), Keychain API-key storage and its
settings window, cloud-first answers with local fallback, a cloud-first final note pass, and
"GPT-5 mini" copy in the design mockups for the plugin.

### 5. The rest of the path

With the cloud gone, the final pass had only its extractive fallback: every AI line became a quoted
transcript passage ("Transcript excerpts · local fallback"), `lww?` and `ship date` got **0
excerpts** (no shared words, and the final pass weights typing time at 0.15, under the 0.3 bar), and
there were **no action items** (the extractive path writes none). The fixture's finalized state shows
exactly this.

## Fixes

### Echo, layer (a): Apple voice processing on the mic (`Capture.swift`)

- `inputNode.setVoiceProcessingEnabled(true)` before the tap: Apple's AUVoiceProcessingIO echo
  canceller, with AGC.
- `voiceProcessingOtherAudioDuckingConfiguration = (advanced: false, level: .min)`: voice processing
  otherwise ducks other apps' playback, which would turn the call down for the user and for the
  ScreenCaptureKit system-audio track.
- The VP unit is duplex; the main mixer gets volume 0 so it has a silent output path.
- Sample rates: VP may expose its own rate and several channels. `AudioTrack` already converts any
  input format to 16 kHz mono with `AVAudioConverter`, rebuilt whenever the format changes, so the
  backlog, WAV and recognizer see the same 16 kHz s16 stream as before. ScreenCaptureKit (48 kHz
  stereo) is untouched.
- Setting "Cancel speaker echo on the mic" (default on); `WORKSCRIBE_DISABLE_VOICE_PROCESSING=1` for
  isolated runs. The level meter's tooltip says when it is active.

### Echo, layer (b): a cross-channel duplicate filter (`WorkScribeCore/EchoFilter.swift`)

Pure and tested. A microphone segment is echo when it overlaps system speech in time (±1.5 s; the
clocks start a few hundred ms apart) and at least half of its words were heard on the system side
in that window. Words match ignoring case and punctuation and tolerating recognition errors
(prefix/suffix such as "counts"/"accounts", edit distance 1–2 such as "merch"/"merge",
"parody"/"parity"). Fragments between two echoes, inside system speech, are echo when they are
three words or fewer ("I killed in" for "One more thing") or a quarter of their words match ("I'll
tell how this are known"). A lone "yeah" or the user talking over the call is kept: its words are not
in the system transcript.

`Meeting.removeEchoes()` moves echoes to `echoSegments` (kept for audit, never shown, searched or
quoted) and aliases each echo's id to the system segment it repeated, so an AI line that cited the
echo now resolves to the real line. It runs on every completed live event and after the Stop-time
polish. While the system channel is mid-utterance, `settledSegments` holds back microphone segments
from that stretch, so neither the transcript view nor AI-line evidence sees an echo before it can be
recognized as one.

### The microphone clock (`AppModel+Screen.swift`, `TranscriptPolisher.swift`)

Await first, then assign. Recordings already made without the mic offset recover it at polish time:
tracks stop together, so offset = session end − file duration, corrected by how far the system
track's own end-aligned estimate is from its recorded offset. On the fixture this gives **1.047 s**;
an independent envelope cross-correlation of the two WAVs gives ~1.00 s, and the live replay with
1.047 s reproduces the original 36 microphone segments to within 0.1 s. The recovered offset is
saved.

### Capture never lands in `error` while a source works (`Capture.swift`, `CaptureHealth.swift`)

- System audio and the mic start and fail independently; `start` throws only when neither works.
- The mic opens with retries: a fresh engine up to three times with back-off (0.4 / 0.8 / 1.2 s),
  then once without voice processing, which builds a simpler device.
- If the mic still cannot open, the recording continues with call audio and says so:
  "Recording call audio · your mic isn’t available", in the status line, notification, an orange
  banner with a Sound settings button, the level meters ("Mic unavailable") and `/v1/status`
  (`sources.mic = false`). The unopened mic's empty WAV and recognizer stream are dropped.
- Digital silence: after 8 s of input with not one non-zero sample (`SilenceMeter`), or no samples
  at all, the mic is named: "Recording call audio · “MacBook Pro Microphone” is sending only
  silence". Quiet hiss (−90 dBFS) is a working mic, not silence.
- `AVAudioEngineConfigurationChange` (headset plugged in, AirPods switching profile) reopens the
  mic on the new route instead of silently stopping; a device that flaps more than 5 times a minute
  is reported unavailable. Losing ScreenCaptureKit mid-call degrades to mic only instead of ending.

### The brief (`Grounding.swift`: `BriefPolicy`)

Written last, by the local model, from the finished note only: grounded AI lines, Also-discussed
topics and action items, never raw transcript. Accepted only if it is one or two plain sentences,
6–45 words (a long second sentence is dropped), with no markup, list, heading, citation or label,
every number stated by those facts, and at least 60 % of its words from them. Otherwise the note has
no brief: none is better than a wrong one. The concatenation in `MeetingRetention` is gone.
Regression test: `HappyPathTests.testBrokenBriefRegression` (the exact broken brief is rejected).

### The final pass, on device (`NoteEnhancer.swift`, `Notes.swift`, `Commitments.swift`)

- One focused prompt per note to the line model (the same model the live lines use: Qwen3 4B on MLX
  when installed, else the bundled Qwen 3.5; see [model-integration.md](model-integration.md)), with
  that note's evidence only. A question sees the turns that answered it; other notes citing the same
  passage no longer inherit that context (it used to be written into the shared excerpt).
- Every line passes `Grounding.supported`: every number in it is in its evidence (digits and spoken
  forms are the same number: "two hundred" = 200, "one and a half" = 1.5, "twenty eighth" = 28,
  "two point four" = 2.4; a bare "billion" is not a number), and half its content words come from
  the evidence. Greedy decoding means a retry must change the prompt: the second attempt sees only the
  passage nearest the moment the note was typed. A line that still fails becomes the quoted passage.
- Shorthand the transcript never says ("lww?", "ship date") falls back to typing time: the two
  passages heard just before or starting just after the note. Because time alone can be wrong
  ("pricing?" typed right after the Android line), such a note gets a line only if EmbeddingGemma
  rates the passage as about it (cosine ≥ 0.68; "ship date" 0.73, "pricing?" ≤ 0.64) and the line
  names the note's words. Abbreviations ("lww") are exempt from both. Without a score, no line.
- Action items are found in what was said, not by the model: "I'll / I will / we'll / I'm going to
  …", or "Can / could / will you …?" answered by another speaker with "Yes / Sure / OK / Give me …".
  Run-on speech is cut after its time phrase ("tell Halverson on Friday"). The model only rewords a
  task that leans on a pronoun ("Prototype that by Monday" → "Prototype checklist merge by Monday"),
  and the rewording is rejected if its dates or numbers differ ("…by November fourth" was rejected).
  Owners are kept only when the user named that voice; speaker numbers are not people. Dates are never
  computed from "by Monday".
- Live AI lines pass the same grounding gate.
- Small fixes on the way: the note's `duration` rounds (172 s is "3 min", not "2 min"); a model's
  template label ("Short topic:") is dropped instead of discarding the line; stutters
  ("prototype prototype") are collapsed.

### No cloud

Deleted `CloudAnswers.swift` (OpenAI generator, Keychain key storage, `CloudSettings`, the settings
window, `FallbackAnswerGenerator`) and `OpenAIResponses.swift`; removed the cloud branches from
answers, the final note pass, `--verify-notes --note-provider cloud`, the settings menu item and the
"Cloud" trace location. README, `docs/api/local-api.md`, `docs/specs/making-your-own.{md,html}`,
`sources.example.toml` / `sources.schema.json`, `BUILDING-verification.md` and the design mockups
(where the plugin's "GPT-5 mini" copy lived) now describe on-device models only. `NoCloudTests`
fails the build if any Swift source mentions OpenAI, GPT, API keys or cloud settings, uses the
Keychain outside the Plaud build, or opens a network client other than the loopback verification
client.

## Numbers

| | Before | After |
| --- | --- | --- |
| Microphone segments in the transcript (live) | 36 | 6 |
| … of which echoes of system speech | 30 | 0 |
| Real user speech lost | – | 0 (the 6 kept are room speech from before the call, 34–71 s, when system audio was digital silence) |
| Live replay, both WAVs (`--replay-transcript system.wav --microphone microphone.wav`) | 36 mic segments, 30 duplicates | 6 mic segments, 0 duplicates |
| Stop-time polish of the mic track | skipped (no offset) | recognized: 26 segments, 20 echoes removed, 0 remain |
| `lww?` AI line | "Merchandise at the field level for checklists and keep last." (from the mic's "merch") | "The team will merge at the field level for checklists while maintaining last right wins for other items, with a prototype by Monday." |
| `ship date` AI line | "Everything else can you prototype that by Monday." | "The ship date is November fourth, but the SQL live migration requires a full week, so the date will not work." |
| `pricing?` (never discussed) | – | no AI line |
| Action items | none | "Prototype checklist merge by Monday", "Tell Halverson on Friday" |
| Brief | none on this note; elsewhere the glued `*\*\*Cutscenes…*` line | "The team will merge checklists at the field level with a prototype by Monday, and the ship date will be delayed until after the SQL migration." |
| Stop → Finalize on the fixture (`--verify-finalize … --warm`) | – | 10.8 s: polish both tracks, 6 lines, actions, brief, write the note |

"right" for "write" and "parody" for "parity" are the system recognizer's own errors; the lines repeat
them because they are grounded in them.

## Live test: two blocking failures, and their causes

The first live run of this build (meeting `8D1F0708…`, API snapshots `handoffs/aec-live.json` and
`aec-final.json`) proved echo cancellation works: 7 clean system segments, and the mic dropped from
~30 duplicates to 5 segments (1 garbled residual echo and 4 noise fragments). It also found two
blocking failures. Each one had several causes.

### Failure 1: AI lines stuck `pending` during the recording

1. **My placeholder filter threw every live line away.** In a1fb42e, `NoteOutput.usable` rejected
   bullets whose label is the prompt's placeholder ("Topic"), to clean up the topic list. Live, the
   2B model copies the template literally: `* **Topic:** Photo upload constraints` with the sentence
   wrapped onto the next line. All six live passes ended "No usable AI line" (the traces in
   `aec-final.json`). Replaying that meeting's notes and transcript through `--verify-notes
   --incremental` reproduced six empty lines. Now the placeholder label is dropped, a title on the
   bullet line becomes the topic when the sentence wraps, and the line is kept.
2. **One prompt for all notes drops notes.** The same replay produced 5 bullets for 6 notes. The
   alignment by shared words cannot place "lww?" or "ship date", so they never got a line. Live lines
   now use the same one-note-per-prompt path as the final pass. A pass takes at most 2 notes, newest
   first, and the rest follow 4 s later.
3. **Nothing rescheduled after the Mac stopped being busy.** AI lines were rescheduled only on the
   transition back to `.normal`. Under a steady load the lag settles between 2 and 6 s
   (`screenPaused`), where AI lines are allowed but nothing asks for them. Once the call goes quiet
   there are no transcript events left to ask either. Now the notes are scheduled the moment
   `liveAIPaused` turns false. `LiveSessionTests.testLiveLinesResumeWhenTheMacStopsBeingBusy` runs
   0 passes on the old build and 1 on this one.
4. **Evidence waited for the call to pause.** Speech without a long enough pause stays one
   in-progress hypothesis, so there were no completed system segments to quote. The replay trace
   showed 20 segments but 0 excerpts for `lww?` at 108 s. Now the in-progress system hypothesis is
   live evidence, under the id its first segment keeps when it completes (`Meeting.evidenceSegments`).
   The replay's first live line now lands 5 s after the transcript catches up, not 45 s.
5. **Found by the replay: starvation.** A note whose line fails the checks was retried every pass
   and, being newest, crowded out the older notes. Now a note that got no line from exactly this
   evidence waits for new evidence or an edit.
6. **The model and the recognizer share the GPU.** A live pass can push recognition behind, so when
   the lag reaches the AI-pause level the pass yields. The lines it already finished are kept.

### Failure 2: Stop skipped the final pass

**Root cause.** Polish handles the microphone track first. With echo cancellation, the batch recognizer
heard no speech on the mic, while the live mic transcript still had 5 segments. The guard "empty
output must never erase recognized speech" threw `The transcript polish returned no speech`, and
`finish` returned false. The result: no final pass, notes left `pending`, `transcriptPolishedForEnd`
null (as in the owner's library copy), "ready" in 4 s, and the message "the final AI pass could not
finish". `LiveSessionTests.testStopRunsTheFinalPassWhenTheMicTrackIsSilent` reproduces exactly that
message on the old build.

**Fix.**
- When a track comes back empty, its live segments of three words or fewer are set aside as
  `unheardSegments`, because that is what a recognizer makes of noise ("fees", "can set"). Longer
  segments stay, in case the decoder failed, and the other tracks are still polished.
- If the polish fails for any other reason, the final notes are written from the live transcript with
  echoes removed, and Stop says so: "Recording saved · notes were written from the live transcript
  because the final transcript pass couldn't finish (…)".
- Every Stop message now names the reason when there are no final notes.
- Stop cancels a live pass in flight instead of waiting behind it.
- The final pass's stall watchdog counts each model call as progress, so a slow model on a busy Mac
  is not mistaken for a hung one.

**Echo after polish.** The residual "Friday on John says online that you end up a year…" scored 0.45
against "…on Friday their contract says offline capture by the end of the year". A second tier now
treats a segment as echo when it lies mostly inside system speech and shares at least 4 content words
and 35 % of all its words with it (test on `Golden/aec-live-segments.json`). The polished transcript
runs through the filter again.

### The replay: `--verify-live-session`

`WorkScribe --verify-live-session <folder>` replays `system.wav` and `microphone.wav` at real-time pace
into the app's own pipeline: `FileCapture` replaces only the audio devices. It does the following:
- starts through the local API and opens the meeting note through the document API
- types the folder's notes into the vault file at their original times and PATCHes them as the plugin
  does
- slows recognition for a stretch to simulate a busy Mac (`--busy-from/--busy-to/--slowdown`)
- stops through the API
- fails unless live lines appeared, Stop polished, nothing is left pending, every note with evidence
  has a line, there are action items, no echo duplicates remain, and the phase is `ready`

`--finalize` also writes and prints the vault note; `--until` ends the replay early.

| Replay (real time, busy for 30 s) | Live lines before Stop | Stop | Final transcript | Final note |
| --- | --- | --- | --- | --- |
| TTS fixture (no AEC), busy 75–105 s | 4 of 5 discussed notes, the first 5 s after the transcript caught up | 11.3 s, `ready` | 7 system, 6 room-speech mic, 0 duplicates | 5 lines, `pricing?` none, 2 action items, brief |
| The live-test recording itself (first 235 s), busy 20–50 s | 4 (lww?, android, beta accts, photo cap) | 12.4 s, `ready` | 7 system, 0 mic (2 echoes removed, 4 noise fragments set aside), 0 duplicates | 4 lines; `ship date` none (both of the model's attempts were about other topics and failed the "names the note" check); `pricing?` none; 2 action items; brief |

A live line can be weaker than the final one. On the live-test recording, the live `lww?` line drew on
the in-progress ship-date speech. The final pass replaced it with "Merge checklists at the field level
and keep the last right wins for all other fields."

On the old build the three `LiveSessionTests` fail 14 assertions, matching the live symptoms: no pass
after the load eases, "the final AI pass could not finish", notes `pending`, no action items, and the
echo and noise fragments still in the transcript. On this build they pass.

One oddity: the owner's library copy of `8D1F0708…` now has AI lines labelled "Gemma 4", written 17 s
after Stop. No path in `happy` uses Gemma 4 for text notes (only for notes with images), so another
build or tool wrote to that library after the test.

## How to reproduce

```
swift build
F=/private/tmp/claude-501/fixtures/tts-offline-sync
.build/debug/WorkScribe --replay-transcript $F/system.wav --microphone $F/microphone.wav \
    --system-offset 0.2135 --microphone-offset 1.047          # live recognizer + reducer + echo filter
.build/debug/WorkScribe --verify-finalize $F/transcript.json --warm   # Stop → polish → final pass → Finalize
swift test --filter EchoFilterTests                            # the fixture's 36 → 6
.build/debug/WorkScribe --verify-live-session <folder with system.wav, microphone.wav, transcript.json> \
    --busy-from 75 --busy-to 105 --finalize                   # the live sequence end to end
```

`--verify-finalize` copies the recording into a throwaway library and vault, resets it to the moment
Stop was pressed, runs the real scheduler and `MeetingRetention.finalize`, prints the finished
Markdown on stdout and the numbers on stderr. `WORKSCRIBE_NOTES_DEBUG=1` prints every prompt and raw
model output.

## Checks

`swift build`; `swift test` (all pass, including `LiveSessionTests`); `--verify-api`; `--verify-purge`; in `obsidian-plugin/`:
`npm ci`, `npm test` (89 pass, 2 real-API tests skipped), `npm run build`, `npm run smoke`, and
`WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test` (91 pass).

## Not verified

- **Echo cancellation itself.** It needs a live call through the speakers; a recorded fixture cannot
  exercise AUVoiceProcessingIO. Open questions for that recording: how much echo VP removes when the
  far end is another app's output (VP's reference is the device output it sees), whether the
  minimum ducking level is inaudible, and the format VP exposes on this Mac's built-in and USB mics.
  The transcript filter does not depend on it.
- **-308 recovery.** The retry, the voice-processing-off attempt, the system-only fallback and the
  route-change reopen are reasoned from CoreAudio's behaviour and are not reproduced: I could not
  trigger -308 on demand. The degraded-capture decisions are unit tested (`CaptureHealth`), the
  device paths are not.
- **Digital-silence naming** is unit tested on samples, not on a muted interface.
- **Embedding latency.** With the disk 99 % full during this work the Neural Engine could not cache
  EmbeddingGemma's compiled model, and a cold load took up to 110 s. The final pass waits at most 20 s
  for a relevance score (the app shares the search index's embedder and starts warming it when Stop
  is pressed); without a score a time-matched note gets no AI line, so on a cold run `ship date` stays
  plain. Normal load times on a healthy disk were not measured here.
- **Line quality** is a 2B model's: "Beta accounts are scheduled to be the first of forty total
  accounts" loses that Halverson is the first beta account. It passes the gate because every word and
  number is in the evidence; the gate prevents invention, not clumsy paraphrase.
- The Plaud Note Pro hand-off (an opt-in build, off in the public tree) signs in to Plaud's service.
  It was outside this list and is unchanged.
