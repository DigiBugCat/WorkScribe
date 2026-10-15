# Making your own WorkScribe

This is for a developer who wants WorkScribe to work somewhere it doesn't yet: a company that forbids recording, a team whose meetings all happen in one platform, a person who wants a different model or a different notes app. It describes the seams WorkScribe exposes for that, the contract each seam enforces, and how to keep a fork small enough that you can still merge upstream next month.

The transcript is the main case. Some workplaces don't allow recording, but they do allow the meeting platform's own transcript. Others allow recording on this Mac but not anything that leaves it. WorkScribe should handle all of them without anyone editing the recorder. "If Zoom's captions are on, use them; otherwise take notes only" should be a few lines of config, and writing the piece that reads Zoom's captions should be a small program in whatever language you like.

Upstream will not ship platform integrations. It ships the seams, the contract, a conformance kit and three reference sources that prove the contract holds. Reading Zoom's live captions through macOS Accessibility is the motivating example of a source someone else writes, and this document uses it throughout as the example. Nothing here claims that it works or is allowed where you are.

Status: this is a design spec. The seams described in sections 2–5 do not exist yet; section 8 is the plan that builds them. Everything said about *today's* code was read from the integration branch at `1383630`.

---

## 0. The short version

There are three ways to change where a meeting's transcript comes from, from least to most work:

1. **Write a rule.** `~/Library/Application Support/WorkScribe/sources.toml` decides which source a meeting uses, with an ordered fallback chain and a policy layer that can forbid recording outright. No code.
2. **Write a command source.** Any executable that reads and writes JSON lines on stdin/stdout can be a transcript source. Python, Node, a shell script, a Rust binary. WorkScribe launches it, supervises it and throws it away. About 120 lines for a real one.
3. **Write a Swift source.** Conform to `TranscriptSource`, register it in `Sources/WorkScribeExtensions/`, which upstream never edits. Same contract as a command source, without the process boundary.

Whatever you write, run `WorkScribe --verify-source <id>` before you trust it. It replays fixtures through the real meeting pipeline and checks clock alignment, evidence links and purge.

The same pattern, with less depth, covers the note and answer model, the screen and context source, where notes are written, and the embedder (section 5).

---

## 1. The seams

A seam is a place where you can replace one part without touching the parts around it. Each seam has a contract, which is what the rest of WorkScribe relies on, and a registration point, which is where you plug in.

| Seam | Today | What changes | Your interface |
| --- | --- | --- | --- |
| **Transcript source** | Hard-wired in `AppModel.start` / `finishRecording`: two `AudioTrack`s, `AudioCapture`, one `SpeechConnection` per track, NeMo event dictionaries parsed in `AppModel.consume`. Two more sources hide in AppModel: Plaud import (`PlaudImport.swift`) and the synthetic caption demo (`runCaptionDemo`). | Extract the recorder into `LocalRecorderSource`. AppModel talks to `SourceHost`, which consumes canonical events. Add rules, policy, command and ingest sources. | `TranscriptSource` (Swift), the `wsp/1` JSON-lines protocol, or `POST /v1/sources/ingest` |
| **Note and answer model** | `AnswerGenerator` is already a protocol with three conformers. Note lines (`NoteEnhancer`) and titles (`TitleGenerator`) call llama.cpp directly and format chat templates themselves. | One `TextModel` protocol used by all three jobs. Templates move into providers. An OpenAI-compatible provider with a configurable base URL covers Ollama, LM Studio and vLLM. | `TextModel` (Swift) or any OpenAI-compatible endpoint |
| **Screen and context** | `ScreenRecorder` (ScreenCaptureKit video + Vision OCR → `ScreenMoment`), started from `AppModel+Screen.swift`. | `ContextSource` with the transcript source's lifecycle and the same wire protocol, emitting `moment` events. | `ContextSource` (Swift) or `wsp/1` with `role = "context"` |
| **Where notes live** | `VaultStore` writes Markdown into an Obsidian vault or a folder. The live document is bound to the Obsidian plugin. | `NoteDestination` for the final write-up. The live pencil stays Obsidian-only. | `NoteDestination` (Swift) |
| **Embedder** | `Embedder` is already a protocol in Core. `IndexService` stores a concrete `CoreMLEmbedder?`. | Store `any Embedder`. Add an OpenAI-compatible `/v1/embeddings` provider. | `Embedder` (Swift) or an embeddings endpoint |

Two things are deliberately *not* seams: the meeting store and the retention journal. They are what make "only the note survives" true, and every seam above has obligations toward them rather than a way around them.

---

## 2. Transcript sources

### 2.1 What a source is

A transcript source turns a meeting into a stream of timed, attributed text. Some listen and some only read.

| Source | Kind | Live or after | Hears audio? | Ships |
| --- | --- | --- | --- | --- |
| This Mac's mic and call audio, NeMo on device | `local-recorder` | live | yes, mic + system | upstream (refactor of today's recorder) |
| A transcript file (VTT, SRT) imported after the call | `file-import` | after | no | upstream |
| A program speaking `wsp/1` | `command` | either | it declares | upstream supervisor + a Python example |
| Something posting to the local API | `ingest` | either | it declares | upstream endpoint |
| Nothing: notes only | `notes-only` | n/a | no | upstream, always available |
| A replayed fixture | `replay` | live | no | upstream, for tests and the QA preview |
| Zoom's live captions via Accessibility | `command` (yours) | live | no | a fork |
| A Note Pro recording, transcribed on device | `plaud-import` | after | audio files only | upstream, after migration step 9 |

`notes-only` is a real source with no output. Every fallback chain ends with it, so a meeting always has somewhere to land. In notes-only mode the note, the pencil lines (which still tidy your shorthand and can use screen evidence where allowed), Ask over your files and Finalize all keep working. What disappears is transcript evidence.

### 2.2 Capabilities

Every source declares what it does before it is started. WorkScribe uses the declaration three ways: policy filters on it without launching anything, the UI words its status from it, and the conformance kit checks the source's behaviour against it.

```swift
public struct SourceCapabilities: Codable, Equatable, Sendable {
    public enum Timing: String, Codable, Sendable { case live, postHoc = "post-hoc" }
    public enum Speakers: String, Codable, Sendable { case none, labels, names }
    public enum Clock: String, Codable, Sendable { case meeting, wall, media }
    public enum Egress: String, Codable, Sendable { case none, local, internet }
    public enum Permission: String, Codable, Sendable {
        case microphone, systemAudio = "system-audio", screenRecording = "screen-recording",
             accessibility, automation, files, network
    }
    public struct Audio: Codable, Equatable, Sendable {
        public var microphone = false   // opens an input device
        public var system = false       // captures other apps' output (ScreenCaptureKit or a Core Audio tap)
        public var files = false        // transcribes audio files it was given (a hardware recorder's)
    }

    public var timing: Timing
    public var partials: Bool           // emits provisional text that later becomes final
    public var speakers: Speakers       // none · labels ("speaker 2") · names ("Priya Raman")
    public var words: Bool              // word-level timing
    public var corrections: Bool        // may revise or retract text it already called final
    public var audio: Audio
    public var screen: Bool             // records or reads the screen
    public var permissions: [Permission]
    public var egress: Egress           // where meeting content goes: nowhere, another local process, the internet
    public var clock: Clock             // the time basis of every time it emits (2.5)
    public var latency: Double?         // live: typical seconds from speech to final
    public var expectedDelay: Double?   // post-hoc: typical seconds after the meeting ends until text exists
    public var keepsAudio: Bool         // writes audio into the meeting folder (voice matching, audio search)
}
```

Today's recorder, Zoom captions read through Accessibility, and an imported VTT, side by side:

| | `local-recorder` | Zoom captions (fork) | `file-import` (VTT) |
| --- | --- | --- | --- |
| timing | live | live | post-hoc |
| partials | true | true (the caption line grows) | false |
| speakers | labels | names | names when the file has them |
| words | true | false | false |
| corrections | false | false | false |
| audio | mic + system | none | none |
| permissions | microphone, system-audio | accessibility | files |
| egress | none | none | none |
| clock | meeting | wall | media |
| latency | ~1 s | depends on Zoom; measure it | n/a |
| keepsAudio | true | false | false |

Declare what is true, not what is flattering. A source that says `speakers = "names"` and then sends "Speaker 1" fails the kit. A source that declares no audio and then opens the microphone is killed (4.5).

### 2.3 Lifecycle

```
            availability ──► start ──► events… ──► stop ──► drain ──► end ──► (meeting finalizes)
                 │                                                        │
       unavailable: try next                                 purge, at Done or 24 h
```

