# Modifiers and the economy (4.5.2)

Reverse engineered from the GOG 4.5.2 build and its PDB (static analysis: disassembly, call graph,
class layouts), checked against the game's own documentation (`modifiers.log`) and the vanilla
script files. Addresses are GOG RVAs (image base `0x140000000`). **[V]** marks what was verified in
the disassembly or the PDB (the instruction or call is given), **[I]** what is inferred from names,
call lists or logs. Nothing here was measured at runtime yet.

The Lua replacement built on this is described in [modifier_graph.md](modifier_graph.md).

## In short

- A modifier type is an index into one global array of 45,583 definitions; 711 are built in code,
  44,872 are generated while the databases load (economic categories, ship sizes, jobs, ...).
- A value set (`CModifier`) is two unsorted parallel arrays (types, `{value, type}` entries): every
  read is a linear scan. Values are fixed point, 1.0 = 100000.
- Every object with modifiers has a modifier node (`NModifierNode::CModifierNode`): its whole
  `CModifier`, rebuilt from scratch (clear, then the object's `CalculateModifier`) whenever it is
  invalidated. A node reads its parents' nodes (a ship its fleet's, a fleet its country's, ...)
  through `AddModifierNode`, which recomputes the parent first if it is stale and registers the
  child; the dependency edges are discovered while computing and consumed by invalidation.
- Invalidation is eager and transitive (filtered by category masks); the recomputation is batched:
  `CModifierNodeManager::Update` runs a task graph of the 34 node categories, after every root
  effect, after each player command, twice a day, at the start of the monthly update, and at load.
- The economy (`CEconomicUnitBase::ApplyModifiersToTable<N>`) reads modifier values by linear
  search for every entry of every resource table, every time: there is no cache and no dirty flag.
  Income is computed once a month (a task graph over all registered economic units); the UI
  recomputes production, upkeep and ship design costs every frame (planet view, its tooltips,
  fleet and outliner buttons).

## Values: CFixedPoint

`CFixedPoint` is a signed int64 with 1.0 = 100000 (5 decimals) **[V]**: `AddModifierEntry(entry,
mult)` computes `a*b`, multiplies by `0x29F16B11C6D1E109` and shifts right by 14 (a division by
100000), with an overflow-safe slow path when an operand is outside +/-3037000499;
`ApplyModifiersToTable` initializes multipliers with `mov eax, 100000`. (`fpml::fixed_point<int64,
48, 15>` is another type, used for military power and one `ApplyModifierMult` overload.)

## Definitions

### ModifierType and `_Definitions`

`ModifierType` is an index into `CPdxModifier<ModifierType, ModifierCategory, CModifier,
CDefaultPdxModifierValueReader>::_Definitions`, a `CPdxArray<CPdxModifierDefinition>` at
`0x2800248` (data `0x2800250`, size `0x280025c`) **[V]**. The PDB enum has 571 named types
(`_MOD_BLANK_MODIFIER_` = 0 to 570); 571 (`_NUM_MODIFIERTYPES_`) is also the "none" sentinel of
economic category tables (`cmp ecx, 571`), and `0x7FFFFFFF` (`_MAX_MODIFIER_TYPE_`) is what a
failed name lookup returns. Generated types are numbered from 571 in creation order: line k of
`modifiers.log` is type k.

`CPdxModifierDefinition<ModifierType, ModifierCategory>` (176 bytes) **[V]**:

| offset | member | |
|---|---|---|
| `+0x00` | `CString _Tag` | localization key: `MOD_POP_HAPPINESS`, `MOD_<name>` for generated types |
| `+0x30` | `CString _Icon` | resolved by `InitDefinitionIcons` |
| `+0x60` | `CString _PostFix` | e.g. "YEARS" |
| `+0x90` | `int _Token` | the lexer token of the script name |
| `+0x94` | `ModifierType _Type` | |
| `+0x98` | `int _nMaxDecimals` | |
| `+0x9c` | `ModifierCategory _Category` | a mask, see below |
| `+0xa0` | `CFixedPoint _vMultMin` | the floor of `1 + v` in `ApplyModifierMult` |
| `+0xa8` | `_Settings` | ShowAsPercent 1, Good 2, Hidden 4, Neutral 8, NoDiff 16, CapZeroToOne 32 (reads clamp to [0, 1]), AddPostFixSpacing 64, LocalizeWithValueKey 128, ReferencedFromScript 256, ScriptedModifier 512, Used `0x20000000` (set by `AddModifierEntry`), DEBUG_DynamicallyAdded `0x40000000` |

Name lookup is a linear scan of the 45,583 definitions comparing `_Token`, with a 176-byte stride
**[V]**: `CModifier::GetTypeFromToken` (`0x36e380`), `CPdxModifier::TryReadMember` (`0x23af70`,
every modifier key read from script), and `CModifier::TryAddDynamicModifier` (`0x36e710`, every
generated modifier, after `CStaticLexer::AddDynamicToken`). Generating the definitions is therefore
quadratic, about 10^9 compares **[V]** (the algorithm) / **[I]** (its share of the load time, not
measured).

### How they are made

- **`CModifier::InitDefinitions`** (`0x35c970`, from `CGameApplication::InitGame` before the
  databases) **[V]**: returns if already done, reserves 5120, then 575 `AddDefinition` calls
  (`0x376c50`) for types 0-570 (four types are defined twice, identically), a few icons and post
  fixes, and `InitShipClassModifiers` (`0x3765a0` -> `CShipClassModifierHelper::Init`): 14 engine
  ship classes x 10 (`shipclass_<class>_build_cost_mult`, ...), types 571-710.
- **The generators** run in the databases' `InitPostRead` / `PostReadInit` during
  `NNullObjAndDatabaseInitUtil::SetupDatabases` (9 to 26 seconds into the load, see
  [loading.md](loading.md)); all call `TryAddDynamicModifier` **[V]** (callers). By index range in
  `modifiers.log` **[V]**, attributed to a generator by name pattern and callers **[I]**:

| types | count | names | generator |
|---|---|---|---|
| 0-570 | 571 | built in | `InitDefinitions` |
| 571-710 | 140 | `shipclass_*` | `CShipClassModifierHelper` |
| 711-827 | 117 | weapon types, slots, weapon tags | `CWeaponTagModifierHelper::CreateModifierType` |
| 828-1035 | 208 | 26 resources x 8 (stockpiles, starbase collection) | `CStrategicResource`, `CStrategicResourceModifierGenerator` |
| 1036-1105 | 70 | `op_cat_*` | `CEspionageOperationCategory` |
| 1106-8463 | 7,358 | economic categories | `CEconomicCategory::GenerateModifiers` (`0x1654a10`) -> `FillModifierTable<0/1>` |
| 8464-8528 | 65 | species archetypes, ethics attraction, bypasses | `CSpeciesArchetype`, `CEthicModifierGenerator`, `CBypassTypeDatabase` |
| 8529-9613 | 1,085 | building and district build speed, district max | `CBuildingTypeDatabase`, `CDistrictTypeDatabase` |
| 9614-9820 | 207 | `pc_<class>_*` | `CPlanetClassModifierGenerator` |
| 9821-41401 | 31,581 | `shipsize_<size>_<base>`: 319 sizes x 99 | `CShipSize::CreateModifiers` (`0xd29c00`): 98 base types in a table, plus build speed |
| 41402-44382 | 2,981 | `pop_cat_*`; 365 jobs x 8 (`job_<J>_add`, `job_<J>_per_pop`, ...) | `CPopCategory`, `CJobType`, `CJobTypeModifierGenerator` |
| 44383-45255 | 873 | resolutions, anomalies, situations, espionage operations, megastructures, country types, tech categories, leader classes | their databases |
| 45256-45393 | 138 | `common/scripted_modifiers` | `CScriptedModifier::PostReadInit` (`0x8b3060`) |
| 45394-45582 | 189 | councilors, patrons | `CGovernmentCouncilorType`, `CPatronType` |

  Ship sizes alone make 69% of all types. `CScriptedModifier::PostReadInit` can redefine an
  existing type (it logs "Modifier `%s` already exists!" but overwrites the flags) **[V]**.
- **`CModifier::InitDefinitionIcons`** (`0x36e950`, end of `SetupDatabases`) **[V]**: for each
  definition, the sprite `GFX_<icon>` from `gfx/interface/icons/modifiers/<icon>.dds`, created if
  the file exists, else "Missing modifier icon" once per icon.
- **`CModifier::LogDefinitions`** (`0x36d980`, after `CEventManager::InitEventConnectivityMaps`)
  **[V]** writes `modifiers.log`: a header, then `- <name>, Category: <labels>` per type in index
  order (`GetModifierCategoryName`, `0x35bfc0`). [loading.md](loading.md) measured 3.7 s for it.
- **`CEconomicCategory::LogUnusedGenerated{Add,Mult,Triggered}Modifiers`** (`0x1654e70`,
  `0x1654fa0`, `0x1655160`, right after `LogDefinitions`) **[V]**: diagnostics only: "Generated
  'add' modifiers for table ... is never used from script" when no generated type of a table has
  ReferencedFromScript. No runtime effect.

### Economic category names

From `CEconomicCategory::ReadMember` / `FillModifierTable` and the string tables at `0x2460920`
(`cost`, `produces`, `upkeep`, `logistics`) and `0x2460960` (`add`, `mult`) **[V]**, and checked
against `modifiers.log` with `tools/graph_mapping.lua` (vanilla: 270 categories, 26 resources;
**all 7,758 names the rules make are in the log**):

- `generate_mult_modifiers = { T }`: `<cat>_<T>_mult` (every resource) and `<cat>_<res>_<T>_mult`.
- `generate_add_modifiers = { T }`: `<cat>_<res>_<T>_add` only (there is no all-resource add).
- `triggered_<T>_modifier = { key = K modifier_types = { add mult } trigger = { } }`:
  `<K>_<res>_<T>_<add|mult>` and `<K>_<T>_mult`.
- `modifier_category = x` sets the category bit (default Economic Units); AI Economy is always set.

### ModifierCategory

A bit mask **[V]** (PDB enum). Each definition has one (`_Category`, `+0x9c`); each `CModifier`
has a filter (`_Categories`, `+0xac`, default all). The labels are what `modifiers.log` prints:

| value | label | value | label |
|---|---|---|---|
| 2 | Pops | 32768 | Deposits |
| 4 | Orbital Stations | 65536 | Megastructures |
| 8 | Space Stations | 131072 | Habitability |
| 16 | Military Ships | 262144 | Starbases |
| 32 | Civilian Ships | 524288 | Economic Units |
| 64 | Science Ships | 1048576 | Star Systems |
| 128 | Fleets | 2097152 | Waystations |
| 256 | Countries | 4194304 | Federations |
| 512 | Armies | 8388608 | Espionage |
| 1024 | Leaders | 16777216 | AI Economy |
| 2048 | Planets | 33554432 | Ship Design Stats |
| 4096 | Ship Components | 67108864 | Astral Rift |
| 8192 | Pop Factions | 134217728 | Cosmic Storm Influence Field |
| 16384 | Transport Ships | 268435456 | Owned Ships |
| 16508 | Ships (stations and the four ship kinds) | 536870912 | Galactic Community |
| -1 | All | 1073741824 | Colony |

In `modifiers.log`: Ships 20,948 definitions, AI Economy 7,363, Colony 6,674, Pops 1,433,
Countries 1,307, ... (`GetModifierCategoryFromToken`, `0x35c810`, maps script names such as
`country` or `pop_group` to these values; the exact mapping is **[I]**).

## A value set: CModifier

`CModifier` (184 bytes) is a `CPdxModifier<...>` with no members of its own **[V]**:

| offset | member | |
|---|---|---|
| `+0x00` | vtable (`CPersistent`) | `0x2332a58` |
| `+0x08` | `CPdxHybridArray<ModifierType, 4> _EntryTypes` | data `+0x10`, size `+0x1c`, 4 inline |
| `+0x30` | `CPdxHybridArray<CPdxModifierEntry, 4> _Entries` | data `+0x38`, size `+0x44`; an entry is `{ CFixedPoint _vValue, ModifierType _Type }`, 16 bytes |
| `+0x88` | `CPdxModifierParents _Added` | the parents added into it (`{ modifier, multiplier, name, category filter }`): the tooltip breakdown |
| `+0xa0` | `CPdxModifierName _Name` | |
| `+0xa8` | `int _nDepth` | 1 by default |
| `+0xac` | `ModifierCategory _Categories` | the filter, -1 by default |
| `+0xb0` | `bool _bLoadEmpty` | |

Operations **[V]**:

- `GetValueOptional` (`0x16d7be0`) and the inlined `GetValue`: linear scan of `_EntryTypes`, the
  value of the matching entry, clamped to [0, 1] for CapZeroToOne definitions.
- `AddModifierEntry(entry)` (`0x232430`): dropped if `def._Category & _Categories` is 0; otherwise
  added to the existing entry of that type, or appended (the arrays stay unsorted).
  `AddModifierEntry(entry, mult)` (`0x232670`) adds `value * mult / 100000`.
- `AddModifierInternal(src, allocator, mult, include, exclude, name)` (`0x2328b0`): every entry of
  `src` whose category meets `_Categories & include` and not `exclude`, added as above (the plain
  version when mult is 1.0). If `_nDepth > 0` and something was added, it also records the parent:
  a clone of `src` (`Clone`, from a pooled, refcounted allocator) in `_Added`. Wrappers:
  `AddModifier<CModifier / CStaticModifier / CCustomDescriptionModifier / CPdxModifierParent>`;
  `AddModifierValueOnly` (`0x3e6f80`) does not record **[I]**.
- `CalcModifierMult` (`0x36e5b0`): `max(minMult, 1 +/- v)`; `ApplyModifierMult` (`0x36e3c0`): `base *
  max(def._vMultMin, 1 + v)`.
- Reading script: `CModifier::TryReadMember` (`0x36df60`) reads a modifier key, or a static
  modifier's key (`CStaticModifierDatabase::GetStaticModifier`, then adds that modifier times the
  value); unknown keys are queued (`CPostInitModifierDatabase`) and retried after the static
  modifiers are read, then logged "Invalid modifier".

