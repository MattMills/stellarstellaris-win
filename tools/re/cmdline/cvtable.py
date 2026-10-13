#!/usr/bin/env python3
# cvtable.py: consolevars.tsv -> markdown rows, CCheatManager members named, and whether
# CCheatManager::ResetAllCheats (run by every new CGameState) overwrites the variable.
import re, subprocess
members = {}
out = subprocess.run(["python3", "/root/fnm_tmp/pdbtype.py", "CCheatManager"], capture_output=True, text=True,
                     cwd="/root/fnm_tmp").stdout
for l in out.splitlines():
    m = re.match(r"\s+\+0x([0-9a-f]+)\s+.*\s(\w+)$", l)
    if m:
        members[int(m.group(1), 16)] = m.group(2)
CM = 0x2800680
# ResetAllCheats writes 0x0, 0x20-0x30, 0x50-0x51, 0x70-0x78 (0x73/0x74/0x78 from the force flags 0x79-0x7b),
# 0x7c-0x91, 0x94, 0x98-0x9c. It leaves 0x79-0x7b, 0x9d and 0x9e alone.
RESET = {0x0, 0x20, 0x24, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x30, 0x50, 0x51} | set(range(0x70, 0x79)) | \
        set(range(0x7c, 0x92)) | {0x94} | set(range(0x98, 0x9d))
seen = set()
for l in open("/root/fnm_tmp/cmdargs/consolevars.tsv"):
    name, typ, va, var, init, lo, hi, fn = l.rstrip("\n").split("\t")
    if (name, va) in seen:
        continue
    seen.add((name, va))
    note = ""
    if va:
        v = int(va, 16)
        if CM <= v < CM + 160:
            off = v - CM
            note = "`CCheatManager::%s`" % members.get(off, "+0x%x" % off)
            if off in RESET:
                note += ", reset when a game starts or loads"
            # g_CheatManager's own static initializer runs ResetAllCheats before the command line
            init = {0x72: "true", 0x8a: "true", 0x94: "-1", 0x2c: "3"}.get(off, init)
        elif var and not var.startswith("?_pDatabase") and "+0x" not in var:
            var = re.sub(r"^(public|private|protected): ", "", var)
            m = re.match(r"\?(\w+)@(\w+)@@", var)
            if m and m.group(2) and not m.group(2).startswith("3"):
                var = "%s::%s" % (m.group(2), m.group(1))
            else:
                m = re.match(r"\?(\w+)@@3", var)
                if m:
                    var = m.group(1)
            note = "`%s`" % var.split(" ")[-1]
    num = lambda s: s.replace("-1e+06", "-1000000").replace("1e+06", "1000000")
    rng = "%s .. %s" % (num(lo), num(hi)) if (lo or hi) else ""
    print("| `%s` | %s | %s | %s | %s |" % (name, typ, init, rng, note))
