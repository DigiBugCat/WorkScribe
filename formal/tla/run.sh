#!/bin/bash
# Runs every TLC configuration of Recording.tla, Retention.tla, NoteScheduler.tla, IndexPurge.tla,
# VaultNote.tla and PluginNote.tla and compares the result with what the file name says.  (CodexSession and
# ScreenWatch have their own scripts.)
#
#   <Spec>_<code>_<scenario>__holds.cfg               every property listed in the cfg must hold
#   <Spec>_<code>_<scenario>__violates_<Property>.cfg  TLC must report a violation of exactly <Property>
#
# <code> says which code the configuration describes:
#   edcaebae   the code at git edcaebae, as it was first modelled
#   candidate  edcaebae plus the fix sketches its findings were first checked against (not the code)
#   previous   the working tree with the first round of fixes only, before the two later rounds
#   current    the working tree on top of edcaebae: the fixes as they were actually written
#   found      (the three later specs) the code before the round that modelled it
#   fixed      (the three later specs) the working tree
#
# Exit status is 0 only when every configuration behaves as its name says: non-zero if a property
# expected to hold is violated, if a recorded violation no longer occurs, or if TLC fails to run
# (the model or the code it mirrors changed: re-read the README before "fixing" this).
#
#   ./run.sh                    run everything, one configuration at a time
#   JOBS=4 ./run.sh             ... four at a time (same results, same order of output)
#   ./run.sh Retention          run the configurations whose name starts with "Retention"
#   ./run.sh Recording_current  ... or with any other prefix
#   ./run.sh -l                 list configurations without running them
#
# Counterexamples are written to traces/<cfg>.txt.  TLC's state files go to a scratch directory
# outside the repository and are deleted afterwards.
set -u
cd "$(dirname "$0")"
# The script calls itself once per configuration; by then the directory has changed, so a relative $0
# (as in `bash formal/tla/run.sh` from the repository root) would no longer name it.
SELF="$PWD/$(basename "$0")"

JAVA="${JAVA:-/opt/homebrew/opt/openjdk/bin/java}"
TLA_JAR="${TLA_JAR:-$HOME/Library/Caches/WorkScribe/formal/tla2tools.jar}"
TLA_SHA="e1f11b75c4b5bc4478ba0ac5cb6ae28e40a01b0016bc33e0aa97da22dfdbcd7f"   # TLA+ tools 1.8.0
JOBS="${JOBS:-1}"
SPECS="Recording Retention NoteScheduler IndexPurge VaultNote PluginNote"