So every modifier is additive: an object's value of a type is the sum of its entries.
"Multiplicative" modifiers (`_mult`) are sums too; the code that uses them applies `1 + sum`
(`ApplyModifierMult`, the economy below). Entries added with a multiplier are rounded per entry, so
the order of additions can change the last digit of scaled values **[I]**.

## The modifier databases

- **`CStaticModifierDatabase`** (`common/static_modifiers`, `_pInstance` `0x3100bc8`, `Init`
  `0x3742c0`, late in `InitGame`) **[V]**: an array of `CStaticModifier` (464 bytes: a
  `CGraphicalModifier`, i.e. a `CModifier` with icon and tooltip, plus `_Key` at `+0x168` and flags
  ApplyToOtherPlanets 1, FullyRead 2, DivideOverPopGroups 4), about 120 of them cached in members
  (`_pEmpireBase`, `_pPopBase`, ...). `GetStaticModifier(key)` (`0x3754f0`) is a linear scan of the
  keys. Vanilla: 3,095 static modifiers, 5,975 modifier entries (`tools/graph_mapping.lua`).
- **Triggered modifiers** (`CTriggeredModifierBase<CStaticModifier>`, 1,352 bytes: key, a
  `CFixedPointVariableValue _Mult`, the `CStaticModifier`, a potential trigger) **[V]**: added by
  `AddModifierIfPotential` when the owner rebuilds its triggered modifiers
  (`CModifier::AddTriggeredModifiers<...>`, from `UpdateTriggeredModifiers` of pop groups, ships,
  fleets, edicts, traits, relics, ...) **[I]**. `NTriggeredModifier::PopulateOutModifiers`
  (`0xa31c10`) evaluates a list into a sorted (modifier, mult) array, and `IsArraysSame`
  (`0x77fee0`) lets starbase, waystation and building caches invalidate a node only when the active
  set changed **[V]**.
