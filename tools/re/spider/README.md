# The game's types, from the PDB, for a spider of the game's objects

The game has no RTTI. The GOG build's PDB names every class and vtable. These tools carry those
names to the running build (Steam), so that Lua can walk the game's objects and build them.

- `typecrawl.py <types.pickle> <out_dir> [roots]` finds every type reachable from
  `CGameStateDatabase` (the default root). It follows members, bases, pointers and arrays. Through
  a pointer to a base class it also reaches the classes derived from that base.
  - Each instantiation is grouped with its template (`CPdxArray<>`, `TPdxRefDatabase<>`, ...), so
    walking or building code is written once per template.
  - It writes `types.tsv`, `members.tsv` and `templates.tsv`.
  - 4.5.2: 11,105 types and 37,206 members; 5,933 instantiations of 419 templates, plus 5,121 plain
    classes.
- `vtrefs.py <full.asm> <names.tsv> <data.tsv> <out.tsv>` finds, for every vtable, the code that
  loads it (a constructor's `lea reg, [rip + vtable]`) and that lea's ordinal within its function.
- `vtmap.lua <gog.exe> <gog.sig> <steam.exe> <data.tsv> <out.tsv> <cache> <refs.tsv>` finds every
  vtable in the other build with stellar-fnmatch (lua_fnmatch):
  - From code: it finds the loading function by its signatures, and takes the lea of the same
    ordinal there.
  - Otherwise from slots: by the functions in the vtable's slots.
  - Vtables whose slots are identical can be told apart only from code.
  - Steam 4.5.2: 10,898 of 10,900 found, 9,024 of them exactly from code.

The inputs are on hippo, in `/root/fnm_tmp`:
- `types452.pickle`, from pdbtype.py;
- `full452.asm`, llvm-objdump of the GOG exe;
- `names452.tsv` and `data452.tsv`, the PDB names of functions and data;
- the GOG `.sig`, in `/zpool0/share/stellar_except_analysis/graph/sigs`.

The outputs stay there: they are derived from the game, not part of the repository.
