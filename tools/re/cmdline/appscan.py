#!/usr/bin/env python3
# reads `grep -A N "# 0x143144ba0" full452.asm` on stdin; tracks reg loaded from app instance and prints uses with given offsets
import sys,re,bisect
offs=set(int(x) for x in sys.argv[1].split(","))
rv=[];nm=[]
for l in open("/root/fnm_tmp/cmdargs/names452_split.tsv"):
    a,b=l.rstrip("\n").split("\t",1); rv.append(int(a,16)); nm.append(b)
idx=sorted(range(len(rv)),key=lambda i:rv[i]); rv=[rv[i] for i in idx]; nm=[nm[i] for i in idx]
def fn(va):
    i=bisect.bisect_right(rv,va-0x140000000)-1; return "%s+0x%x"%(nm[i],va-0x140000000-rv[i])
regs=set()
for line in sys.stdin:
    if line.startswith("--"): regs=set(); continue
    m=re.match(r"\s*([0-9a-f]+):\s+(\S+)\s*(.*)",line)
    if not m: continue
    va=int(m.group(1),16); op=m.group(2); args=m.group(3)
    if "0x143144ba0" in args and op=="mov":
        r=args.split(",")[0].strip(); regs={r}; continue
    for r in list(regs):
        for mm in re.finditer(r"\[%s \+ (\d+)\]"%r,args):
            if int(mm.group(1)) in offs: print("%s\t%x\t%s %s"%(fn(va)[:120],va,op,args[:90]))
    # kill if reg overwritten
    dst=args.split(",")[0].strip()
    if dst in regs and op not in ("cmp","test") and not dst.startswith("["): regs.discard(dst)
