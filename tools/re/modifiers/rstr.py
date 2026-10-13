import struct,sys
E='/zpool0/share/stellaris_backups_gog/4.5.2/windows/depots/stellaris.exe'
f=open(E,'rb'); d=f.read(4096)
pe=struct.unpack_from('<I',d,0x3c)[0]
ns=struct.unpack_from('<H',d,pe+6)[0]; osz=struct.unpack_from('<H',d,pe+20)[0]
st=pe+24+osz; secs=[]
for i in range(ns):
    o=st+40*i; va,vs,rs,rp=struct.unpack_from('<IIII',d,o+12-0+0) if False else (struct.unpack_from('<I',d,o+12)[0],struct.unpack_from('<I',d,o+8)[0],struct.unpack_from('<I',d,o+16)[0],struct.unpack_from('<I',d,o+20)[0])
    secs.append((va,vs,rs,rp))
def rd(rva,n):
    for va,vs,rs,rp in secs:
        if va<=rva<va+max(vs,rs):
            f.seek(rp+rva-va); return f.read(n)
for a in sys.argv[1:]:
    rva=int(a,16)
    if rva>=0x140000000: rva-=0x140000000
    b=rd(rva,200); s=b.split(b'\0')[0]
    print(hex(rva), repr(s.decode('latin1')))
