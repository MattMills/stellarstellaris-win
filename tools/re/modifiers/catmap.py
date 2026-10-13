import re,subprocess
tok={}
for l in open('/root/fnm_tmp/tokens452.tsv',encoding='utf-8',errors='replace'):
    p=l.rstrip('\n').split('\t')
    if len(p)>=2 and p[0].isdigit(): tok[int(p[0])]=p[1]
out=subprocess.run(['python3','/root/fnm_tmp/annotate.py','35c810'],capture_output=True,text=True,cwd='/root/fnm_tmp').stdout
lines=out.split('\n')
print(lines[0]); print(lines[1][:300])
for l in lines[3:]:
    m=re.search(r'cmp (\w+), (\d+)\s*$',l.strip())
    if m and int(m.group(2))>20: print(l.split()[0], 'cmp', m.group(1), m.group(2), tok.get(int(m.group(2)),'?'))
    m=re.search(r'mov (e\w+), (\d+)\s*$',l.strip())
    if m: print(l.split()[0],'mov',m.group(1),m.group(2))
