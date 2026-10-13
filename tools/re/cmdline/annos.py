#!/usr/bin/env python3
# annos.py [--refs] <function name or hex rva>...: annotate.py, plus the strings the code points at
# (C strings in .rdata/.data shown inline as "...").
import re, struct, sys
sys.argv[0] = "annotate.py"
EXE = "/zpool0/share/stellaris_backups_gog/4.5.2/windows/depots/stellaris.exe"
BASE = 0x140000000
blob = open(EXE, "rb").read()
pe = struct.unpack_from("<I", blob, 0x3c)[0]
nsec = struct.unpack_from("<H", blob, pe + 6)[0]
optsz = struct.unpack_from("<H", blob, pe + 20)[0]
secs = []
for i in range(nsec):
    o = pe + 24 + optsz + 40 * i
    name = blob[o:o + 8].rstrip(b"\0").decode()
    vsize, va, rsize, raw = struct.unpack_from("<IIII", blob, o + 8)
    secs.append((name, va, max(vsize, rsize), raw, rsize))

def cstr(rva):
    for name, va, size, raw, rsize in secs:
        if name == ".text":
            continue
        if va <= rva < va + rsize:
            off = raw + rva - va
            end = blob.find(b"\0", off, off + 400)
            if end <= off:
                return None
            s = blob[off:end]
            if all(32 <= c < 127 or c in (9, 10, 13) for c in s) and len(s) >= 2:
                return s.decode()
            # UTF-16LE
            w = []
            k = off
            while k + 1 < len(blob) and len(w) < 200:
                c = struct.unpack_from("<H", blob, k)[0]
                if c == 0:
                    break
                if not (32 <= c < 127):
                    return None
                w.append(chr(c)); k += 2
            return ("L" + "".join(w)) if len(w) >= 2 else None
    return None

src = open("/root/fnm_tmp/annotate.py").read()
src = src.replace('notes = [s for s in (sym(int(h, 16) - BASE) for h in re.findall(r"0x(1[0-9a-f]{8})\\b", text)) if s]',
                  'notes = [s for s in (note(int(h, 16) - BASE) for h in re.findall(r"0x(1[0-9a-f]{8})\\b", text)) if s]')
src = src.replace('text = re.sub(r"\\s+", " ", m.group(2)).strip()',
                  'text = re.sub(r"\\s*<[^>]*>", "", re.sub(r"\\s+", " ", m.group(2))).strip()')
src = src.replace('def find(arg):\n',
                  'def find(arg):\n'
                  '    if re.fullmatch(r"[0-9a-f]+-[0-9a-f]+", arg):\n'
                  '        a, b = (int(x, 16) for x in arg.split("-")); fname.setdefault(a, "range"); fend[a] = b; return [a]\n')
assert "note(" in src and '<[^>]*>' in src and "fullmatch" in src

def note(rva):
    s = cstr(rva)
    n = sym(rva)
    if s is not None and (n is None or "+0x" in n or n.startswith("??_C@") or n.startswith(chr(34))):
        return repr(s)
    return n
exec(compile(src, "annotate.py", "exec"))
