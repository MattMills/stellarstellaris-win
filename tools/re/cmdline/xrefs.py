#!/usr/bin/env python3
# xrefs.py <hex va[:len]>...: the functions whose code references each address range (rip-relative
# operands in full452.asm), with the instruction kind (r = read, w = write, & = address taken).
import bisect, re, sys
want = []
for a in sys.argv[1:]:
    v, _, n = a.partition(":")
    v = int(v, 16)
    if v < 0x140000000:
        v += 0x140000000
    want.append((v, v + (int(n) if n else 1), a))
funcs = []
for line in open("/root/fnm_tmp/cg452.tsv"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "F":
        funcs.append((int(p[1], 16), p[4].split(" | ")[0] or "sub_" + p[1]))
funcs.sort()
starts = [f[0] for f in funcs]
refs = {w[2]: {} for w in want}
rx = re.compile(r"^([0-9a-f]+):\s+(\w+)\s+([^#]*)# 0x([0-9a-f]+)")
for line in open("/root/fnm_tmp/full452.asm"):
    m = rx.match(line)
    if not m:
        continue
    t = int(m.group(4), 16)
    for lo, hi, key in want:
        if lo <= t < hi:
            op, ops = m.group(2), m.group(3)
            dst = ops.split(",")[0]
            kind = "&" if op == "lea" else ("w" if "ptr [rip" in dst and op.startswith(("mov", "or", "and", "add", "sub", "inc", "dec", "xchg", "lock", "bts", "btr")) else "r")
            rva = int(m.group(1), 16) - 0x140000000
            i = bisect.bisect_right(starts, rva) - 1
            f = funcs[i][1] if i >= 0 else "?"
            refs[key].setdefault(f, set()).add(kind + ("" if t == lo else "+%x" % (t - lo)))
for lo, hi, key in want:
    print("== %s" % key)
    for f, k in sorted(refs[key].items()):
        print("   %-6s %s" % ("".join(sorted(k))[:30], f[:150]))