1. **Availability.** Before a meeting starts, WorkScribe asks each source in the chosen chain whether it can work right now, in parallel, with a 3-second limit each. For an automatic start the probes run during the existing 3-second settle window, so they cost no time. An answer is `ready`, `unavailable(reason, fix)` or `needsPermission(permission, fix)`. The reason is a sentence a person can read: "Zoom isn't in a meeting", "Captions are off in this meeting". The first `ready` source wins.
2. **Start.** The host creates the meeting (or a new session of a resumed one), creates `Meetings/<id>/sources/<source-id>/` as the source's scratch folder, and calls `start`. A live source starts emitting. A post-hoc source says it is `waiting`.
3. **Events.** Partials, finals, revisions, speaker names, status. Section 2.4.
4. **Stop.** The user presses Stop, the call ends, or the app quits. The host calls `stop(reason)`. A live source flushes its last line as final and sends `end`. A post-hoc source keeps its stream open: it is now waiting for the platform's transcript.
5. **Drain.** The host keeps consuming until `end`, with the same stall rule today's recorder uses (`RecordingDeadline`: give up when no progress for 30 s). For post-hoc sources the deadline is `expectedDelay × 3`, capped at 22 hours so it always lands before the 23-hour automatic Finalize.
6. **End.** `end(reason, complete)`. `complete: false` means "this is what I have and there won't be more". The meeting records it so the note can say "Transcript ends at 41:10".
7. **Finalize** belongs to the meeting, not the source. The final pencil pass runs after the source ends (live) or when the post-hoc transcript arrives. If you press Finalize before a post-hoc transcript arrives, the note finalizes without it. A transcript that arrives later is kept for Ask and search until the fade but never changes a finalized note, and the pill says so in one line.
8. **Purge** happens at Done or 24 hours after the meeting ended, exactly as today. Section 2.8.

**Resume** and **switching sources** reuse what already exists. Resume (`Meeting.resume`) appends a `RecordingSession` with its own speaker namespace and per-channel offsets. Switching from Zoom's captions to local recording halfway through a meeting is the same operation with a different source: a new session whose `source` field names the new source. Nothing is merged across the boundary.

### 2.4 Events

One vocabulary, used three ways: as a Swift enum for in-process sources, as JSON lines for command sources, and as the request body of the ingest endpoint.

```swift
public enum SourceEvent: Equatable, Sendable {
    case status(SourceState, message: String?)       // starting · listening · waiting · degraded · paused
    case clock(mediaOrigin: Date, exact: Bool)       // media-clock sources: when media time 0 happened
    case partial(SourcePartial)                      // provisional; replaces the previous partial with this id
    case final(SourceSegment)                        // settled text; promotes a partial with the same id
    case revise(SourceRevision)                      // correction to a final segment; the id stays
    case retract(id: String)                         // the platform withdrew this text
    case speaker(SpeakerInfo)                        // a name for a speaker key, or "this is you"
    case end(EndReason, complete: Bool)              // stopped · meeting-ended · complete · failed · timeout
}

public struct SourcePartial: Equatable, Sendable {
    public var id: String; public var channel: String?; public var speaker: String?
    public var start: Double?; public var text: String
}
public struct SourceSegment: Equatable, Sendable {
    public var id: String; public var channel: String?; public var speaker: String?
    public var start: Double; public var end: Double; public var text: String
    public var words: [SourceWord]?; public var confidence: Double?
}
public struct SourceWord: Equatable, Sendable { public var text: String; public var start: Double; public var end: Double; public var confidence: Double? }
public struct SourceRevision: Equatable, Sendable {
    public var id: String; public var text: String?; public var start: Double?; public var end: Double?
    public var speaker: String?; public var words: [SourceWord]?
}
public struct SpeakerInfo: Equatable, Sendable {
    public var key: String; public var channel: String?; public var name: String?; public var you: Bool?
}
```

| Event | Means | Host does |
| --- | --- | --- |
| `partial` | "Someone is saying this, and it may change." | Sets the channel's provisional line (today's `Meeting.setPartial`). Not saved as evidence, not cited, shown live. |
| `final` | "This was said, by this speaker, at this time." | Appends a `Segment` (`Meeting.finishPartial`), saves, schedules the title and pencil passes, emits SSE `transcript`. |
| `revise` | "I called this final but it was wrong." | Replaces text/time/speaker on the stored segment, keeping its ID. Notes citing it are marked stale and re-enhanced. |
| `retract` | "Forget this." | Removes the segment. Excerpts that cited it drop out on the next pass. |
| `speaker` | "Key `p-2` is Priya Raman" or "key `me` is you". | Stores a source-provided name (2.6). Never overrides a name the user chose. |
| `status` | Human status. | Shown in the pill and the menu. `degraded` is amber, never red. |
| `clock` | "Media time 0 was 14:02:07Z." | Fixes alignment for `media` clocks (2.5). |
| `end` | No more events. | Ends the session. Anything after `end` is a protocol error. |

Rules a source must keep:

- **Finals per channel arrive in time order**, allowing up to 0.5 s of overlap between neighbours. Out-of-order corrections go through `revise`.
- **Segments are sentence-sized.** Aim for one speaker turn of 1–30 seconds. Rolling captions should be coalesced: keep emitting `partial` with one id while the line grows, then `final` when the speaker changes, after 1.5 s without change, or at 30 s. These are the same thresholds `TranscriptParser` and `TranscriptTurns` use for NeMo output, so turns read the same whichever source made them.
- **Text is plain.** No markup, no caption positioning, no `[MUSIC]` unless the platform really said that. At most 10,000 characters per segment.
- **No transcript text in logs.** stderr and `status.message` are for humans and may be shown on screen.

### 2.5 Time

Everything in a meeting is on one clock: **seconds since `Meeting.startedAt`**. Segment times, the time each note line was first typed (`Note.createdAt`, `NoteDocument.Block.at`), screen moments, clip offsets and deep links (`workscribe://meeting/<id>?t=541`) all use it. Pencil lines depend on it: `ExcerptPolicy` prefers transcript that ended up to 90 seconds before you typed a line, or started up to 10 seconds after. If a source's clock is off by two minutes, every pencil line cites the wrong moment, confidently.

A source declares one of three clocks, and every time it emits is a number in that clock:

| `clock` | Times are | Host converts with | Typical source |
| --- | --- | --- | --- |
| `meeting` | seconds since `startedAt` | nothing | in-process Swift sources using `session.meetingTime()` |
| `wall` | Unix epoch seconds (fractional) | `t − startedAt` | anything watching a live meeting: captions, a bridge |
| `media` | seconds from the start of some recording | `t + offset`, where offset is found by alignment | VTT/SRT files, cloud recording transcripts |

**Live sources** stamp each segment with when the words were *spoken*, not when they were seen. A source that can only observe arrival (an Accessibility observer sees a caption when Zoom draws it) subtracts its typical delay and declares it in `latency`. The kit measures your residual error against a fixture; the target is ±5 seconds, well inside the 10-second lead `ExcerptPolicy` allows.

**Post-hoc sources** usually only know media time. A Teams or Zoom transcript file starts at 00:00:00 when *the platform's* recording started, which may be before or after WorkScribe's meeting started. The host finds the offset in this order, and records which method won in `Meeting.transcriptSource.alignment`:

