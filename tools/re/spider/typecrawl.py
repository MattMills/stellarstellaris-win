#!/usr/bin/env python3
# typecrawl.py <types.pickle> <out_dir> [root ...] : every type reachable from the roots (default
# CGameStateDatabase) in the PDB's type records (pdbtype.py's pickle of `llvm-pdbutil dump
# -types`): each class's members, followed recursively through embedded members, base classes,
# pointers, references, arrays and modifiers. Through a pointer, the classes derived from the one
# pointed to are reached too (a CTrigger * may hold any trigger).
#
# Templates: an instantiation (TPdxRefDatabase<CPlanet,8>, CPdxArray<CTrigger *,int>) is its
# template (TPdxRefDatabase<>, CPdxArray<>) with arguments; code that walks or builds objects is
# written once per template, the arguments as parameters.
#
# Writes <out_dir>/types.tsv (class, template, arguments, size, depth, reached from, vtable, bases,
# members, derived, persisted: has ReadMember / WriteMembers), <out_dir>/members.tsv (class,
# offset, member, type), <out_dir>/templates.tsv (template, instantiations, example, members of
# the example) and a summary on stderr.
import os, pickle, re, sys
from collections import Counter, defaultdict, deque

types_path, out_dir = sys.argv[1:3]
roots = sys.argv[3:] or ["CGameStateDatabase"]
# @file: the roots listed in a file, one a line
roots = [r for arg in roots for r in ([l.strip() for l in open(arg[1:]) if l.strip()] if arg.startswith("@") else [arg])]
recs, byname = pickle.load(open(types_path, "rb"))

SIMPLE = {0x03: "void", 0x10: "char", 0x20: "uint8", 0x68: "int8", 0x70: "char", 0x11: "short", 0x21: "uint16",
          0x74: "int", 0x75: "uint", 0x12: "long", 0x22: "ulong", 0x13: "int64", 0x23: "uint64", 0x76: "int64",
          0x77: "uint64", 0x40: "float", 0x41: "double", 0x30: "bool", 0x71: "wchar", 0x7a: "char16", 0x7b: "char32"}
CLASSY = ("LF_CLASS", "LF_STRUCTURE", "LF_UNION")

def text_of(ti):
    kind, head, body = recs[ti]
    return " ".join([head] + body)

def name_of(ti):
    m = re.search(r"`(.*)`", recs[ti][1])
    return m.group(1) if m else None

def ref(text, key):
    m = re.search(key + r" = (0x[0-9A-Fa-f]+)", text)
    return int(m.group(1), 16) if m else None

definitions = {}

def definition(name):
    """the type index of a class's full definition (not a forward reference), or None"""
    if name in definitions:
        return definitions[name]
    found = None
    for ti in byname.get(name, []):
        if recs[ti][0] in CLASSY and re.search(r"field list: 0x", text_of(ti)):
            found = ti
            break
    definitions[name] = found
    return found

def tname(ti, depth=0):
    if ti < 0x1000:
        return SIMPLE.get(ti & 0xFF, hex(ti)) + ("*" if ti & 0xF00 else "")
    r = recs.get(ti)
    if r is None or depth > 8:
        return hex(ti)
    kind = r[0]
    if kind in CLASSY or kind == "LF_ENUM":
        return name_of(ti) or hex(ti)
    text = text_of(ti)
    if kind == "LF_POINTER":
        inner = ref(text, "referent")
        mode = "&" if "mode = ref" in text or "mode = rvalue ref" in text else "*"
        return (tname(inner, depth + 1) if inner is not None else "?") + mode
    if kind == "LF_MODIFIER":
        inner = ref(text, "referent")
        return ("const " if "const" in text else "") + (tname(inner, depth + 1) if inner is not None else "?")
    if kind == "LF_ARRAY":
        inner = ref(text, "element type")
        s = re.search(r"size: (\d+)", text)
        return "%s[%s bytes]" % (tname(inner, depth + 1) if inner is not None else "?", s.group(1) if s else "?")
    if kind in ("LF_PROCEDURE", "LF_MFUNCTION"):
        return "fn"
    if kind == "LF_BITFIELD":
        return "bitfield(%s)" % tname(ref(text, "type") or 0x74, depth + 1)
    return kind

