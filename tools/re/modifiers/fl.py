import sys,re
ids=set(sys.argv[1:])
cur=None
hdr=re.compile(r'^\s+(0x[0-9A-F]+) \| (LF_\w+)')
out={}
with open('/root/fnm_tmp/types452.txt',encoding='utf-8',errors='replace') as f:
    for line in f:
        m=hdr.match(line)
        if m:
            cur = m.group(1) if (m.group(1) in ids and m.group(2)=='LF_FIELDLIST') else None
            if cur: out[cur]=[]
            if len(out)==len(ids) and cur is None and all(out.values()): break
            continue
        if cur and 'LF_ENUMERATE' in line:
            out[cur].append(line.strip()[len('- LF_ENUMERATE '):])
for k in sys.argv[1:]:
    v=out.get(k,[])
    print('==',k,len(v))
    print('\n'.join(v))
