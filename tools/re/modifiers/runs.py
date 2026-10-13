import re,collections
names=[];cats=[]
for l in open('/root/fnm_tmp/modrep/modifiers.log',encoding='utf-8',errors='replace'):
    if l.startswith('- '):
        n,_,c=l[2:].rstrip('\n').partition(', Category: ')
        names.append(n);cats.append(c)
print(len(names))
def fam(n):
    return n.split('_')[0]
runs=[];start=571
for i in range(572,len(names)+1):
    if i==len(names) or fam(names[i])!=fam(names[start]):
        runs.append((start,i-1)); start=i
# merge small runs
for s,e in runs:
    if e-s+1>=15:
        print(s,e,e-s+1,names[s],'..',names[e])
    else:
        print('   small',s,e,e-s+1,names[s][:60],'..',names[e][:60])
