import re,collections
names=[]
for l in open('/root/fnm_tmp/modrep/modifiers.log',encoding='utf-8',errors='replace'):
    if l.startswith('- '):
        n,_,c=l[2:].rstrip('\n').partition(', Category: '); names.append((n,c))
for i in range(44740,44750): print(i,names[i][0])
def cnt(a,b,pats):
    c=collections.Counter()
    for i in range(a,b+1):
        n=names[i][0]
        for p in pats:
            if re.search(p,n): c[p]+=1; break
        else: c['other']+=1
    return c
print('eco',cnt(1106,8463,[r'_produces_add$',r'_produces_mult$',r'_upkeep_add$',r'_upkeep_mult$',r'_cost_add$',r'_cost_mult$',r'_logistics_mult$']).most_common())
# eco without resource: names X_produces_mult etc where no resource token
res=['energy','minerals','food','physics_research','society_research','engineering_research','influence','unity','trade','consumer_goods','alloys','volatile_motes','exotic_gases','rare_crystals','sr_living_metal','sr_zro','sr_dark_matter','nanites','minor_artifacts','astral_threads','biomass','menace','integrity','advanced_logic','feral_insight','entropy_crystals']
c=collections.Counter()
for i in range(1106,8464):
    n=names[i][0]
    r=next((x for x in res if ('_'+x+'_') in n),None)
    c['per-resource' if r else 'all-resource']+=1
print(c)
print('jobs',cnt(41474,44382,[r'^job_.*_max_workforce_add$',r'^job_.*_max_workforce_mult$',r'^job_.*_automated_workforce_mult$',r'^job_.*_per_pop$',r'^job_.*_per_crime$',r'^job_.*_add$',r'^pop_.*_bonus_workforce_mult$',r'^pop_.*_workforce_mult$']).most_common())
print('shipsize kinds sample:')
ss=collections.Counter()
for i in range(9821,41402):
    n=names[i][0]
