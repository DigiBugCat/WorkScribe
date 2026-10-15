# First real recording: reliability repairs

## Recording lifecycle

Launch recovers persisted `starting`, `recording`, and `finalizing` meetings as interrupted before exposing the library/API. It preserves transcript evidence, repairs unfinished WAVs from the on-disk PCM journal, and sets the retention deadline. Replaying recovery is idempotent.

Concurrent Stop requests join one save transaction. Start reports the actual busy phase. Audio closes before transcript catch-up. A finalizer that makes no progress for 30 seconds releases the UI with the saved recording intact; late recognition callbacks cannot mutate another recording. A stalled native recognizer requires an app restart and says so. AI final-pass failure is separate from recording success.

Quit confirmation leaves capture, API and vault services intact on Cancel. Accepted/repeated quits share one save and close services only afterward. Synthetic tests cover cancellation, duplicate requests, concurrent Stop/Quit, and an unresponsive final AI pass. The process-restart test launches a child XCTest process with synthetic active meetings, terminates it without cleanup, and checks the recovered states and playable WAV lengths on relaunch. No test opens an audio device.

## Audio under load

Each converted PCM buffer goes to the WAV and a private disk journal. Recognition reads at most 32 KB (one second) per batch. There is no fixed-count audio queue to overflow. Pending time includes inference already in flight.

At 2 seconds of lag, screen work pauses; at 6 seconds, live AI work pauses; at 12 seconds, provisional transcript updates slow to one every three seconds. Final segments are retained. Capture continues and the queue drains during recording or after Stop. User-requested screen pause remains respected when pressure clears. Both app and plugin expose “Your Mac is busy · still recording, the transcript will catch up”.

The slowed fake recognizer test writes 510 synthetic buffers (51 seconds of PCM), exceeds the former 128-buffer limit, closes capture, and drains every byte. It verifies the saved WAV frame count and sample value, and the degradation/recovery thresholds. PCM journals disappear after successful drain; interrupted journals remain available with the recording until normal retention cleanup.

## Readable transcript and excerpts

Native and Obsidian transcript views group final segments with the same source and speaker identity, respecting explicit speaker corrections. Boundaries include a 1.5-second pause, 30-second span, sentence boundary after 12 words, and a 60-word target. Unknown speakers and provisional text are not guessed into a shared identity. Original segments, IDs and timestamps remain unchanged. Excerpts use the same grouping; timestamps for split excerpts are derived within the original segments, rather than interpolated across pauses. Legacy excerpt IDs remain resolvable.

The synthetic fixture `Tests/WorkScribeCoreTests/Golden/realrun-fragments.json` models five turns from a two-minute live stream; it is not a reconstruction of the user's recording.

| Measurement | Before | After |
| --- | ---: | ---: |
| Transcript/excerpt units | 25 | 5 |
| Median words per unit | 3 | 15 |
| Original segments/IDs retained | 25 | 25 |
| Text retained | 100% | 100% |

Boundary tests cover pauses, source changes, identity changes, segment-specific assignments, unknown voices, and provisional text.

## Vault identity

App and plugin resolve filesystem paths, including existing ancestors of new files, rather than rewriting macOS path prefixes. Vault state, watcher/index paths, document paths and API synchronization use the canonical identity. Existing vault bookkeeping can be read using its prior key. Tests include arbitrary symlink chains, future documents, sibling-prefix rejection, escaping symlinks and a real HTTP document synchronization through an alias.

When the FSEvents service is unavailable, a metadata-only snapshot watcher keeps vault edits working. Its checkpoints are explicitly marked `snapshot`, not represented as replayable FSEvent IDs. This path is exercised in the restricted test session.

## Verification

- `swift test --disable-sandbox --jobs 2`: 166 passing tests. The flag disables SwiftPM's nested sandbox, which this execution environment cannot create.
- `.build/debug/WorkScribe --verify-api`: passes, including token and Host checks.
- `.build/debug/WorkScribe --verify-purge`: passes; raw material is removed and the final note survives.
- Plugin `npm test`: 87 pass, two opt-in native API tests skipped.
- `WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test`: all 89 pass, no skips.
- Plugin `npm run build` and `npm run smoke`: pass.

Optional native UI probe: `cd obsidian-plugin && node dev/realrun-check.mjs`. It uses a separate profile/vault under `.artifacts/realrun-native`, only synthetic data, and asserts notice appearance/removal plus unchanged user text. In this session the isolated Obsidian process aborted before CDP became available (exit 134). No native screenshot or motion verification is claimed. The installed WorkScribe app was not replaced, and the user's audio was not captured.

