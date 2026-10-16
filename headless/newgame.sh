#!/bin/bash
# newgame.sh <empire design> <ticks> <out dir>
#
# The real Stellaris 4.5.2 makes a new game headless, through its own path and without the menus:
# headless.c does at the main menu what the command line's -empire=<design> does (a human with that
# design, then CFrontEndIdler::StartNewGame -> LaunchNewGame), with the single-player galaxy
# settings of settings.txt. headless.c sets the global random state right before
# CGameState::GenerateNewGalaxy and writes
#   <out dir>/day0.gamestate         right after the generation (InitPostGalaxyCreation done)
#   <out dir>/ticks<ticks>.gamestate after OnNewGameStarted and <ticks> ticks (10 = the first day)
#   <out dir>/headless.log           the driver's log: the random state, the galaxy seed, times
#
# <empire design>: a key of the empire design database: a prescripted country (humans1_1, the
# United Nations of Earth) or a design of HEADLESS_NG_DESIGNS.
#
# Environment (and run.sh's HEADLESS_ROOT, HEADLESS_TIMEOUT, HEADLESS_KEEP, HEADLESS_DLCS,
# LP_NUM_THREADS, HEADLESS_NO_ASLR):
#   HEADLESS_NG_RANDOM   "SEED:POS", the global generator (CRandom::_Random) at the generation's
#                        start; default 0:0 (the Lua generator's --global-seed 0)
#   HEADLESS_NG_VALUE    the value GenerateNewGalaxy derives the galaxy seed from; default: one draw
#                        of the global stream, as the game does
#   HEADLESS_NG_SETTINGS a file appended to settings.txt: the galaxy settings
#                        (`galaxy_config_sp={ template="tiny" ... }`, see README); default: the game's
#                        defaults
#   HEADLESS_NG_DESIGNS  a user_empire_designs_v3.4.txt for the user dir (the setup's designs)
#   HEADLESS_ARGS        the game's command line (default "-threads=1")
set -u
if [ $# -lt 3 ]; then
	echo "usage: $0 <empire design> <ticks> <out dir>" >&2
	exit 2
fi
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${HEADLESS_ROOT:-/opt/stellaris-headless}
DESIGN=$1
TICKS=$2
mkdir -p "$3" || exit 2
OUTDIR=$(readlink -f "$3")
TIMEOUT=${HEADLESS_TIMEOUT:-1800}
[ -x "$ROOT/game/stellaris" ] || { echo "no game in $ROOT/game (see README: setup)" >&2; exit 2; }

SO=$ROOT/headless.so
if [ ! -f "$SO" ] || [ "$HERE/headless.c" -nt "$SO" ]; then
	gcc -O2 -Wall -shared -fPIC -o "$SO.tmp" "$HERE/headless.c" -ldl -lpthread && mv "$SO.tmp" "$SO" || exit 2
fi

mkdir -p "$ROOT/work" "$ROOT/cache/mesa"
WORK=$(mktemp -d "$ROOT/work/newgame.XXXXXX")
USERDIR="$WORK/home/.local/share/Paradox Interactive/Stellaris"
mkdir -p "$USERDIR/save games/headless"
if [ -f "$HERE/settings.txt" ]; then cp "$HERE/settings.txt" "$USERDIR/settings.txt"; else printf 'language="l_english"\n' >"$USERDIR/settings.txt"; fi
[ -n "${HEADLESS_NG_SETTINGS:-}" ] && cat "$HEADLESS_NG_SETTINGS" >>"$USERDIR/settings.txt"
[ -n "${HEADLESS_NG_DESIGNS:-}" ] && cp "$HEADLESS_NG_DESIGNS" "$USERDIR/user_empire_designs_v3.4.txt"

export HEADLESS_NEWGAME=1 HEADLESS_NG_EMPIRE=$DESIGN HEADLESS_NG_RANDOM=${HEADLESS_NG_RANDOM:-0:0} HEADLESS_NG_DAY0=day0.gamestate \
	HEADLESS_TICKS=$TICKS HEADLESS_MODE=loop HEADLESS_TIMEOUT=$TIMEOUT HEADLESS_OUT=out.gamestate \
	HEADLESS_LOG="$WORK/headless.log"
[ -n "${HEADLESS_DLCS:-}" ] && export HEADLESS_DLCS
export HOME="$WORK/home" LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=${LP_NUM_THREADS:-4} \
	MESA_SHADER_CACHE_DIR="$ROOT/cache/mesa"
GAME_ARGS="${HEADLESS_ARGS--threads=1}"
# HEADLESS_LAUNCH: a command the game runs under (e.g. "gdb -batch -x FILE --args"; its output
# goes to game.log, kept with HEADLESS_KEEP=1)
LAUNCH=${HEADLESS_LAUNCH:-}
[ "${HEADLESS_NO_ASLR:-0}" = 1 ] && LAUNCH="setarch $(uname -m) -R"

start=$(date +%s.%N)
cd "$ROOT/game" || exit 2
xvfb-run -a -n $((100 + $$ % 800)) -s "-screen 0 1920x1080x24 +extension GLX -nolisten tcp" \
	timeout -s KILL $((TIMEOUT + 60)) $LAUNCH env LD_PRELOAD="$SO" ./stellaris $GAME_ARGS >"$WORK/game.log" 2>&1
rc=$?
end=$(date +%s.%N)

grep -v '] DLC o' "$WORK/headless.log" 2>/dev/null
cp "$WORK/headless.log" "$OUTDIR/headless.log" 2>/dev/null
[ -f "$USERDIR/day0.gamestate" ] && tr -d '\r' <"$USERDIR/day0.gamestate" >"$OUTDIR/day0.gamestate"
if [ $rc -eq 0 ] && [ -f "$USERDIR/out.gamestate" ]; then
	tr -d '\r' <"$USERDIR/out.gamestate" >"$OUTDIR/ticks$TICKS.gamestate"
	printf 'ok: new game (%s, %d ticks) -> %s in %.1f s\n' "$DESIGN" "$TICKS" "$OUTDIR" "$(echo "$end - $start" | bc)"
	[ "${HEADLESS_KEEP:-0}" = 1 ] || rm -rf "$WORK"
	exit 0
fi
echo "FAILED (exit $rc); work dir kept: $WORK" >&2
ls "$USERDIR/crashes" 2>/dev/null | sed 's/^/crash: /' >&2
exit 1
