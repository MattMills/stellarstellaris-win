import re,sys,collections
tok={}
for l in open('/root/fnm_tmp/tokens452.tsv',encoding='utf-8',errors='replace'):
    p=l.rstrip('\n').split('\t')
    if len(p)>=2 and p[0].isdigit(): tok[int(p[0])]=p[1]
lines=open(sys.argv[1],encoding='utf-8',errors='replace').read().split('\n')
st={}; s=None; rows=[]
for l in lines:
    m=re.search(r'lea rdx, \[rip.*?; (?:"([^"]*)"|\?\?_C@_\w+@(\w+)@)',l)
    if m: s=m.group(1) or m.group(2)
    m=re.search(r'mov (?:byte|dword|qword) ptr \[rsp \+ (\d+)\], (\S+)',l)
    if m: st[int(m.group(1))]=m.group(2)
    m=re.search(r'(?:mov|xor) (r9b|r9d), (\S+)',l)
    if m: st['r9']= '0' if m.group(1)=='r9d' and 'xor' in l else m.group(2)
    m=re.search(r'mov edx, (\d+)',l)
    if m: st['edx']=m.group(1)
    m=re.search(r'xor edx, edx',l)
    if m: st['edx']='0'
    m=re.search(r'mov ecx, (\d+)',l)
    if m: st['ecx']=m.group(1)
    if 'AddDefinition' in l and 'call' in l:
        t=int(st.get('ecx','-1')) if st.get('ecx','x').isdigit() else -1
        rows.append(dict(type=st.get('edx'),token=tok.get(t,'?%s'%t),tag=s,pct=st.get('r9'),good=st.get(32),hidden=st.get(40),dec=st.get(48),neutral=st.get(56),nodiff=st.get(64),cat=st.get(72),cap01=st.get(80),a12=st.get(88),multmin=st.get(96),lockey=st.get(104)))
        st={}
print(len(rows))
import json
with open(sys.argv[2],'w') as f:
    for r in rows: f.write('\t'.join(str(r[k]) for k in ['type','token','tag','pct','good','hidden','dec','neutral','nodiff','cat','cap01','a12','multmin','lockey'])+'\n')
