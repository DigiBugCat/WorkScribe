#!/bin/bash
# Runs every formal check and the tests that hold them against the real code.
# Exits non-zero if any part fails. See formal/README.md for what each part does and does not establish.
set -u
cd "$(dirname "$0")/.." || exit 2
failed=()
step() { # step <name> <command...>
    printf '\n=== %s\n' "$1"; shift
    "$@" || failed+=("$*")
}
jar="${TLA_JAR:-$HOME/Library/Caches/WorkScribe/formal/tla2tools.jar}"
if [ ! -f "$jar" ]; then
    echo "TLC is missing. Fetch it once:"
    echo "  mkdir -p \"$(dirname "$jar")\" && curl -fsSL -o \"$jar\" https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar"
    exit 2
fi
step "TLA+: Codex session" bash formal/tla/check_codex.sh
step "TLA+: screen watch" bash formal/tla/check_screen.sh
step "TLA+: recording, retention, note scheduler, index purge, vault note, plugin note" bash formal/tla/run.sh
step "Lean: line, auto-record, backlog, small policies" bash -c 'cd formal/lean && lake build --wfail'
step "Swift: the models and proofs against the real code" \
    swift test --filter 'CodexSessionTests|CodexAppServerTests|ScreenWatchTests|ScreenDayTests|ScreenWatcherTests|FormalConformanceTests|RecordingRaceTests|RetentionRaceTests|IndexPurgeTests|VaultStoreTests|LateResultsTests'
printf '\n'
if [ ${#failed[@]} -eq 0 ]; then echo "All formal checks passed."; else printf 'FAILED: %s\n' "${failed[@]}"; exit 1; fi
