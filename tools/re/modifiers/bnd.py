import re
names=[]
for l in open('/root/fnm_tmp/modrep/modifiers.log',encoding='utf-8',errors='replace'):
    if l.startswith('- '):
        n,_,c=l[2:].rstrip('\n').partition(', Category: '); names.append((n,c))
def shape(n):
    # strip well-known tails
    n=re.sub(r'_(add|mult|produces|upkeep|cost|max|build_speed|weapon_damage|fire_rate|speed|stealth|skill|difficulty)(_.*)?$','',n)
    return n.split('_')[0]
regions=[(700,1110),(8375,8540),(41395,41480),(44375,44425),(44640,44665),(44740,44765),(44930,44945),(45095,45235),(45560,45583)]
for a,b in regions:
    prev=None
    for i in range(a,min(b,len(names))):
        s=shape(names[i][0])
        if s!=prev: print(i,names[i][0],'|',names[i][1][:50]); prev=s
    print('---')