def classes_in(ti, via_pointer=False, depth=0):
    """the classes a member of type ti leads to: [(class name, through a pointer)]"""
    if ti < 0x1000 or depth > 8:
        return []
    r = recs.get(ti)
    if r is None:
        return []
    kind = r[0]
    if kind in CLASSY:
        n = name_of(ti)
        return [(n, via_pointer)] if n else []
    text = text_of(ti)
    if kind == "LF_POINTER":
        inner = ref(text, "referent")
        return classes_in(inner, True, depth + 1) if inner is not None else []
    if kind == "LF_MODIFIER":
        inner = ref(text, "referent")
        return classes_in(inner, via_pointer, depth + 1) if inner is not None else []
    if kind == "LF_ARRAY":
        inner = ref(text, "element type")
        return classes_in(inner, via_pointer, depth + 1) if inner is not None else []
    if kind == "LF_BITFIELD":
        return []
    return []

def split_template(name):
    '''(template, [arguments]): the outermost template argument lists of a name replaced by <>
    (nested names keep theirs: TPdxRefDatabase<CPlanet,8>::LookupElement -> TPdxRefDatabase<>::LookupElement)'''
    out, args, depth, current = [], [], 0, ''
    for c in name:
        if c == '<':
            if depth == 0:
                out.append('<')
                current = ''
            else:
                current += c
            depth += 1
        elif c == '>':
            depth -= 1
            if depth == 0:
                args.append(current.strip())
                out.append('>')
            else:
                current += c
        elif c == ',' and depth == 1:
            args.append(current.strip())
            current = ''
        elif depth == 0:
            out.append(c)
        else:
            current += c
    return ''.join(out), [a for a in args if a]

layouts = {}

def layout(name):
    if name in layouts:
        return layouts[name]
    ti = definition(name)
    if ti is None:
        layouts[name] = None
        return None
    text = text_of(ti)
    size = re.search(r"sizeof (\d+)", text)
    lines = recs[int(re.search(r"field list: (0x[0-9A-Fa-f]+)", text).group(1), 16)][2]
    bases, members, methods, vtable = [], [], set(), False
    for i, l in enumerate(lines):
        m = re.search(r"- LF_MEMBER \[name = `(.*)`, Type = (0x[0-9A-Fa-f]+).*offset = (\d+)", l)
        if m:
            members.append((int(m.group(3)), m.group(1), int(m.group(2), 16)))
            continue
        if "- LF_BCLASS" in l:
            t = re.search(r"type = (0x[0-9A-Fa-f]+), offset = (\d+)", l + " " + (lines[i + 1] if i + 1 < len(lines) else ""))
            if t:
                bases.append((int(t.group(2)), tname(int(t.group(1), 16))))
            continue
        if "- LF_VFUNCTAB" in l:
            vtable = True
            continue
        m = re.search(r"- LF_(ONE)?METHOD \[name = `(.*)`", l)
        if m:
            methods.add(m.group(2))
    result = {"size": int(size.group(1)) if size else 0, "bases": bases, "members": sorted(members),
              "methods": methods, "vtable": vtable}
    layouts[name] = result
    return result

# every class's direct bases, for "derived from"
derived = defaultdict(set)
for name in list(byname):
    ti = definition(name)
    if ti is None:
        continue
    text = text_of(ti)
    m = re.search(r"field list: (0x[0-9A-Fa-f]+)", text)
    fl = int(m.group(1), 16) if m else None
    if fl is None or fl not in recs:
        continue
    lines = recs[fl][2]
    for i, l in enumerate(lines):
        if "- LF_BCLASS" in l:
            t = re.search(r"type = (0x[0-9A-Fa-f]+)", l + " " + (lines[i + 1] if i + 1 < len(lines) else ""))
            if t:
                derived[tname(int(t.group(1), 16))].add(name)

