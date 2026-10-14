#!/bin/bash
# view.sh [--size WxH] [--listen [ADDR:]PORT] [--script FILE] [--replies FILE] [--menu] <save.sav>
#
# The real Stellaris 4.5.2 Linux build with its frames drawn (Xvfb, Mesa llvmpipe), driven by
# commands (headless.c, HEADLESS_MODE=view): the renderer's protocol (docs/render.md section 9), so
# sim/render/tools/ctl.py drives both. The save gives the owned DLCs and is loaded at start (with
# --menu the game waits at the main menu for a `load` command). The window is WxH (default
# 1600x900, windowed, no vsync) on an Xvfb screen of the same size. --script runs a file of
# commands first (replies to --replies, else stdout); with --listen the game then serves TCP until
# `quit` (localhost unless an address is given); without it the game exits after the script.
#
# Environment: HEADLESS_ROOT, HEADLESS_TIMEOUT (seconds, default 3600), LP_NUM_THREADS (default 8),
# HEADLESS_FRAME_WAIT / HEADLESS_FRAME_MIN / HEADLESS_FRAME_TIMEOUT (a `frame` waits at least 2 s
# and 10 frames, then until the picture settles, at most 30 s), HEADLESS_KEEP=1.
set -u
SIZE=1600x900
LISTEN=""
SCRIPT=""
REPLIES=""
MENU=0
while [ $# -gt 0 ]; do
	case "$1" in
	--size) SIZE=$2; shift 2 ;;
	--listen) LISTEN=$2; shift 2 ;;
	--script) SCRIPT=$(readlink -f "$2"); shift 2 ;;
	--replies) REPLIES=$(readlink -f "$2"); shift 2 ;;
	--menu) MENU=1; shift ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) break ;;
	esac
done
if [ $# -lt 1 ] || { [ -z "$LISTEN" ] && [ -z "$SCRIPT" ]; }; then
	echo "usage: $0 [--size WxH] [--listen [ADDR:]PORT] [--script FILE] [--replies FILE] [--menu] <save.sav>" >&2
	echo "       (at least one of --listen, --script)" >&2
	exit 2
fi
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${HEADLESS_ROOT:-/opt/stellaris-headless}
SAVE=$(readlink -f "$1")
W=${SIZE%x*}
H=${SIZE#*x}
TIMEOUT=${HEADLESS_TIMEOUT:-3600}
[ -f "$SAVE" ] || { echo "no such save: $1" >&2; exit 2; }
[ -x "$ROOT/game/stellaris" ] || { echo "no game in $ROOT/game (see README: setup)" >&2; exit 2; }

SO=$ROOT/headless.so
if [ ! -f "$SO" ] || [ "$HERE/headless.c" -nt "$SO" ]; then
	gcc -O2 -Wall -shared -fPIC -o "$SO.tmp" "$HERE/headless.c" -ldl -lpthread && mv "$SO.tmp" "$SO" || exit 2
fi

mkdir -p "$ROOT/work" "$ROOT/cache/mesa"
WORK=$(mktemp -d "$ROOT/work/view.XXXXXX")
USERDIR="$WORK/home/.local/share/Paradox Interactive/Stellaris"
mkdir -p "$USERDIR/save games/headless"
cat >"$USERDIR/settings.txt" <<EOF
language="l_english"
graphics=
{
	size=
	{
		x=$W
		y=$H
	}
	gui_scale=1.000000
	gui_safe_ratio=1.000000
	refreshRate=60
	fullScreen=no
	borderless=no
	display_index=0
	renderer=2
	shadowSize=2048
	multi_sampling=0
	multi_sampling_quality=0
	maxanisotropy=16
	gamma=50.000000
	vsync=no
}
EOF

HEADLESS_DLCS=${HEADLESS_DLCS:-$(unzip -p "$SAVE" meta | tr -d '\r' |
	awk '/^required_dlcs=/{f=1;next} f&&/^}/{f=0} f&&/"/{gsub(/^[ \t]*"|"[ \t]*$/,""); print}' | paste -sd';')}
if [ $MENU = 0 ]; then
	cp "$SAVE" "$USERDIR/save games/headless/$(basename "$SAVE")"
	export HEADLESS_SAVE="save games/headless/$(basename "$SAVE")"
fi
export HEADLESS_DLCS HEADLESS_MODE=view HEADLESS_TIMEOUT=$TIMEOUT HEADLESS_LOG="$WORK/headless.log" \
	HEADLESS_LISTEN="$LISTEN" HEADLESS_SCRIPT="$SCRIPT" HEADLESS_REPLIES="$REPLIES"
export HOME="$WORK/home" LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=${LP_NUM_THREADS:-8} \
	MESA_SHADER_CACHE_DIR="$ROOT/cache/mesa"
GAME_ARGS=${HEADLESS_ARGS--loadrandomseed -threads=1}

echo "view: work dir $WORK (log: $WORK/headless.log)" >&2
start=$(date +%s.%N)
cd "$ROOT/game" || exit 2
# The kill timeout is on the game itself (not on xvfb-run, which would leave the game running).
xvfb-run -a -n $((100 + $$ % 800)) -s "-screen 0 ${W}x${H}x24 +extension GLX -nolisten tcp" \
	timeout -s KILL $((TIMEOUT + 60)) env LD_PRELOAD="$SO" ./stellaris $GAME_ARGS >"$WORK/game.log" 2>&1
rc=$?
end=$(date +%s.%N)
grep -v '] DLC o' "$WORK/headless.log" 2>/dev/null | tail -40 >&2
printf 'view: exit %d after %.1f s\n' $rc "$(echo "$end - $start" | bc)" >&2
if [ $rc -eq 0 ] && [ "${HEADLESS_KEEP:-0}" != 1 ]; then
	rm -rf "$WORK"
else
	echo "work dir kept: $WORK" >&2
fi
exit $rc
