#!/bin/bash
# run.sh BINARY RUN_DIR SCENARIO.txt [VAR=VALUE...]: one scenario (scenarios.sh) run offscreen
# with the frame profiler on (STELLAR_PROF=1 unless given), its replies in RUN_DIR/out.txt, the
# log in err.txt, each measurement's spans in RUN_DIR/NAME.prof; then the table (summary.py).
#   bash sim/render/tools/profile/run.sh $T/release/stellar-render /root/prof/runs/base /root/prof/scen/map.txt
# Run from anywhere; the renderer runs in this worktree's sim/render (its Lua). Set STELLARIS_DIR
# for another install than /opt/stellaris.
set -u
B=${1:?BINARY}; O=${2:?RUN_DIR}; S=${3:?SCENARIO}
shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$O" && rm -f -- "${O:?}"/*.prof "${O:?}"/out.txt "${O:?}"/err.txt
sed "s|{OUT}|$O|g" "$S" > "$O/script.txt"
cd "$HERE/../.." || exit 1
env STELLAR_PROF=1 "$@" "$B" --game "${STELLARIS_DIR:-/opt/stellaris}" --script "$O/script.txt" > "$O/out.txt" 2> "$O/err.txt"
echo "exit $? ($O)"
python3 "$HERE/summary.py" "$O"
