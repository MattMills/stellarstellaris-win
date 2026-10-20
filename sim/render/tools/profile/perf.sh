#!/bin/bash
# perf.sh BINARY RUN_DIR SETUP.txt "BENCH ..." [SECONDS]: `perf record` of the renderer during one
# measurement, not its load or its exit (docs/profiling.md). The renderer serves the command
# protocol (--listen, PERF_PORT 7931); SETUP's commands go first (ctl.py --file: the load, a window
# opened), then the measurement's command (a `bench`, e.g. "bench 12 hover 100 150 1000 600"), and
# perf samples the process for SECONDS (8) from a second into it. The reports: the CPU by thread
# (the commands' thread is named as the binary, the window's `ui`; llvmpipe's rasterising is its
# `llvmpipe-N` threads, the simulation `simulation`), the hottest functions of the commands'
# thread with and without their callees. perf sees the CPU only: a thread waiting (a blocking
# query to the simulation, the GPU's frame) shows as nothing; the frame profiler's spans see it.
#   PERF_FREQ (499) samples a second; PERF_CALLGRAPH (dwarf,8192; fp is cheaper and blind in
#   Rust's release code, which keeps no frame pointers)
set -u
B=${1:?BINARY}; O=${2:?RUN_DIR}; S=${3:?SETUP}; M=${4:?MEASUREMENT}; SECS=${5:-8}
HERE=$(cd "$(dirname "$0")" && pwd)
PORT=${PERF_PORT:-7931}
CTL="python3 $HERE/../ctl.py --addr 127.0.0.1:$PORT"
mkdir -p "$O" && rm -f -- "${O:?}"/perf.data "${O:?}"/*.txt
cd "$HERE/../.." || exit 1
STELLAR_PROF=1 "$B" --game "${STELLARIS_DIR:-/opt/stellaris}" --listen "$PORT" > "$O/out.txt" 2> "$O/err.txt" &
RP=$!
for _ in $(seq 120); do grep -q "listening on" "$O/err.txt" && break; sleep 0.5; done
$CTL --file "$S" > "$O/setup.txt" || { echo "setup failed: $(tail -1 "$O/setup.txt")"; kill $RP; exit 1; }
$CTL "$M" > "$O/measurement.txt" &
CP=$!
sleep 1
perf record -F "${PERF_FREQ:-499}" --call-graph "${PERF_CALLGRAPH:-dwarf,8192}" -p $RP -o "$O/perf.data" -- sleep "$SECS" 2> "$O/perf.err"
wait $CP
$CTL quit > /dev/null
wait $RP 2> /dev/null
T=$(basename "$B" | cut -c1-15)
perf report -i "$O/perf.data" --no-children --sort comm --stdio 2> /dev/null | grep -v '^#' | grep -v '^$' | head -40 > "$O/threads.txt"
perf report -i "$O/perf.data" --comm "$T" --percentage relative --no-children --sort dso,sym --stdio -g none 2> /dev/null | grep -v '^#' | grep -v '^$' | head -60 > "$O/main_self.txt"
perf report -i "$O/perf.data" --comm "$T" --percentage relative --children --sort sym --stdio -g none 2> /dev/null | grep -v '^#' | grep -v '^$' | head -80 > "$O/main_children.txt"
cut -c1-300 "$O/measurement.txt"
echo "== threads"; head -12 "$O/threads.txt"
echo "== the commands' thread, self"; head -25 "$O/main_self.txt"
