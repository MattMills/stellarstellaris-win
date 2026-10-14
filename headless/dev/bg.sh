#!/bin/sh
# Development helper: run the game in the background on a fixed Xvfb display, to probe it.
#   dev/bg.sh start [game args...]   start Xvfb :77 and the game (env passes through)
#   dev/bg.sh shot out.png           screenshot of the display
#   dev/bg.sh gdb 'cmd' ...          gdb batch commands against the running game
#   dev/bg.sh stop                   kill the game and Xvfb
ROOT=${HEADLESS_ROOT:-/opt/stellaris-headless}
DISP=${HEADLESS_DISPLAY:-77}
HERE=$(cd "$(dirname "$0")" && pwd)
case "$1" in
start)
	shift
	if [ -f "$ROOT/runs/game.pid" ] && kill -0 "$(cat "$ROOT/runs/game.pid")" 2>/dev/null; then
		echo "a game is already running (pid $(cat "$ROOT/runs/game.pid")): dev/bg.sh stop" >&2
		exit 1
	fi
	mkdir -p "$ROOT/runs"
	Xvfb :$DISP -screen 0 1920x1080x24 +extension GLX -nolisten tcp >/dev/null 2>&1 &
	echo $! >"$ROOT/runs/xvfb.pid"
	sleep 1
	cd "$ROOT/game" || exit 1
	HOME=${HEADLESS_HOME:-$ROOT/home} DISPLAY=:$DISP LIBGL_ALWAYS_SOFTWARE=1 \
		LD_PRELOAD=${HEADLESS_SO:-$ROOT/headless.so} nohup ./stellaris "$@" >"$ROOT/runs/bg.log" 2>&1 &
	echo $! >"$ROOT/runs/game.pid"
	echo "game pid $(cat "$ROOT/runs/game.pid") on :$DISP"
	;;
shot)
	xwd -root -display :$DISP -silent >/tmp/headless_shot.xwd && python3 "$HERE/xwd2png.py" /tmp/headless_shot.xwd "$2"
	;;
gdb)
	shift
	args=""
	for c in "$@"; do args="$args -ex \"$c\""; done
	eval gdb -nx -batch -p "$(cat "$ROOT/runs/game.pid")" $args 2>&1 | grep -v -E "^\[New LWP|^\[Thread|^warning: "
	;;
stop)
	[ -f "$ROOT/runs/game.pid" ] && kill -9 "$(cat "$ROOT/runs/game.pid")" 2>/dev/null
	[ -f "$ROOT/runs/xvfb.pid" ] && kill "$(cat "$ROOT/runs/xvfb.pid")" 2>/dev/null
	rm -f "$ROOT/runs/game.pid" "$ROOT/runs/xvfb.pid"
	;;
esac
