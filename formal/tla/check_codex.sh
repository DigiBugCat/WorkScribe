#!/bin/bash
# Runs every CodexSession configuration: the three that must pass, the mutations that must each
# break their property, and the reachability checks that must each be "violated".
# Exit 0 only when every run ends as expected.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; cd "$here" || exit 2
java="${JAVA:-/opt/homebrew/opt/openjdk/bin/java}"
jar="${TLA_JAR:-$HOME/Library/Caches/WorkScribe/formal/tla2tools.jar}"
work="$(mktemp -d "${TMPDIR:-/tmp}/workscribe-tlc.XXXXXX")"; trap 'rm -rf "$work"' EXIT
bad=0

run() { # run <cfg-file> -> writes $work/out.log, returns TLC's status
    "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -deadlock -noGenerateSpecTE \
        -metadir "$work/meta-$RANDOM" -config "$1" CodexSession.tla > "$work/out.log" 2>&1
}
cfg() { # cfg <gens> <spawns> <checkMayFail> <mutation> <INVARIANTS...|PROPERTIES...> -> path
    local file="$work/case.cfg"
    { echo "SPECIFICATION Spec"; echo "CONSTANTS"; echo "    Gens = $1"; echo "    MaxSpawns = $2"; echo "    MaxDeltas = 1"
      echo "    ServerMayUseTools = TRUE"; echo "    CheckMayFail = $3"; echo "    Mutation = \"$4\""; shift 4; printf '%s\n' "$@"; } > "$file"
    echo "$file"
}
expect_pass() { # label cfg
    if run "$2" && grep -q "No error has been found" "$work/out.log"; then
        echo "pass      $1  ($(grep -o '[0-9]* distinct states found' "$work/out.log" | tail -1))"
    else echo "UNEXPECTED FAILURE  $1"; grep -E "Error:|violated" "$work/out.log" | head -5; bad=1; fi
}
expect_violation() { # label property cfg
    if run "$3"; then echo "UNEXPECTED PASS  $1 (expected $2 to be violated)"; bad=1
    elif grep -q -E "(Invariant $2 is violated|Temporal property $2 was violated|Temporal properties were violated)" "$work/out.log"; then echo "violated  $1  ($2, as expected)"
    else echo "WRONG FAILURE  $1"; grep -E "Error:|violated" "$work/out.log" | head -5; bad=1; fi
}

SAFETY="INVARIANTS TypeOK ExactlyOnce NoTextFromToolTurn NoOrphanWhenDown NoStaleRoute PromptOnlyWhenVerified UnsafeIsQuiet TextHasASource"
echo "== must hold"
expect_pass "safety, 2 callers, 2 process starts" "$(cfg '{g1, g2}' 2 TRUE none $SAFETY)"
expect_pass "liveness, 1 caller, 2 process starts" "$(cfg '{g1}' 2 TRUE none INVARIANTS ExactlyOnce PROPERTIES EveryRequestEnds)"
expect_pass "liveness, 2 callers, 1 process start" "$(cfg '{g1, g2}' 1 FALSE none INVARIANTS ExactlyOnce PROPERTIES EveryRequestEnds)"

echo "== each removed guard must break its property"
expect_violation "keepRoute" ExactlyOnce "$(cfg '{g1, g2}' 1 FALSE keepRoute INVARIANTS ExactlyOnce)"
expect_violation "trustAbandoned" ExactlyOnce "$(cfg '{g1, g2}' 1 FALSE trustAbandoned INVARIANTS ExactlyOnce)"
expect_violation "toolIgnored" NoTextFromToolTurn "$(cfg '{g1, g2}' 1 FALSE toolIgnored INVARIANTS NoTextFromToolTurn)"
expect_violation "eofSilent" NoOrphanWhenDown "$(cfg '{g1, g2}' 1 FALSE eofSilent INVARIANTS NoOrphanWhenDown)"
expect_violation "noTimeout" EveryRequestEnds "$(cfg '{g1}' 1 FALSE noTimeout PROPERTIES EveryRequestEnds)"
expect_violation "ignoreCheck" PromptOnlyWhenVerified "$(cfg '{g1, g2}' 1 TRUE ignoreCheck INVARIANTS PromptOnlyWhenVerified)"

echo "== the interesting states are reachable (each 'never' must be violated)"
for never in NeverText NeverUnsafe NeverAbandonedMidStart NeverLateMessage; do
    expect_violation "$never" "$never" "$(cfg '{g1, g2}' 1 TRUE none INVARIANTS $never)"
done
exit $bad
