#!/usr/bin/env python3
# folders.py <full.asm> <stellaris elf> <databases list> <out.tsv>: each database's folder (the
# CString its constructor or CreateInstance builds from a literal: "common/named_colors")
import re, struct, sys
asm, elf_path, names_path, out_path = sys.argv[1:5]
names = [l.split("\t")[0].strip() for l in open(names_path) if l.strip() and not l.startswith("#") and not l.startswith("database\t")]
want = {}
for n in names:
    want["%s::%s()" % (n, n)] = n
    want["TGameDatabase<%s>::CreateInstance()" % n] = n
    want["%s::CreateInstance()" % n] = n
    want["%s::Init()" % n] = n
e = open(elf_path, "rb").read()
phoff = struct.unpack_from("<Q", e, 0x20)[0]
phn = struct.unpack_from("<H", e, 0x38)[0]
segs = []
for i in range(phn):
    t, fl, off, va, pa, fs, ms, al = struct.unpack_from("<IIQQQQQQ", e, phoff + i * 56)
    if t == 1:
        segs.append((va, off, fs))
def cstr(va):
    for s, o, fs in segs:
        if s <= va < s + fs:
            b = e[o + va - s:o + va - s + 200]
            return b.split(b"\0")[0].decode("latin-1")
    return None
fn_re = re.compile(r"^[0-9a-f]+ <(.*)>:$")
lea_re = re.compile(r"lea\s+0x[0-9a-f]+\(%rip\),%rsi\s+# ([0-9a-f]+)")
cur, pending = None, None
found = {}
for line in open(asm, errors="replace"):
    m = fn_re.match(line)
    if m:
        cur = want.get(m.group(1))
        pending = None
        continue
    if cur is None:
        continue
    m = lea_re.search(line)
    if m:
        pending = int(m.group(1), 16)
        continue
    if pending and "<CString::CString(char const*)>" in line:
        s = cstr(pending)
        if s and ("/" in s) and cur not in found:
            found[cur] = s
        pending = None
with open(out_path, "w") as f:
    for n in names:
        f.write("%s\t%s\n" % (n, found.get(n, "")))
print(len(found), "folders of", len(names))
