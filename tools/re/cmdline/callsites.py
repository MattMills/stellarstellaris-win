#!/usr/bin/env python3
# callsites.py <hex rva>...: every call to the targets in full452.asm, with the register arguments
# loaded just before (rcx, rdx, r8, r9: strings, PDB names or immediates) and the calling function.
import bisect, re, sys
sys.argv, targets = sys.argv[:1], set(int(a, 16) + 0x140000000 for a in sys.argv[1:])
exec(open("/root/fnm_tmp/cmdargs/annos.py").read().split("src = open")[0])  # cstr()
funcs = []
for line in open("/root/fnm_tmp/cg452.tsv"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "F":
        funcs.append((int(p[1], 16), p[4].split(" | ")[0] or "sub_" + p[1]))
funcs.sort()
starts = [f[0] for f in funcs]
data = {}
for line in open("/root/fnm_tmp/data452.tsv", errors="replace"):
    r, n = line.rstrip("\n").split("\t", 1)
    data[int(r, 16)] = n
REGS = {"rcx": "rcx", "ecx": "rcx", "cl": "rcx", "rdx": "rdx", "edx": "rdx", "dl": "rdx",
        "r8": "r8", "r8d": "r8", "r8b": "r8", "r9": "r9", "r9d": "r9", "r9b": "r9"}
args = {}
rx = re.compile(r"^([0-9a-f]+):\s+(\w+)\s+([^,#]*)(?:,\s*([^#]*))?(?:#\s*0x([0-9a-f]+))?")
for line in open("/root/fnm_tmp/full452.asm"):
    m = rx.match(line)
    if not m:
        continue
    addr, op, dst, src, ref = m.groups()
    dst = dst.strip()
    if op in ("call", "jmp"):
        t = re.search(r"0x([0-9a-f]+)", dst)
        if t and int(t.group(1), 16) in targets:
            rva = int(addr, 16) - 0x140000000
            i = bisect.bisect_right(starts, rva) - 1
            print("%x\t%x\t%s\t%s" % (rva, int(t.group(1), 16) - 0x140000000, funcs[i][1] if i >= 0 else "?",
                  "\t".join("%s=%s" % (r, args.get(r, "?")) for r in ("rcx", "rdx", "r8", "r9"))))
        args = {}
        continue
    if op == "ret":
        args = {}
    if dst in REGS:
        r = REGS[dst]
        if ref:
            v = int(ref, 16) - 0x140000000
            s = cstr(v)
            args[r] = repr(s) if s is not None else data.get(v, "&%x" % v)
        elif src and re.fullmatch(r"-?\d+", src.strip()):
            args[r] = src.strip()
        elif op in ("mov", "lea", "xor", "movzx", "movsxd"):
            args[r] = (op + " " + (src or dst)).strip() if not (op == "xor" and src and src.strip() == dst) else "0"
