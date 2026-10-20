#!/bin/bash
# save_roundtrip.sh [save.sav] [days] [more_days] : saves between the real Stellaris 4.5.2 (the
# headless game, headless/README.md) and the simulation, both ways (docs/saves.md). On the test box
# (10.5.0.24); at most 3 headless games box-wide, this script runs one at a time.
#
#   1. the writer: we read the save and write it back (0 days); the game runs N days from the
#      game's save and from ours. A lossless writer gives the same gamestate (gsdiff.sh).
#   2. the game continues our save: we run N days and save; the game loads it (0 ticks: accepted),
#      runs M more days, and saves again with its own save path (view.sh `save`); we load that save.
#   3. our M days from our save against the game's M days from it (examples/diff: store by store).
#   4. our N days from the game's save against the game's N days (examples/diff).
#
# Defaults: /opt/stellaris-saves/autosave_2210.01.01.sav, 30 and 30 days. Output: $SAVE_RT_OUT
# (default /root/saves/rt/<save>_<N>_<M>): the saves, gamestates, logs and summary.txt.
# Environment: CARGO_TARGET_DIR (default /root/saves/target-sim), HEADLESS_ROOT (run.sh's),
# STELLARIS_DIR (default /opt/stellaris), SAVE_RT_SKIP_BUILD=1.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SIM=$(cd "$HERE/.." && pwd)
REPO=$(cd "$SIM/.." && pwd)
SAVE=$(readlink -f "${1:-/opt/stellaris-saves/autosave_2210.01.01.sav}")
N=${2:-30}
M=${3:-30}
NAME=$(basename "$SAVE" .sav)
OUT=${SAVE_RT_OUT:-/root/saves/rt/${NAME}_${N}_${M}}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-/root/saves/target-sim}
export STELLARIS_DIR=${STELLARIS_DIR:-/opt/stellaris}
CARGO=${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}
RUN=$REPO/headless/run.sh
VIEW=$REPO/headless/view.sh
GSDIFF=$REPO/headless/dev/gsdiff.sh
[ -f "$SAVE" ] || { echo "no such save: $SAVE" >&2; exit 2; }
[ -x "$RUN" ] || [ -f "$RUN" ] || { echo "no headless/run.sh (git submodule update --init headless)" >&2; exit 2; }
mkdir -p "$OUT"
SUM=$OUT/summary.txt
: >"$SUM"
say() { echo "$*" | tee -a "$SUM"; }

# one headless game at a time, and only when the box has room (TESTBOX rules: 3 at most)
wait_slot() {
	while [ "$(pgrep -c stellaris)" -ge 3 ]; do sleep 10; done
}
game_run() { # save ticks out.gamestate
	wait_slot
	bash "$RUN" "$1" "$2" "$3" >"$3.log" 2>&1
}
gs() { unzip -p "$1" gamestate; }

if [ "${SAVE_RT_SKIP_BUILD:-}" != 1 ]; then
	(cd "$SIM" && "$CARGO" build --release --example resave --example diff) >"$OUT/build.log" 2>&1 || { echo "build failed: $OUT/build.log" >&2; exit 1; }
fi
RESAVE=$CARGO_TARGET_DIR/release/examples/resave
DIFF=$CARGO_TARGET_DIR/release/examples/diff

say "save: $SAVE ($N then $M days)"