- **`CScriptedModifierDatabase`** (`common/scripted_modifiers`, 138 in vanilla) defines new, empty
  modifier types with their display settings **[V]**.
- **`CPlanetModifierDatabase`** (`common/planet_modifiers`): random planet modifiers at galaxy
  generation (`CPlanet::RandomizePlanetModifiers`) **[V]**.
- **Timed modifiers** (`add_modifier = { modifier = x days = n }`) **[V]**: `CTimedModifier` (40
  bytes: the `CStaticModifier`, `_nDaysLeft` (-1 permanent), `_vMult`, clear on owner change) in
  a `CTimedModifierCollection` on the object (`CCountry +0x1a28`, `CColonyCarrier +0x260` (planets,
  ships), `CFleet +0x2a8`, `CPopGroup +0x420`, `CStarbase +0x1328`, `CGalacticObject +0x670`,
  `CMegaStructure +0x620`, ...). `CTimedModifierCollection::DailyUpdate` (`0x373990`) counts the
  days down and removes the expired entries (returns true if any), from each object's daily
  update; `CollectModifier` (`0x373a70`) adds them in `CalculateModifier`. `CAddModifierEffect`
  (`0x17ccb40`) calls the scope's `AddTimedModifier`, then invalidates its node.

## Per-object modifier nodes