# --one <scratch> <cfg>: run a single configuration; leave its result line and verdict in <scratch>.
if [ "${1:-}" = "--one" ]; then
    SCRATCH="$2"; cfg="$3"
    name="$(basename "$cfg" .cfg)"
    spec="${name%%_*}"
    expect="${name##*__}"
    # One worker for expected violations: breadth-first search then returns a shortest trace, the same every run.
    if [ "$expect" != "holds" ]; then workers=1
    elif [ "$JOBS" -gt 1 ]; then workers=$(( $(sysctl -n hw.ncpu 2>/dev/null || echo 4) / JOBS )); [ "$workers" -lt 1 ] && workers=1
    else workers=auto; fi
    out="$SCRATCH/$name.out"
    start=$(date +%s)
    "$JAVA" -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers "$workers" -noGenerateSpecTE \
        -metadir "$SCRATCH/states/$name" -config "$cfg" "$spec.tla" > "$out" 2>&1
    secs=$(( $(date +%s) - start ))
    rm -rf "$SCRATCH/states/$name"
    states="$(sed -n 's/.* \([0-9][0-9]*\) distinct states found.*/\1/p' "$out" | tail -1)"
    depth="$(sed -n 's/^The depth of the complete state graph search is \([0-9]*\)\..*/\1/p' "$out" | tail -1)"
    violated="$(sed -n -e 's/^Error: Invariant \([A-Za-z0-9_]*\) is violated.*/\1/p' \
                       -e 's/^Error: Action property \([A-Za-z0-9_]*\) is violated.*/\1/p' \
                       -e 's/^Error: Temporal property \([A-Za-z0-9_]*\) was violated.*/\1/p' \
                       -e 's/^Error: Temporal properties were violated.*/SOME_TEMPORAL_PROPERTY/p' "$out" | head -1)"
    if grep -q "Model checking completed. No error has been found" "$out"; then got="holds"
    elif [ -n "$violated" ]; then got="violates_$violated"
    else got="ERROR"; fi

    if [ "$got" = "$expect" ]; then
        if [ "$expect" = "holds" ]; then verdict="holds"; else verdict="violated"; fi
    else
        verdict="MISMATCH"
    fi
    trace="-"
    rm -f "traces/$name.txt"
    if [ "$got" != "holds" ]; then
        # Keep the counterexample (or the error) next to the specs.
        sed -n '/^Error: /,$p' "$out" > "traces/$name.txt"
        trace="$(grep -c '^State [0-9]*:' "$out")"         # states in the counterexample
    fi
    # depth = how deep TLC's search went (the whole graph when it holds; up to the violation otherwise).
    {
        printf '%-108s %-9s %10s %6s %6s %7s\n' "$name" "$verdict" "${states:-?}" "${depth:--}" "$trace" "$secs"
        if [ "$verdict" = "MISMATCH" ]; then
            echo "    expected: $expect    got: $got    (output: traces/$name.txt)"
            [ "$got" = "holds" ] && echo "    a recorded violation no longer occurs"
            [ "$got" = "ERROR" ] && sed -n '1,40p' "$out" | sed 's/^/    | /'
        fi
    } > "$SCRATCH/$name.line"
    [ "$verdict" = "MISMATCH" ] && : > "$SCRATCH/$name.failed"
    [ "$JOBS" -eq 1 ] && cat "$SCRATCH/$name.line"
    rm -f "$out"
    exit 0
fi

list() { for s in $SPECS; do ls -1 ./"$s"_*.cfg 2>/dev/null | sed 's|^\./||'; done; }
if [ "${1:-}" = "-l" ]; then list; exit 0; fi
[ -x "$JAVA" ] || { echo "No Java at $JAVA (set JAVA=...)"; exit 2; }
[ -f "$TLA_JAR" ] || { echo "No tla2tools.jar at $TLA_JAR (set TLA_JAR=...)"; exit 2; }
if [ "$(shasum -a 256 "$TLA_JAR" | cut -d' ' -f1)" != "$TLA_SHA" ]; then
    echo "warning: $TLA_JAR is not the TLA+ tools 1.8.0 build these results were recorded with" >&2
fi

FILTER="${1:-}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/workscribe-tlc.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p traces

matching() { while read -r cfg; do case "$cfg" in ("$FILTER"*) echo "$cfg" ;; esac; done; }
cfgs="$(list | matching)"
total="$(printf '%s\n' "$cfgs" | grep -c .)"
if [ "$total" -eq 0 ]; then echo "no configuration matches '$FILTER'"; exit 2; fi

printf '%-108s %-9s %10s %6s %6s %7s\n' "configuration" "result" "states" "depth" "trace" "seconds"
export JAVA TLA_JAR JOBS
printf '%s\n' "$cfgs" | xargs -P "$JOBS" -n 1 bash "$SELF" --one "$SCRATCH"
# With several jobs the lines are printed here, in the order of the list.
if [ "$JOBS" -gt 1 ]; then
    printf '%s\n' "$cfgs" | while read -r cfg; do cat "$SCRATCH/$(basename "$cfg" .cfg).line" 2>/dev/null; done
fi
ran="$(ls "$SCRATCH"/*.line 2>/dev/null | grep -c .)"
fail="$(ls "$SCRATCH"/*.failed 2>/dev/null | grep -c .)"

echo
if [ "$ran" -ne "$total" ]; then echo "only $ran of $total configurations produced a result"; exit 1; fi
if [ "$fail" -eq 0 ]; then echo "all $total configurations behaved as recorded"; exit 0; fi
echo "$fail of $total configurations did not behave as recorded"; exit 1
