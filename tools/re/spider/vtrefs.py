#!/usr/bin/env python3
# vtrefs.py <full.asm> <names.tsv> <data.tsv> <out.tsv> : for every vtable the PDB names, the code
# that loads its address (`lea reg, [rip + x]`, a constructor or destructor storing it): the
# function, and which rip-relative lea of that function it is (its ordinal). The same function in
# another build (vtmap.lua, stellar-fnmatch) has the same instructions: its lea of the same ordinal
# gives the vtable's address there, exactly, even for vtables whose slots are identical to another's.
import bisect, re, sys

asm_path, names_path, data_path, out_path = sys.argv[1:5]
BASE = 0x140000000
starts = []
for line in open(names_path):
    a, _, n = line.rstrip("\n").partition("\t")
    try:
        starts.append(int(a, 16))
    except ValueError:
        pass
starts = sorted(set(starts))
vtables = {}
for line in open(data_path, errors="replace"):
    a, _, n = line.rstrip("\n").partition("\t")
    if "`vftable'" in n:
        vtables.setdefault(int(a, 16), n)

refs = {}  # vtable rva -> [(function rva, ordinal)]
function, ordinal, next_start = None, 0, None
for line in open(asm_path, errors="replace"):
    m = re.match(r"^\s*([0-9a-f]+):\s+lea\s+\w+, \[rip [+-] \d+\]\s+# 0x([0-9a-f]+)", line)
    a = re.match(r"^\s*([0-9a-f]+):", line)
    if not a:
        continue
    rva = int(a.group(1), 16) - BASE
    if next_start is None or rva >= next_start or (function is not None and rva < function):
        k = bisect.bisect_right(starts, rva) - 1
        function = starts[k] if k >= 0 else None
        next_start = starts[k + 1] if k + 1 < len(starts) else None
        ordinal = 0
    if m:
        target = int(m.group(2), 16) - BASE
        if target in vtables and function is not None:
            lst = refs.setdefault(target, [])
            if len(lst) < 4:
                lst.append((function, ordinal))
        ordinal += 1

with open(out_path, "w") as out:
    out.write("vtable_rva\tfunction_rva\tordinal\n")
    for vt in sorted(refs):
        for f, o in refs[vt]:
            out.write("%x\t%x\t%d\n" % (vt, f, o))
print("vtables %d, referenced by code %d" % (len(vtables), len(refs)), file=sys.stderr)
