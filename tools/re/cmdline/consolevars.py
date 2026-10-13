#!/usr/bin/env python3
# consolevars.py: every console variable (tweakable) registered by a static initializer
# (`dynamic initializer for 'CONSOLEVAR_n'`), as TSV: name, type, variable, initial value in the
# exe image, min, max, extra args.
import re, struct, subprocess
exec(open("/root/fnm_tmp/cmdargs/annos.py").read().split("src = open")[0])
BASE = 0x140000000
TYPES = {0x1b44cc0: "float", 0x1b44fe0: "bool", 0x1b452b0: "int", 0x1b455a0: "string", 0x1b45870: "custom"}
data = {}
for line in open("/root/fnm_tmp/data452.tsv", errors="replace"):
    r, n = line.rstrip("\n").split("\t", 1)
    data[int(r, 16)] = n
funcs = {}
for line in open("/root/fnm_tmp/cg452.tsv"):
    p = line.rstrip("\n").split("\t")
    if p[0] == "F" and "CONSOLEVAR_" in p[4]:
        funcs[int(p[1], 16)] = int(p[2], 16)

def raw(rva, n):
    for name, va, size, rawoff, rsize in secs:
        if va <= rva < va + size:
            if rva - va + n > rsize:
                return bytes(n)          # .bss: zero
            return blob[rawoff + rva - va:rawoff + rva - va + n]
    return None

rows = []
for start, end in sorted(funcs.items()):
    out = subprocess.run(["llvm-objdump-14", "-d", "-M", "intel", "--no-show-raw-insn",
                          "--start-address=0x%x" % (BASE + start), "--stop-address=0x%x" % (BASE + end + 16),
                          EXE], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines() if re.match(r"\s*[0-9a-f]+:\s", l)]
    regs = {}
    for i, l in enumerate(lines):
        m = re.match(r"\s*([0-9a-f]+):\s+(\w+)\s+([^,#]+)(?:,\s*([^#]*))?(?:#\s*(0x[0-9a-f]+))?", l)
        if not m:
            continue
        addr, op, dst, src, ref = m.groups()
        dst = dst.strip(); src = (src or "").strip()
        nxt = int(re.match(r"\s*([0-9a-f]+):", lines[i + 1]).group(1), 16) if i + 1 < len(lines) else None
        if op in ("call", "jmp"):
            t = re.search(r"0x([0-9a-f]+)", dst)
            if t and int(t.group(1), 16) - BASE in TYPES:
                rows.append((TYPES[int(t.group(1), 16) - BASE], dict(regs), start))
                regs = {}
                break
            continue
        if ref:
            v = int(ref, 16) - BASE
            regs[dst] = ("addr", v)
        elif op == "movss" and "rip" in src and nxt:
            disp = int(re.search(r"rip ([+-]) (\d+)", src).group(2)) * (1 if "+" in src else -1)
            regs[dst] = ("float", struct.unpack("<f", raw(nxt + disp - BASE, 4))[0])
        elif op == "xorps" and dst == src:
            regs[dst] = ("float", 0.0)
        elif op == "mov" and re.fullmatch(r"-?\d+", src):
            v = int(src) & 0xffffffff
            regs[dst] = ("int", v - (1 << 32) if v >= 1 << 31 else v)
        elif op in ("mov", "lea") and dst.startswith("qword ptr [rsp"):
            regs[dst] = regs.get(src)
        elif op == "lea" and re.fullmatch(r"\[(r\w+) ([+-]) (\d+)\]", src) and regs.get(re.fullmatch(r"\[(r\w+) ([+-]) (\d+)\]", src).group(1) + "d"):
            mm = re.fullmatch(r"\[(r\w+) ([+-]) (\d+)\]", src)
            b = regs[mm.group(1) + "d"]
            regs[dst] = ("int", b[1] + (int(mm.group(3)) if mm.group(2) == "+" else -int(mm.group(3))))
        elif op == "xor" and dst == src:
            regs[dst] = ("int", 0)

def val(regs, *names):
    for n in names:
        if n in regs and regs[n] is not None:
            return regs[n]
    return None

for typ, regs, start in rows:
    nm = val(regs, "rcx")
    name = cstr(nm[1]) if nm and nm[0] == "addr" else "?"
    var = val(regs, "rdx")
    vaddr = var[1] if var and var[0] == "addr" else None
    vname = data.get(vaddr, "") if vaddr is not None else ""
    init = ""
    if vaddr is not None:
        b = raw(vaddr, 4)
        if b is not None:
            if typ == "bool":
                init = "true" if b[0] else "false"
            elif typ == "int":
                init = str(struct.unpack("<i", b)[0])
            elif typ == "float":
                init = "%g" % struct.unpack("<f", b)[0]
    lo = hi = ""
    if typ == "float":
        lo, hi = val(regs, "xmm2"), val(regs, "xmm3")
    elif typ == "int":
        lo, hi = val(regs, "r8d", "r8"), val(regs, "r9d", "r9")
    fmt = lambda x: "" if not x else ("%g" % x[1] if x[0] in ("float", "int") else "")
    print("\t".join([name or "?", typ, ("%x" % vaddr) if vaddr is not None else "", vname[:80], init, fmt(lo) if lo else "", fmt(hi) if hi else "", "CONSOLEVAR_fn_%x" % start]))
