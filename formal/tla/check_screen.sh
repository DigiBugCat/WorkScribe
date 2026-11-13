#!/bin/bash
# Runs every ScreenWatch configuration: the ones that must pass, the mutations that must each break
# their property, and the reachability checks that must each be "violated".
# Exit 0 only when every run ends as expected.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; cd "$here" || exit 2
java="${JAVA:-/opt/homebrew/opt/openjdk/bin/java}"
jar="${TLA_JAR:-$HOME/Library/Caches/WorkScribe/formal/tla2tools.jar}"
work="$(mktemp -d "${TMPDIR:-/tmp}/workscribe-tlc.XXXXXX")"; trap 'rm -rf "$work"' EXIT
bad=0

run() {
    "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -deadlock -noGenerateSpecTE \
        -metadir "$work/meta-$RANDOM" -config "$1" ScreenWatch.tla > "$work/out.log" 2>&1
}
cfg() { # cfg <moves> <controls> <losses> <mutation> <INVARIANTS...|PROPERTIES...> -> path
    local file="$work/case.cfg"
    { echo "SPECIFICATION Spec"; echo "CONSTANTS"; echo "    Apps = {mail, browser, vault}"; echo "    Denied = {vault}"
      echo "    Moves = $1"; echo "    Controls = $2"; echo "    Losses = $3"; echo "    Mutation = \"$4\""; shift 4; printf '%s\n' "$@"; } > "$file"
    echo "$file"
}
expect_pass() {
    if run "$2" && grep -q "No error has been found" "$work/out.log"; then
        echo "pass      $1  ($(grep -o '[0-9]* distinct states found' "$work/out.log" | tail -1))"
    else echo "UNEXPECTED FAILURE  $1"; grep -E "Error:|violated" "$work/out.log" | head -5; bad=1; fi
}
expect_violation() {
    if run "$3"; then echo "UNEXPECTED PASS  $1 (expected $2 to be violated)"; bad=1
    elif grep -q -E "(Invariant $2 is violated|Temporal property $2 was violated|Temporal properties were violated)" "$work/out.log"; then echo "violated  $1  ($2, as expected)"
    else echo "WRONG FAILURE  $1"; grep -E "Error:|violated" "$work/out.log" | head -5; bad=1; fi
}

SAFETY="INVARIANTS NothingFromDeniedApps NothingFromPrivateWindows NothingReadWhileShut OneLiveRead ShutMeansNotWaiting"
echo "== must hold"
# A larger run (4 moves, 3 controls: 109,592,023 states for an earlier version of this module) takes
# several minutes; set DEEP=1 to repeat it.
expect_pass "safety, 3 moves, 3 controls, 1 lost read" "$(cfg 3 3 1 none $SAFETY)"
if [ "${DEEP:-0}" = "1" ]; then expect_pass "safety, 4 moves, 3 controls, 1 lost read" "$(cfg 4 3 1 none $SAFETY)"; fi
expect_pass "liveness, 2 moves, 2 controls, 1 lost read" "$(cfg 2 2 1 none PROPERTIES EventuallyRead)"

echo "== each removed rule must break its property"
expect_violation "wholeScreen" NothingFromDeniedApps "$(cfg 2 1 0 wholeScreen INVARIANTS NothingFromDeniedApps)"
expect_violation "trustTheTitle" NothingFromPrivateWindows "$(cfg 2 1 0 trustTheTitle INVARIANTS NothingFromPrivateWindows)"
expect_violation "keepAcrossPause" NothingReadWhileShut "$(cfg 1 3 0 keepAcrossPause INVARIANTS NothingReadWhileShut)"
expect_violation "manyReads" OneLiveRead "$(cfg 1 1 0 manyReads INVARIANTS OneLiveRead)"
expect_violation "noTimeout" EventuallyRead "$(cfg 1 1 1 noTimeout PROPERTIES EventuallyRead)"

echo "== the interesting states are reachable (each 'never' must be violated)"
for never in NeverKept NeverDropsAStaleRead NeverFindsAPrivateWindowByReading; do
    expect_violation "$never" "$never" "$(cfg 2 2 0 none INVARIANTS $never)"
done
exit $bad
