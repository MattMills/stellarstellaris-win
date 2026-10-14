# The game databases, and Lua building them

How Stellaris 4.5.2 builds its 198 game databases (`common/` and a few others: technologies,
buildings, jobs, ...), how Lua can build them instead with the game's readers turned off, the form
of the definitions that the in-game builder and the simulation can share, and a proof in the real
game.

- Addresses are given as GOG rva / Linux address. The GOG build has the PDB (MSVC layouts). The
  Linux build has symbols and RTTI but no DWARF for the game's code (only breakpad and libgcc
  have it), so Linux layouts come from its code.
- [V] is verified in the code or in a run; [I] is inferred.
- The tools are in `tools/re/databases/`; the prototype is in `headless/dev/` (section 6).

## In short

- **The pattern.** 163 of the 198 databases are one template: `TSingleObjectGameDatabase<DB, T,
  hashed>`, six of them through `TExtendableObjectGameDatabase`. The other 35 have their own code.
  - Each object derives from `TGameDatabaseObject<T>` (an index and a key) and, unless the database
    is keys only, `CPersistent`. It is allocated with `malloc`/`calloc` and read by its own
    `ReadMember(reader, token)`.
  - References between databases are read at once (`NParserUtil::ReadKeyReference<DB>`: 200
    calling functions), or deferred to `CGlobalDeferredDatabaseObjectResolver::Run`, which runs
    after every database is read (159).
  - Script members are compiled while they are read. Every trigger and effect registers itself in
    a global set.
  - Modifier definitions are made by linear searches over a 45,000-entry array.
- **Recommendation: the hybrid (option c).**
  - Lua makes each object and writes its data members from the definitions: the vtables, the
    index, the key, the scalars, the references, the database's own work after the read.
  - The game compiles only the script members, from a reader that Lua gives the members' own lines.
  - The game's `Init` never runs for a database that Lua builds. Databases without a schema yet
    stay with the game, one database at a time.
  - Scripts then move to Lua, and so does modifier generation, where most of the time goes.
- **The shared form.** The definitions are one store, the data layer's
  (`sim/lua/engine/store`). They are kept in the game's load order, with the game's duplicate rule
  and locations.
  - A schema per database gives the typed fields.
  - Script members stay trees of the store, which the simulation evaluates and the builder hands
    to the game's compiler.
- **Proof** (headless Linux game, 2210.01.01 save, 30 days). Lua built five databases with the
  game's `Init` off:
  - `CNamedColorDatabase`: data only;
  - `CTraitTagDatabase`, `CJobTagDatabase`: keys only, which the game's own trait and job readers
    then look up;
  - `CAIAttitudesDatabase`: data, tokens, the database's own cached pointers;
  - `CAIEspionageOperationPoliciesDatabase`: script values compiled by the game from Lua's lines.

  Every object matched the game's own (shadow). The gamestate after 30 days was identical to an
  unmodified run, as were `error.log` and the object census. Two controls show that the game runs
  on Lua's databases:
  - without the attitudes database's own work, 32 lines of the gamestate differ;
  - with one trait tag left out, the game's trait reader reports 220 failed references to it.

## 1. How a database is built

### 1.1 The table and the loop

