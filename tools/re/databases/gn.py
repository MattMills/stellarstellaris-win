#!/usr/bin/env python3
# gn.py <regex> [max]: GOG 4.5.2 functions whose name (one of the ICF aliases) matches; prints rva, size, the matching alias
import re, sys
pat = re.compile(sys.argv[1])
mx = int(sys.argv[2]) if len(sys.argv) > 2 else 200
ends = {}
for line in open("/root/fnm_tmp/cg452.tsv"):
    if line.startswith("F\t"):
        p = line.rstrip("\n").split("\t")
        ends[int(p[1], 16)] = int(p[2], 16)
n = 0
for line in open("/root/fnm_tmp/names452.tsv", errors="replace"):
    r, names = line.rstrip("\n").split("\t", 1)
    al = [a for a in names.split(" | ") if pat.search(a)]
    if al:
        rv = int(r, 16)
        tot = names.count(" | ") + 1
        print("%x\t%s\t%s%s" % (rv, hex(ends.get(rv, rv) - rv), al[0], ("  [+%d aliases, %d match]" % (tot - 1, len(al))) if tot > 1 else ""))
        n += 1
        if n >= mx:
            break
