# The game's types, from the PDB, for a spider of the game's objects

The game has no RTTI. The GOG build's PDB names every class and vtable. These tools carry those
names to the running build (Steam), so that Lua can walk the game's objects and build them.

- `demangle_vtables.py <data.tsv> <out.tsv>` spells every vtable in the PDB's data names as
  `const X::`vftable'`. Some vtables, most trigger and effect classes among them, are named only by
  their mangled symbol (`??_7CAndTrigger@@6B@`): 7,747 in 4.5.2, demangled with `llvm-undname`.
  The tools below take its output.
- `typecrawl.py <types.pickle> <out_dir> [roots | @file]` finds every type reachable from
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
  - Steam 4.5.2: 18,644 of 18,647 found, 15,749 of them exactly from code.

`lua/stellar/spider.lua` uses these in the game. It reads three tables from `cache/`:
- `spider_types-<md5>.tsv` and `spider_members-<md5>.tsv`, a crawl whose roots are every class
  with a vtable plus every `C...Database`: 20,687 types and 47,106 members;
- `spider_vtables-<md5>.tsv`, from vtmap.lua.

From roots (each database's instance, the trigger and effect databases, the game state's database),
it walks every object reachable:
- a polymorphic object is the class its vtable names, its start found from the base the vtable is for;
- members are followed by their PDB types;
- containers are walked once per template: `CPdxArray<>`, `CPdxHybridArray<>`, `std::vector<>`,
  `std::list<>`, `std::map<>`, `std::set<>`, `TPdxRefDatabase<>` (its lookup array of live objects),
  `CPdxRobinHoodTable<>` (`CPdxUnorderedMap` and `CPdxUnorderedSet`).

Steam 4.5.2 at the main menu, 197 roots: 2,340,813 objects of 4,007 classes (935 MB), walked in 69s.
2,169 objects (0.09%) have a vtable that is not named, 136 reads failed, and 68 containers had
impossible counts.

The inputs are on hippo, in `/root/fnm_tmp`:
- `types452.pickle`, from pdbtype.py;
- `full452.asm`, llvm-objdump of the GOG exe;
- `names452.tsv` and `data452.tsv`, the PDB names of functions and data;
- the GOG `.sig`, in `/zpool0/share/stellar_except_analysis/graph/sigs`.

The outputs stay there: they are derived from the game, not part of the repository.