def all_derived(name, seen=None):
    seen = seen if seen is not None else set()
    for d in derived.get(name, ()):
        if d not in seen:
            seen.add(d)
            all_derived(d, seen)
    return seen

reached = {}
queue = deque()
for r in roots:
    reached[r] = (0, "(root)")
    queue.append(r)
while queue:
    name = queue.popleft()
    depth, _ = reached[name]
    l = layout(name)
    if l is None:
        continue
    nexts = []
    for off, base in l["bases"]:
        nexts.append((base, "base of " + name))
    for off, mname, mti in l["members"]:
        for cls, through_pointer in classes_in(mti):
            nexts.append((cls, "%s.%s" % (name, mname)))
            if through_pointer:
                for d in all_derived(cls):
                    nexts.append((d, "%s.%s (derived from %s)" % (name, mname, cls)))
    for cls, how in nexts:
        if cls and cls not in reached:
            reached[cls] = (depth + 1, how)
            queue.append(cls)

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "types.tsv"), "w") as f, open(os.path.join(out_dir, "members.tsv"), "w") as g:
    f.write("class\ttemplate\targuments\tsize\tdepth\treached_from\tvtable\tbases\tmembers\tderived\tpersisted\n")
    g.write("class\toffset\tmember\ttype\n")
    for name, (depth, how) in sorted(reached.items(), key=lambda kv: (kv[1][0], kv[0])):
        l = layout(name)
        if l is None:
            t, a = split_template(name)
            f.write("%s\t%s\t%s\t\t%d\t%s\t\t\t\t\tno definition\n" % (name, t, " | ".join(a), depth, how))
            continue
        persisted = ",".join(m for m in ("ReadMember", "WriteMembers", "Read", "Write") if m in l["methods"])
        t, a = split_template(name)
        f.write("%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\n" % (name, t, " | ".join(a), l["size"], depth, how, "yes" if l["vtable"] else "",
            ";".join("%s@%d" % (b, o) for o, b in l["bases"]), len(l["members"]), len(derived.get(name, ())), persisted))
        for off, mname, mti in l["members"]:
            g.write("%s\t%d\t%s\t%s\n" % (name, off, mname, tname(mti)))

defined = [n for n in reached if layout(n)]
templates = {}
for n in defined:
    t, a = split_template(n)
    templates.setdefault(t, []).append(n)
with open(os.path.join(out_dir, "templates.tsv"), "w") as h:
    h.write("template\tinstantiations\texample\tmembers\n")
    for t, names in sorted(templates.items(), key=lambda kv: -len(kv[1])):
        ex = names[0]
        h.write("%s\t%d\t%s\t%s\n" % (t, len(names), ex, "; ".join("%s@%d" % (m, o) for o, m, _ in layout(ex)["members"][:12])))
plain = sum(1 for t in templates if "<" not in t)
by_depth = Counter(reached[n][0] for n in defined)
print("from %s: %d types reached, %d defined (%d with a vtable, %d persisted: ReadMember or WriteMembers), %d members" % (
    ", ".join(roots), len(reached), len(defined), sum(1 for n in defined if layouts[n]["vtable"]),
    sum(1 for n in defined if {"ReadMember", "WriteMembers"} & layouts[n]["methods"]),
    sum(len(layouts[n]["members"]) for n in defined)), file=sys.stderr)
print("templates: %d types are %d distinct shapes (%d plain classes, %d templates with %d instantiations)" % (
    len(defined), len(templates), plain, len(templates) - plain, len(defined) - plain), file=sys.stderr)
for t, names in sorted(templates.items(), key=lambda kv: -len(kv[1]))[:15]:
    print("  %-60s %d" % (t[:60], len(names)), file=sys.stderr)
print("by depth: " + ", ".join("%d: %d" % kv for kv in sorted(by_depth.items())), file=sys.stderr)
for kind, pat in (("databases", r"Database"), ("triggers", r"Trigger$"), ("effects", r"Effect$"), ("modifier nodes", r"ModifierNode")):
    print("  %s: %d" % (kind, sum(1 for n in defined if re.search(pat, n))), file=sys.stderr)
