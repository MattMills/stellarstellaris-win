#!/usr/bin/env python3
# xrefs.py <full.asm> <out.tsv>: the references between databases the Linux build reads, from every call
# of NParserUtil::ReadKeyReference<DB> (looked up at once), ReadKeyReferenceUniform<DB> and
# ReadKeyReferenceDeferred<DB> / DeferredUniform (registered with the deferred resolver): the
# function that makes the call (its class: the reader) and the database read
import re, sys, collections
fn_re = re.compile(r"^[0-9a-f]+ <(.*)>:$")
call_re = re.compile(r"(?:call|jmp)\s+[0-9a-f]+ <([^+]*?NParserUtil::ReadKeyReference(Uniform|Deferred|DeferredUniform)?<(\w+)>[^+]*)>\s*$")
cur = None
out = collections.Counter()
for line in open(sys.argv[1], errors="replace"):
    m = fn_re.match(line)
    if m:
        cur = m.group(1)
        continue
    if cur and "ReadKeyReference" in line and "NParserUtil::ReadKeyReference" not in cur:
        m = call_re.search(line)
        if m:
            kind = {"": "now", None: "now", "Uniform": "now", "Deferred": "deferred", "DeferredUniform": "deferred"}[m.group(2) or ""]
            # the reader: the class of the calling function (template arguments and parameters dropped)
            name = re.sub(r"\(.*$", "", cur)
            segs = [s for s in re.split(r"::", re.sub(r"<[^<>]*(<[^<>]*>[^<>]*)*>", "", name)) if s]
            reader = segs[-2] if len(segs) >= 2 else segs[0] if segs else "?"
            out[(reader, m.group(3), kind, cur[:120])] += 1
with open(sys.argv[2], "w") as f:
    f.write("reader\tdatabase\tkind\tcalls\tfunction\n")
    for (reader, db, kind, fn), n in sorted(out.items()):
        f.write("%s\t%s\t%s\t%d\t%s\n" % (reader, db, kind, n, fn))
print(len(out), "call sites (grouped)")
