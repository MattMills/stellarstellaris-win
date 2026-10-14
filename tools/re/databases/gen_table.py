#!/usr/bin/env python3
# gen_table.py <out.md>: the database table of docs/databases.md from the RE tables in this directory
# (dbtable.tsv, members.tsv from the GOG PDB; linux_sizes.tsv, folders.tsv from the Linux build;
# census.tsv from the headless game; database_*.tsv from the Windows runtime's caches)
import csv, os, sys, collections
H = os.environ.get("DBRE_DIR") or os.path.dirname(os.path.abspath(__file__))
def tsv(name, header=True):
    rows = list(csv.reader(open(os.path.join(H, name)), delimiter="\t"))
    return rows
db = {r[0]: r for r in tsv("dbtable.tsv")[1:]}
hdr = tsv("dbtable.tsv")[0]
col = {h: i for i, h in enumerate(hdr)}
order = [l.strip() for l in open(os.path.join(H, "database_order.tsv")) if l.strip()]
lin = {r[0]: r for r in tsv("linux_sizes.tsv")[1:]}
census = {r[0]: r[3] for r in tsv("census.tsv")[1:] if len(r) > 3}
folders = {r[0]: r[1] for r in tsv("folders.tsv") if len(r) > 1 and "%" not in r[1] and len(r[1].strip("/")) > 0}
deps = collections.defaultdict(list)
for r in tsv("database_dependencies.tsv"):
    if len(r) > 1:
        deps[r[0]].append(r[1])
secs = {}
for r in tsv("database_boot_order.tsv")[1:]:
    secs[r[0]] = float(r[2])
# Linux post-read functions and their sizes (nm -S -C): name -> bytes
psize = {}
for l in open(os.path.join(H, "postread_syms.txt")):
    p = l.rstrip("\n").split(" ", 3)
    if len(p) == 4:
        psize[p[3]] = int(p[1], 16)
def post_read_bytes(n, obj, kind):
    # the database's PostReadInit: its own, or the template's (which calls T::PostReadInit on each)
    own = psize.get("%s::PostReadInit()" % n)
    if own:
        return own, "own"
    for k, v in psize.items():
        if (k.startswith("TSingleObjectGameDatabase<%s, " % n) or k.startswith("TExtendableObjectGameDatabase<%s, " % n)) \
                and k.endswith("::PostReadInit()"):
            return v, "template"
    return None, None
def init_post_read(obj):
    return sum(v for k, v in psize.items() if k.startswith("%s::InitPostRead(" % obj)) if obj else 0
modw = set(l.strip() for l in open(os.path.join(H, "database_modifier_writers.tsv")) if l.strip())
flagw = set(l.strip() for l in open(os.path.join(H, "database_flag_writers.tsv")) if l.strip())
# the object class of each database -> the database; references by target
obj_db = {}
for n, r in db.items():
    if r[col["object"]]:
        obj_db.setdefault(r[col["object"]], n)
# bespoke databases: the element class of their main array
for r in tsv("members.tsv"):
    n, owner_obj, off, ty, name, cat = r[0], r[1], r[2], r[3], r[4], r[5]
    if db.get(n) and db[n][col["kind"]] == "bespoke" and ty.startswith("CPdxArray<") and name in ("_Array", "_Cultures", "_SpecialProjectTypes"):
        el = ty[len("CPdxArray<"):].split(",")[0].replace("const", "").replace("*", "").strip()
        obj_db.setdefault(el, n)
refs = collections.defaultdict(set)
for r in tsv("members.tsv"):
    n, ty, cat = r[0], r[3], r[5]
    t = ty.replace("const ", "")
    for cls, target in obj_db.items():
        if target != n and (("%s*" % cls) in t.replace(" ", "") or ("<%s*" % cls) in t.replace(" ", "")):
            refs[n].add(target.replace("Database", "").replace("DataBase", ""))
# the references read through NParserUtil::ReadKeyReference[Uniform|Deferred]<DB> (xrefs.tsv): by the
# reading class (the class of the calling function), the database it reads, at once or deferred
xr = collections.defaultdict(lambda: {"now": set(), "deferred": set()})
for r in tsv("xrefs.tsv")[1:]:
    xr[r[0]][r[2]].add(r[1].replace("Database", "").replace("DataBase", ""))
def short(name):
    return name.replace("Database", "").replace("DataBase", "")
out = open(sys.argv[1], "w")
out.write("| # | database | folder | kind | object | size MSVC / Linux | vanilla | members | script parts | refs to | own work | waits for | s |\n")
out.write("|---|---|---|---|---|---|---|---|---|---|---|---|---|\n")
for i, n in enumerate(order, 1):
    r = db.get(n)
    kind = r[col["kind"]]
    obj = r[col["object"]]
    l = lin.get(n)
    lookup = l[2] if l else ""
    k = {"single": "single", "extendable": "extendable", "bespoke": "own"}[kind]
    if kind != "bespoke" and r[col["mode"]] == "1":
        k += ", hashed"
    size = ""
    if kind != "bespoke":
        size = "%s / %s" % (r[col["sizeof_object"]], l[3] if l and l[3] else "?")
    else:
        size = "db %s / %s" % (r[col["sizeof_db"]], l[4] if l and l[4] else "?")
    cnt = census.get(n, "")
    mem = r[col["members"]]
    scr = []
    if kind == "bespoke":
        mem = "db: " + mem   # the database class's own members (its objects are other classes)
    else:
        for c, tag in (("trigger", "T"), ("effect", "E"), ("script_value", "V"), ("modifier", "M"), ("weight", "W")):
            v = r[col[c]]
            if v not in ("0", ""):
                scr.append("%s%s" % (v, tag))
    own = []
    dbm = r[col["db_methods"]].split(",") if r[col["db_methods"]] else []
    om = r[col["object_methods"]].split(",") if r[col["object_methods"]] else []
    if kind != "bespoke" and "Init" in dbm:
        own.append("Init")
    pb, how = post_read_bytes(n, obj, kind)
    if pb and pb > 1:
        own.append("PostRead %d B" % pb)
    ipr = init_post_read(obj)
    if ipr:
        own.append("InitPostRead %d B" % ipr)
    if n in modw:
        own.append("modifiers")
    if n in flagw:
        own.append("flags")
    direct = set(refs.get(n, []))
    x = xr.get(obj) if obj else None
    now = (x["now"] if x else set()) - {short(n)}
    dfr = (x["deferred"] if x else set()) - {short(n)}
    parts = []
    if now | direct:
        parts.append(", ".join(sorted(now | direct)))
    if dfr:
        parts.append("deferred: " + ", ".join(sorted(dfr)))
    rf = "; ".join(parts)
    dp = ", ".join(sorted(short(d) for d in deps.get(n, [])))
    s = secs.get(n)
    out.write("| %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" % (
        i, short(n), folders.get(n, "") or "", k, obj, size, cnt, mem, " ".join(scr), rf, ", ".join(own), dp,
        ("%.2f" % s) if s is not None else ""))
out.close()
print("ok", len(order))