### The node

`NModifierNode::CModifierNodeBase<CModifier, EModifierNodeCategory>` (360 bytes) **[V]**:

| offset | member | |
|---|---|---|
| `+0x00` | `const CNodeTypeInstance *_NodeType` | `{ type_index, EModifierNodeCategory _Category (+8), span _Dependencies (+0x10) }` |
| `+0x08` | `uint _NodeId` | -1 when not registered; index in the low 20 bits (`and 0xFFFFF`), a version above |
| `+0x0c` | `uint _OwnerId` | |
| `+0x10` | `std::function _CalculateFunction` | the object's `CalculateModifier` |
| `+0x50` | `CModifier _Modifier` | the value set (built with a depth and a category filter given by each object type) |
| `+0x108` | `atomic<bool> _Invalidated` | |
| `+0x110` | `CPdxMutex _UpdateMutex` | (an SRW lock) |
| `+0x124` | `CPdxReadWriteLock _ChildNodesLock` | a spin lock |
| `+0x128` | `CPdxUnorderedSet<uint> _ChildNodes` | the ids of the nodes that read this one |
| `+0x150` | `CPdxPooledModifierAllocator` | for the parent clones of `_Modifier._Added` |

The manager, `NModifierNode::CModifierNodeManager<CModifier, EModifierNodeCategory>` (2,432
bytes, `CGameStateDatabase +0x0`, `_pInstance` `0x31003b8`) **[V]**: `_Registry` (`+0x0`, an
array of `{ id, ..., node * }`, 24 bytes each), `_UpdateGraph` (`+0x28`, a `CPdxGraphJob`),
`_ThreadInvalidNodes` (`+0x30`, per thread an array of 34 sets of node ids), `_InvalidNodes`
(`+0x80`, 34 arrays of nodes), `_Updating` (`+0x900`), `_Dirty` (`+0x901`),
`_AllowInvalidateFromAddModifier` (`+0x948`), `_UpdateLocked` (`+0x949`).

### The 34 node categories and what reads what

`EModifierNodeCategory` **[V]** (PDB enum). Each node type is `CModifierNode<CModifier, E, N,
SDependencies<...>>`: the template lists the node categories it reads, and
`CModifierNodeManager::BuildDependencyGraph` (`0x2a1d40`) builds its task graph from these lists
(`CNodeTypeInstance::_Dependencies`) **[V]**. Read from the PDB types of the members:

| # | category | held by | reads (declared dependencies) |
|---|---|---|---|
| 0 | CountryRelayNetwork | relay network manager | |
| 1 | Country | `CCountry +0x3150` | 9 Federation, 25 StarbaseCountry, 33 WaystationNetworkCountry |
| 2-7 | GalacticObjectTimed, -Leader, -CosmicStorm, -PsionicAura, -PopJob, -Building | `CGalacticObject +0x748 ... +0xe50` | |
| 8 | LeaderSkill | `CLeader +0x130` | |
| 9 | Federation | `CFederation +0x108` | |
| 10 | GalacticCommunity | | |
| 11 | EspionageOperation | | 13 |
| 12 | Sector | `CSector +0x1f0` | |
| 13 | SpyNetwork | | 1, 8 |
| 14 | Orbital | `CStarbase +0xfa0`, `CMegaStructure +0x350` | |
| 15 | CosmicStorm | | |
| 16 | Planet | `CPlanet +0x700` | 3, 12, 26, 0, 4, 5, 1 Country, 27, 21 |
| 17 | Colony | `CColony +0x120` | 16 Planet, 31 Ship (the carrier ship [I]), ... (the PDB name is truncated) |
| 18 | AstralRift | | 1 |
| 19 | Leader | `CLeader +0x298` | 1 |
| 20 | MegaStructure | `CMegaStructure +0x1e8` | 8, 1 |
| 21 | MegaStructureSystem | `CMegaStructure +0x4b8` | |
| 22 | PopGroup | `CPopGroup +0x18` | 17 Colony, ... |
| 23 | Fleet | `CFleet +0x10a8` | 2, 3, 12, 14, 8, 1 Country, 5, 4, 29 Starbase, 26, 21 |
| 24-28 | StarbaseExternal, -Country, -System, -Planet, -DefensePlatform | `CStarbase +0x898 ... +0x1108` | |
| 29 | Starbase | `CStarbase +0xa00` | 3, 12, 24, 4, 5, 1, 0, 32 |
| 30 | Army | `CArmy +0x330` | 8, 1, 17 Colony, 31 Ship, ... |
| 31 | Ship | `CShip +0xa78` | 23 Fleet, 28, 27 |
| 32-33 | WaystationNetworkSystem, -Country | | |

So a ship's value of a type is its own sources plus its fleet's whole value (which holds the
country's, the system's, the leader's, the starbase's, ...): every node holds a merged copy of
everything above it. Some objects also keep plain `CModifier` caches outside the nodes
(`CShip _ConstantModifier +0xbe0`, `_AurasModifier +0xd28`; `CColony` designation-scaled sets
`+0x2a0 ... +0x4c8`; `CPopJob _SystemModifiers +0xf8`; `CLeader _RulerTriggeredModifiers +0x8e8`).

### Computing a node

- **`CModifierNodeBase::Update`** (`0x239330`) **[V]**: if registered and `_Invalidated`, under
  `_UpdateMutex`: clear `_Invalidated`, clear `_Modifier` (vtable `+128`, with the node's
  allocator), call `_CalculateFunction`. A full rebuild: nothing is incremental.
- **`CalculateModifier`** of each object (`CShip` `0xcb26d0`, `CFleet` `0xc77700`, `CCountry`
  `0x7091f0`, `CPlanet` `0xe02880`, `CLeader` `0x8928a0`, ...) **[V]** (call lists) adds static
  modifiers (`AddStaticModifier`), timed modifiers (`CTimedModifierCollection::CollectModifier`),
  triggered modifiers (evaluating their triggers), situation modifiers, and its parents' nodes
  through `AddModifierNode`. The country's also adds contributions computed from other objects:
  buildings, jobs and pop groups of its colonies scaled by their amount
  (`CColony::ApplyBuildingUntriggeredModifiersToCountry`, `CPopJob::CalcAmountMultiplier`, ...),
  agreements, federation, council, AI difficulty. `CPlanet::CalculateModifier` ends with
  `CPlanet::UpdateEconomicResources`.
- **`AddModifierNode(this, parent, mult, mask)`** (`0x232b40`) **[V]**: `parent->Update()` (pull:
  a stale parent is recomputed first, on this thread), `AddModifierInternal(parent's modifier,
  mult, mask)`, then if `_AllowInvalidateFromAddModifier`, `InvalidateChildren(this, the
  categories added)`, and finally `AddExplicitDependency(this, parent)` (`0x232a90`): this node's
  id into the parent's `_ChildNodes`. The edges are discovered while computing.

### Invalidation

- **`CModifierNodeBase::Invalidate(mask)`** (`0x23a770`) **[V]**: nothing if the node is not
  registered, or if its `_Modifier._Categories` filter meets neither the mask (0 or -1 always
  pass); else set `_Invalidated`, `InvalidateChildren(mask)`, and
  `CModifierNodeManager::MarkNodeAsInvalid(id, category)`.
