#!/bin/bash
# run.sh <save.sav> <ticks> <out.gamestate> [loop|frame]
#
# Runs the real Stellaris 4.5.2 Linux build headless (Xvfb, Mesa software GL): loads the save,
# runs exactly <ticks> ticks, writes the resulting gamestate (the game's own writer, LF line ends)
# to <out.gamestate>. Each run gets its own HOME under $HEADLESS_ROOT/work, so runs can go in
# parallel. Exit status 0 on success.
#
# Environment: HEADLESS_ROOT (default /opt/stellaris-headless: game/ is the install, headless.so
# the preload), HEADLESS_TIMEOUT (seconds, default 1800), HEADLESS_KEEP=1 to keep the work dir,
# HEADLESS_DLCS to override the DLC list (default: the save's required_dlcs), LP_NUM_THREADS
# (llvmpipe threads, default 4), HEADLESS_ARGS (the game's command line, default
# "-loadrandomseed -threads=1"), HEADLESS_RNG_POS (a position, or "save"), HEADLESS_PROFILE and
# HEADLESS_PROFILE_OUT (random-draw profile per call site, see README).
set -u
if [ $# -lt 3 ]; then
	echo "usage: $0 <save.sav> <ticks> <out.gamestate> [loop|frame]" >&2
	exit 2
fi
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${HEADLESS_ROOT:-/opt/stellaris-headless}
SAVE=$(readlink -f "$1")
TICKS=$2
OUT=$(readlink -f "$3")
MODE=${4:-loop}
TIMEOUT=${HEADLESS_TIMEOUT:-1800}
[ -f "$SAVE" ] || { echo "no such save: $1" >&2; exit 2; }
[ -x "$ROOT/game/stellaris" ] || { echo "no game in $ROOT/game (see README: setup)" >&2; exit 2; }

SO=$ROOT/headless.so
if [ ! -f "$SO" ] || [ "$HERE/headless.c" -nt "$SO" ]; then
	gcc -O2 -Wall -shared -fPIC -o "$SO.tmp" "$HERE/headless.c" -ldl -lpthread && mv "$SO.tmp" "$SO" || exit 2
fi

mkdir -p "$ROOT/work" "$ROOT/cache/mesa"
WORK=$(mktemp -d "$ROOT/work/run.XXXXXX")
USERDIR="$WORK/home/.local/share/Paradox Interactive/Stellaris"
mkdir -p "$USERDIR/save games/headless"
cp "$SAVE" "$USERDIR/save games/headless/in.sav"
[ -f "$HERE/settings.txt" ] && cp "$HERE/settings.txt" "$USERDIR/settings.txt"
# HEADLESS_AUTOSAVE=<level>: the game's own autosaves (2 monthly, 3 quarterly, 4 half-yearly, 5
# yearly), all kept; HEADLESS_SAVES_OUT=<dir> receives them.
if [ -n "${HEADLESS_AUTOSAVE:-}" ]; then
	printf 'language="l_english"\nautosave=%s\n' "$HEADLESS_AUTOSAVE" >"$USERDIR/settings.txt"
	export HEADLESS_AUTOSAVE
	if [ -n "${HEADLESS_SAVES_OUT:-}" ]; then
		mkdir -p "$HEADLESS_SAVES_OUT"
		export HEADLESS_AUTOSAVE_DIR=$(readlink -f "$HEADLESS_SAVES_OUT")
	fi
fi

if [ -z "${HEADLESS_DLCS:-}" ]; then
	HEADLESS_DLCS=$(unzip -p "$SAVE" meta | tr -d '\r' |
		awk '/^required_dlcs=/{f=1;next} f&&/^}/{f=0} f&&/"/{gsub(/^[ \t]*"|"[ \t]*$/,""); print}' | paste -sd';')
fi

export HEADLESS_DLCS HEADLESS_TICKS=$TICKS HEADLESS_MODE=$MODE HEADLESS_TIMEOUT=$TIMEOUT \
	HEADLESS_SAVE="save games/headless/in.sav" HEADLESS_OUT=out.gamestate HEADLESS_LOG="$WORK/headless.log"
export HOME="$WORK/home" LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=${LP_NUM_THREADS:-4} \
	MESA_SHADER_CACHE_DIR="$ROOT/cache/mesa"

# -loadrandomseed: the load keeps the save's random_seed and random_count (by default a single
# player load reseeds from the clock, and two runs of one save differ from the first draw on).
# -threads=1: one task thread; with more, the AI's own (unsynchronized) generators are drawn in a
# varying order and runs of one save drift apart.
GAME_ARGS=${HEADLESS_ARGS--loadrandomseed -threads=1}
# HEADLESS_PROFILE=1: the default call-site table (the tick's phases), made once.
if [ "${HEADLESS_PROFILE:-}" = 1 ]; then
	HEADLESS_PROFILE=$ROOT/cache/sites.tsv
	[ -s "$HEADLESS_PROFILE" ] || python3 "$HERE/dev/callsites.py" "$ROOT/game/stellaris" "$HEADLESS_PROFILE" >&2
	export HEADLESS_PROFILE HEADLESS_PROFILE_OUT=${HEADLESS_PROFILE_OUT:-${OUT%.gamestate}.profile.tsv}
fi
# HEADLESS_RNG_POS=save: after the load, put the generator back at the save's random_count (the
# load draws ~112 values), so the run continues the saved session's random stream.
if [ "${HEADLESS_RNG_POS:-}" = save ]; then
	HEADLESS_RNG_POS=$(unzip -p "$SAVE" gamestate | grep -a -m1 '^random_count=' | tr -dc '0-9')
	export HEADLESS_RNG_POS
fi

# HEADLESS_NO_ASLR=1: the game runs with address-space randomization off (setarch -R).
LAUNCH=""
[ "${HEADLESS_NO_ASLR:-0}" = 1 ] && LAUNCH="setarch $(uname -m) -R"

start=$(date +%s.%N)
cd "$ROOT/game" || exit 2
# The kill timeout is on the game itself (not on xvfb-run, which would leave the game running).
xvfb-run -a -n $((100 + $$ % 800)) -s "-screen 0 1920x1080x24 +extension GLX -nolisten tcp" \
	timeout -s KILL $((TIMEOUT + 60)) $LAUNCH env LD_PRELOAD="$SO" ./stellaris $GAME_ARGS >"$WORK/game.log" 2>&1
rc=$?
end=$(date +%s.%N)

grep -v '] DLC o' "$WORK/headless.log" 2>/dev/null
if [ $rc -eq 0 ] && [ -f "$USERDIR/out.gamestate" ]; then
	tr -d '\r' <"$USERDIR/out.gamestate" >"$OUT"
	if [ -n "${HEADLESS_SAVES_OUT:-}" ]; then
		mkdir -p "$HEADLESS_SAVES_OUT"
		find "$USERDIR/save games" -name '*.sav' ! -name in.sav -exec cp -p {} "$HEADLESS_SAVES_OUT/" \;
	fi
	printf 'ok: %s (%d ticks) -> %s in %.1f s\n' "$1" "$TICKS" "$OUT" "$(echo "$end - $start" | bc)"
	[ "${HEADLESS_KEEP:-0}" = 1 ] || rm -rf "$WORK"
	exit 0
fi
echo "FAILED (exit $rc); work dir kept: $WORK" >&2
ls "$USERDIR/crashes" 2>/dev/null | sed 's/^/crash: /' >&2
exit 1
