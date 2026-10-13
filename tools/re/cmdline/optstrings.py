#!/usr/bin/env python3
# optstrings.py <regex>: C strings in the exe's data sections matching the regex, and the functions
# whose code references them (rip-relative operands in full452.asm).
import bisect, re, struct, sys
exec(open("/root/fnm_tmp/cmdargs/annos.py").read().split("src = open")[0])
pat = re.compile(sys.argv[1])
found = {}
for name, va, size, raw, rsize in secs:
    if name in (".text",):
        continue
    data = blob[raw:raw + rsize]
    for m in re.finditer(rb"[\x20-\x7e]{2,200}\x00", data):
        s = m.group()[:-1].decode()
        if pat.search(s):
            # every suffix start counts too (the linker merges tails), but keep the whole string
            found[va + m.start()] = s
funcs = []
for line in open("/root/fnm_tmp/cg452.tsv"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "F":
        funcs.append((int(p[1], 16), p[4].split(" | ")[0] or "sub_" + p[1]))
funcs.sort()
starts = [f[0] for f in funcs]
want = {"%x" % (0x140000000 + k): k for k in found}
refs = {}
rx = re.compile(r"^([0-9a-f]+):.*# 0x([0-9a-f]+)")
for line in open("/root/fnm_tmp/full452.asm"):
    m = rx.match(line)
    if m and m.group(2) in want:
        rva = int(m.group(1), 16) - 0x140000000
        i = bisect.bisect_right(starts, rva) - 1
        refs.setdefault(want[m.group(2)], set()).add(funcs[i][1] if i >= 0 else "?")
for k in sorted(found):
    print("%x\t%r\t%s" % (k, found[k], ", ".join(sorted(refs.get(k, []))) or "-"))