- **`InvalidateChildren(mask)`** (`0x239460`) **[V]**: for every child id (looked up in the
  registry, version checked), `child->Invalidate(mask)`, recursively; the children that were
  invalidated (and the dead ones) are removed from `_ChildNodes`: an edge lives until its first
  invalidation, and is registered again when the child is recomputed. It does not stop at a node
  that is already invalid, so a node reached by several paths is visited again each time.
- **`MarkNodeAsInvalid(id, category)`** (`0x23a6f0`) **[V]**: the id into this thread's set for
  that category, and `_Dirty = 1`.
- **`InvalidateAllModifiers`** (`0x29e3e0`): every registered node.

About 136 functions call `MarkNodeAsInvalid` (directly or inlined) **[V]**, and the objects'
`InvalidateModifier` functions are called from about 80 more. The kinds of events:

- Country: technologies (`CTechnologyStatus::IncreaseTechnologyLevel`), traditions, ascension
  perks, edicts, policies, civics and government, ethics, relics, timed modifiers, wars,
  federations, agreements, council and ruler, galactic community resolutions, situations, owned
  colonies, megastructures and starbases, daily (`CCountry::DailyUpdateSerial`,
  `DailyUpdateSelfDontReadOthers`) and monthly updates.
- Colony and planet: buildings and districts finished, repaired, replaced or removed, pops added or
  removed, designation, governor, branch offices, owner and controller, monthly growth, job
  updates (`CColony::EnsurePopJobsAreUpToDate`, `NPlanetJobs::TryAssignPopsToJob`).
- Fleet and ship: ships added or removed, merges, leaders, orbit entered, combat start and end,
  cloaking, owner change, timed modifiers.
- Leaders (traits, skill level, class, location), pop groups (daily update, faction approval,
  habitability traits), starbases (level, buildings and modules, triggered modifiers), sectors,
  espionage, waystations, relay networks, the effects `add_modifier`, `remove_modifier`,
  `add_trait`, `change_leader_class`, ...
- Load and new game: `CGameState::OnNewGameStarted`, `ClearModifiers`, `RegisterNode`.

### Recomputation: `CModifierNodeManager::Update`

`CModifierNodeManager::Update` (`0x29e250`) **[V]**: returns if `_UpdateLocked` or already
updating, or if `_Dirty` was not set; otherwise clears `_Dirty`, disables
`_AllowInvalidateFromAddModifier`, forbids random numbers (`CRandom::_InForbiddenZone`), runs
`_UpdateGraph` and then cleanup tasks (detached), and restores the flags. Its callers run it under
`g_nThreadSafetyState = 0x40000`.

The graph (`BuildDependencyGraph`, built once in the constructor) has three tasks per node
category **[V]**: `CollectInvalid` (merge the threads' invalid sets into `_InvalidNodes[c]`), then
`ClearInvalid` (a parallel-for clearing those nodes), then `UpdateInvalid` (a parallel-for
computing them); for each declared dependency d of c: `UpdateInvalid(d)` before `UpdateInvalid(c)`
and `ClearInvalid(c)` before `ClearInvalid(d)`. Within a category the nodes are computed in
parallel; a node can also be computed earlier, on demand, by a child's `AddModifierNode`.

When **[V]** (callers):

| caller | when |
|---|---|
| `CRootEffect::Execute` (`0x3ac1b0`) | after every root effect block (events, decisions, on_actions, ...): profile tag "UpdateModifiers" |
| `CEveryInListEffect`, `CRandomInListEffect`, `COrderedListEffect`, `CClosestSystemEffect`, `CEffectOnBlobEffect::ListColonySystemsSorted` | before iterating a list |
| `CSetUpdateModifiersBatch::ExecuteActual` | the effect `set_update_modifiers_batch = begin / end`: locks the updates (`_UpdateLocked`) between begin and end, then updates |
| `CGameState::AfterCommandExecutedUpdate` (`0x24cfb0`) | after each command executed by `CGameApplication::Update` (player actions) |
| `CGameState::DailyUpdate` (`0x25cde0`) | twice: before a parallel phase (`0x25e898`) and after contracts and missions (`0x25eec3`) |
| `CGameState::MonthlyUpdate` (`0x261620`) | at `0x26195f`, right before the budget (`CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>`) |
| `CGameState::RecalculateModifierTrees` (`0x257fc0`) | inside `RecalculateCachedData` (load, new game, lobby start) |

`CGameState::RecalculateCachedData` (`0x2585f0`) **[V]**: `ClearModifiers`, then
`RecalculateModifierTrees`, `InvalidateAllModifiers`, `RecalculateModifierTrees`,
`InvalidateAllModifiers`, `RecalculateModifierTrees`: three full rebuilds, since values computed
from modifiers (jobs, pops, triggered modifiers) feed modifiers again **[I]** (the reason).
`RecalculateModifierTrees` runs `PostClearPreCalcModifiers` (parallel-fors over leaders,
federations, countries, sectors, armies, pop groups, fleets, starbases, planets, colonies, galactic
objects, ships), pop factions, species, pop jobs, galactic objects, the manager's `Update`, then
starbases.

Reads **[V]**: `GetModifier()` returns the node's `_Modifier` as it is (`CShip::GetModifier`
`0x1b03f0`, `CPlanet::GetModifier` `0x2323a0`): possibly stale until the next update.
`UpdateModifier()` (`CShip` `0x1b0500`, `CPlanet` `0x2323b0`) recomputes it first if invalid.

