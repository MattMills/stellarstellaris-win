"""callsites.py <stellaris exe> <out.tsv> [function regex ...]

The direct calls (and tail jumps to other functions) inside the game functions whose demangled
names match the regexes, from objdump: one row per site, for headless.so's random-draw profiler
(HEADLESS_PROFILE). Columns: site offset, target offset, kind (call/jmp), caller, callee.

Calls into shared libraries (@plt) and to functions that do not return normally (throws, unwind,
terminate) are left out: the profiler hijacks the return address of each instrumented call.
"""
import re
import subprocess
import sys

DEFAULT = [
    r"^CGameState::HandleTurnTick\(",
    r"^CGameState::(MicroUpdate|ProcessAI|DailyUpdate|MonthlyUpdate|YearlyUpdate)\(\)$",
    r"^CTurnTickCommand::Execute\(\)$",
    r"^\(anonymous namespace\)::UpdateShipParallel\(",
]
SKIP = re.compile(r"@plt|_Unwind|__cxa|throw|terminate|__stack_chk|abort|exit\(|__clang_call_terminate")

exe, out = sys.argv[1], sys.argv[2]
pats = [re.compile(p) for p in (sys.argv[3:] or DEFAULT)]

funcs = []  # (addr, size, demangled)
nm = subprocess.run(["nm", "-S", "-C", "--defined-only", exe], capture_output=True, text=True).stdout
for line in nm.splitlines():
    parts = line.split(" ", 3)
    if len(parts) != 4 or parts[2] not in "tTwW":
        continue
    name = parts[3]
    if any(p.search(name) for p in pats):
        funcs.append((int(parts[0], 16), int(parts[1], 16), name))
funcs = sorted(set(funcs))

insn = re.compile(r"^\s*([0-9a-f]+):\s+(call|jmp)\s+([0-9a-f]+) <(.*)>\s*$")
rows = []
for addr, size, name in funcs:
    dis = subprocess.run(
        ["objdump", "-d", "-C", "--no-show-raw-insn", f"--start-address={addr:#x}",
         f"--stop-address={addr + size:#x}", exe],
        capture_output=True, text=True).stdout
    for line in dis.splitlines():
        m = insn.match(line)
        if not m:
            continue
        site, kind, target, callee = int(m.group(1), 16), m.group(2), int(m.group(3), 16), m.group(4)
        if "+0x" in callee or SKIP.search(callee):
            continue  # a jump inside a function, or a call that does not come back
        if kind == "jmp" and addr <= target < addr + size:
            continue
        rows.append((site, target, kind, name, callee))

with open(out, "w") as f:
    for site, target, kind, caller, callee in rows:
        f.write(f"{site:x}\t{target:x}\t{kind}\t{caller}\t{callee}\n")
print(f"{len(funcs)} functions, {len(rows)} sites -> {out}")
