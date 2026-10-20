#!/bin/bash
# window.sh BINARY RUN_DIR [DISPLAY_NUMBER]: the real window under Xvfb (1280x720, its own display:
# 83 by default), the save as a running simulation (--map --sim, the 2210.01.01 autosave unless
# STELLAR_SAVE), driven by xdotool: the map hovered paused, then running (Space), then the
# technology view (F4) hovered with the clock running. The frame profiler's tables (STELLAR_PROF=1,
# every STELLAR_PROF_EVERY=5 s, the `ui` and `main` threads, each headed by its Unix time) in
# RUN_DIR/err.txt, the steps' Unix times in RUN_DIR/marks.txt, screens in RUN_DIR/sN.png
# (ImageMagick's import, if there) (docs/profiling.md).
# xdotool's keys go to the focused window: `windowfocus` then a plain `key` (`key --window` is
# ignored by the renderer).
set -u
B=${1:?BINARY}; O=${2:?RUN_DIR}; D=:${3:-83}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$O" && rm -f -- "${O:?}"/s*.png "${O:?}"/err.txt "${O:?}"/out.txt "${O:?}"/marks.txt
pkill -f "Xvfb $D " 2> /dev/null; sleep 1
Xvfb "$D" -screen 0 1280x720x24 > /dev/null 2>&1 &
XP=$!
sleep 2
export DISPLAY=$D
cd "$HERE/../.." || exit 1
STELLAR_PROF=1 STELLAR_PROF_EVERY=${STELLAR_PROF_EVERY:-5} "$B" --game "${STELLARIS_DIR:-/opt/stellaris}" --map --sim --size 1280x720 > "$O/out.txt" 2> "$O/err.txt" &
RP=$!
W=$(xdotool search --sync --onlyvisible --pid $RP | head -1)
xdotool windowmove "$W" 0 0
# the simulation loaded (its log), then a few seconds more
for _ in $(seq 120); do grep -q "simulation: loaded" "$O/err.txt" && break; sleep 1; done
sleep 3
shot() { command -v import > /dev/null && import -window root "$O/$1.png" 2> /dev/null; }
hover() { # hover X0 Y0 X1 Y1 SECONDS: the pointer along the line and back, 30 moves a second
    local n=$(( $5 * 30 )) i
    for i in $(seq 0 $n); do
        local t=$(( i * 2000 / n )); [ $t -gt 1000 ] && t=$(( 2000 - t ))
        xdotool mousemove --window "$W" $(( $1 + ($3 - $1) * t / 1000 )) $(( $2 + ($4 - $2) * t / 1000 ))
        sleep 0.033
    done
}
echo "$(date +%s.%N) map, paused" >> "$O/marks.txt"
hover 100 150 1000 600 6
shot s1
xdotool windowfocus --sync "$W"; xdotool key space
echo "$(date +%s.%N) map, running" >> "$O/marks.txt"
hover 100 150 1000 600 6
xdotool windowfocus --sync "$W"; xdotool key F4
sleep 1
echo "$(date +%s.%N) technology, running" >> "$O/marks.txt"
hover 100 150 1000 600 6
shot s2
xdotool windowfocus --sync "$W"; xdotool key F4
sleep 1
kill $RP; wait $RP 2> /dev/null
kill $XP 2> /dev/null
grep -c "^thread ui" "$O/err.txt" | sed 's/^/reports: /'