## The economy

From the economy agent's analysis, all **[V]** unless marked.

### Categories and units

`CEconomicCategory` (520 bytes; database `common/economic_categories`): `_pParent` (`+0x90`),
`_PerResourceModifiers` (`+0x98`, per resource: the ModifierType of add and mult for each table),
`_GlobalModifiers` (`+0xb0`, per table: the all-resource mult), `_TriggeredModifiers` (`+0xd0`, per
table: `CTriggeredModifierTable { per-resource types, CRootTrigger, global types }`, 248 bytes),
`_Settings` (`+0x130`: Hidden 1, UseForAIBudget 2, then a bit per table and kind: CostAdd 4,
TrigCostAdd 8, ProducesAdd `0x10`, ..., UpkeepMult `0x1000`, TrigUpkeepMult `0x2000`, Logistics
`0x4000`-`0x20000`), `_ModifierCategory` (`+0x138`). Tables: `EEconomicUnitTableType` Cost 0,
Produces 1, Upkeep 2, Logistics 3.

A resource table (`CTriggeredResourceTable`, 72 bytes) is a list of blocks, each with a trigger, a
`CFixedResourceTable` (one CFixedPoint per strategic resource) and a multiplier: the `resources = {
category = C produces = { ... } upkeep = { ... } }` of a job, building, district, pop category,
ship size, ... (`CEconomicUnitTemplate`, 296 bytes: the category and one table per kind). A unit
is a set of templates with multipliers (`CEconomicUnitTemplateCollection`, entries `{ category,
table, multiplier }`).

### The formula: `ApplyModifiersToTable<N>`

`CEconomicUnitBase<...>::ApplyModifiersToTable<N>` (Cost `0x3cc5f0`, Produces `0x420450`, Upkeep
`0x3cc2d0`, Logistics `0xcc3f70`), with the unit's modifier set M (the node of the object the unit
belongs to), for an entry of category C with scale s:

1. base: the blocks whose trigger holds (`CTriggeredResourceTable::CalcResources`, `0x16d42d0`),
   times their multiplier, times s;
2. if M is empty, stop;
3. add, **own category only**: `base[i] += s * (M[C_<res>_N_add] + the triggered adds of C whose
   trigger holds)`;
4. if every `base[i]` is 0, stop;
5. `G = sum over C and its ancestors of (M[a_N_mult] + their true triggered globals)`;
6. for each resource with `base[i] != 0`: `P[i] = sum over the chain of (M[a_<res>_N_mult] +
   triggered)`, `mult[i] = 1 + max(MIN_ECONOMIC_MODIFIER_MULT, G + P[i])` (the define is at
   `0x313d630`, -0.9 in vanilla);
7. `out[i] = base[i] * mult[i]` (0 if `mult[i] <= 0`).

So `out = s * (base + A) * (1 + max(-0.9, G + P))`: adds are not inherited by child categories,
mults are summed up the whole chain (vanilla's deepest chain has 8 categories, e.g.
`planet_bio_trophies`; `planet_rangers -> planet_researchers -> planet_jobs_specialist ->
planet_jobs_productive -> planet_jobs -> planets -> country`). Every M[x] is a linear search of the
unit's modifier entries. A triggered category modifier's trigger is evaluated only when M has a
non-zero value for its type (`EvalTriggeredPerResourceModifier`, `0x3cfee0`), and never cached.
The work per entry is about chain depth x resources x (1 + triggered blocks) lookups.

Scales: a job is `max(0, (workforce + bonus) / 100)` (`CPopJob::UpdateEconomicResources`
`0x835f90`; `POP_BULK_UNIT_SIZE` = 100), times 0 when the colony is occupied
(`CalcEconomicMultiplier`); a pop group is `size / 100`; buildings 1, districts their count. Jobs
and colony units read the colony's node, a pop group its own, ship designs the country's.

### When it is computed

- **The budget**, monthly: `CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>` (`0x16605d0`)
  right after the modifier update in `MonthlyUpdate`. 22 kinds of economic units are registered
  (`CEconomicUnitManager::_Tables` `0x3103bd0`: megastructures, ships, planets, starbases, armies,
  pop jobs, pop groups, leaders, sectors, colonies, ...); a task graph per kind: "UpdateResources"
  (rebuild the templates), then "CalcProduces" / "CalcUpkeep" (parallel-fors adding into
  per-country, per-category atomic tables), ship upkeep with fleet logistics and navy capacity
  multipliers; then country-level units (country type, edicts, relics, crisis perks), and
  `CCountryBudget::EndMonthlyUpdate<0>` which adds the balance to the stockpile
  (`CEconomyCountryModule::AddResources`). `<1>` runs at load / new game without the stockpile.
  The budget pages (`CCountry +0x1c80`, `_CurrentMonth`, `_LastMonth`) are what the top bar reads
  until the next month.
