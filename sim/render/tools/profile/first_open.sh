#!/bin/bash
# first_open.sh BINARY RUN_DIR [NAME...]: each window's first opening, each in a process of its own
# (docs/profiling.md section 8): the 2210.01.01 autosave loaded (LOAD: its command(s), `load-sim
# SAVE` by default; `load-sim async SAVE` and `loaded` on two lines for the load screen's flow),
# the galaxy shown, paused, then the window opened once: NAME_cmd.prof (the command's spans),
# NAME_frames.prof (2 s of frames after it), NAME.out (the replies: `bench 2`'s worst frame is the
# opening's). Without NAMEs, every window below. LUAPROF="STELLAR_LUA_PROF=1
# STELLAR_LUA_PROF_RUNTIME=map" adds the Lua samples (of the map's runtime there).
set -u
B=${1:?BINARY}; O=${2:?RUN_DIR}; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
LOAD=${LOAD:-load-sim /opt/stellaris-saves/autosave_2210.01.01.sav}
WINDOWS="planet|open_planet 0
fleet|open fleet 1
fleet_select|select fleet 1
designer|open_designer
starbase|open_starbase 0
diplomacy|open_diplomacy contacts"
for v in situation council traditions technology leaders species empire expansion_planner fleet_manager discoveries claims market; do
    WINDOWS="$WINDOWS
$v|open_view $v"
done
mkdir -p "$O"
cd "$HERE/../.." || exit 1
while IFS='|' read -r n c; do
    [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$n" && continue
    cat > "$O/$n.txt" <<X
$LOAD
resize 1280 720
view galaxy
pause
bench 2
prof reset
$c
prof report $O/${n}_cmd.prof
bench 2
prof report $O/${n}_frames.prof
quit
X
    env STELLAR_PROF=1 ${LUAPROF:-} "$B" --game "${STELLARIS_DIR:-/opt/stellaris}" --script "$O/$n.txt" > "$O/$n.out" 2> "$O/$n.err"
    scene=$(awk '/^  scene  /{s+=$4} END{print s+0}' "$O/${n}_cmd.prof" "$O/${n}_frames.prof")
    up=$(awk '/^  upload  /{print $4}' "$O/${n}_frames.prof")
    echo "$n: scene ${scene} ms, upload ${up:-0} ms"
done <<< "$WINDOWS"
