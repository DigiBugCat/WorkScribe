# Public build verification

Date: 2026-10-15. Implementation verified at `86d8e2764f45dada95e04e497e6e73f3a5985500` (later documentation-only changes do not affect the products). Tested on an arm64 Mac, macOS 26.5.1 (25F80), Xcode 26.6
(17F113), Apple Swift 6.3.3, Python 3.14.7, Node 26.3.1, npm 11.16.0.

## Isolation and source

The test root was `/tmp/workscribe-public-verification`. No existing WorkScribe
runtime, Plaud frameworks, meeting library or Obsidian vault was used. The first
setup pass began with empty runtime/cache/home directories. During implementation,
completed downloads were retained there; the committed branch was then cloned
again into `fresh-final` and fast-forwarded as fixes landed. No source edits were
made in that verification clone. Only this task's downloaded assets and caches
were reused between passes.

Commands below use `SOURCE` for the original `public` worktree and `CHECK` for
that isolated test root. The original worktree's absolute machine-specific path
is intentionally not embedded in these instructions.

```sh
SOURCE="$PWD"                         # run from the public worktree
CHECK=/tmp/workscribe-public-verification
mkdir -p "$CHECK/home" "$CHECK/cache"
git clone --branch public "$SOURCE" "$CHECK/fresh-final"
cd "$CHECK/fresh-final"

export HOME="$CHECK/home"
export CFFIXED_USER_HOME="$HOME"
export WORKSCRIBE_RUNTIME_HOME="$CHECK/runtime"
export WORKSCRIBE_RUNTIME_CACHE="$CHECK/cache/runtime"
export WORKSCRIBE_MIGRATE_LEGACY=0
export WORKSCRIBE_PLAUD=0
export WORKSCRIBE_PLAUD_FRAMEWORKS="$CHECK/no-plaud-frameworks"
export WORKSCRIBE_SIGN_IDENTITY=-
export WORKSCRIBE_DISABLE_AUTORECORD=1
export WORKSCRIBE_DATA_DIR="$HOME/Meetings"
export WORKSCRIBE_NOTES_DIR="$HOME/Notes"
export WORKSCRIBE_INDEX_DIR="$HOME/Index"
export WORKSCRIBE_CONVERSATIONS_DIR="$HOME/Conversations"
export WORKSCRIBE_API_DIR="$HOME/API"
export WORKSCRIBE_VAULT_STATE_DIR="$HOME/Vault"
export WORKSCRIBE_CLIP_SOCKET="$HOME/clip.sock"
export XDG_CACHE_HOME="$CHECK/cache"
export CLANG_MODULE_CACHE_PATH="$XDG_CACHE_HOME/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$XDG_CACHE_HOME/swift-modules"
export npm_config_cache="$XDG_CACHE_HOME/npm"
export PYTHONDONTWRITEBYTECODE=1
```

`WORKSCRIBE_MIGRATE_LEGACY=0` disables opportunistic legacy/cache migration.
`CFFIXED_USER_HOME` redirects Foundation's user home, in addition to the explicit
application storage overrides. WorkScribe has no cloud features, so nothing reads the
Keychain; signing uses an ad-hoc identity. Xcode, the OS SDK, system frameworks and
installed command-line prerequisites are still the host's normal tools.

## Commands and results

The runner forbids SwiftPM's nested sandbox: plain `swift build` failed at
manifest evaluation with `sandbox-exec: sandbox_apply: Operation not permitted`.
The documented runner-only override was therefore used:

```sh
export WORKSCRIBE_SWIFT_DISABLE_SANDBOX=1
scripts/bootstrap.sh
swift build --disable-sandbox
scripts/build-app.sh
swift test --disable-sandbox
.build/debug/WorkScribe --doctor --check
.build/debug/WorkScribe --verify-api
.build/debug/WorkScribe --verify-purge
python3 -m unittest discover -s scripts/tests
(cd obsidian-plugin && npm ci && npm test && npm run build && npm run smoke)
```

This verifies the normal build products while disabling only SwiftPM's own
nested sandbox. It does **not** prove that this restricted runner can execute
plain `swift build` or `swift test`; normal Terminal users should start with the
README's unmodified commands.

| Check | Result |
| --- | --- |
| Empty-home runtime download | PASS — 10,372,649,025 pinned runtime/model bytes; all hashes verified, all three Core ML encoders compiled; CMake 3.31.6 installed privately because no system CMake was available. |
| Bootstrap from committed clone | PASS — runtime, image helper and npm dependencies ready. |
| Idempotent bootstrap repeat | PASS — existing models verified, all three encoders reported already prepared, no model download repeated. |
| Debug Swift build | PASS — no proprietary frameworks available. |
| Release app build / ad-hoc signature | PASS — `dist/WorkScribe.app`; `codesign --verify --deep --strict` passed. |
| Swift tests | PASS — 203 tests, zero failures. |
| Runtime doctor check | PASS — required runtime, models, compiled graphs and local receipts verified; alternate Gemma title model also present. |
| API verification | PASS — 401 without token, 403 for foreign Host, valid status and empty meeting list. |
| Purge verification | PASS — final note retained; raw folder, index and vectors removed; repeat cleanup idempotent. |
| Python runtime tests | PASS — 16 tests, including partial download continuation, ignored Range responses, complete-partial recovery and failed-compile preservation. |
| npm ci / test / build / smoke | PASS — 25 packages installed; 89 tests passed and 2 opt-in tests skipped; TypeScript/build and bundle/mock smoke passed. |

Additional checks:

```sh
(cd obsidian-plugin && WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test)
(cd obsidian-plugin && bash scripts/install.sh "$CHECK/plugin-vault")
codesign --verify --deep --strict dist/WorkScribe.app
dist/WorkScribe.app/Contents/MacOS/WorkScribe --verify-api
dist/WorkScribe.app/Contents/MacOS/WorkScribe --verify-purge
```

All passed. The real-API plugin run passed **91/91**, with no skips. Plugin
installation into a disposable vault copied the built plugin and third-party
notices. Both verification commands also passed from the **signed release
bundle**, not just the debug executable. Compilation emits existing deprecation
and isolation warnings; they are not build failures. npm reported a deferred
esbuild postinstall script, but its pinned native package built and ran normally.

The download inventory is checked against the installer's URLs/hashes by the
Python suite. SHA-256 checks cover all model source files; the native archive
is checksum-pinned, and generated native/Core ML outputs have local receipts.
The no-system-CMake path installed its hash-pinned universal macOS wheel in the
isolated cache. SwiftPM and npm caches were created under the isolated home/cache.

## Native execution and GUI limit

```sh
curl -fL https://raw.githubusercontent.com/NVIDIA/NeMo-Speech.cpp/v0.2.0/test_files/asr/wav/test/jfk.wav -o "$CHECK/jfk.wav"
WORKSCRIBE_SPEECH_CPU=1 .build/debug/WorkScribe --verify-audio "$CHECK/jfk.wav"
WORKSCRIBE_TEXT_CPU=1 .build/debug/WorkScribe --verify-notes "$CHECK/note-fixture.json"
```

The upstream JFK fixture has SHA-256
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
Native ASR/diarization produced nonempty final transcript events on CPU. The
synthetic two-note fixture (Friday release / monthly hosting budget) produced
two enhanced notes with the expected source IDs. This is an inference/wiring
check, not a factual-accuracy benchmark; generated wording still needs review.
An initial `say` fixture contained zero PCM samples in this runner and was
replaced by the upstream WAV for the actual speech check.

The unmodified Metal note-inference attempt failed with `failed to create
command queue` / `Could not create the text-generation context`. CPU switches
were used only for these additional inference checks; they were not needed for
the prescribed build, unit, API or purge checks. Metal execution is **unverified**.

A disposable copy of the app used a unique bundle identifier, isolated storage,
cloud disabled and automatic recording disabled for startup testing. Direct
GUI startup aborted before publishing an API. Launching via `open -n -g` then
failed with `kLSNoExecutableErr` (-10827), despite the executable being present,
executable and signature-valid. A separately compiled/signed minimal AppKit
app was rejected by Launch Services with the same error. This supports a runner
launch restriction; it does not establish that WorkScribe's GUI startup passed.
**A normal Terminal/Finder first launch, privacy prompts and live capture still
need an external check.** No existing WorkScribe app, vault or preferences were
used for that attempted GUI test.

Full command logs and the disposable fixtures remain under the test root.

## Plaud boundary

The default `swift package --disable-sandbox dump-package` contains neither
`COpus`, `WorkScribePlaud` nor `WorkScribePlaudTests`. Setting
`WORKSCRIBE_PLAUD=1` restores all three targets in the manifest. The default
build/test runs use a nonexistent frameworks directory. A dedicated `WORKSCRIBE_PLAUD` Swift define ensures stale module caches cannot enable the feature. The signed bundle has no Plaud framework, no Bluetooth usage-description key and no “Save & release Note Pro” menu string. The optional hardware
integration was not built or exercised: it requires separately authorized SDK
frameworks and a device.

## Tree and attribution audit

No project LICENSE was added. The README retains an explicit owner TODO.
`Resources/licenses/` now includes the actual native archive's notices, NVIDIA's
OpenMDW-1.1 model terms/cards, Apache model attribution, FluidAudio's transitive
notices, the native text-processing engine's notices, npm package licenses and
the pinned build tool's license. The exact legacy WeSpeaker conversion has an
unresolved provenance gap, documented separately; the modern Community-1 notice
must not be represented as covering it. No inspected public model/runtime terms
explicitly prohibit redistribution. The proprietary Plaud SDK is not shipped.

The removed binary-inspection research document has no remaining links. Its
literal prompt fields were replaced with a WorkScribe JSON input record, and
associated design wording was rewritten. Ordinary concepts such as evidence
citations, Markdown bullets and user-owned notes remain WorkScribe behavior.

No references to the excluded third-party product remain in the tree; two public landscape references in the EmbeddingGemma research notes were removed before publishing.

These entries contain public product descriptions, no binary-inspection findings
and no claim that WorkScribe is derived from that product. There are no remaining
mentions in `design/` or application code.

Owner-specific absolute paths and signing-team identifiers were removed. Remaining
`/example/...` paths are deliberately fictional link-format fixtures; `/tmp` versus
`/private/tmp` tests exercise macOS path canonicalization. They are not required
files on a developer's machine. `docs/specs/making-your-own.md` does not exist in
this tree, so the README does not link to it.

## Boundaries

Live meeting capture, physical Plaud transfer, actual Obsidian UI interaction,
privacy permission grants, Intel Macs and older OS/toolchains are outside this test. The plugin smoke test
uses a mock server and inert DOM; it is not a visual test.

The runner also makes this worktree's Git metadata read-only. Commits were created
using a temporary index and Git's commit-tree/update-ref plumbing against the
allowed shared repository metadata, updating only `refs/heads/public`. Nothing
was pushed and no other worktree was changed. The original worktree's ordinary
index could not be refreshed; in a normal Terminal, `git reset --mixed HEAD`
refreshes it without altering working files. The committed verification clone
uses a normal, clean index.