- **Colony snapshots**, monthly: `NColonyUpdate::MonthlyParallelUpdate` (`0xe3ac40`) recomputes
  each colony's produces, upkeep and profits (`CColony::CalcTableIncludePops<N>`: buildings,
  districts, every job, every pop group), read by triggers, UI and AI; `CStarbase::
  MonthlyUpdateParallel` computes the colony's produces once more.
- **Daily**: job assignment may rebuild job templates (`CPopJob::UpdateEconomicResources`);
  deficits; ship upgrade checks compute design upkeep.
- **No dirty flag and no cache** for production: every value is a full recomputation, scheduled or
  on demand (`EColonyFlags::RecalcPopJobs` drives job assignment, not production).

### What the UI recomputes

- **Planet view** (`CPlanetView::Update`, `0x11d9ee0`, every tab every frame): the summary tab
  recomputes the colony's produces and upkeep (`CalcTableIncludePops<1/2>`); the population tab
  recomputes every job's tables and every pop group's on each job
  (`NPopUtil::CalcTotalProduceUpkeepAndModifier`, `CalcTotalProduceUpkeepAndModifierForPopsWorkingJob`).
  `CPlanetView::GetToolTip` (`0x11ed1f0`) recomputes the colony with tooltip text, every frame
  while shown. Job and pop category tooltips likewise.
- **Fleets and the outliner**: `CFleetActionUpgradeButton::IsValid` and
  `CFleet::HasShipsThatCanBeUpgraded` (outliner entries) reach `CCountry::GetLatestShipDesign`
  (`0x70e1e0`), which computes the upkeep of every candidate design with the country's modifiers
  (`CEconomicUnitCollection<CShipGrowthStageEconomicUnit>::CalcResource<2>`, `0x772510`), every
  frame. Ship and fleet tooltips (`CShip::GetResourceToolTip`, `CFleet::GetObservationPostProduction`,
  `CShip::CalcUpkeep`) recompute per call. (The older profile in
  [performance_notes/selected_fleets_lag.md](performance_notes/selected_fleets_lag.md) names
  `ApplyModifiersToValue` and `CShipDesignEconomicUnit`, which no longer exist in 4.5.2.)
- **Cached**: the resource group windows of colonies and sectors (`CGuiCacheManager`, at
  `g_CurrentInGameIdler +0xf60`) compute once and clear at the monthly update.
- **Modifier tooltips**: the breakdown is the `_Added` tree of clones each `CModifier` records
  while it is built (depth limited per object, e.g. `CColony::CalcTooltipMaxModifierDepth`), so
  every node rebuild copies its parents for tooltips that may never be shown.

## What feeds what

```
script sources (static, timed, triggered modifiers, traits, edicts, techs, buildings, jobs, ...)
   -> CalculateModifier of each object -> its node's CModifier (full rebuild)
country node  <- federation, starbase (country), waystation network; colonies' buildings, jobs,
                 pop groups (by amount), agreements, ...
planet node   <- country, sector, system leader / storms / auras, starbase (planet, system), ...
colony node   <- planet, carrier ship
pop group     <- colony                    fleet <- country, system, leader, starbase, orbital
ship          <- fleet, starbase (defense platforms, planet)
                                              |
economic units (jobs, pop groups, buildings, districts, ships, armies, ...):
   templates {category, table, multiplier} x scale (workforce/100, size/100, count)
   -> ApplyModifiersToTable: (base + own add) x (1 + max(-0.9, chain mults)), modifiers from the
      unit's node, triggers evaluated each time
   -> monthly: per-country categorized income/expenses -> budget pages -> stockpile
   -> monthly: colony produces/upkeep snapshots (triggers, UI, AI)
   -> every frame: planet view, its tooltips, fleet/outliner upgrade checks (design upkeep)
values computed from modifiers (jobs, housing, stability, pop counts) -> modifiers again
   (country contributions; three rebuild passes at load)
```

## Open points

- The full dependency lists of the Colony, PopGroup and Army nodes (their PDB names are
  truncated); read them from `CNodeTypeInstance::_Dependencies` at runtime.
- Which node modifiers are built with depth 0 (no parent clones), per object type.
- The cost of the quadratic definition lookups and of `LogDefinitions` at load (measure).
- 41 keys in vanilla `common/static_modifiers` are not types in `modifiers.log` (e.g.
  `specialist_and_complex_drone_cat_bonus_workforce_mult`); check the game's error log for
  "Invalid modifier".
- Runtime confirmation of the call frequencies (hooks on `CModifierNodeManager::Update`,
  `CModifierNodeBase::Update`, `ApplyModifiersToTable<N>`): counts per frame and per tick.
