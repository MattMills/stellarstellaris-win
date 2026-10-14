#!/usr/bin/env python3
# dbtable.py [--members] [--types]: the 4.5.2 database table from the GOG PDB.
#   default: one line per database: name, kind, object class, sizeof db, sizeof object, member counts by category
#   --members: every member of every object class (db, object, offset, type, name, category)
#   --types: member types over all object classes, by count
import sys, os, re, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pdbx
HERE = os.environ.get("DBRE_DIR") or os.path.dirname(os.path.abspath(__file__))
names = [l.strip() for l in open(os.path.join(HERE, "database_order.tsv")) if l.strip()]

def template_args(t):
    m = re.match(r"^[\w:]+<(.*)>$", t)
    if not m:
        return []
    out, depth, cur = [], 0, ""
    for ch in m.group(1):
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    return out

# the database's object class: the T of TSingleObjectGameDatabase<DB, T, mode>
def object_class(db):
    for d, off, b in pdbx.chain(db):
        if b.startswith("TSingleObjectGameDatabase<") or b.startswith("TExtendableObjectGameDatabase<"):
            a = template_args(b)
            kind = "extendable" if b.startswith("TExtendable") else "single"
            return kind, a[1], a[2] if len(a) > 2 else ""
    return None, None, None

objs = {}
for n in names:
    kind, t, mode = object_class(n)
    if t:
        objs[t] = n

def strip(t):
    t = t.replace("const ", "").strip()
    return t

def category(t):
    s = strip(t)
    base = s.rstrip("*&").strip()
    if s.endswith("*") and base in objs:
        return "ref"
    m = re.match(r"^(CPdxArray|CPdxHybridArray|CPdxSmallArray|std::vector|CPdxUnorderedSet|CPdxSet|std::set)<(.*?)(,.*)?>$", s)
    if m and strip(m.group(2)).rstrip("*").strip() in objs:
        return "ref_list"
    if re.search(r"TPdxNullObject|CNullObj", s):
        return "other"
    if re.search(r"\bC\w*Trigger\b|CTrigger", s):
        return "trigger"
    if re.search(r"\bC\w*Effect\b|CEffect", s):
        return "effect"
    if re.search(r"CScriptableValue|CScriptValue|CVariableValue|CScriptedValue|CComplexValue|CScriptableLookupValue", s):
        return "script_value"
    if re.search(r"CModifier|CScriptedModifier|ModifierDefinition|CStaticModifier", s):
        return "modifier"
    if re.search(r"CMeanTimeToHappen|CAIChance|CWeight|MTTH|CAIMTTHChance", s):
        return "weight"
    if re.search(r"CString|CLocKey|CPdxStringView|CScriptableLocalization|CLocalization", s):
        return "string"
    if re.search(r"CToken|EToken|CFlag|CPdxIntegerFlags", s):
        return "token"
    if s in pdbx.SIZES or re.match(r"^(CFixedPoint|CFixedPoint64|CColor|CVector\w*<.*>|E\w+|bitfield:.*)$", s):
        return "scalar"
    if re.match(r"^(CPdxArray|CPdxHybridArray|std::vector|CPdxSmallArray)<", s):
        return "array"
    if re.match(r"^(CPdxUnorderedMap|std::map|CHashTable|CPdxMap|std::unordered_map|CPdxUnorderedSet|std::set)<", s):
        return "map"
    if s.endswith("*"):
        return "pointer"
    if s.startswith("CGfx") or "Gfx" in s or "Sprite" in s or "Entity" in s:
        return "gfx"
    return "other"

CATS = ["scalar", "string", "token", "ref", "ref_list", "trigger", "effect", "script_value", "modifier", "weight",
        "array", "map", "pointer", "gfx", "other"]

def own_members(t):
    """members of t and of its bases below TGameDatabaseObject (the object's own data)"""
    out = []
    for off, ty, nm, owner in pdbx.flat(t):
        if owner.startswith("TGameDatabaseObject<") or owner in ("CDatabaseObjectBase", "CGlobalDeferredDatabaseObject", "CPersistent"):
            continue
        out.append((off, ty, nm, owner))
    return out

mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode == "--types":
    cnt = collections.Counter()
    for t in objs:
        for off, ty, nm, owner in own_members(t):
            cnt[(category(ty), strip(ty))] += 1
    for (c, ty), k in cnt.most_common():
        print("%d\t%s\t%s" % (k, c, ty))
    sys.exit(0)
if mode == "--members":
    for n in names:
        kind, t, md = object_class(n)
        tt = t or n
        for off, ty, nm, owner in (own_members(t) if t else pdbx.flat(n)):
            print("%s\t%s\t0x%x\t%s\t%s\t%s\t%s" % (n, tt, off, ty, nm, category(ty), owner))
    sys.exit(0)
print("database\tkind\tobject\tmode\tsizeof_db\tsizeof_object\tmembers\t" + "\t".join(CATS) + "\tdb_methods\tobject_methods")
for n in names:
    kind, t, md = object_class(n)
    c = pdbx.cls(n)
    dbm = [m for m in (c["methods"] if c else []) if not m.startswith(("~", "operator", "__")) and m != n]
    if t:
        oc = pdbx.cls(t)
        mem = own_members(t)
        cnt = collections.Counter(category(ty) for _, ty, _, _ in mem)
        om = [m for m in (oc["methods"] if oc else []) if not m.startswith(("~", "operator", "__")) and m != t]
        print("%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s" % (n, kind, t, md, c["size"] if c else "?", oc["size"] if oc else "?",
              len(mem), "\t".join(str(cnt.get(k, 0)) for k in CATS), ",".join(dbm), ",".join(om)))
    else:
        mem = pdbx.flat(n) if c else []
        cnt = collections.Counter(category(ty) for _, ty, _, _ in mem)
        print("%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s" % (n, "bespoke", "", "", c["size"] if c else "?", "", len(mem),
              "\t".join(str(cnt.get(k, 0)) for k in CATS), ",".join(dbm), ""))
