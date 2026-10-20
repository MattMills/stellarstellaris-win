#!/usr/bin/env python3
"""summary.py RUN_DIR [RUN_DIR2]: a row per measurement of a profiling run (run.sh): the bench
before each `prof report NAME.prof`: the CPU part a frame (input, update, scene, upload: the UI
thread's work in the window) mean, p50, p99 and max in ms, the scenes built, the GPU's p50 (on
lavapipe: llvmpipe's rasterising) and the spans with the most self time a frame. With a second
run, the two runs' CPU means side by side (before, after).
"""
import os
import re
import sys


def rows(d):
    lines = open(os.path.join(d, "out.txt"), encoding="utf-8", errors="replace").read().split("\n")
    out, last = {}, None
    for line in lines:
        if line.startswith("ok bench"):
            last = line
        m = re.match(r"> prof report (\S+)", line)
        if m and last:
            name = os.path.basename(m.group(1))[: -len(".prof")]
            cpu = re.search(r"\(input, update, scene, upload\) mean ([\d.]+) p50 ([\d.]+) p99 ([\d.]+) max ([\d.]+)", last)
            built = re.search(r"; (\d+) scenes built", last)
            gpu = re.search(r"the GPU.s p50 ([\d.]+)", last)
            top = re.search(r"the most a frame \(self ms\): (.*)$", last)
            top = ", ".join(x for x in (top.group(1) if top else "").split(", ") if not x.startswith("gpu frame"))
            out[name] = (cpu.groups() if cpu else ("?",) * 4, built.group(1) if built else "?", gpu.group(1) if gpu else "?", top)
            last = None
    return out


def main():
    a = rows(sys.argv[1])
    if len(sys.argv) > 2:
        b = rows(sys.argv[2])
        print("%-32s %10s %10s %8s   %10s %10s" % ("measurement", "cpu mean", "after", "ratio", "p99", "after"))
        for k, (ca, _, _, _) in a.items():
            if k not in b:
                continue
            cb = b[k][0]
            try:
                r = "%.1fx" % (float(ca[0]) / max(float(cb[0]), 0.005))
            except ValueError:
                r = "?"
            print("%-32s %10s %10s %8s   %10s %10s" % (k, ca[0], cb[0], r, ca[2], cb[2]))
        return
    print("%-32s %8s %7s %8s %8s %6s %8s  %s" % ("measurement", "cpu mean", "p50", "p99", "max", "built", "gpu p50", "most self ms a frame"))
    for k, (c, built, gpu, top) in a.items():
        print("%-32s %8s %7s %8s %8s %6s %8s  %s" % (k, c[0], c[1], c[2], c[3], built, gpu, top[:140]))


if __name__ == "__main__":
    main()
