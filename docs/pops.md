# Pop growth and decline (4.5.2)

What the game does to its pops each month, reverse engineered statically from the GOG 4.5.2 build
and its PDB on hippo (`/root/fnm_tmp`: `annotate.py`, `pdbtype.py`, the call graph), and what
[`sim/lua/engine/pops.lua`](../sim/lua/engine/pops.lua) models of it. Addresses are GOG RVAs.
**[V]** marks what was read in the disassembly (the address is given), **[I]** what is inferred
(from names, the script files, or checked only against saves). The annotated dumps the notes were
taken from are in `H:\code_working\tmp_pops\re\`.

Numbers are the game's fixed point (`CFixedPoint`, int64, 1.0 = 100000). `a * b` is
`trunc(a * b / 100000)` and `a / b` is `trunc(a * 100000 / b)` (toward zero; the game splits the
operands when they are large, which these values never are); a division by zero gives
`0xFFFFFFFF`. pops.lua computes with LuaJIT int64 to get the same truncations.

## In short

- **Monthly, in `NColonyUpdate::MonthlyUpdate`** (`0xe3a7c0`, the monthly `colonies` phase): the pop
  groups' `can_procreate` flags; per colony in parallel the **demography** (growth, assembly and
  decline of the month, as amounts per species); per colony in order colonization, auto-migration,
  **growth, assembly, decline** applied; the jobs update twice; per colony the month's **growth
  bookkeeping** (`last_month_growth`, `month_start_size`, the colony's growth data).
- **Growth** is logistic per (base) species: `0.0025 * (n - n^2 / K - 1)` with `K` the species' size
  plus the colony's free housing plus 400 (the planet class's `carry_cap_per_free_district`) per free
  district; the species' values are rescaled to sum within `[0.1, the galaxy's logistic ceiling]`;
  each pop group gets its share times `1 + logistic_growth_mult (+ founder, archetype, trait
  modifiers)`, plus bonus growth, all divided by the country's growth scale
  `1 + 0.25 * employable pops / 10000`. The month's growth of a species is the sum over its groups,
  rounded up or down at random (the fraction is the chance to round up).
- **Checked against the game**: from each save's sizes before its last month, the expected growth of
  every growing (colony, species) has the game's integer as its floor or ceiling: **24 of 24** in the
  2210.01.01 save, **24 of 24** in 2210.07.01; in the later saves all but the clone-vat colony
  (whose captured bonus growth went stale). Assembly likewise (4.96 expected, the game 4 and 5).
- **The new pops' category** comes from the jobs update (`NPlanetJobs::UpdatePopJobs`), not modelled:
  pops.lua puts them in the species' civilian/unemployment group (a stand-in).
- **Daily, not monthly**: happiness, political power, crime, amenities and housing usage, habitability
  (`CPopGroup::DailyUpdateOnlyChangeSafePrivate`), ethics drift and factions
  (`CPopGroup::DailyUpdateSerial`), the colony's employable/unemployed/civilian counts, stability,
  crime, amenities (`CColony::DailyUpdateSelfDontReadOthers`, `MicroUpdateCachedValues`). Housing is
  modelled (`pops.daily`), the rest is not.

## 1. The month: `NColonyUpdate::MonthlyUpdate` (`0xe3a7c0`) **[V]**

Called from `CGameState::MonthlyUpdate` (`0x262103`) after `CAgreementManager::MonthlyUpdate` and
`CPlanetManager::ProcessUpdateData`, with the colonies' array (`CGameState +1448`), the date and the
month's **pool of 1,000 random values**: `CGameState::MonthlyUpdate` draws it first thing
(`CRandom::GetIntegersForMacro(1000)`, `0x2616b3`) and hands the same pool to the countries'
parallel update and to the colonies.

| # | what | where |
|---|---|---|
| 1 | every pop group: `CPopGroup::UpdateCanProcreate` (parallel): `can_procreate` from `CGameRules::CanSpeciesProcreate` (infertile species, the species rights' population control, the rule `can_species_procreate`), `can_crossbreed` from a scripted rule | `MonthlyUpdatePopGroupsCanProcreate` lambda `0xe3aad0` |
| 2 | the static per-colony `SDemographySafePrivate` array cleared and sized to the colonies | `0xe3a844` |
| 3 | `NColonyUpdate::MonthlyParallelUpdate` (`0xe3ac40`), four parallel passes over the colonies: | |
| 3a | `CColony::CalcAutoMigrationSafePrivate` (auto-migration's choices) | `CColonyUpdateParallelFunc` `0xe3ab80` |
| 3b | `CColonyDemographyCalculator::MonthlyUpdateSafePrivate(colony, pool[(colony id + 266) % 1000], safe)` (section 2), then `CCountry::UpdateWildernessData` | lambda 12 `0xe3ee30` |
| 3c | `CColony::CalcTableIncludePops<2>` and `<1>`: the colony's own `upkeep` and `produces`, `profits` = produces - upkeep (the units of its jobs, buildings, districts, zones, pop groups) | lambda 13 `0xe3b190` |
| 3d | the tables swapped in; `CColony::UpdateDesignation`; `CColony::MonthlyAutoModUpdate` (habitability auto-modding: `CalcNumMonthlyAutoModdedPops`, `AUTO_MOD_BASE`, `auto_mod_monthly_add/_mult`) | lambda 14 `0xe3d480` |
| 4 | `NColonyUpdate::MonthlySerialUpdate` (`0xe3b350`) -> `CColony::MonthlyUpdateSerial` (`0xdc2c20`) per colony: invalid buildings and districts cleared; **`GrowColonists(pool[(colony id + 6601) % 1000])`** when the colony is being colonized; `ApplyAutoMigrationResults`; **`ApplyMonthlyGrowth`, `ApplyMonthlyAssembly`, `ApplyMonthlyDecline`** (section 3); `InvalidateModifier` if any changed; occupation armies | |
| 5 | `NPlanetJobs::UpdatePopJobs`, twice (unless a cheat flag): the jobs, and with them the pops' categories | `0xe3a9a9` |
| 6 | every colony: **`CColony::UpdateCachedGrowth`** (section 4) | `0xe3aa32` |

A colony's id in the pool index is its full reference (`TPdxRef`: index and generation), the key of
the save's `colony` store.

## 2. The demography: `CColonyDemographyCalculator::MonthlyUpdateSafePrivate` (`0xe514a0`) **[V]**

Writes the colony's `SDemographySafePrivate` (120 bytes): `_PopGroupScores` (per pop group of the
colony, in its order: `{ group, growth, decline }`, fixed point), `_SpeciesScores` (per species:
the same, summed), `_AssemblyScore` (`{ species, amount }`), `_BaseSpeciesGrowthData` (base species
-> `{ size, logistic growth }`), `_PopGroupsToGrow` (species -> its largest scored group).

1. A score entry per pop group of the colony (`colony._PopGroups`, the save's `pop_groups` list).
2. Skipped to the decline (step 6) when the colony is being colonized (`_ColonizingSpeciesRef`
   `+0x48`, the save's `colonizing_species`), its owner is not a country, or the owner's country type
   lacks `HasPopGrowth` (`ECountryTypeFlags` bit 38: `pop_growth = yes` in `common/country_types`,
   only `default` and `awakened_fallen_empire`).
3. `canDecline = CGameRules::CanPopsDeclineOnColony` (rule `can_pops_decline_on_colony`).
4. **Growth**: `CalcBaseSpeciesGrowthData`, then per pop group `CalcGrowthForPopGroup`; a positive
   result is the group's growth score.
5. **Assembly**, when the rule `can_pops_assemble_on_colony` holds: `CalcBestSpeciesToAssemble`, then
   `CalcMonthlyPopAssemblyAmount`; if positive: `n = trunc(amount)`, plus one when a draw's remainder
   is not above the fraction (below); `_AssemblyScore = { species, n }` when `n > 0`.
6. **Decline**, when `canDecline`: per pop group, if `ShouldDecline`: `n = trunc(CalcMonthlyDeclineAmount)`
   (no random part), the group's decline score `n` when `n > 0`.
7. The species' scores: the groups with a growth or decline, in the colony's order, summed by
   species (the group's own species, not the base species); `_PopGroupsToGrow[species]` = the
   largest such group (the first on a tie).
8. Each species' growth rounded: `n = trunc(growth)`, plus one when the draw's remainder is not above
   the fraction; the score becomes `n`.

**The random draws** are not the global generator's. From the pool value `v`, a local
`CNoiseRandom { position = noise(v, 0x5EA6BA9F), seed = 0 }` (the same Squirrel3 function as the
global generator, all 32 bits); each draw is `CNoiseRandom::GetInt64` (`0x1b50900`):
`((noise(p, 0) & 0x7FFFFFFF) << 32) + noise(p + 1, 0)`, the position advanced by 2, and the
remainder modulo 100000 is compared with the fraction. The assembly's stream and the species'
stream both start at that position (the assembly's draw is the first species' draw again).

### 2.1 `CalcBaseSpeciesGrowthData` (`0xe51fd0`)

- Nothing when the rule `can_pops_grow_on_colony` fails, or when the colony is overcrowded:
  `CColony::IsOvercrowdingHaltingGrowthGeneric(OVERCROWDING_NO_GROWTH_THRESHOLD 1.15,
  OVERCROWDING_ABSOLUTE_THRESHOLD_FOR_NO_GROWTH 5)` (`0xdb5bf0`): free housing negative, housing
  usage - housing at least 5, and usage / housing at least 1.15.
- `crossbreed = CGameRules::CanCrossbreedSpeciesOnColony` (rule `can_crossbreed_species_on_colony`).
- Per pop group with `CanProcreate` (`EPopGroupFlags` 8, the save's `can_procreate`): the key is -1
  when crossbreeding and the group has `CanProcreate | CanCrossbreed`, else its base species
  (`CSpecies::GetBaseSpecies`: the save's `base_ref`); the key's size += the group's size.
- Per key: `CalcLogisticGrowthModifier(size)`; their total `T`.
- If `T > 0` and `T < LOGISTIC_POP_GROWTH_FLOOR` (0.1) or `T > logistic ceiling` (the galaxy's
  `logistic_ceiling_v2`, `CGalaxyConfiguration::_vLogisticCeiling` `+0xf0`, 5 here): every key's
  value times `target / T` (the floor or the ceiling).

### 2.2 `CalcLogisticGrowthModifier(size)` (`0xe525b0`)

```
n = max(size, LOGISTIC_POP_GROWTH_MIN_POPS)                     -- 10
K = min(MAX_CARRYING_CAPACITY, districts + size + free_housing) -- 50000; districts: 2.3
K = max(K, 1.0)
LG = LOGISTIC_POP_GROWTH_R * (n - n^2 / K - 1)                  -- R = 0.0025
if n / K < LOGISTIC_POP_GROWTH_LOWER_THRESHOLD and LG < 1: LG = 1   -- threshold 0: never
```

`free_housing` is the colony's cached free housing (`+0xf98`, the save's `free_housing`), which the
day's update computed before the month's (section 6). `CalcCarryingCapacity` (`0xe52540`, the
tooltip's) is the same `K` without the floor.

### 2.3 Free districts: `CalcCarryingCapacityFromDistricts` (`0xe550e0`)

```
districts = (CColonyCarrier::CalcMaxDistricts - CColony::CalcNumDistricts(true))
            * planet class carry_cap_per_free_district          -- @carry_cap_normal 400 (300, 600)
          + max(0, planet_carry_cap_add)                        -- colony modifier, id 154
```

- `CColony::CalcNumDistricts(colony, true)` (`0xdc95b0`): the sum of the colony's districts' `level`,
  plus the district items in its planet's build queue (`build_queue`; items whose buildable is a
  `CDistrictType` of this colony).
- `CColonyCarrier::CalcMaxDistricts(false)` (`0xccc980`):
  `NUM_DISTRICTS_BASE (0) + trunc(planet_size * NUM_DISTRICTS_FROM_PLANET_SIZE (1)) +
  trunc(<class>_max_districts_add)` and, when the planet class has
  `inherit_country_district_modifiers` (default yes, `EPlanetClassSettingsType` bit 34):
  `+ trunc(planet_max_districts_add) + trunc(planet_(non_)artificial_max_districts_add)` (by
  `is_artificial_planet`), the sum times `max(1 + planet_max_districts_mult, the modifier's minimum)`,
  truncated; at least 1.

### 2.4 `CalcGrowthForPopGroup` (`0xe528b0`)

```
e = base data of the group's key (-1 when it procreates, crossbreeds and -1 is there; else its base species)
G = 0
if e and e.size > 0 and the group CanProcreate:
    G = BASE_POP_GROWTH (1) * e.LG
    if G != 0:
        G = G * CPopGroup::CalcMonthlyGrowthMultiplier
        G = G * (group size / e.size)
G = G + CPopGroup::CalcMonthlyBonusGrowth
G = G / CCountry::GetGrowthScale(owner)
```

`CPopGroup::CalcMonthlyGrowthMultiplier` (`0x6808c0`): `max(0, 1 + sum)`, the sum of the pop group's
modifier node values `logistic_growth_mult` (id 17), `founder_species_growth_mult` (492) when
`CGameRules::EvaluateIsFounderSpeciesUsing(152)` (rule `founder_species_uses_logistic_growth_mult`,
root = the owner, from = its founder species), the archetype's `<ARCHETYPE>_logistic_growth_mult`
(`CSpeciesArchetype::_LogisticGrowthMultModifier` `+0x1b4`, when the archetype uses modifiers and is
not robotic), and `CSpecies::CalcMonthlyGrowthMultiplier` (`0x3e5c80`): the same three from the
species traits' `triggered_planet_growth_habitability_modifier` blocks whose `potential` holds
(`CTraitSet::ApplyTriggeredColonyModifiers`: this = the planet, from = the species, fromfrom = the
owner; `mult` applied).

`CPopGroup::CalcMonthlyBonusGrowth` (`0x680df0`): 0 unless the rule `species_uses_bonus_growth`
holds (This = the species, Root = the colony; `CGameRules::SpeciesUsesBonusGrowth` `0x5bd510` also
checks the species rights); else `add * mult` with `add = bonus_pop_growth (18) +
<ARCHETYPE>_bonus_pop_growth + CSpecies::CalcMonthlyBonusGrowthAdd` (trait colony modifiers) and
`mult = 1 + bonus_pop_growth_mult (19) + <ARCHETYPE>_bonus_pop_growth_mult +
founder_species_growth_mult (when EvaluateIsFounderSpeciesUsing(154):
founder_species_uses_bonus_growth_mult) + CSpecies::CalcMonthlyBonusGrowthMult` (not clamped).
Bonus growth reaches groups that cannot procreate (the clone vats' `fake_pop_growth_mod`, budding).

`CCountry::GetGrowthScale` (`0x73b9f0`), in the 48.15 fixed point (`fpml`) and back with rounding:

```
scale = 1 + growth_scale * employable / max(GROWTH_SCALE_MAGNITUDE_OFFSET, 1)
```

with `growth_scale` the galaxy's (`_vGrowthScale` `+0xf8`, the save's `galaxy.growth_scale`, 0.25),
`GROWTH_SCALE_MAGNITUDE_OFFSET` 10000 (`NGameplay`), and `employable` the country's
`_nCachedEmployablePops` (`+0x2f80`): the sum of its colonies' (`_OwnedColonies`, the save's
`owned_planets`) `_CachedEmployablePops`, computed in `CCountry::DailyUpdateSelfDontReadOthers`
(`0x6f0586`). A country of 10,000 employable pops grows its pops 1.25 times slower.

### 2.5 Assembly

`CalcBestSpeciesToAssemble` (`0xe53740`): candidates the owner's built species (`+0x1598`,
`built_species_ref`), its founder species (`+0x1574`, `founder_species_ref`), then its
`_AllSpecies` (`+0x3470`), each when valid and `CGameRules::CanSpeciesBeAssembled` (rule
`can_species_be_assembled`, This = species, Root = colony); the best by
`CompareAssemblyPriority` (`0xe551d0`): the higher `CCountry::CalcAssemblyScoreForSpecies` (the
`ASSEMBLY_WEIGHT_*` defines; not traced), on a tie the one with more pops on the colony.

`CalcMonthlyPopAssemblyAmount` (`0xe54190`):

```
if overcrowded (OVERCROWDING_NO_ASSEMBLY_THRESHOLD 1.15, OVERCROWDING_MACHINE_ABSOLUTE_THRESHOLD 5):
    return MACHINE_ASSEMBLY_WHEN_OVERCROWDED (0)
A = BASE_POP_ASSEMBLY (0) + planet_pop_assembly_add                       -- colony, id 137
founder = EvaluateIsFounderSpeciesUsing(153)                              -- founder_species_uses_assembly
if the species is valid:
    A *= m(species[planet_pop_assembly_mult])    -- CSpecies +472, the species' own modifier
    A *= m(T[planet_pop_assembly_mult])          -- T: its traits' triggered colony modifiers
    if founder: A *= m(species[founder_species_growth_mult]); A *= m(T[founder_species_growth_mult])
    A *= m(1 - T[planet_pop_assembly_reduction])
A *= m(colony[planet_pop_assembly_mult])                                  -- id 138
A *= m(1 - colony[planet_pop_assembly_reduction])                         -- id 139
if founder: A *= m(colony[founder_species_growth_mult])
A = A / GetGrowthScale(owner)
```

with `m(x) = max(the modifier's minimum, 1 + x)` (`CModifier::CalcModifierMult` /
`ApplyModifierMult`, `0x36e5b0` / `0x36e3c0`; the minimum is the definition's `+160`, not in the files).

### 2.6 Decline

`ShouldDecline` (`0xe53f30`): yes when the group is being purged (and the colony has no ground
combat), when the species cannot live on the planet (the carrier's check: rule
`species_can_live_on_planet`), when `CGameRules::ShouldForceDeclineSpecies` (rule
`should_force_decline_species`, This = species, From = colony), or when the colony is overcrowded
(`IsOvercrowdingHaltingGrowthGeneric` with the growth or, for a robotic archetype, the assembly
thresholds) and housing usage / housing is at least `OVERCROWDING_DECLINE_THRESHOLD` (1.25;
`OVERCROWDING_MACHINE_DECLINE_THRESHOLD` 1.25 for robots).

`CalcMonthlyDeclineAmount` (`0xe53970`): `CPopGroup::GetBaseDeclineRate` (`0x6838f0`: the purge type's
rate, a script value in the colony's scope, when purged; else `BASE_POP_DECLINE` 5) times
`max(0, 1 + pop_decline_speed)` (id 15; `pop_purge_speed`, id 16, when purged).

### 2.7 Colonization: `CColony::GrowColonists` (`0xdc1390`)

For a colony with a colonizing species, in the serial pass: `rate = max(0, COLONY_MONTHLY_GROWTH (3,
NEconomy) * (1 + planet_colony_development_speed_mult))` (`CalcMonthlyColonizationGrowthRate`
`0xdbbb80`), rounded with the stream of `pool[(colony id + 6601) % 1000]`; under bombardment the
colonists are killed instead (`GROWTH_CAT_BOMBARDMENT`); else `AddColonistPopGroupSize` (the
colonizing species without a category, `GROWTH_CAT_COLONIZATION`) and
`CheckAndHandleColonizationFinished` (`0xdc0e10`: at `COLONY_POPS_REQUIRED` 100 the colonization ends:
notification, the carrier's own completion).

## 3. Applying the month (serial)

`CColony::ApplyMonthlyGrowth` (`0xdbf1e0`): one draw of the global generator (the scopes'
random seeds), then per species score with growth `n > 0`:
`CColony::AccessOrAddPopGroupAddSize(key = { species, null category }, n, "GROWTH_CAT_GROWTH")`
(`0xdaf400`: the colony's group with exactly that key, else a new one), then the on_action
`on_pop_growth` (this = the colony, from = the owner, fromfrom = the pop group, `local_pop_amount =
n`). The group without a category is emptied by the jobs update the same month (section 1, step 5).

`CColony::ApplyMonthlyAssembly` (`0xdbfc70`): when there is an assembly, one draw, then the pops to
the species' **smallest** group whose category rank is `NEWLY_ASSEMBLED_POP_TARGET_RANK` (1:
`civilian`, `maintenance_drone`, ...), else without a category; `GROWTH_CAT_ASSEMBLY`;
`on_pop_assembly`.

`CColony::ApplyMonthlyDecline` (`0xdc0160`): one draw; per species score with decline `n`: from the
colony's last group of the species on, `AddSize(-min(n, size), "GROWTH_CAT_DECLINE")` until `n` is
taken; purged groups draw once more and fire `on_pop_displaced` or `on_pop_purged`.

`CPopGroup::AddSize(n, detail)` (`0x67d720`): `n` at least `-size`; the size; the colony's
`OnAddPops` / `OnRemovePops` (the enslaved flag, the modifier invalidated, species rights created,
**`CColony::ExecuteAddPopOnAction`**: two draws and `on_pop_group_added` (this = the group, from = the
colony); `_CachedEmployablePops = CalcEmployablePops` (the sum of the colony's living groups' sizes);
`UpdateSpeciesInformation`; `MicroUpdateCachedValues`: `num_sapient_pops` (groups of sapient
species), amenities, stability, crime); an emptied group leaves the colony and is flagged
`ToBeKilled` (`killed = yes`, removed by the next day's pop group phase); `ValidateStats` (the ethics
resized, below); `AddGrowthDetail(detail, n)`.

`CPopGroup::AddGrowthDetail` (`0x67dd50`): the group's current details `[detail] += n` (added even at
0), and the colony's (`CColony::AddGrowthDetail` `0xdb6e40`: `GROWTH_CAT_MIGRATION` is kept as
`GROWTH_CAT_IMMIGRATION` or, negated, `GROWTH_CAT_EMIGRATION`).

`CPopGroup::MoveSizeFrom(source, n, detail)` (`0x67d820`), the jobs' move: ethics and faction stats
moved; when the source is emptied it leaves the colony, is killed, and its current details are added
to the target's; then `target.AddGrowthDetail(detail, n - those details)` and the source the
negation. So the month's new pops show on their final group as `GROWTH = n, PROMOTION = 0`, and the
killed group keeps its own `current_month_growth_details` in the save.

`CBasePopGroupStat<CEthic>::Resize` (`0x45d390`), from `ValidateStats` with the group's size: each
ethic's pops scaled to the new total (`trunc(size * pops / total)`), the remainder one by one to the
largest fractions (ties: the larger count, then the first), sorted by count, empty ones dropped.

## 4. The month's bookkeeping: `CColony::UpdateCachedGrowth` (`0xdb6430`)

Per pop group of the colony (`CPopGroup::UpdateCachedGrowth` `0x67de70`): `last_month_growth =
size - month_start_size`, `month_start_size = size`, `last_month_growth_details` = the current
details, which are cleared.

The colony: the sizes summed in total, per species, and per species per **display category**
(`CPopCategory::_pDisplayCategory`: `display_category` in `common/pop_categories`, e.g.
`slave_unemployment` shows as `worker`); `SMonthlyGrowthData::SetAsLastMonth` (`0xe561a0`) on the
current month's data: its growth = the size now - the month's start, for the total, every species and
category it holds (absent now: `-start`); `ResetAsCurrentMonth` (`0xe55c50`) on a fresh one: starts
= the sizes, growths 0, details cleared; the two swapped, so `last_month_growth_data` is the month
just finished (with its `current_month_growth_details`) and `current_month_growth_data` the new one.

Save forms (`SMonthlyGrowthData::WriteMembers` `0xe556e0`, `NPopUtil::WriteGrowthDetails`
`0xa005a0`):

```
last_month_growth_data = {
    growth_and_size = { month_start_size = 5342 growth = 4 }
    species = { key = 16777218 value = { growth_and_size = { ... } categories = { key = "worker" value = { month_start_size = 2649 growth = 2 } } } ... }
    current_month_growth_details = { key = "GROWTH_CAT_GROWTH" value = 4 key = "GROWTH_CAT_PROMOTION" value = 0 }
}
```

Species by id, categories and details by name (the details are sorted before writing), the details
block only when it has entries.

## 5. Structures **[V]** (`pdbtype.py`)

| type | members |
|---|---|
| `CPopGroup` (2264) | `_Properties +0x188` (flags: ToBeKilled 1, IsEnslaved 4, CanProcreate 8, CanCrossbreed 16, ...), `_Key +0x190` (`_SpeciesRef +0x198`, `_pCategory +0x1a0`), `_ColonyRef +0x1a8`, `_Ethos +0x1b0`, `_Size +0x3d0`, `_LastMonthGrowth +0x3d4`, `_MonthStartSize +0x3d8`, `_LastMonthGrowthDetails +0x3e0`, `_CurrentMonthGrowthDetails +0x400`, `_FactionChangeRemnant +0x390` (the save's `fractions`), `_Habitability`, `_Happiness`, `_PoliticalPower`, `_Crime`, `_AmenitiesUsage`, `_HousingUsage` `+0x8a8..+0x8d0` |
| `CColony` (4336) | `_PopGroups +0x18`, `_ColonizingSpeciesRef +0x48`, `_Districts +0x80`, `_Produces/_Upkeep/_Profits +0xe80/+0xea0/+0xec0`, `_SpeciesInformation +0xf60`, `_Carrier +0xf78`, `_DemographyCalculator +0xf80`, `_vCachedHousing/Usage/FreeHousing +0xf88/+0xf90/+0xf98`, amenities, stability, crime `+0xfa0..+0xfc0`, `_CachedSapientPopAmount +0xfc8`, `_CachedEmployablePops +0xfcc`, `_CachedUnemployedCount +0xfd0`, `_CachedCivilianCount +0xfd4`, `_LastMonthGrowth +0xfd8`, `_CurrentMonthGrowth +0x1030` (`SMonthlyGrowthData`), `_BinaryFlags +0x1088` (ToBeKilled 4: such colonies are skipped) |
| `SDemographySafePrivate` (120) | `_PopGroupScores`, `_SpeciesScores` (`{ ref, _Growth, _Decline }`, 24 bytes), `_AssemblyScore { _SpeciesRef, _Amount }`, `_BaseSpeciesGrowthData { _Size, _LogisticGrowth }`, `_PopGroupsToGrow` |
| `SMonthlyGrowthData` (88) | `_GrowthAndSize { _StartSize, _Growth }`, `_SpeciesData` (species -> `{ _GrowthAndSize, _CategoriesData }`), `_GrowthDetails` |

## 6. What is monthly, what is daily

| field (save) | when | by |
|---|---|---|
| pop group `size` | monthly: growth, assembly, decline, colonization; daily: jobs (`PROMOTION`), resettlement (`RESETTLE`, a command), auto-migration (monthly results) | sections 3, 1 |
| pop group `month_start_size`, `last_month_growth`, `*_growth_details` | monthly, `UpdateCachedGrowth` | section 4 |
| colony `last/current_month_growth_data` | monthly, `UpdateCachedGrowth` (details added on every size change during the month) | section 4 |
| colony `species_information`, `employable_pops` | on every size change (`OnAddPops`); daily (`DailyUpdateSelfDontReadOthers`) | section 3 |
| colony `num_sapient_pops` | on size changes and every micro update (`MicroUpdateCachedValues`) | section 3 |
| colony `upkeep`, `produces`, `profits` | monthly, before the growth (`MonthlyParallelUpdate` lambda 13) | section 1 |
| pop group `ethos.pops` | resized with the size (section 3); daily ethics drift (`EthicChangeSafePrivate` in `DailyUpdateOnlyChangeSafePrivate` with a noise stream; `CPopGroup::DailyUpdateSerial`, `on_daily_pop_ethics_divergence`) | |
| pop group `housing_usage` | daily, `CPopGroup::CalcHousingUsage` (`0x67fd60`): `max(0, size * (pop_housing_usage_base + pop_housing_usage_add) * m(pop_housing_usage_mult))` | `DailyUpdateOnlyChangeSafePrivate` (`0x676d10`) |
| colony `housing_usage`, `free_housing`, `total_housing` | daily: the sum of its groups' usage (checked: 49 of 49 colonies), housing - usage; housing `planet_housing_add * (1 + planet_housing_mult)` (checked 49 of 49 **[I]**) | colony caches |
| pop group `amenities_usage`, `happiness`, `power`, `crime`, `habitability` | daily, `DailyUpdateOnlyChangeSafePrivate` (`CalcAmenitiesUsage`, `CalcHappinessWithModifier`, `CalcCrime`, `NHabitability::CalcHabitability`; power through `ApplyModifierMult`) | not modelled |
| pop group `fractions`, `factions`, `wanted_factions`, `ethics_attraction`, `total_attraction` | daily, factions (`CheckPopFactionChange`, `CalculateFactionChange`, `CPopGroup::DailyUpdateSerial`) | [ethics.md](ethics.md): `ethos`, the attraction, `fractions` without factions (`engine/ethics.lua`) |
| colony `amenities`, `free_amenities`, `amenities_usage`, `stability`, `crime`, `civilian`, `unemploy_pop` | daily / micro: `MicroUpdateCachedValues` (`CalcAmenities`, `CalcPlanetStability`, `CalcPlanetCrime`), `CalcCachedUnemployedPopStatus` | not modelled |
| pop jobs `workforce`, the groups' categories | daily and monthly, `NPlanetJobs::UpdatePopJobs` | not modelled |

## 7. Defines **[V]** (read from `common/defines` by pops.lua)

`NPop`: `BASE_POP_GROWTH` 1, `LOGISTIC_POP_GROWTH_R` 0.0025, `LOGISTIC_POP_GROWTH_FLOOR` 0.1,
`LOGISTIC_POP_GROWTH_MIN_POPS` 10, `LOGISTIC_POP_GROWTH_LOWER_THRESHOLD` 0, `MAX_CARRYING_CAPACITY`
50000, `OVERCROWDING_NO_GROWTH_THRESHOLD` 1.15, `OVERCROWDING_DECLINE_THRESHOLD` 1.25,
`OVERCROWDING_ABSOLUTE_THRESHOLD_FOR_NO_GROWTH` 5, `OVERCROWDING_NO_ASSEMBLY_THRESHOLD` 1.15,
`OVERCROWDING_MACHINE_DECLINE_THRESHOLD` 1.25, `OVERCROWDING_MACHINE_ABSOLUTE_THRESHOLD_FOR_NO_GROWTH`
5, `MACHINE_ASSEMBLY_WHEN_OVERCROWDED` 0, `BASE_POP_DECLINE` 5, `BASE_POP_ASSEMBLY` 0,
`NEWLY_ASSEMBLED_POP_TARGET_RANK` 1, `COLONY_POPS_REQUIRED` 100. `NGameplay`:
`GROWTH_SCALE_MAGNITUDE_OFFSET` 10000, `NUM_DISTRICTS_BASE` 0, `NUM_DISTRICTS_FROM_PLANET_SIZE` 1,
`AUTO_MOD_BASE`. `NEconomy`: `COLONY_MONTHLY_GROWTH` 3. The galaxy setup: `logistic_ceiling_v2`,
`growth_scale`.

## 8. Modifiers

Pop group node: `logistic_growth_mult`, `founder_species_growth_mult`,
`<ARCHETYPE>_logistic_growth_mult`, `bonus_pop_growth`, `bonus_pop_growth_mult`,
`<ARCHETYPE>_bonus_pop_growth(_mult)`, `pop_decline_speed`, `pop_purge_speed`,
`pop_housing_usage_base/_add/_mult`. Colony node: `planet_carry_cap_add`,
`planet_max_districts_add/_mult`, `planet_(non_)artificial_max_districts_add`,
`<class>_max_districts_add`, `planet_pop_assembly_add/_mult/_reduction`,
`founder_species_growth_mult`, `planet_colony_development_speed_mult`, `planet_housing_add/_mult`,
`auto_mod_monthly_add/_mult`. Some modifier definitions clamp their value to [0, 1] (definition flag
bit 5 at `+168`); which ones is not in the files, so pops.lua does not clamp.

## 9. Random draws per month

The pool: 1,000 global draws at the start of `MonthlyUpdate`. Then, global draws in the serial pass:
`ApplyMonthlyGrowth` 1 per colony (every colony), `ApplyMonthlyDecline` 1 per colony (every colony;
1 more per purged decline), `ApplyMonthlyAssembly` 1 per assembling colony,
`ExecuteAddPopOnAction` 2 per `AddSize` > 0 (every growth, assembly, colonization), plus whatever the
on_actions' events draw. The demography's and the colonists' rounding use local noise streams from the
pool, not the global generator.

## 10. In the simulation: `sim/lua/engine/pops.lua`

`pops.monthly(host, date)`, called by the monthly `colonies` phase (`systems.lua`):

1. the killed empty pop groups removed (the next day's kill, which the daily phases do not do yet);
2. `pops.daily`: the day's housing (pop groups' `housing_usage`, the colonies' `total_housing`,
   `housing_usage`, `free_housing`), which the growth reads (the day's update runs before the
   month's in the game; the daily pop group phase is not hooked);
3. the pool: `RUST.monthly_pool()` if the platform has it, else 1,000 `RUST.rand()` draws;
4. the colonies' `upkeep`, `produces`, `profits` from the month's budget (`economy.colony_tables`);
5. per colony `pops.demography(colony, pool[(id + 266) % 1000])`: sections 2.1 to 2.6 (the best
   species to assemble simplified: the first allowed of built, founder, the colony's species);
6. per colony: colonists (2.7), growth, assembly, decline (section 3), with their draws and
   on_actions (`on_pop_group_added`, `on_pop_growth`, `on_pop_assembly`; `local_pop_amount` and
   fromfrom are not passed: the script layer's on_action takes this and from);
7. the colonies' caches (`employable_pops`, `num_sapient_pops`, `species_information`) and the
   month's bookkeeping (section 4).

**The jobs' stand-in** (`pops.target`): the game adds the month's pops without a category and the
jobs update gives them one. pops.lua adds them at once to the species' group of a civilian or
unemployment category (`is_civilian_job` / `is_unemployment_job`), else to its group of the lowest
rank, else to a new group (`civilian`, or `slave_unemployment` for an enslaved species), with the
details the move leaves (`GROWTH`, `PROMOTION 0`). It does not create the transient group without a
category the game creates (its id would not be the game's), and does not fill free jobs (the game's
new specialists on colonies with open specialist jobs go to civilians here).

`engine/pops/script.lua` answers what the rules ask that the script layer does not yet, only while
pops evaluates (on top of `engine/economy/script.lua`): `is_infertile`, `is_robotic(_species)`,
`is_sapient`, `has_species_flag`, `has_citizenship_type` / `has_population_control` with
`country = ...` on a species, `is_being_integrated_by` (no), `is_same_species`, `custom_tooltip`
(evaluated: the script layer treats it as true), the link `owner_main_species`.

### Checks

- `examples/run 0` with the probe `tmp_pops/probe3.lua` on a save: the demography from the sizes
  before the save's last month (size minus that month's GROWTH, ASSEMBLY, COLONIZATION) against the
  month's growth the game applied: 2210.01.01 24 of 24 (colony-species) within the rounding, 92.5
  expected for 91; 2210.07.01 24 of 24 (93.9 for 96); 2211.01.01 to 2212.07.01 all but the clone-vat
  colony 4, whose bonus growth comes from captured modifiers that went stale (the vats change).
  Assembly: colony 6 4.96 expected, the game 4 (2210.01) and 5 (2210.07).
- Housing (`tmp_pops/probe10.lua`): 135 of 140 pop groups' `housing_usage` (5 off by one pop moved by
  the jobs later that day) and 49 of 49 colonies' `housing_usage`.
- Colony tables (`tmp_pops/probe9.lua`, the economy's colony tables against the save before the
  growth): 551 of 570 within 0.1%.
- `examples/diff` 2210.01.01 -> 2210.07.01: before pops.lua `pop_groups` 4,862 fields equal / 512
  differ, `colony` 5,720 / 772; after: `pop_groups` 4,892 / 478, `colony` 5,863 / 630. 42 of 61
  (colony, species) end with the game's size; the others are the rounding draws (the platform's
  generator is not the game's: +-1 to 4 pops), the AI's resettlements (colonies 3/41, 34/45, 32/44:
  100 to 500 pops, a command), a new colony (49), and the clone-vat colony (100 pops declined in the
  simulation: its housing grows in the game, 5,400 -> 5,669, but stays at the captured modifiers'
  5,400 here, so it crosses the decline threshold).

### For the platform and the script layer

- The month's pool: the scheduler could draw it (1,000 `GetIntegerForMacro`) at the start of
  `monthly_update`, before the modifier and budget phases, as the game does, and hand it to Lua as
  `RUST.monthly_pool()` (a table, 1-based); pops.lua draws its own until then.
- `pops.daily` makes no draws: it can run in the daily `pop_groups` phase (parallel), as the game's
  `CPopGroup::DailyUpdateOnlyChangeSafePrivate` does; pops.monthly calls it first anyway (the same
  values).
- The script layer: the triggers of `engine/pops/script.lua`, and on_actions with `fromfrom` and
  the `local_pop_amount` variable (`on_pop_growth`, `on_pop_assembly`, `on_pop_group_added`).

### Not modelled

- the jobs update (`NPlanetJobs::UpdatePopJobs`): categories, promotions, `pop_jobs` workforce;
- auto-migration (`CalcAutoMigrationSafePrivate`, `ApplyAutoMigrationResults`; no
  `GROWTH_CAT_MIGRATION` in these saves), auto-modding (`MonthlyAutoModUpdate`), designation;
- `UpdateCanProcreate` (the save's flags are kept); purges (rates, `on_pop_displaced/purged`);
  `CalcAssemblyScoreForSpecies`; the completion of a colonization; bombardment of colonists;
- the daily pop group and colony recalculations other than housing (section 6);
- the transient pop groups without a category (the game's: killed the next day).
