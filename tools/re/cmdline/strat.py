#!/usr/bin/env python3
# strat.py <hex va or rva>...: the C string at each address of the GOG 4.5.2 exe
import struct, sys
EXE = "/zpool0/share/stellaris_backups_gog/4.5.2/windows/depots/stellaris.exe"
blob = open(EXE, "rb").read()
pe = struct.unpack_from("<I", blob, 0x3c)[0]
nsec = struct.unpack_from("<H", blob, pe + 6)[0]
optsz = struct.unpack_from("<H", blob, pe + 20)[0]
secs = []
for i in range(nsec):
    o = pe + 24 + optsz + 40 * i
    vsize, va, rsize, raw = struct.unpack_from("<IIII", blob, o + 8)
    secs.append((va, rsize, raw))
for a in sys.argv[1:]:
    rva = int(a, 16)
    if rva >= 0x140000000:
        rva -= 0x140000000
    for va, rsize, raw in secs:
        if va <= rva < va + rsize:
            off = raw + rva - va
            end = blob.find(b"\0", off, off + 4000)
            print("%x\t%r" % (rva, blob[off:end].decode("latin-1")))
            break