`NNullObjAndDatabaseInitUtil::SetupDatabases` (0x1b1ff0 / 0x1a1a440) is called by
`CGameApplication::InitGame` (0x1ba200 / 0x1a15860) [V]. It fills a table on its stack, one
`SDatabaseObjectFunctions` (48 bytes) per database: `{ name, CreateInstance, DestroyInstance,
CanInitialize or null, InitInstance, PostReadInitInstance }`. The Linux build has the same 198
entries (the oracle's `oracle/init_sequence.md`; the start of the table read here) [V]. Then:

1. It repeats until nothing changes: a database whose `CanInitialize` passes (its dependencies) is
   made. `CreateInstance` is `calloc` plus the constructor, which stores `_pInstance`; then
   `InitInstance` (`TGameDatabase<DB>::InitInstance` = virtual `Init`, slot 2) runs. Databases still
   left at the end log "Failed to initialize database" [V].
2. `CGlobalDeferredDatabaseObjectResolver::Run` (inlined / 0x42e31c0, called at 0x1a1e98b) [V].
3. `PostReadInitInstance` of every database, in init order: the virtual `PostReadInit`, slot 3 [V].
4. `CModifier::InitDefinitionIcons` [V].

Before the loop, InitGame does three things:
- reads the scripted variables;
- runs `CModifier::InitDefinitions` (0x35c970 / 0x1d8a240);
- allocates and initializes the 323 null objects (`TPdxNullObject<T>`).

After the loop it runs `CStaticModifierDatabase::Init`, `CPostInitModifierDatabase::ProcessModifiers`,
the triggers' and effects' `PostInit` and `PostValidate`, and so on (loading.md has the timeline)
[V].

### 1.2 The kinds and their layouts

| kind | databases | what it is |
|---|---|---|
| `TSingleObjectGameDatabase<DB, T, false>` | 150 | key lookups by linear search of `_Array` |
| `TSingleObjectGameDatabase<DB, T, true>` | 7 | the same plus a hash map, `_Lookup`: technology, technology category, ship size, star class, event chain, leader class, frontend background |
| `TExtendableObjectGameDatabase<DB, T, false>` | 6 | a duplicate key merges into the object: AI economic plans, authorities, ownership limits, species classes, portrait sets and categories |
| their own | 35 | static modifiers, strategic resources, traits, events, on_actions, name lists, portraits, ... (section 2) |

The layouts are the same template on both builds, at different offsets [V]:

| | MSVC (PDB) | Linux (code) |
|---|---|---|
| `TGameDatabase<DB>` vptr | +0x0 | +0x0 |
| `CSingleObjectGameDatabaseBase` (vptr, `CString _FolderPath`, `_FileWatchListener`) | +0x8, 64 bytes | +0x8 |
| `CPdxArray<T const*> _Array` (vptr, data, capacity, size) | +0x48 | +0x48 (data +0x50, size +0x5c) |
| `CPdxUnorderedMap<CString, T const*> _Lookup` | +0x60, 32 bytes | +0x60, 24 bytes (load factor 0.9 at +0x74) |
| `ESingleObjectDatabaseMode _Mode` (`Normal` 0, `KeysOnly` 1) | +0x80 | +0x78 |
| the database class's own members | +0x88 | +0x80 |
| object: vptr, `int _Index`, `CString _Key` (`TGameDatabaseObject<T>`, 64 bytes) | +0, +8, +0x10 | the same |
| object: `CPersistent` vptr | usually +0x40 | usually +0x40 |

Where the two builds differ:
- **Vtable slots.** MSVC has one destructor slot and Itanium has two, so a Linux slot is 8 bytes
  higher. The object's `CPersistent` slots on Linux are `Read` +0x20, `ReadMember` +0x28,
  `InitPostRead()` +0x30, `InitPostRead(file, first, last)` +0x38 [V].
- **Base order.** `CAIEspionageOperationPolicy` has the `CScriptableValue` at +0x40 and
  `CPersistent` at +0x78 on Linux, against `CPersistent` +0x40 and the policy base +0x48 on MSVC
  [V].
- **Sizes.** `std::function` is 64 bytes on MSVC and 32 on Linux, and the unordered map 32 and 24.
  So `CBuildingType` is 6,560 bytes on MSVC and 6,400 on Linux (the table's sizes column) [V].

A Linux layout is therefore read from the code (constructors, `ReadMember`, `LoadFromReader`). The
production target, the Windows game, has its layouts in the PDB.

### 1.3 The read path

All of this is the template's, the same code per instantiation (ICF folds most of it on GOG) [V]:

1. **`Init`** (0x201b90, folded / 0x1aa3950 for named colours):
   - `VFSGetEnumeratedFiles(_FolderPath)`;
   - for each file, `LoadFile(folder + "/" + name, false)` (slot 4 of the database's vtable);
   - `CSingleObjectGameDatabaseBase::AttachFileWatcher`, for reloads.

   It does not call `PostReadInit`. A database class may override `Init`, call the base one and then
   do its own work. `CAIAttitudesDatabase::Init` (0xb3b1e0 / 0x26e6760), for example, caches 24
   attitudes by key in `TCachedDBPtr<CAIAttitude>` members (`CacheItem` 0xb3b710 / 0x26e6db0): the
   object, or the null object and "Failed to cache an item for ..." [V].
2. **`LoadFile`** (0x42c730 / 0x209a040 for technology) makes a `CTextLexer` on the file and a
   `CReader`, then calls `LoadFromReader(reader, reload)` [V].
3. **`LoadFromReader`** (0x21dae0 / 0x1aa41b0 for named colours) [V]:
   - It reads top-level statements (`ReadSimpleStatement`, 0x1ba8710 / 0x42e8010).
   - `inline_script` (token 1080) is read through `CreateInlineScriptReader` (0x1bb4410 / 0x42dbe90).
   - Anything that is not `key = {` reports "Expected format is \"key={\"".
   - The key is looked up: `FindEntryWhileReading`, a linear scan with length and memcmp, or
     `_Lookup` when the database is hashed. A new key goes to `ReadNewEntry`, a known one to
     `ReadExistingEntry` (slot 5).
   - In `KeysOnly` mode every bare word is a key and nothing is read.
4. **`ReadNewEntry`** (0x227720 / inlined for named colours, 0x1aaa3e0 for the espionage policies)
   [V]:
   - allocates the object (`malloc` + `memset` on GOG, `calloc(1, size)` on Linux);
   - constructs `T(int index, CString key)`, where the index is `_Array`'s size: **`_Index` is the
     position at creation and never changes**;
   - calls `Read(reader)` on the object;
   - appends it (`CPdxArray::InsertAtEmplace`), and for a hashed database inserts it in `_Lookup`
     (`AddNewEntry`).
5. **`ReadExistingEntry`** (0x2100c0 / 0x1aa3e10) [V]:
   - In a single-object database the later definition wins. It logs "Object with key: %s already
     exists, using the one at %s", runs the destructor in place, reconstructs `T(old index, key)`
     and reads again. The address and the index stay the same.
   - In an extendable database the block is read into the existing object, with no message.
6. **`CPersistent::Read`** (0x50d6c0 / 0x42e4c10) [V]:
   - `ReadWithoutInitPostRead` (0x1ba6030 / 0x42e41b0): until `}`, each statement goes to
     `ReadMember(reader, token id of the key)`. `@var` statements and inline scripts are handled
     there. An unknown key reaches `CPersistent::ReadMember` (0x3456b0 / 0x42e4c70): "Unexpected
     token", skipped.
   - Then `InitPostRead()` and `InitPostRead(file, first line, last line)`, where the objects
     validate, resolve string keys and make modifiers. `CEthic::InitPostRead` (0x457450 / 0x2532970)
     is an example; 38 object classes have one (the table's "own work").
7. **`ReadMember`** is a switch on token ids. `CNamedColor::ReadMember` (0x852a70 / 0x1db73f0)
   knows one token: 86 `color` calls `CReader::Read(CColor&)`. A number is a hex RGBA; a block is
   3 or 4 numbers, each above 1.0 multiplied by 1/255 as a float, with the alpha 1.0 by default
   [V].

   A token id is the static lexer's id of the word (`CStaticLexer::FindTok`, 0x42dfa90, returns 12
   when there is none). Keys the lexer does not know are added at runtime (`AddDynamicToken`). Ids
   are the same on both builds (`inline_script` 1080, `color` 86, `type` 225) [V].

### 1.4 Allocation, strings, null objects

- **Allocation.** Objects use `malloc`/`calloc` (GOG: UCRT `malloc` + `memset`; Linux: glibc
  `calloc`). `operator new` is the standard one. There is no PDX allocator on this path [V].
- **`CString`** (48 bytes on both builds) [V]:
  - the first 16 bytes are the allocator: `{ EStringAllocStrategy` (Common 0, Frame 1), `CPdxLinearAllocator* }`;
  - then the `std::basic_string` with `CPdxCommonStringAllocator`. On Linux: data +0x10, size +0x18,
    local buffer +0x20. On MSVC: buffer/pointer +0x10, size +0x20, capacity +0x28.
  - Construct and assign through the game's functions: `CString::CString(char const*)` 0x15cbf0 [I] /
    0x424e020, `operator=` 0x1992770 on Linux.
- **Null objects** [V]:
  - `TPdxNullObject<T>::Allocate` reserves protected memory of `sizeof(T)`.
  - `Initialize` constructs `T(-1, "")`, replaces the vptrs with the null object's and protects the
    memory read-only.
  - Its `IsValid()` (vtable +0x10) returns false. A failed lookup returns it, so a reference is
    never null.

### 1.5 References between databases

A database object reads a reference in one of three ways [V]:

1. **At once: `NParserUtil::ReadKeyReference<DB>(reader, db, silent)`.**
   - It does a hash lookup for a hashed database and a linear scan otherwise.
   - A missing key gives the null object and "Failed to read key reference '%s' from database '%s'".
   - The database read must already exist, which is what `CanInitialize` waits for.
   - Examples: `CJobType`'s category is `ReadKeyReference<CPopCategoryDatabase>` (0x4183a0 /
     0x1ce7230); its tags are `ReadKeyReferenceUniform<CJobTagDatabase>`.
2. **A string, resolved in `InitPostRead`.** `CEthic`'s category is kept as `_CategoryKey` and
   looked up after the block.
3. **Deferred: `ReadKeyReferenceDeferred<DB>(owner, reader, T const** out)`** (0x17a19a0 /
   0x371ff40 for ethics).
   - It registers `{ key, location, owner, std::function }` with the resolver (`Register_Internal`
     0x1bb32c0 / 0x42e2e70).
   - `Run` calls each lambda after every database is read. The lambda writes the object or the null
     object to `*out`.
   - A failure logs "Failed to deferred read key reference".
   - An object's destructor unregisters its references, so a rebuilt duplicate drops them.
   - Technology prerequisites go this way, through `CCachedTechAndLevel`.

Every `ReadKeyReference*` call of the Linux build is listed in the table's "refs to" column, by the
class that makes it (`tools/re/databases/xrefs.py`) [V]:
- 359 (calling function, database) pairs: 200 read at once, 159 deferred;
- they include triggers and effects (`CAddEthicEffect` reads `CEthicDatabase`) and the game state
  (`CBuilding` reads `CBuildingTypeDatabase`);
- the objects of 60 databases read other databases or point to their objects.

### 1.6 Script members

Script members are compiled into objects while the database is read [V]:

- **Triggers.**
  - `CRootTrigger` members (334 in database objects) are read by `NParserUtil::ReadTrigger`
    (0x343e60 / 0x1c1d9c0) and then `CTrigger::Read`.
  - Each statement's token finds its entry in `CTriggerDatabase`'s map. Otherwise it becomes a scope
    change (`CContextTrigger`) or a scripted trigger placeholder.
  - **Every `CTrigger::CTrigger`** (0x344d70 / 0x2118de0) calls `CTriggerDatabase::AddTrigger`, a
    global set of every trigger.
- **Effects.** `CRootEffect` members (126) work the same way. `CEffect::CEffect` (0x3a95b0 /
  0x24f6490) appends itself to `CEffectDatabase`'s array.
- **Script values and weights.**
  - `CScriptableValue` / `CMeanTimeToHappen` members: 60 values, 58 weights.
  - `CMeanTimeToHappen::Read` (0x3429a0 / 0x1d58150) reads the base, then one
    `CComplexTriggerMTTHModifier` or `CTriggerMTTHModifier` per `modifier = { }`, each with its
    trigger tree.
- **Modifiers.** 87 members: `CStaticModifier`, `CModifier`, triggered modifiers.
  - `CModifier::TryReadMember` (0x36df60 / 0x1d9cb60) first scans the static modifiers linearly for
    the key, then the modifier definitions (about 45,000 entries; 176 bytes each on Linux).
  - A key that is neither is kept for later (`CPostInitModifierDatabase::CreatePostInitModifier`),
    after the databases.
  - Databases that generate modifiers (`CModifier::TryAddDynamicModifier`, 0x36e710 / 0x1d9dbf0)
    search the same array linearly and number the new definitions as they come. That is why their
    order (`cache/database_modifier_writers`) matters.
- **Script flags.** They are numbered as they are made (`CPdxIntegerFlags`); 29 databases make
  them.

The trigger and effect counts in the census (1,318,141 and 424,716) include these. Anything that
builds a database's script members must register them the same way, or the global sets and the
post-init passes (`CTriggerDatabase::PostInit` and the effects') see a different world.

### 1.7 Where the time goes

`docs/loading.md` measured that most of the database time is not reading: `CJobTypeDatabase` takes
3.0 s, `CShipSizeDatabase` 2.7 s and `CAnomalyTypeDatabase` 1.7 s, for 62,000, 60,000 and 19,000
tokens. The code says why [I: not profiled]:

- **Ship sizes.** `CShipSize::InitPostRead` (0xd27ca0 / 0x2b23dc0) creates about 99 modifier
  definitions per ship size through `CShipSize::CreateModifiers` (0xd29c00 / 0x2b24770), each a
  full linear scan of the definitions.
- **Jobs.** `CJobType::InitPostRead` (0x4156f0 / 0x1ce4e30) makes about 8 per job, and every
  modifier line read scans both arrays.

The cost grows with the square of the definition count. A builder that keeps the definitions in a
hash map does the same work in linear time.

## 2. The table of all databases

Generated by `tools/re/databases/gen_table.py` from:
- the GOG PDB (`pdbx.py`, `dbtable.py`);
- the Linux build (`linux_sizes.py`, `folders.py`, `xrefs.py`, and `nm -S` for the post-read
  sizes);
- the headless game's census (`headless/dev`, `HEADLESS_DB_CENSUS`);
- the Windows runtime's caches (order, dependencies, times, modifier and flag writers).

The columns:

| column | meaning |
|---|---|
| order | the game's init order (Windows `cache/database_order`, the same as the oracle's simulated order) |
| kind | as in 1.2; "hashed" = the template bool |
| size | `sizeof` of the object, or of the database class for the 35 with their own code; MSVC / Linux |
| vanilla | objects in `_Array` after the load (the 163 template databases) [V] |
| members | the object's own data members (PDB) |
| script parts | T triggers, E effects, V script values, M modifiers, W weights / MTTH (members by type) |
| refs to | databases read by the object's class: at once, and deferred (Linux call sites), plus direct pointer members |
| own work | the database's own `Init` override, its `PostReadInit` (Linux size; 60 bytes is the template's loop), the object's `InitPostRead`, and whether it makes modifier types or script flags |
| waits for | its `CanInitialize` dependencies (Windows runtime) |
| s | its time in a parallel boot on Windows (about twice its time alone) |

To regenerate it, put the inputs in one directory (`DBRE_DIR`, here `$W`) and run:

```
# on hippo (the PDB tables): database_order.tsv comes from C:\lfm\ss-run\cache\database_order-<md5>.tsv
cd $W; python3 $T/dbtable.py > dbtable.tsv; python3 $T/dbtable.py --members > members.tsv
# on 10.5.0.24 (the Linux build): A=/opt/stellaris-headless/re/full.asm, E=/opt/stellaris-headless/game/stellaris
python3 $T/linux_sizes.py $A linux_sizes.tsv; python3 $T/folders.py $A $E database_order.tsv folders.tsv
python3 $T/xrefs.py $A xrefs.tsv; nm -S -C $E | grep -E "::PostReadInit\(\)|::InitPostRead\(" > postread_syms.txt
# census.tsv: a db_run.sh run with HEADLESS_DB_CENSUS=1 (section 6); database_dependencies,
# database_boot_order, database_modifier_writers, database_flag_writers: C:\lfm\ss-run\cache\*-<md5>.tsv
DBRE_DIR=$W python3 $T/gen_table.py table.md          # T=tools/re/databases
```

| # | database | folder | kind | object | size MSVC / Linux | vanilla | members | script parts | refs to | own work | waits for | s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | CNamedColor | common/named_colors | single | CNamedColor | 88 / 88 | 89 | 1 |  |  |  |  | 0.00 |
| 2 | CGalaxyShape | map/galaxy | single | CGalaxyShape | 320 / 320 | 10 | 12 |  |  | PostRead 60 B |  | 0.00 |
| 3 | CStaticModifier |  | own |  | db 992 / ? |  | db: 122 |  |  |  |  | 1.90 |
| 4 | CScriptedTriggerTemplate | common/scripted_triggers | single | CScriptedTriggerTemplate | 280 / 280 | 1684 | 8 |  |  | PostRead 61 B |  | 0.11 |
| 5 | CScriptedEffectTemplate | common/scripted_effects | single | CScriptedEffectTemplate | 280 / 280 | 1687 | 8 |  |  | Init, PostRead 61 B |  | 0.26 |
| 6 | CScriptValueTemplate | common/script_values | single | CScriptValueTemplate | 280 / 280 | 682 | 8 |  |  | Init, PostRead 61 B |  | 0.04 |
| 7 | CAsteroidBeltType | common/asteroid_belts | single | CAsteroidBeltType | 208 / 208 | 6 | 5 |  |  |  |  | 0.00 |
| 8 | CWeaponTag |  | own |  | db 1 / ? |  | db: 0 |  |  | modifiers |  | 0.00 |
| 9 | CJobTag | common/job_tags | single | CJobTag | 64 / 64 | 34 | 0 |  |  |  |  | 0.00 |
| 10 | CTraitTag | common/trait_tags | single | CTraitTag | 64 / 64 | 58 | 0 |  |  |  |  | 0.00 |
| 11 | CStrategicResource | common/strategic_resources | own |  | db 144 / ? |  | db: 16 |  |  | modifiers |  | 0.07 |
| 12 | CEspionageOperationCategories | common/espionage_operation_categories | single | CEspionageOperationCategory | 104 / 104 | 10 | 7 |  |  | InitPostRead 2260 B, modifiers |  | 0.00 |
| 13 | CEconomicCategory | common/economic_categories | single | CEconomicCategory | 520 / 520 | 270 | 17 | 1T |  | PostRead 547 B, InitPostRead 409 B, modifiers | CStrategicResource | 0.10 |
| 14 | CLeaderTier | common/leader_tiers | single | CLeaderTier | 128 / 128 | 3 | 2 |  |  |  |  | 0.00 |
| 15 | CSituationLogCategory | common/situation_log/categories | single | CSituationLogCategory | 184 / 184 | 15 | 5 |  |  |  |  | 0.01 |
| 16 | CTechnologyCategory | common/technology/category | single, hashed | CTechnologyCategory | 264 / 264 | 13 | 6 | 1W |  | PostRead 344 B, InitPostRead 1 B |  | 0.01 |
| 17 | CTechnologyTier | common/technology/tier | single | CTechnologyTier | 208 / 208 | 6 | 3 | 1W |  | PostRead 217 B |  | 0.01 |
| 18 | CTechnology | common/technology | single, hashed | CTechnology | 2560 / 2528 | 679 | 32 | 2T 1V 1M 2W | CTechnologyCategory, CTechnologyTier | PostRead 67 B, InitPostRead 751 B | CStaticModifier, CTechnologyCategory, CTechnologyTier | 0.22 |
| 19 | CTargetType | common/target_types | single | CTargetType | 80 / 80 | 4 | 1 |  |  |  |  | 0.00 |
| 20 | CArmyType | common/armies | single | CArmyType | 2600 / 2512 | 70 | 31 | 4T 3E 1V 1M 1W |  | Init, PostRead 60 B | CEconomicCategory, CStaticModifier, CStrategicResource | 0.01 |
| 21 | CShipBehavior |  | own |  | db 64 / ? |  | db: 3 |  |  |  |  | 0.00 |
| 22 | CAmbientObject |  | own |  | db 24 / ? |  | db: 1 |  |  |  |  | 0.01 |
| 23 | CEmpireFlag |  | own |  | db 1320 / ? |  | db: 7 |  |  |  |  | 0.13 |
| 24 | CPortrait | gfx/portraits/environments | own |  | db 7880 / ? |  | db: 17 |  |  |  |  | 0.29 |
| 25 | CLeaderClass | common/leader_classes | single, hashed | CLeaderClass | 744 / 744 | 4 | 24 | 1V 1W |  | PostRead 729 B, InitPostRead 146 B | CEconomicCategory, CPortrait, CStrategicResource | 0.01 |
| 26 | COpinionModifier | common/opinion_modifiers | own |  | db 656 / ? |  | db: 77 |  |  |  |  | 0.05 |
| 27 | CSpeciesArchetype | common/species_archetypes | single | CSpeciesArchetype | 560 / 560 | 6 | 16 |  |  | Init, PostRead 60 B, InitPostRead 716 B, modifiers | CEconomicCategory, CStrategicResource | 0.01 |
| 28 | CSystemType | common/system_types | single | CSystemType | 392 / 376 | 12 | 3 | 1T 1W |  | Init, InitPostRead 331 B |  | 0.00 |
| 29 | CSystemTooltip | common/system_tooltips | single | CSystemTooltip | 888 / 880 | 7 | 1 | 1T |  | Init, InitPostRead 1 B |  | 0.00 |
| 30 | CBombardmentStance | common/bombardment_stances | single | CBombardmentStance | 680 / 664 | 13 | 16 | 1T 3V |  | Init, InitPostRead 1323 B |  | 0.00 |
| 31 | CStarbaseType | common/starbase_types | single | CStarbaseType | 528 / 512 | 26 | 6 | 1T 1W |  | Init, InitPostRead 113 B |  | 0.06 |
| 32 | CEthicCategory | common/ethic_categories | single | CEthicCategory | 72 / 72 | 5 | 0 |  |  |  |  | 0.00 |
| 33 | CEthic | common/ethics | single | CEthic | 1712 / 1696 | 17 | 22 | 2T 3V 2M | CEthicCategory | PostRead 1867 B, InitPostRead 650 B, modifiers | CEthicCategory, CStaticModifier | 0.02 |
| 34 | CEventChain | common/event_chains | single, hashed | CEventChain | 456 / 432 | 300 | 5 | 1T | CSituationLogCategory; deferred: CSituationLogCategory | PostRead 85 B, InitPostRead 834 B, flags |  | 0.12 |
| 35 | CBypassType | common/bypass | single | CBypassType | 1592 / 1520 | 10 | 32 | 4T 1E |  | Init, InitPostRead 851 B, modifiers |  | 0.00 |
| 36 | CBuildingType | common/buildings | single | CBuildingType | 6560 / 6400 | 498 | 58 | 15T 8E 6M 5W | CTechnology | Init, PostRead 578 B, InitPostRead 323 B, modifiers, flags | CEconomicCategory, CEventChain, CStaticModifier, CStrategicResource, CTechnology | 0.34 |
| 37 | CZoneType | common/zones | single | CZoneType | 4320 / 4232 | 146 | 43 | 13T 3E 4M 2W | CBuildingType, CDistrictType, CTechnology | Init, PostRead 60 B, modifiers | CBuildingType, CEconomicCategory, CStaticModifier, CStrategicResource, CTechnology | 0.19 |
| 38 | CDistrictZoneSlot | common/zone_slots | single | CDistrictZoneSlot | 536 / 504 | 33 | 4 | 2T | CZoneType |  | CZoneType | 0.00 |
| 39 | CDistrictType | common/districts | single | CDistrictType | 4264 / 4112 | 147 | 58 | 15T 5E 1M 1W | CDepositTypes | Init, PostRead 60 B, InitPostRead 164 B, modifiers | CDistrictZoneSlot, CEconomicCategory, CStaticModifier, CStrategicResource | 0.04 |
| 40 | CColonyType | common/colony_types | single | CColonyType | 1152 / 1136 | 101 | 14 | 6T 1M 1W |  | Init, PostRead 60 B, InitPostRead 885 B | CStaticModifier | 0.04 |
| 41 | CPlanetClass |  | own |  | db 80 / ? |  | db: 5 |  |  | PostRead 1796 B, modifiers | CDistrictType, CStaticModifier | 0.01 |
| 42 | CShipCategory |  | single | CShipCategory | 312 / 312 | 7 | 10 |  | CNameList, CPlanetClass, CShipSize | Init, PostRead 60 B | CPlanetClass | 0.00 |
| 43 | CGfxCulture | common/graphical_culture | own |  | db 136 / ? |  | db: 3 |  |  |  | CShipCategory | 0.01 |
| 44 | CShipSize | common/ship_sizes | single, hashed | CShipSize | 3816 / 3720 | 319 | 79 | 6T 2M | CGfxCulture, CPlanetClass, CScriptedAction, CShipCategory, CStrategicResource; deferred: CScriptedAction | Init, PostRead 60 B, InitPostRead 2214 B, modifiers | CEconomicCategory, CGfxCulture, CPlanetClass, CShipCategory, CStaticModifier, CStrategicResource | 0.62 |
| 45 | CShipSet | common/ship_sets | single | CShipSet | 376 / 360 | 2 | 2 | 1T |  |  |  | 0.00 |
| 46 | CComponentSlotTemplate | common/component_slot_templates | single | CComponentSlotTemplate | 96 / 96 | 31 | 4 |  |  |  | CGfxCulture | 0.00 |
| 47 | CProjectileGfx |  | own |  | db 48 / ? |  | db: 2 |  |  |  | CComponentSlotTemplate, CGfxCulture | 0.05 |
| 48 | CShipOfSizeLimit | common/country_limits/ship_of_size_limits | single | CShipOfSizeLimit | 1968 / 1952 | 7 | 5 | 1T | CShipSize |  | CShipSize | 0.00 |
| 49 | COwnershipLimits | common/country_limits/ownership_limits | extendable | COwnershipLimits | 96 / 96 | 1 | 1 |  | CShipOfSizeLimit |  | CShipOfSizeLimit | 0.00 |
| 50 | CSpeciesClass | common/species_classes | extendable | CSpeciesClass | 1296 / 1264 | 42 | 24 | 2T 2W | CEthic, CGfxCulture, CSpeciesArchetype, CTrait | Init, PostRead 60 B, InitPostRead 1 B | CEthic, CGfxCulture | 0.00 |
| 51 | CSpeciesPortraitSet | common/portrait_sets | extendable | CSpeciesPortraitSet | 264 / 264 | 67 | 9 |  | CSpeciesClass | PostRead 351 B, InitPostRead 2091 B | CPortrait, CSpeciesClass | 0.01 |
| 52 | CSpeciesPortraitCategory | common/portrait_categories | extendable | CSpeciesPortraitCategory | 192 / 192 | 18 | 3 |  | CSpeciesPortraitSet | PostRead 60 B | CSpeciesPortraitSet | 0.00 |
| 53 | CDepositCategories | common/deposit_categories | single | CDepositCategory | 80 / 80 | 9 | 2 |  |  |  |  | 0.00 |
| 54 | CAIBudgetEntry | common/ai_budget | single | CAIBudgetEntry | 576 / 560 | 200 | 9 | 1T 3V | CEconomicCategory, CStrategicResource | Init, InitPostRead 918 B | CEconomicCategory, CStrategicResource | 0.04 |
| 55 | CAIAttitudes | common/attitudes | single | CAIAttitude | 96 / 96 | 24 | 2 |  |  | Init |  | 0.00 |
| 56 | CAIPersonalities | common/personalities | single | CAIPersonality | 688 / 672 | 51 | 28 | 1T 1V 1W |  | PostRead 61 B |  | 0.02 |
| 57 | CAdvisor |  | own |  | db 19608 / 19608 |  | db: 1 |  |  |  |  | 0.00 |
| 58 | CPlanetDestructionGraphics | gfx/projectiles/planet_destruction | single | CPlanetDestructionGraphicsType | 1136 / 1136 | 10 | 12 |  |  |  |  | 0.00 |
| 59 | CAdvisorVoiceType | sound/advisor_voice_types | single | CAdvisorVoiceType | 424 / 416 | 27 | 5 | 1T 1V |  | PostRead 60 B |  | 0.00 |
| 60 | CPingMap |  | own |  | db 160 / ? |  | db: 11 |  |  |  |  | 0.00 |
| 61 | CStarClass | common/star_classes | single, hashed | CStarClass | 624 / 624 | 36 | 16 | 1M |  | InitPostRead 739 B | CPlanetClass, CStaticModifier | 0.01 |
| 62 | CStarClassRandomizer | common/star_classes/randomizers | single | CStarClassRandomizer | 96 / 96 | 9 | 1 |  | CStarClass | InitPostRead 91 B | CStarClass | 0.00 |
| 63 | CEdicts | common/edicts | single | CEdict | 2416 / 2352 | 171 | 18 | 4T 2E 1V |  | PostRead 61 B | CEconomicCategory, CStaticModifier, CStrategicResource | 0.12 |
| 64 | CCouncilAgenda | common/council_agendas | single | CCouncilAgenda | 1936 / 1888 | 92 | 11 | 2T 2E 1M 1W | CStaticModifier; deferred: CStaticModifier | PostRead 60 B | CStaticModifier, CStrategicResource | 0.05 |
| 65 | CPrecursorCivilizations | common/precursor_civilizations | single | CPrecursorCivilization | 344 / 328 | 9 | 4 | 1T |  | PostRead 61 B, flags |  | 0.00 |
| 66 | CResourceRegion | common/resource_regions | single | CResourceRegion | 80 / 80 | 4 | 2 |  |  | PostRead 61 B, flags |  | 0.00 |
| 67 | CDiplomaticActionType | common/diplomatic_actions | single | CDiplomaticActionType | 1576 / 1504 | 68 | 16 | 3T 3E 1V 1W |  | PostRead 60 B | CStrategicResource | 0.01 |
| 68 | CPlanetModifier | common/planet_modifiers | single | CPlanetModifier | 360 / 344 | 71 | 4 | 1T 1V 1M | CStaticModifier; deferred: CStaticModifier | Init |  | 0.01 |
| 69 | CSpeciesNames | common/species_names | own |  | db 48 / ? |  | db: 2 |  |  |  | CSpeciesClass | 0.01 |
| 70 | CNameList | common/name_lists | own |  | db 112 / ? |  | db: 4 |  |  |  | CPlanetClass, CShipSize | 0.11 |
| 71 | CScriptedModifier | common/scripted_modifiers | single | CScriptedModifier | 144 / 144 | 138 | 6 |  |  | PostRead 60 B |  | 0.00 |
| 72 | CResolutionType | common/resolutions | single | CResolutionType | 2520 / 2424 | 278 | 15 | 6T 2E 1W | CResolutionCategory | PostRead 274 B, flags | CEconomicCategory, CStaticModifier, CStrategicResource | 0.08 |
| 73 | CCitizenshipType | common/species_rights/citizenship_types | single | CCitizenshipType | 1824 / 1776 | 15 | 17 | 4T 2M 1W |  | PostRead 1048 B | CResolutionType, CStaticModifier | 0.01 |
| 74 | CColonizationControl | common/species_rights/colonization_controls | single | CColonizationControl | 1816 / 1760 | 2 | 11 | 4T 2M 1W |  | PostRead 808 B |  | 0.00 |
| 75 | CLivingStandard | common/species_rights/living_standards | single | CLivingStandard | 1808 / 1760 | 35 | 10 | 4T 2M 1W |  | PostRead 808 B | CResolutionType, CStaticModifier | 0.01 |
| 76 | CMigrationControl | common/species_rights/migration_controls | single | CMigrationControl | 1816 / 1760 | 2 | 11 | 4T 2M 1W |  | PostRead 859 B |  | 0.00 |
| 77 | CMilitaryServiceType | common/species_rights/military_service_types | single | CMilitaryServiceType | 1808 / 1760 | 3 | 10 | 4T 2M 1W |  | PostRead 859 B |  | 0.00 |
| 78 | CPopulationControl | common/species_rights/population_controls | single | CPopulationControl | 1816 / 1760 | 2 | 11 | 4T 2M 1W |  | PostRead 859 B | CStaticModifier | 0.00 |
| 79 | CPurgeType | common/species_rights/purge_types | single | CPurgeType | 2424 / 2376 | 11 | 14 | 4T 2M 1W |  | PostRead 1083 B | CStaticModifier | 0.01 |
| 80 | CPopCategory | common/pop_categories | single | CPopCategory | 2904 / 2888 | 24 | 28 | 7T 3M 1W |  | PostRead 60 B, InitPostRead 731 B, modifiers | CEconomicCategory, CStaticModifier, CStrategicResource | 0.16 |
| 81 | CJobType | common/pop_jobs | single | CJobType | 2744 / 2728 | 366 | 33 | 6T 3M 1W | CJobTag, CPopCategory, CPurgeType, CTrait | Init, PostRead 222 B, InitPostRead 865 B, modifiers, flags | CEconomicCategory, CJobTag, CPopCategory, CPurgeType, CStaticModifier, CStrategicResource | 0.73 |
| 82 | CSlaveryType | common/species_rights/slavery_types | single | CSlaveryType | 1864 / 1816 | 8 | 13 | 4T 2M 1W |  | PostRead 1083 B | CResolutionType, CStaticModifier | 0.00 |
| 83 | CSubSpeciesIntegrationType | common/species_rights/subspecies_integration_types | single | CSubSpeciesIntegrationType | 1816 / 1760 | 2 | 11 | 4T 2M 1W |  | PostRead 1083 B |  | 0.00 |
| 84 | CResolutionGroup | common/resolution_groups | single | CResolutionGroup | 80 / 80 | 8 | 2 |  |  |  |  | 0.00 |
| 85 | CResolutionCategory | common/resolution_categories | single | CResolutionCategory | 240 / 240 | 37 | 7 |  | CResolutionGroup, CResolutionType | PostRead 60 B, InitPostRead 382 B, modifiers |  | 0.00 |
| 86 | CSpecimen | common/specimens | single | CSpecimen | 504 / 504 | 258 | 6 | 1T |  | PostRead 60 B | CEconomicCategory, CStaticModifier, CStrategicResource | 0.02 |
| 87 | CObservationStationMissions | common/observation_station_missions | single | CObservationStationMission | 992 / 960 | 3 | 11 | 2T 1V 2M | CStaticModifier | PostRead 61 B | CEconomicCategory, CStrategicResource | 0.01 |
| 88 | CSpecialProject | common/special_projects | own |  | db 24 / ? |  | db: 1 |  |  | flags | CArmyType, CEventChain, CLeaderClass, CShipSize, CSituationLogCategory | 0.31 |
| 89 | CAnomalyType | common/anomalies | single | CAnomalyType | 504 / 496 | 327 | 15 | 1T 2E 1V | CSituationLogCategory; deferred: CSituationLogCategory | PostRead 451 B, InitPostRead 749 B, modifiers, flags |  | 0.05 |
| 90 | CTrait | common/traits | own |  | db 88 / ? |  | db: 4 |  |  | flags | CEconomicCategory, CLeaderClass, CNamedColor, CPlanetClass, CSpeciesArchetype, CSpeciesClass, CStaticModifier, CStrategicResource, CTraitTag | 2.20 |
| 91 | CPolicyCategories | common/policy_categories | single | CPolicyCategory | 120 / 120 | 6 | 1 |  |  |  |  | 0.00 |
| 92 | CPolicies | common/policies | single | CPolicyGroup | 816 / 776 | 60 | 8 | 2T 1E | COpinionModifier, CPolicyCategories | Init, PostRead 61 B | CPurgeType, CResolutionType, CStaticModifier, CStrategicResource | 0.03 |
| 93 | CDiploPhrase | common/diplo_phrases | own |  | db 24 / ? |  | db: 1 |  |  | flags |  | 0.29 |
| 94 | CMessageSystem |  | own |  | db 40 / ? |  | db: 3 |  |  |  | CPingMap | 0.01 |
| 95 | CAlertSystem |  | own |  | db 176 / ? |  | db: 2 |  |  |  |  | 0.00 |
| 96 | CTerraform |  | own |  | db 32 / ? |  | db: 1 |  |  |  | CEconomicCategory, CPlanetClass, CStrategicResource | 0.09 |
| 97 | CStartScreenMessage |  | own |  | db 24 / ? |  | db: 1 |  |  |  |  | 0.01 |
| 98 | CSystemInitializer | common/solar_system_initializers | own |  | db 568 / 568 |  | db: 10 |  |  | PostRead 602 B, flags | CAnomalyType, CArmyType, CAsteroidBeltType, CBuildingType, CDistrictType, CEmpireFlag, CEthic, CGfxCulture, CPlanetModifier, CShipCategory, CSpeciesClass, CStrategicResource, CZoneType | 0.15 |
| 99 | CFallenEmpires |  | own |  | db 24 / ? |  | db: 1 |  |  |  | CEthic, CGfxCulture, CSpeciesClass, CStrategicResource, CSystemInitializer | 0.00 |
| 100 | CFrontendBackground | common/frontend_backgrounds | single, hashed | CFrontendBackground | 128 / 128 | 9 | 2 |  |  |  |  | 0.00 |
| 101 | CGalaxyTemplate | map/setup_scenarios | own |  | db 96 / 96 |  | db: 4 |  |  |  | CGalaxyShape | 0.00 |
| 102 | CWorldGfx |  | own |  | db 40 / ? |  | db: 2 |  |  |  |  | 0.03 |
| 103 | CMapMode | common/map_modes | single | CScriptedMapMode | 472 / 456 | 8 | 6 | 1T |  |  |  | 0.00 |
| 104 | CColors | common/colors | own |  | db 144 / ? |  | db: 6 |  |  |  |  | 0.00 |
| 105 | CPortraitSpriteConfiguration | gfx/portraits/sprite_configurations | single | CPortraitSpriteConfiguration | 360 / 352 | 1 | 3 | 1T |  |  |  | 0.00 |
| 106 | CGameConceptCategory | common/game_concept_categories | single | CGameConceptCategory | 168 / 168 | 7 | 2 |  |  | InitPostRead 533 B |  | 0.00 |
| 107 | CGameConceptType | common/game_concepts | single | CGameConceptType | 512 / 512 | 932 | 6 |  |  | Init, PostRead 56 B | CGameConceptCategory | 0.01 |
| 108 | CGameSettings | common/gamesetup_settings/gamesetup_settings.txt | own |  | db 24 / ? |  | db: 1 |  |  |  |  | 0.00 |
| 109 | CPopFactionType | common/pop_faction_types | single | CPopFactionType | 3536 / 3464 | 42 | 36 | 3T 3E 2V 1M | CEthic | Init, PostRead 60 B | CEconomicCategory, CStaticModifier, CStrategicResource | 0.15 |
| 110 | CDynamicText | common/dynamic_text | single | CDynamicTextDatabaseEntry | 528 / 520 | 0 | 12 | 1T |  | Init, PostRead 60 B |  | 0.00 |
| 111 | CEmpireScriptedFlagsType | common/prescripted_flags | single | CEmpireScriptedFlagsType | 96 / 96 | 21 | 1 |  |  |  |  | 0.00 |
| 112 | CButtonEffect | common/button_effects | single | CButtonEffect | 696 / 656 | 2 | 3 | 2T 1E |  |  |  | 0.00 |
| 113 | CScriptableLocalization | common/scripted_loc | own |  | db 72 / 64 |  | db: 1 |  |  | flags |  | 0.18 |
| 114 | CGovernmentType | common/governments | single | CGovernmentType | 544 / 528 | 170 | 9 | 1T 1V |  | Init, PostRead 60 B |  | 0.01 |
| 115 | CNotificationModifierType | common/notification_modifiers | single | CNotificationModifierType | 120 / 120 | 7 | 1 |  |  | PostRead 60 B |  | 0.00 |
| 116 | CCountryCustomization | common/country_customization | single | CCountryCustomization | 208 / 208 | 4 | 3 | 1W |  |  | CBuildingType, CGfxCulture, CPlanetClass | 0.00 |
| 117 | CStarbaseLevelType | common/starbase_levels | single | CStarbaseLevelType | 744 / 712 | 41 | 17 | 2T 1V | CShipSize; deferred: CShipSize | PostRead 356 B |  | 0.01 |
| 118 | CCasusBelliType | common/casus_belli | single | CCasusBelliType | 1264 / 1208 | 45 | 8 | 3T 1E |  | InitPostRead 169 B | CEconomicCategory, CStrategicResource | 0.01 |
| 119 | CWarGoalType | common/war_goals | single | CWarGoalType | 1488 / 1416 | 87 | 24 | 3T 3E 1W | CCasusBelliType | PostRead 60 B, flags | CCasusBelliType, CStrategicResource | 0.02 |
| 120 | CSectorType | common/sector_types | single | CSectorType | 528 / 528 | 2 | 9 | 2V |  |  | CEconomicCategory, CStrategicResource | 0.00 |
| 121 | CDiplomacyEconomy | common/diplomacy_economy | single | CDiplomacyEconomicUnitCollection | 96 / 96 | 2 | 1 |  |  | Init | CEconomicCategory, CStrategicResource | 0.00 |
| 122 | CCollectedEconomy | common/country_container | single | CMiscEconomicUnitCollection | 96 / 96 | 1 | 1 |  |  | Init | CEconomicCategory | 0.00 |
| 123 | CRelics | common/relics | single | CRelic | 976 / 952 | 68 | 10 | 2T 1E 1V |  | PostRead 61 B, flags | CEconomicCategory, CStaticModifier, CStrategicResource | 0.01 |
| 124 | CArtifactActions | common/artifact_actions | single | CArtifactAction | 1096 / 1056 | 28 | 6 | 2T 1E 1V |  | PostRead 61 B, flags | CEconomicCategory, CStrategicResource | 0.01 |
| 125 | CAstralActions | common/astral_actions | single | CAstralAction | 1704 / 1632 | 16 | 16 | 4T 1E 1V |  | PostRead 61 B | CStrategicResource | 0.01 |
| 126 | CColonyAutomationCategory | common/colony_automation_categories | single | CColonyAutomationCategory | 384 / 368 | 13 | 3 | 1T |  | Init, InitPostRead 703 B |  | 0.00 |
| 127 | CColonyAutomation | common/colony_automation | single | CColonyAutomation | 448 / 432 | 27 | 9 | 1T | CColonyAutomationCategory, CDistrictType, CZoneType | Init, PostRead 60 B | CColonyAutomationCategory | 0.01 |
| 128 | CColonyAutomationException | common/colony_automation_exceptions | single | CColonyAutomationException | 456 / 432 | 22 | 12 | 1T | CColonyAutomationCategory, CDistrictType, CZoneType | Init, PostRead 60 B | CColonyAutomationCategory | 0.00 |
| 129 | CFederationPerk | common/federation_perks | single | CFederationPerkType | 2768 / 2752 | 65 | 11 | 3T 2E |  | PostRead 60 B | CDiplomaticActionType, CStaticModifier | 0.02 |
| 130 | CFederationType | common/federation_types | single | CFederationType | 1112 / 1056 | 7 | 11 | 3T 1E 1W | COwnershipLimits | PostRead 60 B | CFederationPerk, COwnershipLimits | 0.02 |
| 131 | CGalacticFocus | common/galactic_focuses | single | CGalacticFocus | 896 / 856 | 10 | 7 | 2T 1E 1V |  | PostRead 60 B | CStrategicResource | 0.00 |
| 132 | CFederationLaw | common/federation_laws | single | CFederationLaw | 1368 / 1328 | 73 | 10 | 2T 1E 1V 1W | CFederationLawCategory | PostRead 700 B | CDiplomaticActionType, CStaticModifier | 0.02 |
| 133 | CFederationLawCategory | common/federation_law_categories | single | CFederationLawCategory | 320 / 304 | 16 | 3 | 1T | CFederationLaw | PostRead 60 B | CFederationLaw | 0.00 |
| 134 | CLawsuitType | common/lawsuits | single | CLawsuitType | 664 / 656 | 0 | 5 | 1E |  | PostRead 60 B |  | 0.00 |
| 135 | CAIEconomicPlan | common/economic_plans | extendable | CAIEconomicPlan | 496 / 480 | 6 | 10 | 1T 1W |  | PostRead 248 B | CStrategicResource | 0.03 |
| 136 | CEspionageAssetType | common/espionage_assets | single | CEspionageAssetType | 1568 / 1536 | 36 | 6 | 2T 2M | CEspionageOperationCategories |  | CEspionageOperationCategories, CStaticModifier | 0.01 |
| 137 | CAIEspionageOperationPolicies | common/ai_espionage/operations | single | CAIEspionageOperationPolicy | 128 / 128 | 10 | 1 | 1V |  |  |  | 0.00 |
| 138 | CAIEspionageTargetPolicies | common/ai_espionage/targets | single | CAIEspionageTargetPolicy | 128 / 128 | 0 | 1 | 1V |  |  |  | 0.00 |
| 139 | CCrisisPerk | common/menace_perks | single | CCrisisPerk | 1536 / 1528 | 90 | 5 | 1E 2M |  | PostRead 60 B | CStaticModifier | 0.03 |
| 140 | CCrisisLevelType | common/crisis_levels | single | CCrisisLevelType | 512 / 488 | 25 | 4 | 1T 1E | CCrisisPerk | PostRead 61 B, flags | CCrisisPerk, CEventChain | 0.01 |
| 141 | CCrisisObjective | common/crisis_objectives | single | CCrisisObjective | 352 / 336 | 37 | 3 | 1T 1V |  |  |  | 0.00 |
| 142 | CCrisisPathType | common/crisis_paths | single | CCrisisPathType | 168 / 168 | 5 | 3 |  | CCrisisLevelType, CCrisisObjective | PostRead 61 B | CCrisisLevelType, CCrisisObjective | 0.00 |
| 143 | CIntelCategory | common/intel_categories | single | CIntelCategory | 96 / 96 | 29 | 1 |  |  | PostRead 645 B |  | 0.00 |
| 144 | CIntelLevel | common/intel_levels | single | CIntelLevel | 136 / 136 | 11 | 3 |  |  | PostRead 308 B | CIntelCategory | 0.00 |
| 145 | CDlcRecommendation | dlc_metadata/dlc_recommendations | single | CDlcRecommendation | 96 / 96 | 19 | 1 |  |  | Init, PostRead 61 B |  | 0.00 |
| 146 | CGalacticCommunityAction | common/galactic_community_actions | single | CGalacticCommunityAction | 368 / 368 | 2 | 1 |  |  | Init | CEconomicCategory, CStrategicResource | 0.00 |
| 147 | CGreetingOverlaySound | common/greeting_overlay_sounds | single | CGreetingOverlaySound | 392 / 376 | 3 | 3 | 1T 1V |  |  |  | 0.00 |
| 148 | CAgreementTerm | common/agreement_terms | single | CAgreementTerm | 304 / 288 | 17 | 3 | 1T |  |  |  | 0.00 |
| 149 | CAgreementTermValue | common/agreement_term_values | single | CAgreementTermValue | 4048 / 4000 | 46 | 26 | 4T 2E 2V | CAgreementTerm, CStrategicResource | PostRead 60 B, flags | CAgreementTerm, CEconomicCategory, CStaticModifier, CStrategicResource | 0.01 |
| 150 | CTradableAction | common/tradable_actions | single | CTradableAction | 1472 / 1400 | 8 | 18 | 3T 3E 1V 1W |  | PostRead 69 B | CStrategicResource | 0.01 |
| 151 | CSpecialistSubjectPerk | common/specialist_subject_perks | single | CSpecialistSubjectPerk | 2192 / 2176 | 47 | 8 | 2E |  | PostRead 60 B, flags | CStaticModifier | 0.01 |
| 152 | CSpecialistSubjectType | common/specialist_subject_types | single | CSpecialistSubjectType | 568 / 560 | 4 | 6 | 1E | CEthic | PostRead 269 B | CEthic, CSpecialistSubjectPerk | 0.00 |
| 153 | CAgreementPreset | common/agreement_presets | single | CAgreementPreset | 672 / 656 | 56 | 11 | 1T 2V | CSpecialistSubjectType | PostRead 60 B, flags | CAgreementTerm, CAgreementTermValue, CSpecialistSubjectType, CStrategicResource | 0.01 |
| 154 | CAgreementResourceTemplate | common/agreement_resources | single | CAgreementResourceTemplate | 368 / 368 | 1 | 1 |  |  | Init | CEconomicCategory, CStrategicResource | 0.00 |
| 155 | CPreFTLTechAgesType | common/technology_ages/preftl | single | CPreFTLTechAgesType | 128 / 128 | 10 | 2 |  |  | PostRead 416 B |  | 0.00 |
| 156 | CCloakingStrengthLevel | common/cloaking_strength_levels | single | CCloakingStrengthLevel | 600 / 600 | 11 | 4 | 1M |  |  | CStaticModifier | 0.00 |
| 157 | CDustCloudType | common/dust_clouds | single | CDustCloudType | 992 / 960 | 3 | 7 | 1T 2E |  | PostRead 135 B |  | 0.00 |
| 158 | CStormType | common/storm_types | single | CCosmicStormType | 2144 / 2096 | 10 | 37 | 8T 4E 8V |  | PostRead 61 B | CStaticModifier | 0.00 |
| 159 | CMission | common/missions/missions | single | CMissionType | 3456 / 3288 | 102 | 33 | 8T 8E 1V | CEventChain, CMissionCategory, CSituationLogCategory; deferred: CSituationLogCategory | PostRead 60 B, flags | CEventChain, CStrategicResource | 0.08 |
| 160 | CMutation | common/mutations | single | CMutation | 328 / 328 | 119 | 13 |  |  | PostRead 511 B, InitPostRead 1087 B |  | 0.01 |
| 161 | CCountryFocusCardCategory | common/country_focus/card_categories | single | CCountryFocusCardCategory | 744 / 744 | 4 | 10 | 1W |  | PostRead 60 B, InitPostRead 728 B | CEconomicCategory, CStrategicResource | 0.00 |
| 162 | CCountryFocusCard | common/country_focus/focus_cards | single | CCountryFocusCardType | 376 / 376 | 147 | 8 |  | CCountryFocusCardCategory | PostRead 19 B, InitPostRead 355 B | CCountryFocusCardCategory | 0.03 |
| 163 | CTimelineEventDefinition | common/timeline_events | single | CTimelineEventDefinition | 272 / 272 | 193 | 7 |  |  | PostRead 229 B |  | 0.00 |
| 164 | CEventManager |  | own |  | db 712 / ? |  | db: 8 |  |  | flags | CArmyType, CBuildingType, CDistrictType, CEmpireFlag, CEthic, CEventChain, CGfxCulture, CJobType, CLeaderClass, CPlanetClass, CShipCategory, CSpeciesClass, CSpecimen, CStrategicResource, CTimelineEventDefinition, CTraitTag, CZoneType | 1.71 |
| 165 | CDepositTypes | common/deposits | single | CDepositType | 3160 / 3104 | 596 | 33 | 6T 1E 3M 2W | CDepositCategories | PostRead 278 B, flags | CArmyType, CEconomicCategory, CStaticModifier, CStrategicResource, CZoneType | 0.14 |
| 166 | CDecisions | common/decisions | single | CDecision | 3016 / 2912 | 112 | 18 | 5T 4E 1V |  | PostRead 61 B, flags | CBuildingType, CDistrictType, CEconomicCategory, CEthic, CStrategicResource, CZoneType | 0.04 |
| 167 | CSituationType | common/situations | single | CSituationType | 3208 / 3144 | 90 | 42 | 7T 4E 2V 2M | CSituationLogCategory; deferred: CSituationLogCategory | Init, PostRead 381 B, modifiers, flags | CEconomicCategory, CNamedColor, CStaticModifier, CStrategicResource | 0.10 |
| 168 | CStrategicResourceGuiGroup | interface/resource_groups | single | CStrategicResourceGuiGroupType | 288 / 288 | 22 | 9 |  | CSituationType, CStrategicResource | PostRead 89 B | CSituationType, CStrategicResource | 0.00 |
| 169 | COnAction | common/on_actions | own |  | db 152 / ? |  | db: 16 |  |  |  |  | 0.02 |
| 170 | CArchaeologicalSiteType | common/archaeological_site_types | single | CArchaeologicalSiteType | 1472 / 1400 | 124 | 14 | 4T 3E 1V | CSituationLogCategory; deferred: CSituationLogCategory | PostRead 60 B |  | 0.03 |
| 171 | CGovernmentCivicType | common/governments/civics | single | CGovernmentCivicType | 2000 / 1936 | 358 | 34 | 2T 1M 2W | CPlanetClass | Init, PostRead 60 B | CPlanetClass, CStaticModifier | 0.05 |
| 172 | CGovernmentCouncilorType | common/governments/councilors | single | CGovernmentCouncilorType | 1320 / 1272 | 179 | 15 | 4T 2V 1M | CGovernmentCivicType, CLeaderClass | PostRead 60 B | CGovernmentCivicType, CLeaderClass, CStaticModifier | 0.04 |
| 173 | CGovernmentAuthorityType | common/governments/authorities | extendable | CGovernmentAuthorityType | 1080 / 1064 | 8 | 25 | 1T 1M 1W | CGovernmentCouncilorType | Init, PostRead 60 B | CGovernmentCouncilorType, CStaticModifier | 0.03 |
| 174 | CPrescriptedSpecies |  | own |  | db 24 / ? |  | db: 1 |  |  |  |  | 0.01 |
| 175 | CEmpireDesign |  | own |  | db 3264 / ? |  | db: 4 |  |  | PostRead 388 B | CEmpireFlag, CEmpireScriptedFlagsType, CEthic, CGovernmentAuthorityType, CGovernmentCivicType, CGovernmentType, CLeaderClass, CPlanetClass, CShipSize, CSpeciesClass | 0.05 |
| 176 | CFirstContactStage | common/first_contact | single | CFirstContactStage | 1208 / 1152 | 100 | 9 | 2T 3E |  | PostRead 210 B |  | 0.01 |
| 177 | CAstralRiftType | common/astral_rifts | single | CAstralRiftType | 280 / 280 | 32 | 8 | 1E 1V | CSituationLogCategory; deferred: CSituationLogCategory | PostRead 60 B, flags |  | 0.00 |
| 178 | CEspionageOperationType | common/espionage_operation_types | single | CEspionageOperationType | 2000 / 1904 | 27 | 22 | 6T 2E | CEspionageOperationCategories | InitPostRead 2334 B, modifiers | CEconomicCategory, CEspionageOperationCategories, CStrategicResource | 0.02 |
| 179 | CTraditionType | common/traditions | single | CTraditionType | 1688 / 1640 | 234 | 13 | 3T 2E 1W | CTraditionCategory | PostRead 283 B | CStaticModifier | 0.15 |
| 180 | CTraditionCategory | common/tradition_categories | single | CTraditionCategory | 456 / 440 | 33 | 7 | 2T 1W | CTraditionType | PostRead 60 B | CTraditionType | 0.02 |
| 181 | CAscensionPerk | common/ascension_perks | single | CTraditionType | 1688 / 1640 | 49 | 13 | 3T 2E 1W | CTraditionCategory | PostRead 113 B | CStaticModifier | 0.06 |
| 182 | CAscensionPerkCategory | common/ascension_perk_categories | single | CAscensionPerkCategory | 96 / 96 | 2 | 1 |  | CTraditionType |  | CAscensionPerk | 0.00 |
| 183 | CAISpyNetworkStrategies | common/ai_espionage/spynetworks | single | CAISpyNetworkStrategy | 216 / 216 | 3 | 4 | 2V |  |  | CAIEspionageOperationPolicies, CEspionageOperationType | 0.01 |
| 184 | CCountryFocusReward | common/country_focus/focus_rewards | single | CCountryFocusRewardType | 200 / 200 | 30 | 6 | 1E | CCountryFocusCardCategory | PostRead 276 B, InitPostRead 230 B | CCountryFocusCardCategory | 0.00 |
| 185 | CPatronType | common/patrons | single | CPatronType | 872 / 856 | 14 | 22 | 1T | CPatronCallingType, CPatronDeedType, CPsionicAuraType | PostRead 60 B | CStaticModifier, CStrategicResource | 0.01 |
| 186 | CPsionicAuraType | common/patrons/psionic_auras | single | CPsionicAuraType | 2200 / 2128 | 9 | 25 | 8T 7E 3V |  | PostRead 61 B | CStaticModifier | 0.03 |
| 187 | CPatronDeedType | common/patrons/deeds | single | CPatronDeedType | 368 / 344 | 56 | 4 | 1T |  | PostRead 60 B |  | 0.00 |
| 188 | CPatronCallingType | common/patrons/callings | single | CPatronCallingType | 704 / 672 | 29 | 5 | 1T 2E |  | PostRead 60 B |  | 0.00 |
| 189 | COverclockType | common/megastructure_overclock_types | single | COverclockType | 2824 / 2776 | 12 | 13 | 2T 2E 3M 1W |  | PostRead 60 B | CEconomicCategory, CStaticModifier, CStrategicResource | 0.00 |
| 190 | CMissionCategory | common/missions/mission_categories | single | CMissionCategory | 176 / 176 | 22 | 4 |  |  |  |  | 0.00 |
| 191 | CScriptedAction | common/scripted_actions | single | CScriptedActionInfo | 3672 / 3592 | 56 | 46 | 6T |  | PostRead 344 B, InitPostRead 523 B, flags | CStrategicResource | 0.02 |
| 192 | CShipDesignTemplates |  | own |  | db 120 / ? |  | db: 5 |  |  |  | CComponentSlotTemplate, CEconomicCategory, CGfxCulture, CPlanetDestructionGraphics, CProjectileGfx, CScriptedAction, CShipBehavior, CShipSize, CStaticModifier, CStrategicResource, CTargetType | 1.04 |
| 193 | CDesigner | common/global_ship_designs/ | own |  | db 48 / ? |  | db: 2 |  |  | PostRead 1278 B | CShipDesignTemplates, CShipSize | 0.06 |
| 194 | CMegaStructureType | common/megastructures | single | CMegaStructureType | 9296 / 9064 | 164 | 71 | 10T 9E 5M 2W | CBypassType, COverclockType, CScriptedAction, CStarbaseLevelType, CSystemTooltip | Init, PostRead 882 B, InitPostRead 1783 B, modifiers, flags | CBypassType, CEconomicCategory, CEventChain, CGfxCulture, COverclockType, CScriptedAction, CStarbaseLevelType, CStaticModifier, CStrategicResource, CSystemTooltip | 0.20 |
| 195 | CStarbaseModule | common/starbase_modules | single | CStarbaseModule | 7824 / 7672 | 130 | 53 | 17T 5E 9M 3W | CTechnology | PostRead 223 B, InitPostRead 5 B, flags | CEconomicCategory, CShipDesignTemplates, CStaticModifier, CStrategicResource, CTechnology | 0.07 |
| 196 | CStarbaseBuilding | common/starbase_buildings | single | CStarbaseBuilding | 7856 / 7704 | 117 | 52 | 17T 5E 9M 3W | CTechnology | PostRead 175 B, flags | CEconomicCategory, CStaticModifier, CStrategicResource, CTechnology | 0.03 |
| 197 | CResourceConverter | common/resource_converters | single | CResourceConverter | 184 / 168 | 1 | 4 |  | CSituationType, CStrategicResource | PostRead 60 B | CSituationType, CStrategicResource | 0.00 |
| 198 | CCountryType | common/country_types | single | CCountryType | 2192 / 2144 | 101 | 23 | 1T | COwnershipLimits, CShipSize | Init, PostRead 60 B, InitPostRead 221 B, modifiers | CEconomicCategory, COwnershipLimits, CStrategicResource | 0.05 |

## 3. How Lua could build them

What has to be reproduced for a database to be "built", by the evidence above:
- the objects, in index order, with their vtables, index, key and members;
- `_Array`, plus `_Lookup` for a hashed database;
- the references: at once, or registered with the resolver for consumers the game still reads;
- the script members, with their global registrations;
- `InitPostRead` (the objects') and the database's own `Init` work;
- the error messages of the read.

`PostReadInitInstance` and the resolver keep running: they are the game's passes over whatever is
in the databases [V: the proof's databases went through them].

### (a) Lua feeds the game's readers

Lua parses (pdxscript, or a cached form) and serves the game's `CReader` tokens from its trees. The
game's `ReadMember` and everything after it run unchanged.

- **What it takes.** The runtime already does this one level down. The Windows lexer replacement
  (`lua/stellar/script/lexer.lua`, `lexer.txt` replace) gives the game's readers Lua's tokens, and
  every reader of the load reads them. Serving tokens from a tree instead of a text is a small step
  from there.
- **What can break.** Little: the member logic, the allocations and the registrations stay the
  game's. Locations come out right if the tokens keep their lines.
- **Shadow.** Already done for the lexer: the game reads, and every token is compared.
- **Speed.** It removes only the lexing. Reading is a small part of the 17 s; the C++ construction
  (the modifier scans, the post-read work) all stays.
- **Against the goal.** The game's construction code runs for every database. This is the kind of
  speed-up the project does not want: the aim is to replace the game's construction, not to feed
  it faster.

### (b) Lua constructs the objects directly

Lua allocates each object with the game's allocator and writes its vtables, index, key and
members. It appends the object to `_Array` and does the object's and the database's own work. The
game's `Init` never runs.

- **What it takes, per database:**
  - the object's layout: offsets, vtables, what the constructor sets;
  - the key-to-member map of its `ReadMember`, with each member's reading rule;
  - its `InitPostRead` and the database's `Init` extras;
  - for script members, building the compiled trigger, effect and value trees itself: 2,178
    classes (1,098 triggers, 1,080 effects, script_engine.md), each with its own members and
    registrations.

  Across the 163 template databases that is about 2,000 members. The PDB lists them all, and the
  `ReadMember` token switches give the keys (`/root/fnm_tmp/members452.tsv` on hippo already
  extracts them for some classes). The script classes are most of the work.
- **What can break:**
  - **vtables:** the right vtable and offset per base, two or three per object; MSVC and Itanium
    differ (1.2);
  - **`CString`:** use the game's constructor (its allocator head, its own allocate for long
    strings);
  - **`CPdxArray`:** its vptr, and grow it through the game's insert;
  - **allocators:** the game's `malloc`, so that its destructors (reload, shutdown) can free the
    memory;
  - **null objects** for missing keys;
  - **hashed lookups:** insert into `_Lookup` too;
  - **the file watcher's reloads,** which re-read through the game's code;
  - **global numbering:** modifier type ids, script flags and dynamic tokens must come out in the
    game's order, or `modifiers.log` and the saves differ;
  - **the error log:** the game's messages for malformed script.
- **Shadow.** Build both and compare object by object, by the schema for data members and
  structurally for the rest (section 6 does both).
- **Speed.** Parsing (cacheable to nothing, section 4) and direct writes. The quadratic C++ work
  goes away once the modifier definitions are Lua's.

### (c) The hybrid — recommended

Lua does (b) for everything that is data: the object, vtables, index, key, scalars, strings,
tokens, colours, references, arrays of references, and the database's own work (cached pointers).
For the script members, Lua gives the game's compiler only those statements: a `CReader` over a
text of their own lines, then the object's own `Read`. The compiled trees, their locations and
their registrations are then the game's [V: section 6].

- **Cost.** Per database, a schema of its data members, which can mostly be generated from the
  PDB and the `ReadMember` switches, and the database's own work. Nothing per script class.
- **What can break.** As in (b) for the data. The script part is the game's own code on the
  object's own lines, so it is right by construction, but the reading has to be set up the way the
  game sets it up:
  - the file name is the definition's file;
  - the lines are the original lines;
  - the object's `Read` is called as `ReadNewEntry` calls it;
  - `InitPostRead` then runs with the reader's lines, which are the member's lines rather than the
    object's.
- **Shadow.** The same as (b). For the script members, a structural comparison of the two object
  graphs: RTTI names the classes on Linux, the PDB-typed spider (`lua/stellar/spider.lua`) does on
  Windows.
- **Speed.** Data members cost nothing. The script compilation still costs what it costs (not
  measured here). The cost that loading.md and 1.7 point to is the modifier generation, which is
  data and moves to Lua in the same schema work.
- **The way forward:**
  1. **Database by database.** A database with a schema is Lua's. One without stays with the game
     (the prototype's `HEADLESS_DB` list; on Windows, `databases.locate` already has every
     `InitInstance` to hook).
  2. **Then the modifier definitions.** Generate them in Lua, in the game's numbering order, and
     add them in bulk, which removes the quadratic `TryAddDynamicModifier`.
  3. **Then the scripts.** The script layer (script_engine.md, "Toward a Lua script layer")
     evaluates triggers and effects in Lua. Its compiled C++ objects are needed only where C++
     still evaluates them, until those callers move.

## 4. The shared representation

The simulation needs the same definitions (simulation.md section 6). Today
`sim/lua/engine/defs.lua` reads every folder lazily as parsed trees: name -> `{ block, file, line }`,
through `stellar.script.source.definitions`, where a later definition replaces an earlier one in a
map.

The data layer ([data_layer.md](data_layer.md), `sim/lua/engine/store/`) puts the world and the
definitions into one shared-memory store, readable by several Lua threads through the FFI:
- **Entries and blocks.** Entries are 16 bytes: a key string id, a kind, an operator, flags, and a
  value (string id, number or block id). Blocks are contiguous entries, with a key index above 16
  entries. Strings are interned.
- **Typed arrays** for the engine's own state.
- **The definitions.** `engine/store/defs.lua` stores them as one tree under root 1:
  `folder -> name -> the definition's pdxscript block`, the names sorted.

**Where the two designs agree** (data_layer.md sections 6 and 7, and this document). The
definitions are one generic tree in that store, the source for both:
- the simulation reads definitions as blocks, which it already does;
- typed records per database are built once from the trees: data_layer.md's "a `country_type`
  array of structs indexed by database index, names to indexes in a map, shared by the
  simulation's workers and handed to the C++ side in the injected game". This document's schema
  layer (below) is what builds them, and the in-game builder writes the C++ objects from the same
  records;
- script members stay blocks of the tree. The simulation evaluates them in Lua; the builder hands
  the block's lines to the game's compiler (section 6), or later builds them.

**Where they differ today.** The store's definitions are sorted by name, keep the last definition,
and keep no lines (data_layer.md section 2: "Lines and comments are not kept"). The builder needs
both the order and the lines, and so do typed records "indexed by database index" (points 1 and 2
below).

The store is plain memory with a C header (`pdx_store`) and a Rust allocator. The injected runtime
is built with cargo too, so the game process can hold the same store.

**What the builder needs that the store does not have yet:**

1. **The game's order and duplicate rule.**
   - `_Index` is the order of first appearance: the files in name order, then the statements in
     order.
   - A later duplicate replaces the object but keeps its index (single-object databases), or
     merges into it (extendable ones, 1.3).
   - `engine.defs` and `store/defs.lua` keep a map of the last definition, with names sorted. The
     builder needs the folder's definitions in index order, each with its merged or replaced block.
     `headless/dev/db/records.lua` does this.
   - Proposal: `store/defs.lua` keeps the block's entries in load order. It could also keep the
     list of a key's blocks for extendable databases, or the folder's kind could decide the rule
     when the store is built.
2. **Locations.** The game's compiled objects keep "file: X line: N" (`_FileLocationDesc`). Error
   messages need them too.
   - The store's entries have no line.
   - Proposal: a parallel array of 8 bytes per entry, `{ file id, line }`, or at least per block
     `{ file, first, last }`. The builder needs the first and last line of each script member;
     `records.lua` finds the last line by matching braces in the file text.
   - `S.write` gives the same tree but one entry per line, not the file's lines. So the builder
     slices the original text, which needs the file and the lines, and it is what keeps the
     game's locations.
3. **The schema layer.** Per database:
   - the folder and its kind;
   - each member's key, its value type (colour, int, fixed point, bool, token, a reference to
     database X, a list of them, a struct of flags, a script member) and its default;
   - the database's own work.

   This is game knowledge, the same on both sides, so it belongs with the definitions, not in the
   builder. The C++ side (offsets, vtables) is per build and stays with the builder
   (`headless/dev/db/layout.lua`; on Windows, from the PDB).
4. **Resolved references (optional).** The store can keep a reference as the key's string id; each
   side resolves it in its own world, a database index in the simulation and an object pointer in
   the game. The simulation would gain typed columns: one FFI array per database and member
   (`int16 tier[679]`), built once from the blocks by the schema, as `store/arrays.lua` already does
   for engine state.

**A cache.** The store is plain memory, so the definitions can be written to disk after one parse
and mapped at the next start. The game's database phase then begins with no text read at all, and
the simulation starts the same way.

## 5. What the proof shows about speed

These five databases are tiny, so the times say little about the whole:

| database | objects | the game's `Init` | Lua: read and parse | Lua: objects |
|---|---|---|---|---|
| `CNamedColorDatabase` | 89 | 0.2-0.3 ms | 5.5-7 ms | 0.3 ms |
| `CTraitTagDatabase`, `CJobTagDatabase` | 58, 34 | 0.1 ms | 4-5 ms | 0.2-0.3 ms |
| `CAIAttitudesDatabase` | 24 | 0.1 ms | 5 ms | 0.4 ms |
| `CAIEspionageOperationPoliciesDatabase` | 10 | 0.3 ms | 5 ms | 1.3 ms (with the game compiling the scripts) |

- **Reading.** Most of Lua's 5 ms is listing the folder: `source.files` uses `ls` through `popen`
  on Linux, a fork of a game process of several GB. The parse of a small folder is about 1.4 ms in
  a standalone LuaJIT [V].
- **The whole corpus.** pdxscript parses all of the game's script, 54 MB, in about 3.8 s
  (simulation.md section 7). That is less than the database phase and can be cached away
  (section 4). Most of the phase is the work after the read (1.7).
- **Building.** Writing objects is microseconds per object.

## 6. The proof: Lua builds databases in the headless game

`headless/dev/db_headless.c` is the headless driver (`../headless.c`, included unchanged) linked
with LuaJIT (the repo's `lib/luajit`, built static and position-independent).
- It detours each chosen database's `TGameDatabase<DB>::InitInstance` to a stub that calls Lua:
  `dbbuild.init(name, mode)`.
- It gives Lua the executable's symbols (`hdb_sym`).
- When the save is launched, after every database and post-read pass, it calls
  `dbbuild.after_load` for the census and the dump.

The Lua side is in `headless/dev/db/`:

| file | |
|---|---|
| `records.lua` | the folder's files -> records in the game's order and duplicate rule: index, key, file, line, typed fields; script members as their statements. No game memory: the same code runs offline and could run in the simulation |
| `layout.lua` | the Linux 4.5.2 side, through the FFI: the template's layout, five schemas (offsets, vtables, the constructor's defaults, the database's own work), and the game's primitives: `CString`, `CPdxArray::InsertAtEmplace`, `CStaticLexer::FindTok`, the null objects, and a `CReader` over a text (`CMemoryFile` + `CTextLexer` + `CReader`, as `CGameState::Load` makes them) |
| `dbbuild.lua` | records -> objects in the instance `CreateInstance` made; the controls; the shadow comparison (the game's own `Init` into a second instance made by the database's constructor, then object by object); the dump and the census |
| `deep.lua` | a structural comparison of two object graphs without their classes: RTTI names polymorphic objects, `CPdxArray` (by its RTTI name) and `CString` are compared by content, heap blocks are followed by glibc's chunk headers |
| `databases_452.tsv` | the 198 databases, kind and object class (for the census) |

### What Lua builds, per database

- **`CNamedColorDatabase`** (89 objects; data only).
  - `calloc(1, 0x58)`;
  - vptrs at +0 and +0x40 (`_ZTV11CNamedColor` + 0x10 and + 0x40);
  - `_Index` at +8 and `_Key` at +0x10 through `CString::CString`;
  - `CColor` at +0x48, by `CReader::Read(CColor&)`'s rule (white by default);
  - appended with the game's `InsertAtEmplace`.
- **`CTraitTagDatabase`, `CJobTagDatabase`** (58 and 34 objects; keys only).
  - The files are lists of words: the database's `KeysOnly` mode, where each word is an object and
    nothing is read for it.
  - `calloc(1, 0x40)`: one vptr, `_Index`, `_Key`.
  - The game's own readers of other databases look these up by key: traits through
    `ReadKeyReference<CTraitTagDatabase>`, jobs through `ReadKeyReferenceUniform<CJobTagDatabase>`.
    They find Lua's objects in `_Array`.
- **`CAIAttitudesDatabase`** (24 objects).
  - The same, plus the `SBehaviour` struct at +0x48: its own vptr, then 6 bools read by
    `SBehaviour::ReadMember`'s tokens (`attack` +0x50 ... `vassalize` +0x55).
  - `_Token` at +0x58: the `type` word's static lexer id, 13262 (`null`) by default.
  - The database's own work (`CAIAttitudesDatabase::Init` after the base `Init`): 24
    `TCachedDBPtr` members of the database, set to the first object with the key.
- **`CAIEspionageOperationPoliciesDatabase`** (10 objects, the hybrid).
  - The object (0x80 bytes; `CScriptableValue` at +0x40, made by the game's
    `CScriptableValue(EScopeType, bool)`) is Lua's.
  - Its `weight = { ... }` statements go to the game: a reader over a text that holds them at their
    own lines of `common/ai_espionage/operations/00_base_policies.txt`, inside `x = { }`, and the
    file's name on the `CMemoryFile`. Then `ReadSimpleStatement`, and the object's own `Read`
    (slot 3, as `ReadNewEntry` calls it).
  - The game compiles the script values: `CTriggerMTTHModifier`s with their trigger trees,
    registered in the trigger database as when it reads the file.

Lua refuses a class whose `InitPostRead` is not `CPersistent`'s: its work would be skipped. This
is checked on the vtable.

### Results

All runs load `autosave_2210.01.01.sav` and run 300 ticks (30 days) with the defaults
(`-loadrandomseed -threads=1`). The baseline is an unmodified `headless/run.sh` of the same save.

| run | what | objects compared | gamestate vs baseline (1,463,952 lines) | error.log | census (163 databases, 14,992 objects) |
|---|---|---|---|---|---|
| shadow, named colours | Lua builds; the game's `Init` builds a second copy | 89, 0 mismatches (also after the post-reads) | 0 lines differ | identical | |
| lua, named colours | the game's `Init` never runs | | 0 | identical | |
| shadow, named colours + attitudes | | 89 + 24, 0 mismatches, cached pointers equal | 0 | | |
| lua, named colours + attitudes | | | 0 | | |
| shadow, espionage policies (hybrid) | data by schema; object graphs structurally | 10: 2 differences, both creation-order ids (below) | | | |
| lua, named colours + attitudes + espionage policies | | | 0 | identical | identical |
| shadow, trait and job tags (with the three above by Lua) | | 58 + 34, 0 mismatches | 0 | identical | |
| **lua, all five** | Lua builds the five | | **0** | **identical** | **identical** |
| game, all five | the game's `Init` through the same hooks (control) | | 0 | identical | identical |
| control: attitudes without the database's own work | the 24 cached pointers left as the null objects | | **32 lines differ** (ethics attraction values) | | |
| control: trait tag `organic` left out | one record dropped, the others numbered again | | 0 | **220 lines more**: the game's trait reader fails to find `organic` in Lua's database ("Failed to read key reference 'organic' from database '17CTraitTagDatabase' at file: common/traits/02_species_traits_basic_characteristics.txt line: 26", ...) | |
| control: attitudes, `neutral` without `trade` | one value of one record changed | | 0 (not read in these 30 days) | | |

What the controls show:
- **The game runs on Lua's databases.** `CAIAttitudesDatabase` is used within the 30 days, and
  leaving out its `CacheItem` work changes the game.
- **The game's readers use them.** The trait reader, still the game's, resolves its tags in the
  database Lua made.
- **The limit of the gamestate check.** A value the game does not read in 30 days is not checked
  by the gamestate, only by the shadow.

The espionage shadow compares each object's whole graph: the policy, its `CScriptableValue`, the
`CTriggerMTTHModifier`s, `CContextTrigger`s and leaf triggers, their arrays, strings and
locations. The two differences are a 16-bit counter in `CHasDefensivePactTrigger` (+0x3a0) and in
`CIsGalacticCommunityMemberTrigger` (+0x200): `0x76cb` against `0x76cc`, and `0x5664` against
`0x5666` in another run. They increase with each object made, so they are creation order: Lua's
copy is made before the shadow [I].

Getting the structural comparison clean took three things, because the game leaves memory
unwritten:
- the fill pattern (`MALLOC_PERTURB_=165` and `GLIBC_TUNABLES=glibc.malloc.tcache_count=0` for the
  shadow run, so that every allocation is filled);
- arrays and strings compared by their used part only;
- bytes that are padding next to a smaller member (a fill byte on one side, zero on the other: 19
  qwords) left out.

The first comparisons reported hundreds of differences (495, before the statements were at their
own lines), nearly all of them in memory the game never wrote.

### Run it

On 10.5.0.24 (the game in `/opt/stellaris-headless/game`; LuaJIT and the driver are built in
`DB_ROOT=/opt/stellaris-headless/dbwork` on the first run; nothing in the repo is written):

```
H=/zpool0/share/code_working/stellarstellaris-sim/headless
S=/opt/stellaris-saves/autosave_2210.01.01.sav
O=/opt/stellaris-headless/dbwork/out
bash $H/run.sh $S 300 $O/base300.gamestate                       # the baseline
ALL=CNamedColorDatabase,CJobTagDatabase,CTraitTagDatabase,CAIAttitudesDatabase,CAIEspionageOperationPoliciesDatabase
HEADLESS_DB=$ALL HEADLESS_DB_DUMP=1 HEADLESS_DB_CENSUS=1 bash $H/dev/db_run.sh $S 300 $O/lua5.gamestate
bash $H/dev/gsdiff.sh $O/base300.gamestate $O/lua5.gamestate | wc -l    # 0
# shadow: the game's Init into a second instance, compared object by object (the driver's log)
HEADLESS_DB="CNamedColorDatabase:shadow,CTraitTagDatabase:shadow,CJobTagDatabase:shadow,CAIAttitudesDatabase:shadow" \
  bash $H/dev/db_run.sh $S 300 $O/s.gamestate
MALLOC_PERTURB_=165 GLIBC_TUNABLES=glibc.malloc.tcache_count=0 \
  HEADLESS_DB="CAIEspionageOperationPoliciesDatabase:shadow" bash $H/dev/db_run.sh $S 300 $O/e.gamestate
# controls
HEADLESS_DB="CAIAttitudesDatabase:lua" HEADLESS_DB_NOPOST=1 bash $H/dev/db_run.sh $S 300 $O/nopost.gamestate
HEADLESS_DB="CTraitTagDatabase:lua" HEADLESS_DB_PERTURB=drop:organic bash $H/dev/db_run.sh $S 300 $O/drop.gamestate
```

- **Modes** (`HEADLESS_DB="<database>:<mode>,..."`): `lua` (the default), `shadow` (the game's
  `Init` also builds a second instance, compared object by object), `game` (the game's `Init`
  through the same hook).
- **Controls:** `HEADLESS_DB_NOPOST=1`, `HEADLESS_DB_PERTURB="<key>.<field>[.<member>]=<value>"`
  and `HEADLESS_DB_PERTURB=drop:<key>`.
- **Outputs next to `<out>`:** `.dump.txt` (`HEADLESS_DB_DUMP=1`), `.census.tsv`
  (`HEADLESS_DB_CENSUS=1`), `.error.log`, `.time.log`. The driver's log is the run's output.
- **If Lua fails** for a database, the game's `Init` runs instead and the log says so.

### Limits of the prototype

- **Offsets.** The schemas are written by hand from the Linux code. On Windows they would come from
  the PDB, and for most members they could be generated (section 3).
- **References.** Lua's databases are read by the game's (the tags), but none of the five reads a
  reference itself. The next step is a database that does, at once and deferred, and a hashed one
  (its `_Lookup` filled too).
- **Folder listing.** `records.lua` lists folders through `stellar.script.source`, which uses
  `popen("ls")` on Linux. A shared fix (an FFI `opendir` there) would serve both the game and the
  simulation.
- **Fallback.** When Lua fails partway, the objects it already appended stay before the game's
  `Init` runs. Fine for the prototype, not for production.
- **`include`.** It uses `headless.c` by `#include`. A change there (another agent's work in
  progress was uncommitted during these runs) is compiled in.
