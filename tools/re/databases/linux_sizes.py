#!/usr/bin/env python3
# linux_sizes.py <full.asm> <out.tsv>: for every TSingleObjectGameDatabase<DB, T, b> of the Linux build,
# the object size (the calloc in its ReadNewEntry / LoadFromReader / CreateEntryInArray) and the
# database size (the calloc in TGameDatabase<DB>::CreateInstance)
import re, sys
fn_re = re.compile(r"^([0-9a-f]+) <(.*)>:$")
obj_fn = re.compile(r"^TSingleObjectGameDatabase<(\w+), (\w+), (true|false)>::(ReadNewEntry|LoadFromReader|CreateEntryInArray)\(")
ext_fn = re.compile(r"^TExtendableObjectGameDatabase<(\w+), (\w+), (true|false)>::(ReadNewEntry|LoadFromReader|CreateEntryInArray)\(")
db_fn = re.compile(r"^TGameDatabase<(\w+)>::CreateInstance\(\)$")
cur, kind, last_esi = None, None, None
objs, dbs, flags = {}, {}, {}
for line in open(sys.argv[1], errors="replace"):
    m = fn_re.match(line)
    if m:
        name = m.group(2)
        cur, kind, last_esi = None, None, None
        mo = obj_fn.match(name) or ext_fn.match(name)
        if mo:
            cur, kind = (mo.group(1), mo.group(2)), "obj"
            flags[mo.group(1)] = mo.group(3)
        else:
            md = db_fn.match(name)
            if md:
                cur, kind = md.group(1), "db"
        continue
    if cur is None:
        continue
    m = re.search(r"mov\s+\$0x([0-9a-f]+),%esi", line)
    if m:
        last_esi = int(m.group(1), 16)
        continue
    if "<calloc@plt>" in line and last_esi:
        if kind == "obj":
            objs.setdefault(cur, last_esi)
        else:
            dbs.setdefault(cur, last_esi)
        last_esi = None
with open(sys.argv[2], "w") as f:
    f.write("database\tobject\tlookup\tsizeof_object_linux\tsizeof_db_linux\n")
    names = sorted(set([k[0] for k in objs]) | set(dbs))
    by_db = {k[0]: (k[1], v) for k, v in objs.items()}
    for n in names:
        o = by_db.get(n, ("", ""))
        f.write("%s\t%s\t%s\t%s\t%s\n" % (n, o[0], flags.get(n, ""), o[1], dbs.get(n, "")))
print(len(objs), "object sizes,", len(dbs), "database sizes")