1. **Declared.** The source sends `clock(mediaOrigin:exact:)` because it knows (an API returned the recording's start time, or the file says so). `exact: true` is used as is.
2. **From your notes.** If at least three note lines have typing times, the host searches offsets from −15 to +15 minutes in 2-second steps and scores each one with the matcher the pencil already uses:

   ```
   score(δ) = Σ over typed notes  max over transcript chunks  meaning(note, chunk) × timeScore(chunk shifted by δ, note.at)
   ```

   with `LexicalMatcher` (or the embedder, when loaded) and the default `ExcerptPolicy`. It accepts the best δ when its score is at least 1.0 and at least 1.25 times the score at the prior guess; otherwise it keeps the prior. Screen moments, when allowed, add a second signal: OCR text against transcript text.
3. **Prior guess.** Media zero equals the meeting start, or the declared origin with `exact: false`.

The result is shown plainly: "Transcript lined up with your notes (shifted 1 min 37 s)" or "Times are approximate". A nudge control in the Transcript tab moves the whole channel in 5-second steps. Alignment rewrites segment times for that channel and stores the offset in `Meeting.sourceOffsets[channel]`, the dictionary the recorder already uses for per-track offsets. Segment IDs don't change, so evidence links survive; the next pencil pass re-matches notes against the shifted times.

Clock drift inside one meeting is not modelled. Platform servers and your Mac both use network time; over an hour the difference is far below the matching tolerance.

### 2.6 Identity

Pencil lines cite evidence, and evidence must still resolve after a correction, a resume, a crash and a replay. Today:

- `Segment.id` is a random UUID, except that the first final segment reuses its partial's ID (`Meeting.finishPartial`).
- An excerpt reference is a chunk ID, `"<segment id>#<n>"`, where the segment is the first of a grouped turn (`TranscriptChunker`).
- Links are `workscribe://meeting/<meeting>?t=<seconds>&segment=<segment id>`.

The contract keeps all three and makes IDs deterministic:

- **The source owns its IDs.** Any string up to 128 characters, unique within the source's session. The same speech keeps the same ID through `partial`, `final` and every `revise`. An ID is never reused for different speech. If one partial becomes several finals, the first keeps the partial's ID and the rest get new ones, which is today's rule written down.
- **The host derives the stored ID.** `Segment.id = UUIDv5(namespace: meetingID, name: "<source id>/<session id>/<source segment id>")`. Replaying the same events gives the same IDs, so a command source that crashes and re-sends its last minute after restart produces duplicates the host can recognise, and a re-imported VTT doesn't orphan evidence. The result still looks like a UUID, so existing code that stores or links segment IDs needs no change.
- **Chunk references fall back to their segment.** A revision can move sentence boundaries, which renumbers `#n`. When a stored `excerptRef` no longer exists, the host resolves it to the nearest chunk of the same segment. Migration step 6 adds this; it fixes a latent issue with today's recorder too.
- **Channels.** `Segment.source` is `<source id>` or `<source id>/<channel>`. The local recorder is grandfathered: its channels stay `microphone` and `system`, so old meetings and new ones read the same.
- **Speakers.** A source sends a speaker key. The host stores `Segment.speaker = "<channel or source>:<key>"`, prefixed with the session namespace on resumed sessions (today's rule). Keys are scoped to one session: "speaker-2" in session one and session two are not assumed to be the same person.
- **Names.** A source-provided name goes into a new `Meeting.speakerNames[speakerKey]`, not into `speakerAssignments`. Display precedence becomes: this line's user override, then the user's name for the speaker, then the source's name, then "Speaker N". The user always wins, and "Only this line" keeps working. `you: true` marks a speaker as the user; today that is inferred only for a solo microphone voice.

### 2.7 Errors and degradation

| Situation | How the source says it | What the host does | What the user sees |
| --- | --- | --- | --- |
| Can't work right now | `availability = unavailable(reason, fix)` | Tries the next source in the chain. | The source that was used, and on hover why the others weren't. |
| Needs a permission | `needsPermission(.accessibility, fix)` | Tries the next source; offers the fix once. | "Zoom's captions need Accessibility access · Open Settings" |
| Working, but badly | `status(.degraded, "No captions for 2 minutes. Are captions on in Zoom?")` | Keeps the source. | The message, in amber, in the pill. |
| Transient failure | the stream throws or the process exits non-zero | Restarts it up to 3 times (1 s, 4 s, 16 s backoff), deduplicating by ID. | "Reconnecting to Zoom's captions" |
| Gone for good | still failing after the restarts | Follows the rule's `on_failure`. | "Zoom's captions stopped at 23:40. Notes only from here." |
| Lying about itself | uses a capability it didn't declare | Kills it and records the violation. | "Stopped the Zoom captions helper: it tried to use the microphone, which isn't allowed on this Mac." |

`on_failure` is `"notes-only"` (the default) or `"next"`. **A source never fails over to one that captures more.** If captions die and the next source in the chain is the local recorder, WorkScribe offers "Record instead" as a button rather than starting the microphone mid-meeting on its own. Someone who chose captions over recording chose it for a reason, and a silent switch would break that. `"next"` only moves to sources whose `audio` and `screen` capabilities are a subset of the failed one's.

### 2.8 Retention and purge

"Only the note survives" is WorkScribe's central promise. A source must not weaken it.

1. **Write only into your scratch folder.** `Meetings/<id>/sources/<source id>/`. The existing purge deletes the whole meeting folder, so anything there disappears on schedule with no extra work. Command sources get it as `WORKSCRIBE_SCRATCH`, and their `TMPDIR` points inside it.
2. **If you keep anything elsewhere, declare it and purge it.** A manifest says `stores_outside_scratch = true`, and the source implements `purge(meetingID:)` (Swift) or purge mode (`wsp/1`). Purge must be idempotent and safe to replay after a crash, like `RetentionStore.purge`. The host calls it after the raw meeting folder is gone and before it reports `meeting.purged`. If a source's purge keeps failing, WorkScribe finishes its own purge, keeps retrying the source's every minute, and says "Couldn't confirm Zoom's captions helper deleted its copy. Trying again in a minute."
3. **Never extend retention.** Late events for a purging or purged meeting are dropped (`410 Gone` on the ingest endpoint). A post-hoc transcript arriving at hour 20 is kept for the remaining 4 hours. Arrival does not restart the clock.
4. **Never write the note.** Sources produce evidence. The note belongs to the user and the note destination.
5. **Never log meeting content.** stderr from command sources is kept in memory (the last 200 lines, at most 64 KB) for Settings › Sources › Details. It is never written to disk, because it may contain transcript text.
6. **Leave the user's own files alone.** `file-import` copies the file into scratch. The `.vtt` in Downloads is the user's and stays where it is; the import screen says so.

### 2.9 The Swift protocol

```swift
// Sources/WorkScribeCore/Sources/TranscriptSource.swift

/// "Zoom's captions" completes "Transcript from …". `short` fits the pill: "Zoom captions".
public struct SourceLabel: Codable, Equatable, Sendable { public var sentence: String; public var short: String }

public struct SourceFix: Codable, Equatable, Sendable { public var label: String; public var url: String? }

public enum Availability: Equatable, Sendable {
    case ready
    case unavailable(reason: String, fix: SourceFix?)
    case needsPermission(SourceCapabilities.Permission, fix: SourceFix)
}

public enum StopReason: String, Codable, Sendable { case user, callEnded = "call-ended", policy, quit, switched }

/// What WorkScribe knows when it chooses a source. Nil means unknown, never "no".
public struct MeetingContext: Sendable {
    public enum Trigger: String, Sendable { case call, manual, api, `import` }
    public var trigger: Trigger
    public var app: CallApp?                              // CallDetector's signal: name and bundle ID
    public var windowTitle: String?
    public var calendar: CalendarEvent?                   // needs a calendar provider; nil until one exists
    public var online: Bool?
    public var now: Date
}

public struct SourceSession: Sendable {
    public let meetingID: String
    public let sessionID: String          // RecordingSession.id; "initial" for the first
    public let startedAt: Date            // the meeting clock's zero
    public let scratch: URL               // Meetings/<id>/sources/<source id>/, purged with the meeting
    public let resumed: Bool
    public let input: URL?                // a file the user gave an import source
    public let context: MeetingContext
    public func meetingTime(_ date: Date = Date()) -> Double { date.timeIntervalSince(startedAt) }
}

public protocol TranscriptSource: AnyObject, Sendable {
    var id: String { get }
    var label: SourceLabel { get }
    var capabilities: SourceCapabilities { get }
    func availability(_ context: MeetingContext) async -> Availability
    /// The stream ends with `.end`. Throwing means a transient failure; the host may restart the source.
    func start(_ session: SourceSession) async throws -> AsyncThrowingStream<SourceEvent, Error>
    /// Wind down. Live sources flush and end; post-hoc sources keep waiting for their transcript.
    func stop(_ reason: StopReason) async
    /// Remove anything kept outside `session.scratch`. Idempotent. Default: nothing to do.
    func purge(meetingID: String) async throws
}

public extension TranscriptSource {
    func purge(meetingID: String) async throws {}
}
```

Sources that hear audio don't each bring a recognizer. `AudioTranscriber` wraps today's `SpeechRuntime`, `SpeechConnection`, `AudioBacklog` and `TranscriptParser`, takes 16 kHz mono PCM and yields canonical events. `LocalRecorderSource` is `AudioCapture` plus one `AudioTranscriber` per track; Plaud import is a file reader plus one `AudioTranscriber`. Both keep today's backlog-on-disk design, so a slow Mac still never drops audio.

A source that hears audio reports pressure as status. Today's `RecordingPressure` (lag ≥ 2 s pauses screen, ≥ 6 s pauses live AI, ≥ 12 s delays the transcript) becomes `status(.degraded, "Your Mac is busy · still recording, the transcript will catch up")` plus a `lag` value the host uses for the same decisions.

---

## 3. Sources outside the app

Most people adapting WorkScribe to an environment won't want to write Swift or rebuild the app. They want to read some captions, watch a folder, or bridge something their company already runs. Two ways in, one vocabulary.

### 3.1 Command sources: `wsp/1`

A command source is a folder with a manifest and an executable:

```
~/Library/Application Support/WorkScribe/Sources/zoom-captions/
├── source.toml
├── run                      # any executable; the manifest names it
└── README.md                # what it reads, what it needs, how to turn it off
```

```toml
# source.toml
id = "zoom-captions"
name = "Zoom captions (Accessibility)"
version = "0.1.0"
protocol = 1
command = ["./run"]                   # argv, relative to this folder. No shell.
role = "transcript"                   # or "context" for a screen/context source (5.2)
stores_outside_scratch = false

[label]
sentence = "Zoom's captions"
short = "Zoom captions"

[capabilities]                         # must match what the program says in hello
timing = "live"
partials = true
speakers = "names"
words = false
corrections = false
audio = { microphone = false, system = false, files = false }
screen = false
permissions = ["accessibility"]
egress = "none"
clock = "wall"
latency = 1.5
keepsAudio = false

[config]                               # passed in hello.config; sources.toml may override
poll_ms = 250
```

The manifest exists so WorkScribe can decide whether a source is allowed **without running it**. Under a no-recording policy, a source whose manifest declares microphone audio is never launched.

**The conversation.** One JSON object per line, UTF-8, at most 1 MiB per line. The host writes to the program's stdin; the program writes to stdout; stderr is a human log. Every message has a `type`. Unknown types and unknown fields are ignored in both directions, which is how the protocol grows without breaking anyone.

A live session, in full (host lines marked `→`, source lines `←`; times are epoch seconds because this source declared `clock = "wall"`):

```jsonc
→ {"type":"hello","protocols":[1],"mode":"session","host":{"name":"WorkScribe","version":"0.9.0"},"config":{"poll_ms":250}}
← {"type":"hello","protocol":1,"source":{"id":"zoom-captions","name":"Zoom captions (Accessibility)","version":"0.1.0"},"capabilities":{"timing":"live","partials":true,"speakers":"names","words":false,"corrections":false,"audio":{"microphone":false,"system":false,"files":false},"screen":false,"permissions":["accessibility"],"egress":"none","clock":"wall","latency":1.5,"keepsAudio":false}}
→ {"type":"start","meeting":{"id":"6F1C…","title":"Offline sync — v2.4 scope","startedAt":"2026-10-14T17:02:00.000Z","startedAtEpoch":1791997320.0,"app":{"name":"Zoom","bundleId":"us.zoom.xos"}},"session":{"id":"initial","resumed":false},"scratch":"/Users/you/Library/Application Support/WorkScribe/Meetings/6F1C…/sources/zoom-captions"}
← {"type":"status","state":"listening","message":"Reading Zoom's captions"}
← {"type":"partial","id":"c-0041","speaker":"Priya Raman","text":"So the ship date"}
← {"type":"partial","id":"c-0041","speaker":"Priya Raman","text":"So the ship date moves to November"}
← {"type":"final","id":"c-0041","speaker":"Priya Raman","start":1791997845.2,"end":1791997849.9,"text":"So the ship date moves to November 4 so QA gets a full week."}
← {"type":"speaker","key":"Andrew S.","you":true}
→ {"type":"stop","reason":"user"}
← {"type":"end","reason":"stopped","complete":true}
   (the program exits 0)
```

Before a meeting, the host probes availability with a short-lived process:

```jsonc
→ {"type":"hello","protocols":[1],"mode":"probe","host":{"name":"WorkScribe","version":"0.9.0"},"config":{"poll_ms":250},"context":{"trigger":"call","app":{"name":"Zoom","bundleId":"us.zoom.xos"}}}
← {"type":"hello","protocol":1,"source":{"id":"zoom-captions","name":"Zoom captions (Accessibility)","version":"0.1.0"},"capabilities":{…}}
← {"type":"availability","available":false,"reason":"Captions are off in this meeting.","fix":{"label":"Turn on captions in Zoom"}}
   (the program exits 0)
```

And for purge, when the manifest says `stores_outside_scratch = true`:

```jsonc
→ {"type":"hello","protocols":[1],"mode":"purge","host":{…},"config":{…}}
← {"type":"hello","protocol":1,…}
→ {"type":"purge","meetingId":"6F1C…"}
← {"type":"purged","meetingId":"6F1C…"}
```

**Messages.** The exact schema is `docs/specs/transcript-source.schema.json` (JSON Schema 2020-12).

| Direction | `type` | Required fields | Optional |
| --- | --- | --- | --- |
| host → source | `hello` | `protocols`, `mode` (probe · session · purge), `host` | `config`, `context` (probe) |
| host → source | `start` | `meeting{id,startedAt,startedAtEpoch}`, `session{id,resumed}`, `scratch` | `meeting.title`, `meeting.app`, `meeting.calendar`, `session.lastId`, `input{path}` |
| host → source | `stop` | `reason` | |
| host → source | `purge` | `meetingId` | |
| source → host | `hello` | `protocol`, `source{id,name,version}`, `capabilities` | |
| source → host | `availability` | `available` | `reason`, `fix{label,url?}` |
| source → host | `status` | `state` | `message`, `lag` |
| source → host | `clock` | `mediaOrigin` (epoch seconds) | `exact` |
| source → host | `partial` | `id`, `text` | `channel`, `speaker`, `start` |
| source → host | `final` | `id`, `start`, `end`, `text` | `channel`, `speaker`, `words[]`, `confidence` |
| source → host | `revise` | `id` | `text`, `start`, `end`, `speaker`, `words[]` |
| source → host | `retract` | `id` | |
| source → host | `speaker` | `key` | `channel`, `name`, `you` |
| source → host | `moment` | `id`, `start`, `end`, `text` | `app`, `window` (context sources) |
| source → host | `error` | `code` (permission · unavailable · transient · fatal · protocol), `message` | `fix` |
| source → host | `end` | `reason`, `complete` | |
| source → host | `purged` | `meetingId` | |

**Versioning.** The host offers every protocol major it speaks (`"protocols":[1]`); the source answers with one. Adding a message type or an optional field never changes the major. Removing or changing the meaning of a field does, and the host keeps speaking the old major for at least two releases after a new one ships. A source that answers with a major the host didn't offer is stopped with "This source needs a newer WorkScribe."

**Supervision.**

| What | Rule |
| --- | --- |
| Launch | `Process` with the manifest's argv, working directory = the source's folder, no shell. Its own process group. |
| Environment | `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`, `HOME`, `LANG`, `TMPDIR` (inside scratch), `WORKSCRIBE_SOURCE_PROTOCOL=1`, `WORKSCRIBE_SOURCE_ID`, `WORKSCRIBE_SCRATCH` (session mode only). Nothing else is inherited. The API token is never passed. |
| Timeouts | `hello` within 5 s; probe answer within 3 s; `end` within 10 s of `stop`, then SIGTERM, then SIGKILL 3 s later. |
| stdin closes | The source must exit within 5 s. This is how WorkScribe makes sure no helper outlives a crash. The kit checks it. |
| Liveness | A live source sends something (a `status` with no change is fine) at least every 30 s. After 60 s of silence the host marks it degraded; after 3 minutes it stops and restarts it. |
| Restarts | Up to 3, at 1 s, 4 s and 16 s. The new process gets `start` with `resumed:true` and `lastId`. Re-sent finals with known IDs are deduplicated: identical ones are ignored, changed ones are treated as `revise`. |
| Flooding | More than 200 messages a second: partials are dropped, finals are kept, and the source is marked degraded. |
| Bad lines | A line that isn't valid JSON or fails the schema is dropped and counted. After 50, the source is stopped. |
| Logs | stderr in an in-memory ring (2.8). |

**Permissions and the sandbox.** WorkScribe is not App Sandboxed; it is a signed developer build. A child process is not sandboxed either. macOS's privacy system (TCC) generally attributes a child's access to the app that launched it (the "responsible process"), so a Python script reading Zoom's Accessibility tree will need **WorkScribe** to have Accessibility access, and the prompt and the System Settings entry will name WorkScribe. Verify this on your macOS version before you write instructions for others; it is the behaviour we expect, not something this spec guarantees. Two consequences:

- Settings › Sources lists, for each source, which permissions it asked WorkScribe to hold on its behalf, so a user can see why WorkScribe has Accessibility access.
- The same inheritance is why WorkScribe must police what a child does with audio (4.5).

An organization can require signed sources: `source_signers = ["ABCDE12345"]` in policy makes the host check each command's executable against a Developer ID team before launch. A script interpreter's signature says nothing about the script it runs, so a signed-sources policy effectively means compiled helpers.

### 3.2 HTTP ingest

For something that is already running and wants to push text in: a team's caption bridge, a browser helper, a hardware box on the network that has a small local agent. It uses the local API as it exists today: `127.0.0.1` only, the bearer token from `~/Library/Application Support/WorkScribe/api.json` (mode 0600), 1 MB request bodies. Requests from a browser page are refused by the existing Origin rule; browser extensions should go through the native messaging host (`WorkScribeNativeHost`), as the clipper does.

An ingest source must be declared in `sources.toml` (`kind = "ingest"`) with its capabilities. Possessing the token is not enough to inject a transcript into a meeting: the session must name a declared source that the current policy allows.

| Method and path | Body | Response |
| --- | --- | --- |
| POST `/v1/sources/ingest/sessions` | `{source:"team-bridge", meetingId?, startMeeting?:false}` | 201 `{sessionId, meetingId, startedAt, startedAtEpoch, clock}`; 403 `{error, reason}` when policy forbids; 404 unknown source; 409 no meeting and `startMeeting` false; 410 meeting purged |
| POST `/v1/sources/ingest/sessions/:sid/events` | NDJSON (`application/x-ndjson`), one `wsp/1` source → host message per line | 200 `{accepted, rejected:[{line, error}]}` |
| DELETE `/v1/sources/ingest/sessions/:sid` | — | 204; equivalent to `end{reason:"stopped",complete:true}` |

A session lapses to degraded after 60 seconds without events and ends after 10 minutes. `GET /v1/events` gains one event, `source {meetingId, id, label, state, message?}`, and `GET /v1/status` gains a `transcript` object (4.6).

```sh
TOKEN=$(jq -r .token ~/Library/Application\ Support/WorkScribe/api.json)
PORT=$(jq -r .port ~/Library/Application\ Support/WorkScribe/api.json)
SID=$(curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"source":"team-bridge"}' http://127.0.0.1:$PORT/v1/sources/ingest/sessions | jq -r .sessionId)
printf '%s\n' \
  '{"type":"final","id":"b-1","speaker":"Marcus Chen","start":1791997850.1,"end":1791997853.0,"text":"I can size the migration by Thursday."}' |
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/x-ndjson' --data-binary @- \
  http://127.0.0.1:$PORT/v1/sources/ingest/sessions/$SID/events
```

### 3.3 Handing over a file

Post-hoc transcripts usually arrive as a file. Three ways to hand one to a meeting, all ending in the same `file-import` source:

- `POST /v1/meetings/:id/transcript {path, format?, mediaOrigin?}`, by absolute path, like attachments. The Obsidian plugin gets an **Attach transcript file…** command that calls it.
- Drop the file on the meeting in the menu bar popover.
- A `file-import` source with `watch` set picks up a matching file that appears after a meeting it is waiting for. If two meetings are waiting, it asks which one instead of guessing.

The importer reads WebVTT and SRT. It accepts speakers as WebVTT voice spans (`<v Priya Raman>`) and as a leading `Name: ` prefix, the latter only when the prefix is at most four words and repeats across cues, so a line like "Note: the vendor said…" isn't turned into a speaker called Note. Styling tags and positioning are stripped. Each cue becomes one final segment with ID `cue-<cue identifier or index>`; WorkScribe's own turn grouping joins short cues into readable turns, as it already does for NeMo's fragments (`RealRecordingTests` covers 25 fragments becoming 5 turns).

---

## 4. Choosing a source: rules and policy

### 4.1 Where configuration lives

| Layer | Location | Can set | Who edits it |
| --- | --- | --- | --- |
| Built-in | compiled in | `use = ["local-recorder", "notes-only"]` | upstream |
| Fork defaults | `WorkScribe.app/Contents/Resources/sources.default.toml` | sources, rules, policy | the fork's author |
| User | `~/Library/Application Support/WorkScribe/sources.toml` | sources, rules, policy (self-imposed) | the person, directly or in Settings › Sources |
| Organization file | `/Library/Application Support/WorkScribe/policy.toml` | sources, rules, policy, `user_rules` | an administrator |
| Managed | a configuration profile for the app's bundle ID, key `SourcePolicy`, a dictionary with the same schema | same as the organization file | MDM |

The organization file is read only if it is owned by root and not writable by others; otherwise it is ignored and Settings says why. That doesn't stop an administrator of the Mac from editing it. The point is that the app can't, and the user can't by accident. When both organization layers exist, both apply.

**Rules** are tried in this order, and the first rule whose `when` matches chooses the chain: managed, organization, user, fork defaults, built-in. If an organization sets `user_rules = false`, user rules are skipped and Settings › Sources says "Your organization chooses sources on this Mac".

**Policy** is not ordered. Every `[[policy]]` entry whose `when` matches, from every layer, applies, and prohibitions add up. Nothing can turn a prohibition back off. A user may write policy too, as a promise to themselves ("never record calls with my doctor"), and it is enforced the same way.

### 4.2 Why TOML

The configuration is TOML, parsed by a small strict reader in Core that accepts only what this schema uses (tables, arrays of tables, dotted keys, strings, numbers, booleans, arrays) and reports anything else with a line number. Reasons:

- Comments. A policy file needs to say why a rule exists, for the next administrator.
- Ordered `[[rules]]` express a fallback list without nesting.
- No significant whitespace, and no YAML-style surprises where `no` becomes false.
- It maps one-to-one onto the plist dictionary MDM delivers and onto JSON, so the same schema (`docs/specs/sources.schema.json`) validates all three.

The cost is a parser, since Foundation has none. Writing ~250 lines keeps WorkScribe's dependency list at two packages; taking a TOML package is the alternative (see Decisions).

### 4.3 The file

```toml
version = 1

# Sources you've installed or configured. local-recorder, file-import and notes-only always exist.
[sources.zoom-captions]
kind = "command"
path = "Sources/zoom-captions"            # relative to this file's folder

[[rules]]
name = "Zoom calls"
when.app = ["zoom"]
use = ["zoom-captions", "local-recorder"]
on_failure = "notes-only"

[[policy]]
when.calendar.title = ["*therapy*", "*doctor*"]
audio = "forbidden"
reason = "I don't record health appointments."
```

### 4.4 Conditions

All conditions in one `when` must match. A list means any of its values. Every condition can be unknown, and unknown is handled explicitly:

| Condition | Matches | Source of truth | Unknown when |
| --- | --- | --- | --- |
| `app` | `zoom`, `teams`, `webex`, `facetime`, `slack`, `discord`, `meet`, `browser`, or a bundle ID | `CallDetector`: the app holding the microphone, or a browser whose meeting window title matched. Not the frontmost app: you're usually typing in Obsidian. | manual or API start with no call detected |
| `trigger` | `call`, `manual`, `api`, `import` | how the meeting started | never |
| `window` | glob over the call window's title | `CGWindowList`, needs Screen Recording | permission missing |
| `calendar.title` | globs | a calendar provider (EventKit is planned, not built) | no provider, no access, or no event now |
| `calendar.organizer_domain` | domains | same | same |
| `calendar.attendee_domain` | domains, any attendee | same | same |
| `calendar.link` | globs over the meeting URL (`*zoom.us/j/*`) | same | same |
| `source_available` | source IDs | the availability probes | never (probes have a timeout) |
| `network` | `online`, `offline` | `NWPathMonitor` | before the first path update |
| `time.days` | `mon`…`sun` | the Mac's clock and time zone | never |
| `time.hours` | `"09:00-18:00"` | same | never |

`if_unknown` decides what an unknown condition does: `"skip"` (the default for rules) treats the rule as not matching; `"match"` (the default for policy) treats it as matching. Policy fails closed: if an organization forbids recording for meetings organized from `acme.com` and WorkScribe can't see the calendar, it assumes the meeting might be one.

### 4.5 Chains, policy and the no-record guarantee

A rule's `use` is an ordered chain. To pick a source WorkScribe:

1. finds the first rule that matches (4.1);
2. removes every source the combined policy forbids, remembering why;
3. appends `notes-only` if the chain doesn't end with it;
4. probes availability of what's left, in parallel;
5. uses the first that is ready.

Every step is recorded in `Meeting.transcriptSource`:

```json
{"source":"notes-only","kind":"notes-only","label":"Notes only","rule":"Zoom calls",
 "chain":[{"id":"zoom-captions","outcome":"unavailable","reason":"Captions are off in this meeting."},
          {"id":"local-recorder","outcome":"forbidden","reason":"Acme doesn't allow recording meetings."},
          {"id":"notes-only","outcome":"used"}]}
```

Policy keys:

| Key | Values | Forbids |
| --- | --- | --- |
| `audio` | `allowed`, `forbidden` | any source with `audio.microphone` or `audio.system` |
| `audio_files` | `allowed`, `forbidden` | sources with `audio.files` (transcribing another device's recording). Defaults to the value of `audio`. |
| `screen` | `allowed`, `forbidden` | screen video and OCR, and any source or context source with `screen` |
| `egress` | `internet`, `local`, `none` | sources sending meeting content further than this |
| `cloud` | `allowed`, `forbidden` | cloud model and embedding providers (section 5) |
| `sources` | list of source IDs | everything not listed (an allowlist) |
| `source_signers` | Developer ID team IDs | command sources not signed by one of them |
| `reason`, `contact` | text | shown to the user, verbatim |

**The no-record guarantee.** When `audio = "forbidden"` applies, WorkScribe never opens the microphone or captures system audio. That has to hold even if a rule is wrong, a source lies, or a future change forgets to check. Three layers:

1. **One gate in the app.** `CaptureGate.authorize(_ device:, meeting:)` is the only way to reach `AVCaptureDevice.requestAccess(for: .audio)`, `AVAudioEngine.inputNode`, an `SCStream` with `capturesAudio`, a Core Audio tap, or `ScreenRecorder.start`. It re-reads policy on every call rather than trusting the decision made at meeting start. A unit test fails the build if any of those APIs appears outside `Capture.swift` and `ScreenRecorder.swift`, and both files call the gate first. Under this policy WorkScribe never even asks for microphone permission, so macOS never shows the prompt and the orange microphone indicator never lights. The user can check that themselves.
2. **A tripwire on children.** `CallDetector` already reads, every two seconds, which processes are using audio input (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`). The same loop checks WorkScribe's own process and every source it launched (by `kAudioProcessPropertyPID`). Under a no-audio policy, a child with live input is killed and the meeting records the violation. WorkScribe itself with live input is a bug, and capture is torn down immediately.
3. **An OS rule an administrator controls.** A privacy preferences (PPPC) configuration profile can deny Microphone access to WorkScribe's bundle ID outright; Apple allows MDM to deny, though not to grant, microphone access. With that profile installed the guarantee no longer depends on WorkScribe's code at all, and it covers any child that macOS attributes to WorkScribe. The fork guide's sample org kit includes such a profile. Test it on your fleet's macOS version.

Layers 1 and 2 are what WorkScribe promises. Layer 3 is what lets an organization verify the promise without trusting WorkScribe.

### 4.6 What the user sees

The pill today says "Mic + system" or "Mic only". It becomes the source's short label, and the menu and status API carry the full sentence. Words describe what is listening, never the mechanism.

| Situation | Pill | Menu / hover |
| --- | --- | --- |
| Recording on this Mac | `● 12:04 · Mic + system` | Transcript from this Mac's mic and call audio. |
| Captions | `● 12:04 · Zoom captions` | Transcript from Zoom's captions. Nothing is recorded. |
| Captions, recording forbidden | `● 12:04 · Zoom captions` | Transcript from Zoom's captions. Recording is off: Acme doesn't allow recording meetings. Questions: it-help@acme.example |
| Fell back | `● 12:04 · Notes only` | Zoom's captions are off in this meeting, so there's no transcript. Your notes still work. · Turn on captions in Zoom |
| Waiting for a file | `Notes only · transcript later` | The Teams transcript will be added when it's downloaded. |
| File arrived | — | Transcript added and lined up with your notes (shifted 1 min 37 s). |
| Tried to record, policy says no | — | Recording isn't allowed on this Mac. Set by Acme. Your notes still work. |
| Source degraded | amber dot | No captions for 2 minutes. Are captions on in Zoom? |

Policy text is the administrator's, quoted, with their contact. Nothing about a policy is red: red means recording, amber means it needs you (`design/care` rule 3). Settings › Sources shows the chain each rule produces, greys out what policy removes with the reason beside it, and marks organization-set items "Set by your organization".

`GET /v1/status` gains:

```json
"transcript": {"source":"zoom-captions","kind":"command","label":"Zoom's captions","short":"Zoom captions",
               "live":true,"state":"listening","policy":["Acme doesn't allow recording meetings."]}
```

The existing `sources:{mic,system,screen}` booleans stay, and become accurate: `mic` is false under captions.

### 4.7 Worked examples

**1. The company forbids recording, allows the platform's transcript, and otherwise wants notes only.** Installed by IT as `/Library/Application Support/WorkScribe/policy.toml`, with the captions source in `/Library/Application Support/WorkScribe/Sources/zoom-captions/`.

```toml
version = 1
user_rules = false

[[policy]]
audio = "forbidden"
screen = "forbidden"
cloud = "forbidden"
sources = ["zoom-captions", "zoom-transcript", "notes-only"]
reason = "Acme doesn't allow recording meetings. Zoom's own transcript is approved."
contact = "it-help@acme.example"

[sources.zoom-captions]
kind = "command"
path = "/Library/Application Support/WorkScribe/Sources/zoom-captions"

[sources.zoom-transcript]
kind = "file-import"
label = { sentence = "Zoom's saved transcript", short = "Zoom transcript" }
watch = "~/Documents/Zoom"        # wherever your Zoom client saves transcripts; check, don't assume
match = ["*.vtt"]
within = "2h"                     # only files that appear within 2 h of the meeting ending

[[rules]]
name = "Zoom"
when.app = ["zoom"]
use = ["zoom-captions", "zoom-transcript"]   # live captions; if they're off, the saved file afterwards

[[rules]]
name = "Everything else"
use = ["notes-only"]
```

Pair it with the PPPC profile from 4.5. The local recorder can't run here: policy removes it even if someone adds it to a rule, and `user_rules = false` keeps personal rules out.

**2. Personal default: record locally.** No file is needed; this is the built-in rule. Written out, with one personal limit:

```toml
version = 1

[[rules]]
name = "Default"
use = ["local-recorder"]

[[policy]]
when.calendar.title = ["*therapy*", "*doctor*", "*1:1 with HR*"]
audio = "forbidden"
reason = "I don't record these."
```

Until a calendar provider exists, that policy's calendar condition is unknown, and policy fails closed, so *every* meeting would lose recording. Add `if_unknown = "skip"` to that `[[policy]]` if you'd rather it applied only when the calendar is known.

**3. Import a VTT after the call.** Teams lets you download a transcript after a meeting; take notes during the call and let the transcript fill in the evidence afterwards.

```toml
version = 1

[sources.teams-download]
kind = "file-import"
label = { sentence = "the transcript you download from Teams", short = "Teams transcript" }
watch = "~/Downloads"
match = ["*.vtt"]
within = "6h"

[[rules]]
name = "Teams"
when.app = ["teams"]
use = ["teams-download"]
```

During the call the pill reads "Notes only · transcript later". After Stop, the meeting waits. When a `.vtt` lands in Downloads within six hours, it's matched to the meeting that ended most recently before it appeared, aligned against your notes, and the final pencil pass runs. If you Finalize first, the note is finalized from your notes alone.

**4. If Zoom's captions are up, use them; otherwise record locally.** For someone allowed to record who would rather not when a transcript exists anyway.

```toml
version = 1

[sources.zoom-captions]
kind = "command"
path = "Sources/zoom-captions"

[[rules]]
name = "Zoom: captions first"
when.app = ["zoom"]
use = ["zoom-captions", "local-recorder"]
on_failure = "notes-only"        # if captions die mid-call, don't start the mic on my behalf

[[rules]]
name = "Everything else"
use = ["local-recorder"]
```

If captions are off when the call starts, the probe says so and the recorder starts. If they stop halfway, WorkScribe offers "Record instead" and doesn't start recording on its own.

**5. A team bridge during office hours, a client who forbids recording, and local recording otherwise.**

```toml
version = 1

[sources.team-bridge]
kind = "ingest"
label = { sentence = "the team caption bridge", short = "Team bridge" }
capabilities = { timing = "live", partials = true, speakers = "names", words = false, corrections = true, audio = { microphone = false, system = false, files = false }, screen = false, permissions = ["network"], egress = "local", clock = "wall", keepsAudio = false }

[[policy]]
when.calendar.attendee_domain = ["halvorsen.example"]
if_unknown = "skip"
audio = "forbidden"
reason = "Halvorsen's contract doesn't allow recordings."

[[rules]]
name = "Office hours"
when.time.days = ["mon", "tue", "wed", "thu", "fri"]
when.time.hours = "09:00-18:00"
when.network = "online"
use = ["team-bridge", "local-recorder"]

[[rules]]
name = "Otherwise"
use = ["local-recorder"]
```

A Halvorsen meeting during office hours uses the bridge if it's up, and notes only if it isn't, because policy removes the recorder from the chain.

`docs/specs/sources.example.toml` is the complete reference with every key commented.

---

## 5. The other seams

The same shape as transcript sources, with less to say. Each has a Swift protocol, a way in without Swift where one makes sense, policy that applies to it, and obligations toward retention.

### 5.1 Note and answer models

Today `AnswerGenerator` (`displayName`, `provider`, `modelName`, `isAvailable`, `stream`) is a clean seam for answers, with `LlamaAnswerGenerator`, `AppleIntelligenceAnswerGenerator`, `OpenAIResponsesGenerator` and `FallbackAnswerGenerator`. Note lines and titles bypass it: `NoteEnhancer` and `TitleGenerator` call `ws_generate_text` directly and build Qwen and Gemma chat templates inline.

One protocol for all three jobs, with templates owned by the provider:

```swift
public struct ModelMessage: Sendable { public enum Role: String, Sendable { case system, user }; public var role: Role; public var text: String }
public struct ModelRequest: Sendable {
    public var job: ModelJob              // .noteLines, .title, .answer
    public var messages: [ModelMessage]
    public var maxTokens: Int
    public var stop: [String]
}
public protocol TextModel: Sendable {
    var id: String { get }                // "local-qwen", "openai", "ollama"
    var displayName: String { get }       // "Qwen 3.5 · on this Mac" — shown under answers and in Why?
    var location: ModelLocation { get }   // .onDevice, .localNetwork, .cloud
    var isAvailable: Bool { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<String, Error>
}
```

```toml
[models]
note_lines = ["local"]
titles = ["local"]
answers = ["openai", "local"]          # first available; falls back before any text, like today

[models.providers.ollama]
kind = "openai-compatible"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen3.5:7b"
location = "on-device"
```

`OpenAIResponsesGenerator` already has an `endpoint` property; the OpenAI-compatible provider makes it configuration. Policy `cloud = "forbidden"` removes providers whose location is `cloud`. Provenance stays honest: the `trace` shows the provider that actually answered, as `AnswerProvenance` does today. Obligations: a provider is stateless (no conversation memory outside WorkScribe's stores, which purge), treats prompt content as data, and never logs prompts.

### 5.2 Screen and context sources

Today `ScreenRecorder` records `screen.mov`, OCRs changed frames and emits `ScreenMoment`s on the meeting clock. A `ContextSource` shares the transcript source's lifecycle, capability declaration, rules and wire protocol, and emits `moment` events (`id, start, end, text, app?, window?`) that become `ScreenMoment`s. A fork might want only the frontmost window's title and no pixels at all, or slide text read from Keynote. Policy `screen = "forbidden"` removes any context source declaring `screen`, and `ScreenPrivacy`'s deny list still applies to whatever does run. Context rules are a separate `[[context_rules]]` list with the same `when` and `use`, so a meeting can use captions for text and window titles for context.

### 5.3 Where notes live

Two paths reach the vault today. The live meeting document is a real Obsidian note bound to the plugin (`NoteDocument`, `VaultStore.openDocument` / `finalizeDocument`); that path is Obsidian-specific and stays that way, because the pencil lives in CodeMirror. The other path writes the final write-up for meetings without a live document (`VaultStore.writeMeeting(MeetingWriteUp)` → `VaultWriter.render` and `merge`). That second path is the seam:

```swift
public protocol NoteDestination: Sendable {
    var id: String { get }
    var displayName: String { get }                          // "Obsidian vault “Work”", "Logseq graph", "Notion"
    func write(_ writeUp: MeetingWriteUp) async throws -> NoteWriteOutcome   // created · updated · unchanged · conflicted · unavailable
    func location(forMeeting id: String) -> String?           // shown in Recent and returned as vaultPath
    func releaseManagedMarkers(meetingID: String) async throws // at the fade; WorkScribe never writes again
}
```

Obligations, all of which `VaultStore` meets today: writes are atomic; the user's edits are never overwritten (a conflicting version goes beside the note); writing is idempotent because finalization can replay after a crash; and the outcome must be honest, because **raw material is purged only after a successful write**. That last point is a real tradeoff: `MeetingRetention.finalize` throws `missingNote` when the destination is unavailable, and purge waits. A destination that can be offline (Notion, a network share) should render Markdown into WorkScribe's local Notes folder and report that path rather than fail, or the 24-hour promise quietly becomes "24 hours or until the destination is back".

### 5.4 Embedder

`Embedder` (`modelID`, `dimension`, `text`, `texts`, `audio`, `image`) already lives in Core, and `SearchIndex` already re-embeds when `modelID` changes. What changes is small: `IndexService` holds `any Embedder` instead of `CoreMLEmbedder?`, and memory release becomes an optional `ReleasableEmbedder` refinement. An `openai-compatible` embeddings provider (`base_url`, `model`, `dimension`) covers Ollama and hosted models. An embedder sends text off the Mac if its endpoint is remote, so `cloud = "forbidden"` applies to it too. `modelID` must change whenever anything that affects vectors changes, or the index silently mixes spaces.

---

## 6. Forking

### 6.1 Repository layout

```
Package.swift                         // one marked block for fork dependencies (6.4)
Sources/
  WorkScribeCore/                     upstream. Models, stores, retention, search, API shapes. Pure, tested.
    Sources/                          new: TranscriptSource, SourceEvent, Capabilities, Rules, Policy,
                                      TOML reader, Alignment, Wire (wsp/1 codec), Conformance checks
  WorkScribe/                         upstream. The app.
    Sources/                          new: SourceHost, SourceRegistry, CaptureGate, AudioTranscriber,
                                      LocalRecorderSource, FileImportSource, CommandSource, IngestSource,
                                      ReplaySource, NotesOnlySource
  WorkScribeExtensions/               yours. Upstream ships a stub and never edits this directory again.
    Register.swift
  WorkScribeNativeHost/               upstream. Browser native messaging.
Resources/
  sources.default.toml                yours if you want fork defaults (4.1). Upstream ships none.
  Brand.plist                         yours (6.5)
  licenses/                           upstream + yours
examples/sources/tail-file/           upstream. The Python reference command source.
Tests/
  SourceConformance/fixtures/         upstream fixtures; add your own beside them
  WorkScribeExtensionsTests/          yours
docs/specs/                           this spec, the wire schema, the config schema, the example config
obsidian-plugin/                      upstream
```

### 6.2 Where your code goes

**A command source** needs no fork at all: put the folder in `~/Library/Application Support/WorkScribe/Sources/<id>/` and declare it in `sources.toml`. For a team, ship the folder and a policy file with your device management. Fork only if you need to change WorkScribe itself.

**A Swift source** goes in `Sources/WorkScribeExtensions/`:

```swift
// Sources/WorkScribeExtensions/Register.swift — upstream ships this with an empty body
import WorkScribeCore

public enum ForkExtensions {
    public static func register(_ registry: inout ExtensionRegistry) {
        registry.transcriptSource(kind: "zoom-ax") { config in try ZoomCaptionsSource(config: config) }
        // registry.contextSource(kind:…), registry.textModel(id:…), registry.noteDestination(id:…), registry.embedder(id:…)
    }
}
```

`sources.toml` then refers to `kind = "zoom-ax"` with its own `[sources.<id>.config]` table, passed to your factory as `[String: ConfigValue]`. The app target calls `ForkExtensions.register` once at launch, after the built-ins, and a fork's kind may not reuse a built-in kind name.

**Fork defaults** go in `Resources/sources.default.toml`. A company fork can ship its rules and policy in the app itself; administrators can still add an organization file on top.

### 6.3 The conformance kit

```sh
.build/debug/WorkScribe --verify-source zoom-captions                  # everything that applies to its capabilities
.build/debug/WorkScribe --verify-source zoom-captions --only wire,clock
.build/debug/WorkScribe --verify-source ./my-capture.jsonl --as live-wall   # check a recorded event stream
.build/debug/WorkScribe --verify-source zoom-captions --json > report.json
```

Like `--verify-purge` and `--serve-api-for-tests`, it runs against a throwaway meeting store, conversation store, vault and index in a temporary folder. It never touches your library or vault, opens no audio device, and loads no models unless a check needs the recognizer.

Your source can't be driven by a fixture (nobody can script Zoom), so the kit works on two things: your source's *behaviour* where it can control the inputs, and your source's *output*, recorded from a real session (`--record-fixture` writes the event stream to JSONL with text you can replace by synthetic text before committing it).

| Check | What it proves | How |
| --- | --- | --- |
| `manifest` | the manifest parses and matches `hello` | launch in probe mode, compare |
| `probe` | availability answers within 3 s, with a readable reason when unavailable | launch in probe mode with sample contexts |
| `wire` | every line is valid `wsp/1`; `hello` first, `end` last, nothing after `end` | schema validation over the session |
| `ids` | IDs are stable through partial → final → revise; never reused; revises and retracts refer to known finals | event-stream analysis |
| `clock` | times are in the declared clock, `start ≤ end`, finals ordered per channel, within the meeting ± 5 min | event-stream analysis |
| `alignment` | the golden meeting lines up: each typed note's best excerpt is the expected one | replay the fixture "Offline sync — v2.4 scope" (notes typed at known seconds) through `SourceHost` and `NotePlanner`; for `media` sources, inject a +97 s offset and require recovery within ±5 s |
| `evidence` | citations survive corrections | cite segments, apply `revise` and `retract`, require every `excerptRef` and `workscribe://` link to resolve or be cleanly removed |
| `lifecycle` | `stop` → `end` within 10 s; stdin EOF → exit within 5 s; a crash is restarted and deduplicated | drive the process; kill it mid-session |
| `capabilities` | the source does only what it declares | under `audio = "forbidden"`, run a full meeting with a `CaptureGate` spy and the child tripwire; any open input fails |
| `purge` | nothing survives Done | run a meeting with the sentinel text `zebra-quartz-7731`, press Done, then require: meeting folder gone, source scratch gone, `purged` received if declared, and no file under the source's folder or declared paths containing the sentinel |
| `ux` | status messages are human | `status.message` and availability reasons are sentences under 120 characters, with no stack traces or transcript text |

The fixtures live in `Tests/SourceConformance/fixtures/` as event streams (`golden-live-wall.jsonl`, `golden-media.vtt`, `golden-notes.json` and so on), built from the same "Offline sync — v2.4 scope" meeting the design pages use. Upstream runs the kit against its own reference sources in CI, so a change that breaks the contract breaks upstream first.

### 6.4 Staying mergeable

- **Extend, don't edit.** Everything in 6.2 is additive. If you find yourself editing `AppModel.swift`, that's a missing seam; open an issue upstream before you patch it.
- **One shared file.** `Sources/WorkScribeExtensions/Register.swift` is created once by upstream and never changed again. Its only conflicts will be your own.
- **Dependencies.** `Package.swift` gets a marked block, `// fork: dependencies` / `// end fork`, that upstream keeps empty. Adding a package is a clean insertion that merges without conflicts.
- **Config instead of code.** Defaults belong in `Resources/sources.default.toml`, not in Swift literals.
- **Branding in one file.** `Resources/Brand.plist` (6.5).
- **Run the kit on every merge.** It is the contract; if upstream broke it, you'll see it before your users do.
- **Keep fork-only tests in `Tests/WorkScribeExtensionsTests/`** so upstream's test files merge cleanly.

### 6.5 Naming and branding

A fork that runs beside upstream on one Mac must not share its identity, or the two will fight over data folders, keychain items, URL links and the Obsidian plugin. Today about 25 literals in 20 files carry that identity. Migration step 9 collects them into `Brand`, read from `Resources/Brand.plist` and stamped into `Info.plist` by `scripts/build-app.sh`:

| Key | Upstream | Used for |
| --- | --- | --- |
| `name` | WorkScribe | menu, notifications, About, MCP server name |
| `bundleID` | `local.workscribe.app` | Info.plist, managed preferences domain, TCC grants |
| `urlScheme` | `workscribe` | deep links (`DeepLink.swift`) |
| `dataFolder` | `WorkScribe` | `~/Library/Application Support/<dataFolder>/`: meetings, `api.json`, sources, `sources.toml` |
| `orgFolder` | `WorkScribe` | `/Library/Application Support/<orgFolder>/` |
| `keychainService` | `local.workscribe.openai` | the cloud API key |
| `pluginID` | `workscribe` | the Obsidian plugin's id and discovery |
| `nativeHost` | per `extras/chrome-extension` | browser clip channel |

Pick a name that is yours ("Fieldbook Notes"), not "WorkScribe Pro" or "WorkScribe for Acme". Replace the app icon ("Heard, then written") and the Indigo Wash identity: they are upstream's. An About line such as "Based on WorkScribe" is welcome. Keep `wsp/1` as the protocol's name: sources are meant to work with any fork.

### 6.6 Licensing

Check this before you share a build with anyone.

- **WorkScribe is licensed under Apache-2.0** (`LICENSE`). Forks may copy, modify and redistribute it under those terms, keeping the notices.
- **Third-party notices are in `Resources/licenses/`:**
  - DigUp, MIT: ported search files say so in their headers. Keep the headers and the notice.
  - FluidUse, Apache-2.0.
  - FluidAudio model artifacts, CC-BY-4.0 for the listed files: attribution required.
  - EmbeddingGemma 2 Core ML: Apache-2.0 per its model card. The notice says to verify the upstream Gemma weight terms before distributing a build that bundles them.
  - Image understanding: Gemma 4 terms. `Sources/CTextGeneration/vendor/` has llama.cpp's MIT license and the title models' notice, which says both are Apache-2.0.
- **Gaps to close before distributing a build:**
  - NeMo-Speech.cpp and the two NVIDIA models are downloaded by `scripts/runtime-doctor.py` with pinned hashes, but there is no notice for them in `Resources/licenses/`. Check their licenses and add one.
  - The app target links the **Plaud SDK frameworks** (`WorkScribePlaud`). `experiments/plaud-macos/README.md` says the SDK binaries have a separate proprietary license and are not checked in. A fork that doesn't need Note Pro import should drop that target. One that does needs Plaud's terms for redistribution.
- **Your sources are your own.** A command source is a separate program talking a documented protocol over pipes. It needs no particular license to run with WorkScribe; check that with whoever advises you if it matters for your distribution. What it does inside a meeting platform is between you, the platform's terms and your employer.

---

## 7. Reference examples

Upstream ships three sources with the seam. Together they cover live and post-hoc timing, all three clocks, in-process and out-of-process, labels and names, and audio and no audio, without integrating any platform.

### 7.1 `local-recorder`: today's recorder as just another source

**Demonstrates** that the contract carries the hardest case without loss: two audio channels, partials, word timing, diarization labels, per-track clock offsets, resume sessions, backlog pressure and failure handling (system audio blocked → microphone only). **Built from** `AppModel.start` lines 191–243, the pump loop, `finishRecording`'s drain, and `consume`. **Checks:** the existing reliability, resume and voice tests pass unchanged; `--verify-audio` and `--verify-combined` produce the same transcripts as before; under a no-audio policy it is filtered without being constructed.

### 7.2 `file-import`: VTT and SRT after the call

**Demonstrates** the post-hoc lifecycle (waiting, a deadline, arrival after Stop, arrival after Finalize), the media clock and alignment against notes, named speakers from a file, matching a file to the right meeting, and scratch-only storage. **Lives** in Core, as pure parsing and alignment with no app dependencies, so it is fully unit-tested: WebVTT with voice spans, Zoom-style `Name:` prefixes, SRT with comma decimals, BOMs, CRLF, malformed cues, and alignment recovering injected offsets from −10 to +10 minutes.

### 7.3 `examples/sources/tail-file`: a command source in Python

**Demonstrates** `wsp/1` end to end in about 150 lines of standard-library Python: the manifest, `hello` for probe, session and purge, the wall clock, a growing line sent as `partial` and then `final` under one ID, `Name: text` speaker names, heartbeats, `stop`, and exiting when stdin closes. It tails a text file in which each line is `Speaker: what they said`, so you can drive a whole meeting from a second terminal with `echo "Priya Raman: ship it on the 4th" >> ~/captions.txt`. **It is the template** for a captions reader: replace `read_new_lines()` with whatever reads your platform, keep everything else. It is also the command source the kit and upstream CI use.

The files are in `docs/specs/examples/tail-file/` (`source.toml`, `tail_source.py`). They move to `examples/sources/tail-file/` in migration step 7.

---

## 8. Migration plan

Nine steps, each a reviewable change that leaves WorkScribe shippable. Steps 1–3 are pure refactors: a user can't tell the difference, and the tests prove it.

| Step | Change | Test |
| --- | --- | --- |
| 1 | **Canonical events.** `SourceEvent` and friends in Core. `TranscriptParser` gains `events(fromNeMo:)`. `AppModel.consume` takes `SourceEvent` instead of `[String: Any]`. IDs stay random for now. | Golden: feed `realrun-fragments.json` and the caption demo's script through old and new paths; `transcript.json` is identical apart from UUIDs. All existing tests pass. |
| 2 | **Replay source.** `ReplaySource` plays a JSONL event stream. `WORKSCRIBE_CAPTION_DEMO` becomes a replay of a fixture instead of `runCaptionDemo`. The kit's skeleton (`--verify-source`) runs `wire`, `ids` and `clock` against it. | Caption preview looks the same (screenshot diff in the QA app). Kit passes on the golden fixture and fails on deliberately broken ones. |
| 3 | **Extract the recorder.** `AudioTranscriber` from `SpeechConnection` + `AudioBacklog` + parser. `LocalRecorderSource` from the start/pump/drain code. `SourceHost` owns the active source. `RecordingPressure` comes from source status. AppModel keeps the phase machine, notifications and the 10-second "only your mic" check, now asked of the source (`keepsAudio && audio.system`). | `RecordingReliabilityTests`, `ResumeCaptureTests`, `VoiceLifecycleTests`, `--verify-audio`, `--verify-combined`, `--verify-warm`. A real 30-minute call, comparing turn count and timings with a pre-refactor build on the same audio. |
| 4 | **Capture gate and policy (read-only).** `CaptureGate` in front of every capture API; the API-usage lint test; policy layers parsed and shown in Settings, enforced by the gate; child tripwire. No rules yet: the chain is still always the recorder. | Under `audio = "forbidden"`: a full meeting runs, the gate spy counts zero opens, no microphone prompt appears (manual check on a fresh user account), and the meeting is notes-only. Lint test fails on a planted `AVAudioEngine()` elsewhere. |
| 5 | **Rules and selection.** TOML reader, `SourceSelector` (pure), `Meeting.transcriptSource`, status `transcript`, SSE `source`, Settings › Sources, the plugin pill using `transcript.short`. `notes-only` as a real source. | Table tests over contexts × layers × policy, including unknown conditions and `if_unknown`. TOML reader tests with line-numbered errors. Plugin tests for the pill text. |
| 6 | **Deterministic IDs, speaker names, file import.** UUIDv5 segment IDs for new sessions; `speakerNames`; chunk-ref fallback to segment; `FileImportSource` with VTT/SRT parsing, matching and alignment; transcript waiting state; `POST /v1/meetings/:id/transcript`; the plugin's **Attach transcript file…** command. | Parser fixtures; alignment recovering injected offsets; evidence surviving `revise`; a late transcript after Finalize leaves the note byte-identical; purge removes the imported copy and leaves the original file. |
| 7 | **Command sources.** Manifest loading, the `wsp/1` codec and schema, the supervisor (timeouts, restarts, dedupe, flooding, stderr ring), purge mode, `tail-file` moved to `examples/`. | Protocol tests driving `tail_source.py`; kill it mid-session and check dedupe; close stdin and check exit; malformed lines; a source declaring no audio that opens the mic is killed (a test helper that opens input). |
| 8 | **Ingest.** The three endpoints; leases; 403/404/409/410 cases; the NDJSON body parser. | `LocalAPITests` additions; `--serve-api-for-tests` with the plugin's test suite; a policy that forbids the declared source returns 403 with the reason. |
| 9 | **The rest of the seams and the fork kit.** `TextModel` across notes, titles and answers; `ContextSource` with `ScreenRecorder` behind it; `NoteDestination`; `any Embedder` in `IndexService`; Plaud import as `plaud-import`; `Brand`; `WorkScribeExtensions` with its stub; the `Package.swift` fork block; the org kit (sample policy and PPPC profile). | Each seam's existing verification (`--verify-notes`, `--verify-title`, `--verify-screen`, `--verify-embedding`, `--verify-import`) still passes; a scratch fork with a different `Brand.plist` runs beside upstream on one Mac without sharing data, keychain or links. |

What not to do: don't land step 4 after step 5. Rules that can choose a source must never exist before the gate that makes a wrong choice harmless.

---

## 9. Decisions for you

1. **A license.** Without one, forks can't legally be shared. MIT or Apache-2.0 suit the goal of this spec; Apache-2.0 adds an explicit patent grant. A source-available license would allow reading but not forking.
2. **TOML with a small built-in reader, or a TOML package.** Recommended: the built-in reader (~250 lines, strict, good errors), to keep two dependencies. A package is less code to own.
3. **Mid-meeting failover never escalates to more capture** (2.7). Recommended as written: "Record instead" is a button, never automatic. The cost is a transcript gap when captions die and nobody presses it.
4. **Policy fails closed on unknown conditions** (4.4). Recommended as written for organization policy. It means a calendar-scoped policy without a calendar provider forbids recording for every meeting, which is safe and will surprise someone.
5. **A late post-hoc transcript after Finalize** is kept for search until the fade but never changes the note (2.3). The alternative, reopening the note, breaks "Finalize is the moment you strike what you don't want".
6. **Note destinations and the 24-hour promise** (5.3). Today raw material waits for a successful note write. Recommended: destinations must fall back to the local Notes folder so the fade always happens on time.
7. **Calendar access.** Calendar conditions are only useful once an EventKit provider exists, which `design/care` already lists as a decision (ask at the first meeting). This spec assumes it will exist and works without it.
8. **The Plaud SDK in the main app target.** Recommended: make `WorkScribePlaud` an optional build product so a fork, or a public upstream build, can ship without proprietary frameworks.
