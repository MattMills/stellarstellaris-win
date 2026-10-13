"""callsites.py <stellaris exe> <out.tsv> [-f CALLER_REGEX ...] [--callee CALLEE_REGEX ... --asm FILE]

Call sites for headless.so's profiler (HEADLESS_PROFILE), one row per site: site offset, target
offset, kind (call/jmp), caller, callee (demangled).

  -f REGEX        every direct call (and tail jump to another function) inside the functions whose
                  names match (objdump of each function); default: the tick's phases
  --callee REGEX  every call, anywhere in the executable, to a function whose name matches; needs
                  --asm, a full `objdump -d -C --no-show-raw-insn` of the executable

Calls into shared libraries (@plt) and to functions that do not return normally (throws, unwind,
terminate) are left out: the profiler hijacks the return address of each instrumented call.
"""
import argparse
import re
import subprocess

DEFAULT = [
    r"^CGameState::HandleTurnTick\(",
    r"^CGameState::(MicroUpdate|ProcessAI|DailyUpdate|MonthlyUpdate|YearlyUpdate)\(\)$",
    r"^CTurnTickCommand::Execute\(\)$",
    r"^\(anonymous namespace\)::UpdateShipParallel\(",
]
SKIP = re.compile(r"@plt|_Unwind|__cxa|throw|terminate|__stack_chk|abort|exit\(|__clang_call_terminate")
INSN = re.compile(r"^\s*([0-9a-f]+):\s+(call|jmp)\s+([0-9a-f]+) <(.*)>\s*$")
HEAD = re.compile(r"^([0-9a-f]+) <(.*)>:$")

ap = argparse.ArgumentParser()
ap.add_argument("exe")
ap.add_argument("out")
ap.add_argument("-f", action="append", default=[])
ap.add_argument("--callee", action="append", default=[])
ap.add_argument("--asm")
a = ap.parse_args()
callers = [re.compile(p) for p in (a.f or ([] if a.callee else DEFAULT))]
callees = [re.compile(p) for p in a.callee]

rows = {}

funcs = []  # (addr, size, demangled)
if callers:
    nm = subprocess.run(["nm", "-S", "-C", "--defined-only", a.exe], capture_output=True, text=True).stdout
    for line in nm.splitlines():
        parts = line.split(" ", 3)
        if len(parts) != 4 or parts[2] not in "tTwW":
            continue
        if any(p.search(parts[3]) for p in callers):
            funcs.append((int(parts[0], 16), int(parts[1], 16), parts[3]))
    for addr, size, name in sorted(set(funcs)):
        dis = subprocess.run(
            ["objdump", "-d", "-C", "--no-show-raw-insn", f"--start-address={addr:#x}",
             f"--stop-address={addr + size:#x}", a.exe],
            capture_output=True, text=True).stdout
        for line in dis.splitlines():
            m = INSN.match(line)
            if not m:
                continue
            site, kind, target, callee = int(m.group(1), 16), m.group(2), int(m.group(3), 16), m.group(4)
            if "+0x" in callee or SKIP.search(callee):
                continue  # a jump inside a function, or a call that does not come back
            if kind == "jmp" and addr <= target < addr + size:
                continue
            rows[site] = (target, kind, name, callee)

if callees:
    if not a.asm:
        raise SystemExit("--callee needs --asm")
    caller = "?"
    with open(a.asm, errors="replace") as f:
        for line in f:
            h = HEAD.match(line)
            if h:
                caller = h.group(2)
                continue
            m = INSN.match(line)
            if not m:
                continue
            callee = m.group(4)
            if "+0x" in callee or SKIP.search(callee) or not any(p.search(callee) for p in callees):
                continue
            rows[int(m.group(1), 16)] = (int(m.group(3), 16), m.group(2), caller, callee)

with open(a.out, "w") as f:
    for site in sorted(rows):
        target, kind, caller, callee = rows[site]
        f.write(f"{site:x}\t{target:x}\t{kind}\t{caller}\t{callee}\n")
print(f"{len(funcs)} functions by caller, {len(rows)} sites -> {a.out}")
