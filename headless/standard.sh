#!/bin/bash
# standard.sh <standard dir> [horizon ...]
# standard.sh <standard dir> --against <other standard dir> [horizon ...]
#
# Runs our simulation (the sim's examples/diff) from a correctness standard's start.gamestate to
# the game's own autosave at each horizon (Nm months or Ny years after the start; default 1m 6m 1y
# 2y 5y 10y), all horizons in parallel, and writes a summary table: fields equal / differ / % equal,
# the five stores with the most differing fields, and the random draws (ours against the game's,
# random_count at the horizon minus the position at the first tick).
#
# start.gamestate is the input save with its generator lines set to where the game's generator
# stood at the first tick: the save's seed (or the -rng_seed of a seeded standard) and its
# position after the load's own draws (~112). examples/diff takes the `from` file's random_seed and
# random_count, so no STELLAR_RANDOM is needed (STELLAR_RANDOM=target would start at position 0,
# 112 draws behind the game).
#
# --against: the two standards' autosaves of the same date compared with each other, through the
# same loader and diff with 0 ticks: the spread another random seed alone causes.
#
# Environment: SIM_DIFF (default $CARGO_TARGET_DIR/release/examples/diff, CARGO_TARGET_DIR default
# /root/simtarget), STELLARIS_DIR (default /opt/stellaris), STANDARD_OUT (the result directory,
# default /opt/stellaris-headless/standard_results/<name>-<time>), TOP (fields per store in the
# reports, default 5).
set -u
if [ $# -lt 1 ]; then
	sed -n '2,4p' "$0" >&2
	exit 2
fi
STD=$(readlink -f "$1")
shift
OTHER=""
if [ "${1:-}" = --against ]; then
	OTHER=$(readlink -f "$2")
	shift 2
fi
HORIZONS=${*:-1m 6m 1y 2y 5y 10y}
DIFF=${SIM_DIFF:-${CARGO_TARGET_DIR:-/root/simtarget}/release/examples/diff}
export STELLARIS_DIR=${STELLARIS_DIR:-/opt/stellaris}
[ -x "$DIFF" ] || { echo "no $DIFF: build the sim's examples (README)" >&2; exit 2; }
[ -f "$STD/start.gamestate" ] || { echo "$STD is not a standard (no start.gamestate)" >&2; exit 2; }
NAME=$(basename "$STD")${OTHER:+-vs-$(basename "$OTHER")}
OUTDIR=${STANDARD_OUT:-/opt/stellaris-headless/standard_results/$NAME-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUTDIR" || exit 2

START_DATE=$(grep -a -m1 '^date=' "$STD/start.gamestate" | tr -dc '0-9.')
START_POS=$(grep -a -m1 '^random_count=' "$STD/start.gamestate" | tr -dc '0-9')

target_date() { # <date> <horizon>: the date months or years later (12 months of 30 days)
	python3 -c '
import sys
y, m, d = map(int, sys.argv[1].split("."))
h = sys.argv[2]
n = int(h[:-1]) * (12 if h[-1] == "y" else 1)
m0 = y * 12 + (m - 1) + n
print(f"{m0 // 12:04d}.{m0 % 12 + 1:02d}.{d:02d}")' "$1" "$2"
}

t0=$(date +%s)
for h in $HORIZONS; do
	td=$(target_date "$START_DATE" "$h")
	if [ -n "$OTHER" ]; then
		from="$STD/autosave_$td.sav" to="$OTHER/autosave_$td.sav"
	else
		from="$STD/start.gamestate" to="$STD/autosave_$td.sav"
	fi
	if [ ! -f "$from" ] || [ ! -f "$to" ]; then
		echo "$h: no $to" >"$OUTDIR/$h.txt"
		continue
	fi
	echo "$h $td $from $to" >"$OUTDIR/$h.args"
	("$DIFF" "$from" "$to" "${TOP:-5}" >"$OUTDIR/$h.txt" 2>&1) &
done
wait

python3 - "$OUTDIR" "$START_POS" "${OTHER:+against}" $HORIZONS <<'EOF' | tee "$OUTDIR/summary.tsv"
import os, re, sys

outdir, start_pos, mode, horizons = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
store_re = re.compile(r"^  (\S+)\s+(\d+) in both,\s+(\d+) only here,\s+(\d+) only there; fields (\d+) equal, (\d+) differ")
print("horizon\tdate\tfields_equal\tfields_differ\tpct_equal\tworst_stores\tdraws_sim\tdraws_game\tsim_seconds")
for h in horizons:
    p = os.path.join(outdir, f"{h}.txt")
    text = open(p, errors="replace").read() if os.path.exists(p) else ""
    args = open(os.path.join(outdir, f"{h}.args")).read().split() if os.path.exists(os.path.join(outdir, f"{h}.args")) else [h, "?"]
    m = re.search(r"diff: (\d+) fields equal, (\d+) differ \(([\d.]+)% equal\)", text)
    if not m:
        print(f"{h}\t{args[1]}\tfailed: see {p}")
        continue
    stores = []
    for line in text.splitlines():
        s = store_re.match(line)
        if s:
            eq, ne = int(s.group(5)), int(s.group(6))
            stores.append((ne, s.group(1), eq))
    stores.sort(reverse=True)
    worst = ", ".join(f"{n} {ne}/{ne + eq}" for ne, n, eq in stores[:5])
    r = re.search(r"random: (\d+) draws here; the second save's seed (-?\d+), position (\d+)", text)
    t = re.search(r"days, .* in ([\d.]+) s", text)
    if mode == "against":
        sim, game = "-", f"{r.group(3)} vs the first's" if r else "?"
    else:
        sim = r.group(1) if r else "?"
        game = str(int(r.group(3)) - start_pos) if r else "?"
    print(f"{h}\t{args[1]}\t{m.group(1)}\t{m.group(2)}\t{m.group(3)}\t{worst}\t{sim}\t{game}\t{t.group(1) if t else '?'}")
EOF
echo "reports in $OUTDIR ($(($(date +%s) - t0)) s)"
