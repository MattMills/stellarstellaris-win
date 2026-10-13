import re,collections
names=[];cats=[]
for l in open('/root/fnm_tmp/modrep/modifiers.log',encoding='utf-8',errors='replace'):
    if l.startswith('- '):
        n,_,c=l[2:].rstrip('\n').partition(', Category: ')
        names.append(n);cats.append([x.strip() for x in c.split(',')])
N=len(names)
print('total',N)
lab=collections.Counter(); labh=collections.Counter()
for i,c in enumerate(cats):
    for x in c:
        lab[x]+=1
        if i<571: labh[x]+=1
print('label counts (all / hardcoded 0..570):')
for k,v in lab.most_common(): print('  %-28s %6d %5d'%(k,v,labh[k]))
nc=collections.Counter(len(c) for c in cats); print('num labels per modifier',sorted(nc.items()))
suf=collections.Counter()
pats=['_produces_mult','_produces_add','_upkeep_mult','_upkeep_add','_cost_mult','_cost_add','_build_speed_mult','_max_add','_max_mult','_add','_mult']
for i,n in enumerate(names):
    if i<571: continue
    for p in pats:
        if n.endswith(p): suf[p]+=1; break
    else: suf['(other)']+=1
print('suffix counts (generated only, i>=571):',suf.most_common())
pre=collections.Counter()
for i,n in enumerate(names):
    if i<571: continue
    for p in ['shipsize_','shipclass_','job_','pop_cat_','pop_category_','planet_building_','planet_district_','district_','pc_','megastructure_','country_','planet_','ship_','starbase_','station_','leader_','armies_','army_','councilor_','damage_vs_country_type_','resolution_category_','category_','weapon_type_','op_cat_','hostile_op_cat_','pop_ethic_','pop_']:
        if n.startswith(p): pre[p]+=1; break
    else: pre['(other)']+=1
print('prefix counts (generated):',pre.most_common())
# economic-category style: names containing a resource token
