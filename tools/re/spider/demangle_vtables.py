#!/usr/bin/env python3
# demangle_vtables.py <data.tsv> <out.tsv> [llvm-undname] : the PDB's data names with every vtable
# spelled `const X::`vftable'{for `B'}`. Some vtables are named only by their mangled symbol
# (??_7CAndTrigger@@6B@): most trigger and effect classes. They are demangled with llvm-undname;
# every other line is kept as it is.
import subprocess, sys

data_path, out_path = sys.argv[1:3]
undname = sys.argv[3] if len(sys.argv) > 3 else "llvm-undname-14"
lines = open(data_path, errors="replace").read().split("\n")
mangled = sorted({l.split("\t", 1)[1] for l in lines if "\t??_7" in l})
out = subprocess.run([undname], input="\n".join(mangled) + "\n", capture_output=True, text=True).stdout.split("\n")
# llvm-undname echoes each input, then its demangling
demangled = {}
for i in range(len(out) - 1):
    if out[i].startswith("??_7") and "vftable" in out[i + 1]:
        demangled[out[i]] = out[i + 1]
n = 0
with open(out_path, "w") as f:
    for l in lines:
        if not l:
            continue
        a, _, name = l.partition("\t")
        if name in demangled:
            f.write("%s\t%s\n" % (a, demangled[name]))
            n += 1
        else:
            f.write(l + "\n")
print("vtables demangled: %d of %d" % (len(set(demangled)), len(mangled)), file=sys.stderr)
