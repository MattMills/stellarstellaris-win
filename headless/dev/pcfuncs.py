"""pcfuncs.py <stellaris exe> <pooltrack.tsv>

The reads in a HEADLESS_POOLTRACK table, by the function each reading instruction is in (the
"pc" section: offsets in the executable), from the executable's symbols.
"""
import bisect
import subprocess
import sys

syms = []
nm = subprocess.run(["nm", "-C", "--defined-only", sys.argv[1]], capture_output=True, text=True).stdout
for line in nm.splitlines():
    p = line.split(" ", 2)
    if len(p) == 3 and p[1] in "tTwW":
        try:
            syms.append((int(p[0], 16), p[2]))
        except ValueError:
            pass
syms.sort()
addrs = [a for a, _ in syms]

agg, on = {}, False
for line in open(sys.argv[2]):
    if line.startswith("pc\t"):
        on = True
        continue
    if not on or line.startswith("#") or not line.strip():
        continue
    pc, daily, monthly = line.rstrip("\n").split("\t")
    i = bisect.bisect_right(addrs, int(pc, 16)) - 1
    f = syms[i][1] if i >= 0 else "?"
    a = agg.setdefault(f, [0, 0, 0])
    a[0] += int(daily)
    a[1] += int(monthly)
    a[2] += 1
print("daily_reads\tmonthly_reads\tinstructions\tfunction")
for f, (d, m, n) in sorted(agg.items(), key=lambda kv: -(kv[1][0] + kv[1][1])):
    print(f"{d}\t{m}\t{n}\t{f}")
