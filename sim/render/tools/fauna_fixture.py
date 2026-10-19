#!/usr/bin/env python3
# fauna_fixture.py IN.sav OUT.sav: the creature designer's test save: country 0 gets
# tech_alien_cloning (can_use_artificial_breeding), tech_controlled_mutations and _2 (can_use_mutations,
# mutation_slots_add 3 + 3) and the unique mutation techs.
import sys
import zipfile

TECHS = ["tech_alien_cloning", "tech_controlled_mutations", "tech_controlled_mutations_2",
         "tech_unique_mutation_space_amoeba", "tech_unique_mutation_tiyanki"]

src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)
gs = zin.read("gamestate").decode("utf-8", "surrogateescape")
L = gs.split("\n")
# the top-level country block, then its "\t0={" entry, then that entry's tech_status
top = L.index("country=")
c0 = next(i for i in range(top + 1, len(L)) if L[i] == "\t0=")
ts = next(i for i in range(c0 + 1, len(L)) if L[i] == "\t\ttech_status=") + 1
assert L[ts] == "\t\t{"
have = set()
i = ts + 1
while L[i] != "\t\t}":
    s = L[i].strip()
    if s.startswith("technology="):
        have.add(s.split("=", 1)[1].strip('"'))
    i += 1
add = []
for t in TECHS:
    if t not in have:
        add += ['\t\t\ttechnology="%s"' % t, "\t\t\tlevel=1"]
L[ts + 1:ts + 1] = add
# the grand archive module's culled DNA (the creature picker's categories) [I: the block's key]
assert L[c0 + 1] == "\t{"
L[c0 + 2:c0 + 2] = ["\t\tgrand_archive_country_module=", "\t\t{", "\t\t\tculled_dna_list=", "\t\t\t{",
                    "\t\t\t\tspace_amoeba=0", "\t\t\t\ttiyanki=1", "\t\t\t\tvoidworm=2", "\t\t\t}", "\t\t}"]
out = zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED)
out.writestr("meta", zin.read("meta"))
out.writestr("gamestate", "\n".join(L).encode("utf-8", "surrogateescape"))
out.close()
print("added", len(add) // 2, "techs at line", ts + 1)
