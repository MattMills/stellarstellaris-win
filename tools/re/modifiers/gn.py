import sys,re
pat=re.compile(sys.argv[1])
lim=int(sys.argv[2]) if len(sys.argv)>2 else 300
n=0
for line in open('/root/fnm_tmp/names452.tsv',encoding='utf-8',errors='replace'):
    rva,_,names=line.rstrip('\n').partition('\t')
    for nm in names.split(' | '):
        if pat.search(nm):
            print(rva+'\t'+nm[:260]); n+=1
            if n>=lim: sys.exit()
