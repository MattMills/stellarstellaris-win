#!/bin/bash
# db_run.sh <save.sav> <ticks> <out.gamestate>
#
# run.sh with the database prototype: the driver is dev/db_headless.c (headless.c included, plus
# Lua building the databases named in HEADLESS_DB), linked with LuaJIT. See docs/databases.md.
#
#   HEADLESS_DB="CNamedColorDatabase:lua" headless/dev/db_run.sh save.sav 300 out.gamestate
#   HEADLESS_DB="CNamedColorDatabase:shadow" HEADLESS_DB_DUMP=1 HEADLESS_DB_CENSUS=1 ...
#
# HEADLESS_DB_DUMP=1 / HEADLESS_DB_CENSUS=1 write <out>.dump.txt / <out>.census.tsv (the hooked
# databases' objects; the object count of every single-object database), when the save is launched.
# Environment as run.sh (HEADLESS_ROOT, HEADLESS_ARGS, HEADLESS_TIMEOUT, HEADLESS_KEEP, ...), plus
# DB_ROOT (default /opt/stellaris-headless/dbwork): LuaJIT is built there (luajit-src, from the
# repo's lib/luajit) and the driver too; work dirs go there. Nothing in the repo is written.
set -u
if [ $# -lt 3 ]; then
	echo "usage: $0 <save.sav> <ticks> <out.gamestate>" >&2
	exit 2
fi
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ROOT=${HEADLESS_ROOT:-/opt/stellaris-headless}
DB_ROOT=${DB_ROOT:-/opt/stellaris-headless/dbwork}
SAVE=$(readlink -f "$1")
TICKS=$2
OUT=$(readlink -f "$3")
TIMEOUT=${HEADLESS_TIMEOUT:-1800}
[ -f "$SAVE" ] || { echo "no such save: $1" >&2; exit 2; }
[ -x "$ROOT/game/stellaris" ] || { echo "no game in $ROOT/game (see README: setup)" >&2; exit 2; }
mkdir -p "$DB_ROOT/work"

# LuaJIT, static and position independent, from the repo's copy
LJ=$DB_ROOT/luajit-src
if [ ! -f "$LJ/src/libluajit.a" ]; then
	rm -rf "$LJ" && cp -r "$REPO/lib/luajit" "$LJ" &&
		make -C "$LJ" -j8 BUILDMODE=static XCFLAGS=-fPIC CFLAGS="-O2 -fPIC" >"$DB_ROOT/luajit-build.log" 2>&1 ||
		{ echo "LuaJIT build failed: $DB_ROOT/luajit-build.log" >&2; exit 2; }
fi
SO=$DB_ROOT/db_headless.so
if [ ! -f "$SO" ] || [ "$HERE/db_headless.c" -nt "$SO" ] || [ "$REPO/headless/headless.c" -nt "$SO" ]; then
	gcc -O2 -Wall -shared -fPIC -I"$LJ/src" -o "$SO.tmp" "$HERE/db_headless.c" "$LJ/src/libluajit.a" \
		-ldl -lpthread -lm && mv "$SO.tmp" "$SO" || exit 2
fi

WORK=$(mktemp -d "$DB_ROOT/work/run.XXXXXX")
USERDIR="$WORK/home/.local/share/Paradox Interactive/Stellaris"
mkdir -p "$USERDIR/save games/headless"
cp "$SAVE" "$USERDIR/save games/headless/in.sav"
if [ -z "${HEADLESS_DLCS:-}" ]; then
	HEADLESS_DLCS=$(unzip -p "$SAVE" meta | tr -d '\r' |
		awk '/^required_dlcs=/{f=1;next} f&&/^}/{f=0} f&&/"/{gsub(/^[ \t]*"|"[ \t]*$/,""); print}' | paste -sd';')
fi
[ "${HEADLESS_DB_DUMP:-}" = 1 ] && HEADLESS_DB_DUMP=${OUT%.gamestate}.dump.txt
[ "${HEADLESS_DB_CENSUS:-}" = 1 ] && HEADLESS_DB_CENSUS=${OUT%.gamestate}.census.tsv
export HEADLESS_DB=${HEADLESS_DB:-} HEADLESS_DB_DUMP=${HEADLESS_DB_DUMP:-} HEADLESS_DB_CENSUS=${HEADLESS_DB_CENSUS:-}
export HEADLESS_DB_LUA="$HERE/db" HEADLESS_DB_GAME="$ROOT/game" \
	HEADLESS_DB_PATH="$REPO/lua/?.lua;$REPO/lib/stellar-lua-pdxscript/?.lua"
export HEADLESS_DLCS HEADLESS_TICKS=$TICKS HEADLESS_MODE=loop HEADLESS_TIMEOUT=$TIMEOUT \
	HEADLESS_SAVE="save games/headless/in.sav" HEADLESS_OUT=out.gamestate HEADLESS_LOG="$WORK/headless.log"
export HOME="$WORK/home" LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=${LP_NUM_THREADS:-4} \
	MESA_SHADER_CACHE_DIR="$ROOT/cache/mesa"
GAME_ARGS=${HEADLESS_ARGS--loadrandomseed -threads=1}

start=$(date +%s.%N)
cd "$ROOT/game" || exit 2
xvfb-run -a -n $((100 + $$ % 800)) -s "-screen 0 1920x1080x24 +extension GLX -nolisten tcp" \
	timeout -s KILL $((TIMEOUT + 60)) env LD_PRELOAD="$SO" ./stellaris $GAME_ARGS >"$WORK/game.log" 2>&1
rc=$?
end=$(date +%s.%N)

grep -v '] DLC o' "$WORK/headless.log" 2>/dev/null
# the game's own logs of the run, next to the output
for f in error.log time.log; do
	[ -f "$USERDIR/logs/$f" ] && cp "$USERDIR/logs/$f" "${OUT%.gamestate}.$f"
done
if [ $rc -eq 0 ] && [ -f "$USERDIR/out.gamestate" ]; then
	tr -d '\r' <"$USERDIR/out.gamestate" >"$OUT"
	printf 'ok: %s (%d ticks) -> %s in %.1f s\n' "$1" "$TICKS" "$OUT" "$(echo "$end - $start" | bc)"
	[ "${HEADLESS_KEEP:-0}" = 1 ] || rm -rf "$WORK"
	exit 0
fi
echo "FAILED (exit $rc); work dir kept: $WORK" >&2
ls "$USERDIR/crashes" 2>/dev/null | sed 's/^/crash: /' >&2
exit 1
