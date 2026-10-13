import struct,sys
sys.argv=[sys.argv[0]]+sys.argv[1:]
exec(open('/root/fnm_tmp/modrep/rstr.py').read().split('for a in sys.argv')[0])
names={}
for l in open('/root/fnm_tmp/names452.tsv',encoding='utf-8',errors='replace'):
    r,_,n=l.rstrip('\n').partition('\t'); names[int(r,16)]=n
import sys as S
rva=int(S.argv[1],16); n=int(S.argv[2])
b=rd(rva,8*n)
for i in range(n):
    p=struct.unpack_from('<Q',b,8*i)[0]-0x140000000
    nm=names.get(p,'?')
    nm=' | '.join(x for x in nm.split(' | ') if 'Modifier' in x)[:150] or nm[:150]
    print('+%3d  %x  %s'%(8*i,p,nm))