# 1. the writer
"$RESAVE" "$SAVE" 0 "$OUT/ours_0.sav" >"$OUT/ours_0.log" 2>&1 || { say "1. our 0-day save failed: $OUT/ours_0.log"; exit 1; }
gs "$SAVE" >"$OUT/game_save.gamestate"
gs "$OUT/ours_0.sav" >"$OUT/ours_0.gamestate"
game_run "$SAVE" $((N * 10)) "$OUT/game_N.gamestate" || say "1. the game's run from its save failed: $OUT/game_N.gamestate.log"
game_run "$OUT/ours_0.sav" $((N * 10)) "$OUT/game_N_from_ours_0.gamestate" || say "1. the game's run from our save failed: $OUT/game_N_from_ours_0.gamestate.log"
# the game's own noise: its AI is not repeatable on every save (docs/saves.md section 6), so the
# game's run from its own save is made twice; a writer difference within that noise is the game's
game_run "$SAVE" $((N * 10)) "$OUT/game_N_again.gamestate" || say "1. the game's second run from its save failed: $OUT/game_N_again.gamestate.log"
if [ -s "$OUT/game_N.gamestate" ] && [ -s "$OUT/game_N_from_ours_0.gamestate" ]; then
	bash "$GSDIFF" "$OUT/game_N.gamestate" "$OUT/game_N_from_ours_0.gamestate" >"$OUT/1_writer.diff"
	say "1. writer: the game's $N days from its save and from ours (read, written back) differ in $(grep -c '^[<>]' "$OUT/1_writer.diff") lines (1_writer.diff)"
	if [ -s "$OUT/game_N_again.gamestate" ]; then
		bash "$GSDIFF" "$OUT/game_N.gamestate" "$OUT/game_N_again.gamestate" >"$OUT/1_noise.diff"
		say "1. noise: two runs of the game from its own save differ in $(grep -c '^[<>]' "$OUT/1_noise.diff") lines (1_noise.diff)"
	fi
fi

# 2. the game continues our save
"$RESAVE" "$SAVE" "$N" "$OUT/ours_N.sav" >"$OUT/ours_N.log" 2>&1 || { say "2. our $N-day save failed: $OUT/ours_N.log"; exit 1; }
say "2. ours: $(grep -m1 '^wrote' "$OUT/ours_N.log")"
game_run "$OUT/ours_N.sav" 0 "$OUT/game_loaded_ours_N.gamestate" &&
	say "2. the game loaded our save (0 ticks: $(wc -l <"$OUT/game_loaded_ours_N.gamestate") lines written back)" ||
	say "2. the game did not load our save: $OUT/game_loaded_ours_N.gamestate.log"
game_run "$OUT/ours_N.sav" $((M * 10)) "$OUT/game_M_from_ours_N.gamestate" &&
	say "2. the game ran $M days from our save" || say "2. the game's run from our save failed: $OUT/game_M_from_ours_N.gamestate.log"
# the game saves it again through its own save path (the in-game autosave writer, zip and meta)
mkdir -p "$OUT/game_saves"
printf 'step %s\nsave %s\nquit\n' "$M" "$OUT/game_saves" >"$OUT/view_script.txt"
wait_slot
bash "$VIEW" --script "$OUT/view_script.txt" --replies "$OUT/view_replies.txt" "$OUT/ours_N.sav" >"$OUT/view.log" 2>&1
GSAVE=$(ls -t "$OUT"/game_saves/*.sav 2>/dev/null | head -1)
if [ -n "$GSAVE" ]; then
	say "2. the game saved our game again: $GSAVE"
	"$RESAVE" "$GSAVE" 0 "$OUT/ours_from_game_save.sav" >"$OUT/ours_from_game_save.log" 2>&1 &&
		say "2. we loaded the game's save of our game: $(grep -m1 '^loaded' "$OUT/ours_from_game_save.log")" ||
		say "2. we did not load the game's save: $OUT/ours_from_game_save.log"
else
	say "2. the game's own save of our game: none written ($OUT/view.log, view_replies.txt)"
fi

# 3. our M days from our save against the game's
if [ -s "$OUT/game_M_from_ours_N.gamestate" ]; then
	"$DIFF" "$OUT/ours_N.sav" "$OUT/game_M_from_ours_N.gamestate" >"$OUT/3_ours_vs_game_from_ours.txt" 2>&1
	say "3. our $M days from our save against the game's: 3_ours_vs_game_from_ours.txt"
	tail -5 "$OUT/3_ours_vs_game_from_ours.txt" | sed 's/^/   /' | tee -a "$SUM"
fi

# 4. our N days from the game's save against the game's
if [ -s "$OUT/game_N.gamestate" ]; then
	"$DIFF" "$SAVE" "$OUT/game_N.gamestate" >"$OUT/4_ours_vs_game_from_game.txt" 2>&1
	say "4. our $N days from the game's save against the game's: 4_ours_vs_game_from_game.txt"
	tail -5 "$OUT/4_ours_vs_game_from_game.txt" | sed 's/^/   /' | tee -a "$SUM"
fi
say "done: $OUT"
