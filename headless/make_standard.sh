#!/bin/bash
# make_standard.sh <save.sav> <ticks> <outdir>
#
# A correctness standard: the real game run headless from <save> for <ticks> ticks, with every
# save the game writes on the way. <outdir> gets:
#   autosave_<date>.sav   the game's own monthly autosaves, exactly as it wrote them
#   final_<date>.sav      the state after the last tick (the game's gamestate writer; the meta of
#                         the autosave of that date, or the input's with the date changed)
#   loaded_<date>.sav     the input as the game holds it right after the load (0 ticks)
#   start.gamestate       the input with random_seed / random_count set to where the game's
#                         generator stands at the first tick (the load draws ~112 values): the
#                         `from` file for a simulation (standard.sh)
#   manifest.tsv          file, date, tick, random_seed, random_count, size, sha256
#   run.log               the driver's log (times, autosaves)
#
# The game's command line is HEADLESS_ARGS (run.sh's default: -loadrandomseed -threads=1); for
# another seed: HEADLESS_ARGS="-rng_seed=N -rng_pos=0 -threads=1". HEADLESS_AUTOSAVE (default 2,
# monthly) is the autosave level. Set NO_LOADED=1 to skip the 0-tick run.
set -u
if [ $# -lt 3 ]; then
	echo "usage: $0 <save.sav> <ticks> <outdir>" >&2
	exit 2
fi
HERE=$(cd "$(dirname "$0")" && pwd)
SAVE=$(readlink -f "$1")
TICKS=$2
OUT=$3
mkdir -p "$OUT" || exit 2
OUT=$(readlink -f "$OUT")
export HEADLESS_AUTOSAVE=${HEADLESS_AUTOSAVE:-2}
# The game's parallel-fors run inline on the main thread: with even one task thread the AIs' own
# unsynchronized generators are drawn in a varying order, an AI decision eventually differs (an AI
# research choice in 2211.07 here) and two runs part from 2212.02 on. Inline, 10-year runs are
# byte-identical. HEADLESS_NO_TASK_THREADS=0 keeps the threads.
export HEADLESS_NO_TASK_THREADS=${HEADLESS_NO_TASK_THREADS:-1}
# Address-space randomization off: with it, runs still part after 4.5 to 6.5 years (pop groups'
# ethics attraction first: some order depends on where objects are in memory). Off, the whole
# 10-year run is byte-identical.
export HEADLESS_NO_ASLR=${HEADLESS_NO_ASLR:-1}

start=$(date +%s)
HEADLESS_SAVES_OUT="$OUT" bash "$HERE/run.sh" "$SAVE" "$TICKS" "$OUT/final.gamestate" >"$OUT/run.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
	echo "the run failed (exit $rc): $OUT/run.log" >&2
	exit 1
fi
if [ -z "${NO_LOADED:-}" ]; then
	HEADLESS_AUTOSAVE= bash "$HERE/run.sh" "$SAVE" 0 "$OUT/loaded.gamestate" >"$OUT/run_loaded.log" 2>&1 ||
		echo "the 0-tick run failed: $OUT/run_loaded.log" >&2
fi

# the generator at the first tick, from the driver's log
read -r SEED POS < <(sed -n 's/.*random after load: seed \(-\{0,1\}[0-9]*\) position \([0-9]*\).*/\1 \2/p' "$OUT/run.log" | head -1)

python3 - "$SAVE" "$OUT" "$SEED" "$POS" <<'EOF'
import hashlib, os, re, sys, zipfile

save, out, seed, pos = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
src = zipfile.ZipFile(save)
meta_in, gs_in = src.read("meta"), src.read("gamestate")

def field(text, key):
    m = re.search(rb"^" + key.encode() + rb"=\"?([^\"\n]*)\"?$", text, re.M)
    return m.group(1).decode() if m else ""

def write_sav(path, gamestate, meta):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in (("gamestate", gamestate), ("meta", meta)):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)

def meta_for(date):
    p = os.path.join(out, f"autosave_{date}.sav")
    if os.path.exists(p):
        return zipfile.ZipFile(p).read("meta")
    return re.sub(rb'^date="[^"]*"', b'date="' + date.encode() + b'"', meta_in, flags=re.M)

for kind in ("final", "loaded"):
    p = os.path.join(out, f"{kind}.gamestate")
    if os.path.exists(p):
        gs = open(p, "rb").read()
        date = field(gs, "date")
        write_sav(os.path.join(out, f"{kind}_{date}.sav"), gs, meta_for(date))
        os.remove(p)

# start.gamestate: the input, its top-level generator lines set to the first tick's
gs = re.sub(rb"^random_seed=.*$", b"random_seed=" + seed.encode(), gs_in, count=1, flags=re.M)
gs = re.sub(rb"^random_count=.*$", b"random_count=" + pos.encode(), gs, count=1, flags=re.M)
open(os.path.join(out, "start.gamestate"), "wb").write(gs)

rows = []
for name in sorted(os.listdir(out)):
    p = os.path.join(out, name)
    if name.endswith(".sav"):
        g = zipfile.ZipFile(p).read("gamestate")
    elif name == "start.gamestate":
        g = open(p, "rb").read()
    else:
        continue
    data = open(p, "rb").read()
    rows.append((name, field(g, "date"), field(g, "tick"), field(g, "random_seed"), field(g, "random_count"),
                 str(len(data)), hashlib.sha256(data).hexdigest()))
with open(os.path.join(out, "manifest.tsv"), "w") as f:
    f.write(f"# input {os.path.basename(save)}; generator at the first tick: seed {seed}, position {pos}\n")
    f.write("file\tdate\ttick\trandom_seed\trandom_count\tsize\tsha256\n")
    for r in rows:
        f.write("\t".join(r) + "\n")
print(f"{len(rows)} files in {out}")
EOF
echo "standard in $OUT ($(ls "$OUT" | grep -c '^autosave_') autosaves) in $(($(date +%s) - start)) s; $(du -sh "$OUT" | cut -f1)"
