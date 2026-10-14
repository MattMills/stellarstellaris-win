#!/usr/bin/env python3
# pdbx.py: a module over the GOG 4.5.2 PDB type dump (types452.pickle, from pdbtype.py):
#   cls(name) -> {name, size, bases: [(off, name)], members: [(off, type, name)], statics, methods}
# Run as a script: pdbx.py <class>... prints the class with its bases flattened.
import re, sys, pickle
CACHE = "/root/fnm_tmp/types452.pickle"
recs, byname = pickle.load(open(CACHE, "rb"))

SIMPLE = {0x03: "void", 0x10: "char", 0x20: "uint8", 0x68: "int8", 0x70: "char", 0x11: "short",
          0x21: "uint16", 0x12: "long", 0x22: "ulong", 0x13: "int64", 0x23: "uint64", 0x74: "int", 0x75: "uint",
          0x76: "int64", 0x77: "uint64", 0x40: "float", 0x41: "double", 0x30: "bool", 0x71: "wchar", 0x7a: "char16", 0x7b: "char32"}
SIZES = {"void": 0, "char": 1, "uint8": 1, "int8": 1, "short": 2, "uint16": 2, "long": 4, "ulong": 4, "int64": 8, "uint64": 8,
         "int": 4, "uint": 4, "float": 4, "double": 8, "bool": 1, "wchar": 2, "char16": 2, "char32": 4}

def tname(ti, depth=0):
    v = int(ti, 16)
    if v < 0x1000:
        s = SIMPLE.get(v & 0xFF, ti)
        return s + ("*" if v & 0xF00 else "")
    r = recs.get(v)
    if r is None or depth > 8:
        return ti
    kind, head, body = r
    n = re.search(r"`(.*)`", head)
    if kind in ("LF_CLASS", "LF_STRUCTURE", "LF_UNION", "LF_ENUM"):
        return n.group(1) if n else ti
    text = " ".join([head] + body)
    if kind == "LF_POINTER":
        m = re.search(r"referent = (0x[0-9A-F]+)", text)
        ref = "&" if "mode = ref" in text or "lvalue ref" in text else "*"
        return tname(m.group(1), depth + 1) + ref if m else "ptr"
    if kind == "LF_MODIFIER":
        m = re.search(r"referent = (0x[0-9A-F]+)", text)
        return ("const " if "const" in text else "") + tname(m.group(1), depth + 1) if m else "mod"
    if kind == "LF_ARRAY":
        m = re.search(r"element type = (0x[0-9A-F]+)", text)
        s = re.search(r"size: (\d+)", text)
        return "%s[%s bytes]" % (tname(m.group(1), depth + 1) if m else "?", s.group(1) if s else "?")
    if kind in ("LF_PROCEDURE", "LF_MFUNCTION"):
        return "fn"
    if kind == "LF_BITFIELD":
        m = re.search(r"type = (0x[0-9A-F]+)", text)
        return "bitfield:" + (tname(m.group(1), depth + 1) if m else "?")
    return kind

_cache = {}
def cls(name):
    if name in _cache:
        return _cache[name]
    out = None
    for ti in byname.get(name, []):
        kind, head, body = recs[ti]
        text = " ".join(body)
        fl = re.search(r"field list: (0x[0-9A-F]+)", text)
        size = re.search(r"sizeof (\d+)", text)
        if not fl:
            continue
        lines = recs[int(fl.group(1), 16)][2]
        members, methods, bases, statics, vbases = [], [], [], [], []
        for i, l in enumerate(lines):
            m = re.search(r"- LF_MEMBER \[name = `(.*)`, Type = (0x[0-9A-Fa-f]+).*offset = (\d+)", l)
            if m:
                members.append((int(m.group(3)), tname(m.group(2)), m.group(1)))
            if "- LF_BCLASS" in l:
                t = re.search(r"type = (0x[0-9A-F]+), offset = (\d+)", l + " " + (lines[i + 1] if i + 1 < len(lines) else ""))
                if t:
                    bases.append((int(t.group(2)), tname(t.group(1))))
            if "- LF_VBCLASS" in l or "- LF_IVBCLASS" in l:
                vbases.append(l.strip())
            m = re.search(r"- LF_(ONE)?METHOD \[name = `(.*)`", l)
            if m:
                methods.append(m.group(2))
            m = re.search(r"- LF_STMEMBER \[name = `(.*)`, type = (0x[0-9A-F]+)", l)
            if m:
                statics.append((tname(m.group(2)), m.group(1)))
        out = {"name": name, "size": int(size.group(1)) if size else None, "bases": bases, "members": sorted(members),
               "methods": list(dict.fromkeys(methods)), "statics": statics, "vbases": vbases}
        break
    _cache[name] = out
    return out

def flat(name, base_off=0, path=""):
    """every data member of name and its bases, at its offset in name: [(off, type, name, owner)]"""
    c = cls(name)
    if c is None:
        return []
    out = []
    for off, b in c["bases"]:
        out += flat(b, base_off + off, path)
    for off, t, n in c["members"]:
        out.append((base_off + off, t, n, name))
    return out

def chain(name, depth=0):
    """the base classes, depth first: [(depth, off, name)]"""
    c = cls(name)
    out = []
    if c is None:
        return out
    for off, b in c["bases"]:
        out.append((depth, off, b))
        out += chain(b, depth + 1)
    return out

if __name__ == "__main__":
    for n in sys.argv[1:]:
        c = cls(n)
        if c is None:
            print("no definition for", n)
            continue
        print("%s (sizeof %s)" % (n, c["size"]))
        for d, off, b in chain(n):
            print("  %sbase +0x%x %s" % ("  " * d, off, b))
        for off, t, m, owner in flat(n):
            print("  +0x%-6x %-70s %-30s %s" % (off, t[:70], m, "" if owner == n else "(" + owner + ")"))
        for t, m in c["statics"]:
            print("  static %-60s %s" % (t[:60], m))
        print("  methods: " + ", ".join(c["methods"]))
