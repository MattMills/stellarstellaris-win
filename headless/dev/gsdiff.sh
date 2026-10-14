#!/bin/bash
# gsdiff.sh <a.gamestate> <b.gamestate> [diff options]
# Diffs two gamestates (run.sh outputs, or a save's gamestate) with the one known run-to-run noise
# masked: the position of each country AI's own, unsynchronized generator (the `random_count=`
# lines three tabs deep, inside a country's AI block). Line ends are normalized.
mask() { tr -d '\r' <"$1" | sed -E 's/^(\t\t\trandom_count=).*/\1*/'; }
a=$1 b=$2
shift 2
diff "$@" <(mask "$a") <(mask "$b")
