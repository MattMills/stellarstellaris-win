# The colonies' and pop groups' day (4.5.2)

What the game recalculates each day on its colonies and pop groups (stability, amenities, crime,
housing, the employment counts; the pop groups' happiness, political power, crime and amenities
usage), reverse engineered statically from the GOG 4.5.2 build and its PDB on hippo (`/root/fnm_tmp`:
`annotate.py`, `pdbtype.py`, the call graph), and what
[`sim/lua/engine/colonies.lua`](../sim/lua/engine/colonies.lua) models of it. Addresses are GOG RVAs.
**[V]** marks what was read in the disassembly, **[I]** what is inferred (names, script files, saves).
The annotated dumps are in `H:\code_working\tmp_col\re\`, the checks in `H:\code_working\tmp_col\probe*.lua`.

Numbers are the game's fixed point (`CFixedPoint`, int64, 1.0 = 100000): `a * b` is
`trunc(a * b / 100000)`, `a / b` is `trunc(a * 100000 / b)` (toward zero), a division by zero gives
`0xFFFFFFFF`. A modifier value `v(name)` is read from a modifier node; when the definition's flag
bit 5 (`+168`) is set the value is first clamped to [0, 1] (none of the ones below is in practice).
`m(x) = max(the definition's minimum (+160), 1 + x)` (`CModifier::ApplyModifierMult` `0x36e3c0`); the
minimum is not in the files: colonies.lua takes 0.

## In short

- **Two phases of `CGameState::DailyUpdate`** ([simulation.md](simulation.md) section 1): the
  colonies' (17) and, later the same day, the pop groups' (20). A colony's cached values are computed
  from its pop groups' cached values, so they are those of the previous day's pop group phase.
- **Colony** (`CColony::MicroUpdateCachedValues`, each day and after every size change):
  `amenities = max(0, planet_amenities_add + planet_amenities_no_happiness_add) * max(0, 1 + _mult +
  no_happiness_mult)`; `amenities_usage = Σ groups' usage + BASE_AMENITIES_USAGE (500)`;
  `stability = (50 + min(planet_stability_add_with_limit, 15) + planet_stability_add) * max(0, 1 +
  planet_stability_mult) + happiness effect`, within [0, 100]; `crime = (Σ groups' crime +
  planet_crime_add + _no_happiness_add) * max(0, 1 + _mult + _no_happiness_mult)`, within
  [max(0, planet_crime_floor_add), 100].
- **The happiness effect on stability**: the colony's average happiness `h` weighted by **political
  power held within [0.05, 20] below 0.5 happiness and [0, 20] at or above** (NPop
  `MIN/MAX_POLITICAL_POWER_NEGATIVE/POSITIVE_STABILITY_IMPACT`); `(1 - h / 0.5) * -50` below 0.5,
  `(h - 0.5) / 0.5 * 30` above.
- **Pop group** (`CPopGroup::DailyUpdateOnlyChangeSafePrivate`): `happiness = 0.5 + pop_happiness +
  <archetype>_pop_happiness + pop_citizen_happiness (groups that can vote) +
  pop_cat_<category>_happiness`, within [0, 1] (0.5 without happiness); `power = size * 0.01 *
  m(pop_political_power) * m(pop_cat_<category>_political_power)`; `crime = size * 0.02 * (1 -
  yesterday's happiness)`; `amenities_usage = size * (base + add + no_happiness base + add) * m(mult +
  no_happiness_mult + organic or robotic mult + psionic mult)`.
- **Checked on the game's saves at day 0**: colonies' stability 47 of 49, crime 49 of 49,
  amenities_usage 49 of 49, housing 49/48/48 of 49, employable and sapient pops 49 of 49; pop groups'
  power 139 of 144, amenities usage 141 of 144, crime 134 of 144, happiness 88 exact and 52 more
  off by one amount shared by all the groups of their colony (the capture holds a colony-wide
  modifier at another moment than the save's). What is left over is the capture's moment (amenities
  29 of 49) and the sizes before the month (section 7).
- **No random draws** in what is modelled. The colony's and pop group's daily updates read the day's
  pool of 1,000 values for their triggered modifiers and the ethics drift (section 8).

## 1. Where in the day **[V]**

| phase (simulation.md) | game | what |
|---|---|---|
| 17 par | `NColonyUpdate::DailyParallelUpdate` (`0xe3a340`) -> `lambda_1` (`0xe3d5c0`) -> `CColony::DailyUpdateSelfDontReadOthers` (`0xdbc410`, then `0xddbe50`) | per colony, section 2; `g_nThreadSafetyState` set, `CRandom::_InForbiddenZone` |
| 17 ser | `NColonyUpdate::DailySerialUpdate` (`0xe3a470`) -> `CColony::DailyUpdateSerial` (`0xdc2490`) | colonies whose carrier is gone `SetToBeKilled`, killed ones deleted; then section 5 |
| 17 | `NColonyUpdate::MonthlyOrDailyUpdatePopJobsInColony` (`0xe3a740`) | the jobs |
| 20 par | `CPopGroup::DailyUpdateOnlyChangeSafePrivate` (`0x676d10`) | per pop group into its `SDailySafePrivate`, section 4 |
| 20 par | `CPopGroup::DailyUpdateSelfDoNotReadOthers` (`0x677400`) | the safe values copied in, section 4.6 |
| 20 ser | `CPopGroup::AddSize`, empty groups killed, `CPopGroup::DailyUpdateSerial` (`0x677800`) | ethics divergence, factions (section 6) |

`CColony::MicroUpdateCachedValues` (`0xdd5190`) also runs on every size change
(`CColony::OnAddPops` / `OnRemovePops`, from `CPopGroup::AddSize` and `MoveSizeFrom`), on branch
offices, colonization data and `EnsurePopJobsAreUpToDate`. So after the month's growth (and the jobs
moves) a colony's values are recomputed from its groups' cached values of the same day. A save is
written after the monthly update: its colonies' values come from the last such call.

## 2. `CColony::DailyUpdateSelfDontReadOthers` (`0xddbe50`) **[V]**

`0xdbc410` makes an event scope seeded from the pool (`pool[(id + 5353) % 1000]` through the noise
function, `CNoiseRandom` position, the same Squirrel3 as [pops.md](pops.md) section 2) and calls
`0xddbe50`, which does, for a valid colony not flagged ToBeKilled (`_BinaryFlags` bit 2):

1. armies' lists cleaned (`DailyUpdateCleanupArmiesSelfDontReadOthers` lambda, twice);
2. `ClearInvalidPops`;
3. `_CachedEmployablePops` (`+0xfcc`, the save's `employable_pops`) = `CalcEmployablePops`
   (`0xdc1f50`): the sizes of its valid pop groups not ToBeKilled;
4. `UpdateBuildings`; two counters (`+0xf44`, `+0xf5c`) zeroed; `UpdateSpeciesCache` when it has pop
   groups;
5. every `NGameplay::TRIGGERED_MODIFIER_UPDATE_DELAY` days (`(day counter + id) % delay == 0`):
   `UpdateTriggeredModifiersInternal`;
6. flags of `+0xe70`: the rule `is_new_colony` (bit 7), the branch office owner a criminal syndicate
   (`CGameRules::IsCriminalSyndicate`, bit 8), "something changed" (bit 1);
7. **`MicroUpdateCachedValues`** (section 3); when it changed a value, flag bit 3 (`+0xe70`): the serial
   update then invalidates the colony's modifier node (`DailyUpdateSerial`: bits 1-3 ->
   `CColony::InvalidateModifier`), since stability and amenities feed the colony's modifiers
   (section 3.5);
8. `CalculatePopTriggeredModifiersForAll(pool[(id + 12481) % 1000])` (`0xdc2e70`: the buildings',
   districts', deposits', designation's and jobs' triggered modifiers);
9. when it has pop groups: **`CalcCachedUnemployedPopStatus`** (`0xdc16b0`, section 3.6),
   `DailyUpdateSlavery_Threaded`, the planet's event chances (`lambda_19` `0xddc170`, twice: two event
   lists of `CEventManager`);
10. flag bit 5 = `CGameRules::CanCrossbreedSpeciesOnColony`; bit 6 = `CCountry::SpeciesHasHappiness`
    (the owner, its founder species `+0x1574`).

## 3. `CColony::MicroUpdateCachedValues` (`0xdd5190`) **[V]**

For a valid colony not ToBeKilled. The modifier node is the colony's own (`CColony +0x170`, ids at
`+0x180`, values at `+0x1a8`). Each value is stored only when it changed (the return value says
whether one did).

| step | field (`CColony`) | save | formula |
|---|---|---|---|
| 1 | | | the carrier's own update (virtual) |
| 2 | `_CachedSapientPopAmount +0xfc8` | `num_sapient_pops` | `CalcSapientPopAmount` (`0xdaf070`): the sizes of the groups whose species is sapient (`CSpecies +0x53c` bit 0; ToBeKilled ones not excluded: they are empty) |
| 3 | `_vCachedHousing +0xf88` | `total_housing` | `max(0, v(planet_housing_add) [152]) * m(v(planet_housing_mult) [153])` |
| 4 | `_vCachedHousingUsage +0xf90` | `housing_usage` | Σ groups' `_HousingUsage` (`+0x8d0`) |
| 5 | `_vCachedFreeHousing +0xf98` | `free_housing` | housing - usage |
| 6 | `_vCachedAmenities +0xfa8` | `amenities` | `CalcAmenities` (3.1) |
| 7 | `_vCachedAmenitiesUsage +0xfb0` | `amenities_usage` | `IsColony` ? Σ groups' `_AmenitiesUsage` (`+0x8c8`) + `NGameplay::BASE_AMENITIES_USAGE` : 0 |
| 8 | `_vCachedFreeAmenities +0xfa0` | `free_amenities` | amenities - usage |
| 9 | `_vCachedPlanetStability +0xfb8` | `stability` | `CalcPlanetStability(node, no tooltip)` (3.2) |
| 10 | `_vCachedPlanetCrime +0xfc0` | `crime` | `CalcPlanetCrime` (3.4) |

`CColony::IsColony` (`0xdbb330`): a valid colony that is being colonized (`_ColonizingSpeciesRef`
`+0x48`, the save's `colonizing_species`), or whose owner's country type has a flag (`+0x2a68` ->
`+0x48` bit 0; not identified), or with sapient pops.

### 3.1 `CColony::CalcAmenities` (`0xdb3730`)

```
0 when not IsColony
amenities = max(0, v(planet_amenities_add) [140] + v(planet_amenities_no_happiness_add) [142])
          * max(0, 1 + v(planet_amenities_mult) [141] + v(planet_amenities_no_happiness_mult) [143])
```

### 3.2 `CColony::CalcPlanetStability` (`0xdb3a40`)

```
0 when not IsColony; BASE_PLANET_STABILITY when the colony is being colonized
S = (BASE_PLANET_STABILITY + min(v(planet_stability_add_with_limit) [146], ADDITIONAL_PLANET_STABILITY_LIMIT)
     + v(planet_stability_add) [144]) * max(0, 1 + v(planet_stability_mult) [145])
h = CalcAverageHappiness (3.3); when there is one:
    h < BASE_HAPPINESS:  S += (1 - h / BASE_HAPPINESS) * LOW_HAPPINESS_STABILITY_EFFECT        -- -50
    else:                S += (h - BASE_HAPPINESS) / (1 - BASE_HAPPINESS) * HIGH_HAPPINESS_STABILITY_EFFECT  -- 30
S = clamp(S, MIN_PLANET_STABILITY, MAX_PLANET_STABILITY)                                     -- 0, 100
```

(With no `add_with_limit` the min is `min(0, LIMIT)`: 0.) A colony without pops with happiness
effects (gestalt drones) has no average: `50 + add` times the mult.

### 3.3 `CColony::CalcAverageHappiness` (`0xdb4a50`)

Over the colony's pop groups whose species is sapient (`+0x53c` bit 0) and that are not ToBeKilled:

```
h = HasHappinessEffects ? the group's _Happiness (+0x8b0) : BASE_HAPPINESS
p = the group's _PoliticalPower (+0x8b8), held within
      [MIN, MAX]_POLITICAL_POWER_NEGATIVE_STABILITY_IMPACT  (0.05, 20) when h < BASE_HAPPINESS
      [MIN, MAX]_POLITICAL_POWER_POSITIVE_STABILITY_IMPACT  (0, 20)    otherwise
average = Σ p * h / Σ p        (-1, "none", when Σ p <= 0)
```

So the large groups count at most 20 each: the size-weighted mean (29.006 against the game's 29.041 on
2211.07.01's colony 5) and the plain power-weighted one (29.17) are both off.

`CPopGroup::HasHappinessEffects` (`0x67e5a0`): when the species' class is robotic (the class's
virtual `+16`), only if the owner has the policy flag `NGameplay::AI_FULL_RIGHTS_POLICY_FLAG`
(`ai_full_rights`, the country's `policy_flags`); then `HasHappiness`. `CPopGroup::HasHappiness`
(`0x67e4a0` -> `0x67e430`): the owner's `CCountry::SpeciesHasHappiness` (`0x754a30`, a cache of the
rule by species) or the rule `species_has_happiness` (This = species, From = the owner).

### 3.4 `CColony::CalcPlanetCrime` (`0xdb4d80`)

```
0 when not IsColony
crime = (Σ groups' _Crime (+0x8c0, not ToBeKilled) + v(planet_crime_add) [147] + v(planet_crime_no_happiness_add) [150])
      * max(0, 1 + v(planet_crime_mult) [148] + v(planet_crime_no_happiness_mult) [151])
crime = max(crime, max(MIN_PLANET_CRIME, v(planet_crime_floor_add) [149]));  min(crime, MAX_PLANET_CRIME)
```

### 3.5 What the colony's modifiers read of it (the modifier graph's part)

`CColony::GetStabilityEffectScale` (`0xdb4800`): with `s` the stability, 0 at 50; below 50 `1 - s/50`
(1 at 0 or less), above `(s - 50) / (100 - 50)` (1 at 100). `CColony::GetAmenitiesEffectScale`
(`0xdb25c0`), with `r = amenities / usage`: 0 when equal or usage 0; below, `1 - (r - MIN_PLANET_AMENITIES)
/ (1 - MIN)` (1 at `r <= 0.25`); above, `(r - 1) / (MAX_PLANET_AMENITIES - 1)` (1 at `r >= 2`).
`GetStabilityEffectsMod` / `GetAmenitiesEffectsMod` (`0xdb47c0` / `0xdb2580`) pick the static modifier
(`CStaticModifierDatabase +464..+552`) by the sign and `_BinaryFlags` bit 6. These are the
"status multipliers" the modifier graph applies; they change when the cached values do (step 7 of
section 2).

In the game's fixed point, as the modifier graph (PR #22) found exact on both captures: below,
`1 - trunc((r - MIN) / (1 - MIN))` in that order (`trunc((1 - r) / 0.75)` is a unit off); the
amenities ratio `r` is truncated before it is used, the housing ratio is not.

### 3.6 `CColony::CalcCachedUnemployedPopStatus` (`0xdc16b0`)

- `_CachedCivilianCount` (`+0xfd4`, the save's `civilian`): the sizes of the groups
  `NPopUtil::FilterOutGroups` keeps (a category with `is_civilian_job` **[I]**: the counts match).
- `_CachedUnemployedCount` (`+0xfd0`, `unemploy_pop`): over the colony's pop jobs (`+0x38`) whose job
  type's category (`CJobType +0xaa0`) has `_IsUnemploymentJob` (`CPopCategory +0x9ea`,
  `is_unemployment_job`), the sizes of their pop groups (`CPopJob +0xe0`), each group once. The jobs'
  groups are not in the save (`pop_group = 4294967295`); a group works the jobs of its own category,
  so colonies.lua sums the groups of such a category.
- Then auto-migration's candidates (`CanColonyAutoMigrate`, `CanReceiveAutoMigration`,
  `CalcVacantWorkspaces`, `CalcValidDestinationForAutoMigrate`), not modelled.

Both run in the parallel phase, before the day's jobs update and (on the 1st) the month's growth: a
save's counts are the sizes before the month, while `employable_pops` follows every size change.

## 4. The pop group's day: `CPopGroup::DailyUpdateOnlyChangeSafePrivate` (`0x676d10`) **[V]**

Writes the group's `SDailySafePrivate` (`rdx`; the pool is the fourth argument), for a group on a valid
colony. The group's node is `CPopGroup +0x68` (ids `+0x78`, values `+0xa0`).

| safe | what |
|---|---|
| +0 | habitability: `NHabitability::CalcHabitability` with the species traits' `ApplyTriggeredColonyModifiersValueOnly` (not modelled) |
| +8 | happiness (4.1) |
| +16 | political power (4.2) |
| +24 | crime (4.3) |
| +32 | amenities usage (4.4) |
| +40 | housing usage: `CalcHousingUsage` ([pops.md](pops.md) section 6, `pops.daily`) |
| +48 | `CanJoinFactions`; factions' wanted lists cleared; flags (`+628`): `_Properties` value 2 carried over (bit 1), `CGameRules::CanPopGroupVote` (bit 4; the rule `can_vote_in_democratic_election` **[I]**) |
| | `EthicChangeSafePrivate` (section 6), `CheckPopFactionChange` when it changed and the owner is valid |
| | `CalcCategoryScaledPlanetTriggerModifiers(pool[(id + 911) % 1000])` (`0x6766c0`); checksums of two modifier arrays; `UpdateTriggeredModifiers` every `TRIGGERED_MODIFIER_UPDATE_DELAY` days |

### 4.1 Happiness: `CPopGroup::CalcHappinessWithModifier` (`0x67e820`)

`BASE_HAPPINESS` when `HasHappiness` fails (`0x676f0a`); else (the cheat override aside):

```
h = BASE_HAPPINESS + v(pop_happiness) [2]
  + v(archetype's _PopHappinessModifier)   when its _bUsesModifiers (CSpeciesArchetype +0x1b0, +0x229):
                                           biological_pop_happiness, ROBOT_..., MACHINE_..., lithoid_...
  + v(pop_citizen_happiness) [23]          when the group can vote (_Properties bit 5, the save's can_vote;
                                           set the day before, section 4.6)
  + v(the category's _HappinessModifier)   (CPopCategory +0xb48: pop_cat_<category>_happiness)
h = clamp(h, 0, 1)
```

### 4.2 Political power (inline, `0x676f37`)

```
p = size * BASE_POLITICAL_POWER                       -- NPop, 0.01
p = p * max(def[1].min, 1 + v(pop_political_power) [1])
p = ApplyModifierMult(p, the category's _PoliticalPowerModifier)   -- CPopCategory +0xb4c: pop_cat_<category>_political_power
```

### 4.3 Crime: `CPopGroup::CalcCrime` (`0x67f7b0`)

0 when the group is valid and the rule `pop_group_generates_crime` (This = the group) fails; else
`size * NGameplay::POP_CRIME * (1 - _Happiness)`, with `_Happiness` (`+0x8b0`) **the cached value, the
previous day's** (the new one is only in the safe struct). The planet class flag and `HasHappiness`
only choose the tooltip's words.

### 4.4 Amenities usage: `CPopGroup::CalcAmenitiesUsage` (`0x67ffa0`)

```
base = v(pop_amenities_usage_base) [6] + v(_add) [7] + v(pop_amenities_usage_no_happiness_base) [12] + v(_no_happiness_add) [13]
mult = 1 + v(pop_amenities_usage_mult) [8] + v(_no_happiness_mult) [14]
     + (robotic species class ? v(pop_amenities_usage_robotic_mult) [10] : v(_organic_mult) [9])
     + (CGameRules::IsPsionicSpecies (rule is_psionic_species) ? v(_psionic_mult) [11] : 0)
usage = max(0, size * base * max(def[8].min, mult))
```

### 4.5 Where the values go (`CPopGroup` `+0x8a8..+0x8d0`)

`_Habitability`, `_Happiness`, `_PoliticalPower`, `_Crime`, `_AmenitiesUsage`, `_HousingUsage`; the
save writes `habitability` always, `happiness` when not 1.0, the others when not 0
(`CPopGroup::WriteMembers` `0x673d23..0x673e4e`; between habitability and happiness: timed modifiers,
flags, variables). A group made by the month's growth has the defaults until its first day (happiness
1, the rest 0).

### 4.6 `CPopGroup::DailyUpdateSelfDoNotReadOthers` (`0x677400`)

Habitability, happiness, power and crime copied in, each change invalidating the group's node; the
faction attraction map; amenities and housing usage; `CTimedModifierCollection::DailyUpdate`; the
`can_vote` flag (`_Properties` value 32) from the safe flag; `CalcShouldBeEnslaved` (IsEnslaved, value
4) and the safe struct's value 2.

## 5. `CColony::DailyUpdateSerial` (`0xdc2490`) **[V]**

`InvalidateModifier` when flags 1-3 of `+0xe70` (section 2); `NPlanetJobs::UpdatePopJobs` when the
colony has pop groups and flags 2 or 4; `UpdateColonyOnActions`; `DailyUpdateSerialHandleConstruction`;
the planet's events (`CEventManager::TriggerEvent`); branch offices (`CanEstablishBranchOffice`,
`CloseBranchOffice`); ground combat (`ClearGroundCombat`, `DailyUpdateSerialHandleCombat`). None of
these is a recalculation of the fields above (the jobs' moves trigger `MicroUpdateCachedValues`).

## 6. Ethics and factions

`CPopGroup::EthicChangeSafePrivate` (`0x677d00`): every `NGameplay::POP_ETHOS_DIVERGENCE_INTERVAL`
days (`(id + a day counter) % interval == 0`), a draw from the noise stream of `pool[(id + 1160) %
1000]` (`CNoiseRandom::GetInt64`, its remainder modulo 1.0 below `POP_ETHOS_DIVERGENCE_RATE_MULT`;
`pop_ethics_shift_speed_mult` [22] is looked up just before, its use not traced); on success
`FillEthicsAttraction` and
`CPopGroupEthos::RandomizeEthics` with `POP_ETHOS_DIVERGENCE_SIZE_CHANGE_MIN/MAX`,
`_SHIFT_SPEED_DIVIDER` (a second draw at `0x6781fa`). `CPopGroup::DailyUpdateSerial` (`0x677800`):
the ethos resized and diffed (`CBasePopGroupStat<CEthic>::Resize`, `CalcPopsDiff`),
`OnEthicsDivergence` (`on_daily_pop_ethics_divergence`), factions validated and
`PopulateWithTargetedFactions`. The save's `ethos.pops`, `fractions`, `factions`, `wanted_factions`,
`ethics_attraction`, `total_attraction` come from here: [ethics.md](ethics.md) (`engine/ethics.lua`).

## 7. Checks

`examples/run 0` with `tmp_col/probe2.lua`: every colony's values from its node (the capture) and its
groups' saved values; every group's values from its node, its size before the month (size minus the
month's GROWTH, ASSEMBLY, COLONIZATION and PROMOTION details) and its saved happiness (for crime).

| | 2210.01.01 (capture 2210) | 2211.07.01 (capture 2211.07.01) |
|---|---|---|
| pop groups happiness | 88 of 144, +52 off by one colony-wide shift | 89 of 148, +51 |
| power | 139 of 144 | 129 of 148 |
| crime | 134 of 144 | 124 of 148 |
| amenities usage | 141 of 144 | 136 of 148 |
| colonies stability | 47 of 49 | 45 of 51 |
| crime | 49 of 49 | 50 of 51 |
| amenities_usage | 49 of 49 | 51 of 51 |
| amenities | 29 of 49 | 26 of 51 |
| total_housing, housing_usage | 49, 48 of 49 | 51, 49 of 51 |
| employable_pops, num_sapient_pops | 49, 49 of 49 | 51, 51 of 51 |
| unemploy_pop, civilian | 46, 32 of 49 | 48, 32 of 51 |

What differs, by cause:

- **The capture's moment**: the capture was taken after the game loaded the save, not when it wrote
  it; jobs' output moved meanwhile. Amenities differ by the capture's `planet_amenities_add` (colony 0:
  5933.75 against the save's 5932.65, the same 1.1 at both dates), happiness by one amount for all the
  groups of a colony (colony 0: `pop_citizen_happiness` 0.13575 in the capture, 0.1357 in the save's
  values), stability by the capture's `planet_stability_add` (gestalt colony 6 on 2211.07.01: 78.3398
  against 78.273, its average happiness 0.5).
- **The sizes before the month** are estimated: PROMOTION mixes the month's daily jobs moves with the
  month's own; the groups one pop off are those (power, amenities usage, crime). The counts
  (`civilian`, `unemploy_pop`) are the sizes before the day's jobs and the month's growth: they differ
  by the month's new civilians (colony 0: 945 now, 943 counted).
- **Crime reads yesterday's happiness**: colony 4's groups on 2210.01.01 (crime implies 0.80143, the
  saved happiness is 0.80161).

Over 180 days (`examples/diff` 2210.01.01 -> 2210.07.01, capture 2210):

| | before colonies.lua | after |
|---|---|---|
| all stores | 697,840 equal / 36,135 differ | 697,865 / 36,111 |
| `colony` | 5,847 / 646 | 5,856 / 638 |
| `pop_groups` | 4,877 / 493 | 4,893 / 477 |

`tmp_col/probe4.lua` splits the daily fields by whether the game changed them over the 180 days
(within 0.01%; "same size": the group's size, or the colony's employable pops, equal to the game's):

| 2210.01.01 -> 2210.07.01, capture 2210 | before: changed / kept | after: changed / kept |
|---|---|---|
| pop group happiness | 0 of 55 / 87 of 87 | 0 of 55 / 84 of 87 |
| power | 0 of 36 / 106 of 106 | 6 of 36 (same size 2 of 3) / 105 of 106 |
| crime | 0 of 66 / 76 of 76 | 3 of 66 / 76 of 76 |
| colony stability | 0 of 17 / 32 of 32 | 0 of 17 / 31 of 32 |
| colony crime | 0 of 18 / 31 of 31 | 2 of 18 / 31 of 31 |

| 2211.01.01 -> 2211.07.01, capture 2211.07.01 (the end date's modifiers) | before | after |
|---|---|---|
| pop group happiness, changed | 0 of 60 | 18 of 60 |
| power, changed | 0 of 43 | 5 of 43 (same size 4 of 7) |
| colony stability, changed | 0 of 21 | 9 of 21 (same size 4 of 5) |
| colony crime, changed | 0 of 20 | 6 of 20 |
| amenities_usage, changed | 0 of 21 | 5 of 21 |

The fields the game kept stay as they were (a few broken by the capture's moment); the ones it changed
follow only as far as the modifiers do: with the capture frozen at the start, happiness and stability
cannot follow the colony modifiers' changes over six months (amenities, stability effects, policies),
and sizes differ where pop growth and the jobs do (`pops.lua`, the jobs update not modelled).

## 8. Random draws

None in what is modelled. The game reads the day's pool (the 1,000 `GetIntegerForMacro` of
`DailyUpdate`, [simulation.md](simulation.md) phase 9) at: `(colony + 5353) % 1000` (the colony's event
scope seed), `(colony + 12481) % 1000` (`CalculatePopTriggeredModifiersForAll`), `(group + 911) % 1000`
(`CalcCategoryScaledPlanetTriggerModifiers`), `(group + 1160) % 1000` (ethics divergence). Modelling
those needs the day's pool from the platform (`RUST.daily_pool`, like `RUST.monthly_pool`).

## 9. Defines **[V]**

`NGameplay`: `BASE_AMENITIES_USAGE` 500, `MIN_PLANET_STABILITY` 0, `BASE_PLANET_STABILITY` 50,
`MAX_PLANET_STABILITY` 100, `ADDITIONAL_PLANET_STABILITY_LIMIT` 15, `LOW_HAPPINESS_STABILITY_EFFECT`
-50, `HIGH_HAPPINESS_STABILITY_EFFECT` 30, `POP_CRIME` 0.02, `MIN_PLANET_CRIME` 0, `MAX_PLANET_CRIME`
100, `MIN_PLANET_AMENITIES` 0.25, `MAX_PLANET_AMENITIES` 2, `TRIGGERED_MODIFIER_UPDATE_DELAY`,
`AI_FULL_RIGHTS_POLICY_FLAG` "ai_full_rights", `POP_ETHOS_DIVERGENCE_*`. `NPop`: `BASE_HAPPINESS` 0.5,
`BASE_POLITICAL_POWER` 0.01, `MIN/MAX_POLITICAL_POWER_POSITIVE_STABILITY_IMPACT` 0 / 20,
`MIN/MAX_POLITICAL_POWER_NEGATIVE_STABILITY_IMPACT` 0.05 / 20, `LOW_HAPPINESS` 0.4 and
`HIGH_HAPPINESS` 0.6 (tooltip colours only).

## 10. Modifiers (ids: the order of `modifiers.log`)

Colony node: `planet_amenities_add` 140, `_mult` 141, `planet_amenities_no_happiness_add` 142, `_mult`
143, `planet_stability_add` 144, `_mult` 145, `planet_stability_add_with_limit` 146,
`planet_crime_add` 147, `_mult` 148, `planet_crime_floor_add` 149, `planet_crime_no_happiness_add` 150,
`_mult` 151, `planet_housing_add` 152, `_mult` 153. Pop group node: `pop_political_power` 1,
`pop_happiness` 2, `pop_amenities_usage_base` 6, `_add` 7, `_mult` 8, `_organic_mult` 9,
`_robotic_mult` 10, `_psionic_mult` 11, `pop_amenities_usage_no_happiness_base` 12, `_add` 13, `_mult`
14, `pop_ethics_shift_speed_mult` 22, `pop_citizen_happiness` 23, `<archetype>_pop_happiness`
(8466 biological, 8472 ROBOT, 8475 MACHINE, 8478 lithoid), `pop_cat_<category>_happiness` and
`_political_power` (41402...).

## 11. In the simulation: `sim/lua/engine/colonies.lua`

- `colonies.daily_parallel(host, date)` (the `colonies_parallel` phase): every colony's
  `employable_pops`, `num_sapient_pops`, housing, amenities, stability, crime, `unemploy_pop`,
  `civilian` (sections 2 and 3) from its node and its groups' cached values, written in the save's
  form (the counts only when not 0).
- `colonies.pop_groups_daily(host, date)`: every living group's happiness, power, crime (from the
  previous day's happiness) and amenities usage (section 4), computed for all, then written (happiness
  left out at 1, the others at 0). It belongs to the `pop_groups` phase; until that phase calls it,
  `colonies.daily_serial` (the `colonies_serial` phase) runs it last: nothing between the two phases
  changes what it reads.
- `colonies.colony_values(cid)`, `colonies.pop_group_values(gid[, size])`: the values without writing.
- `colonies.micro_update(cid)`: `MicroUpdateCachedValues` written, for a caller that changed sizes.
- The rules (`species_has_happiness`, `pop_group_generates_crime`, `is_psionic_species`) are evaluated
  by the script layer, cached per day. `engine/colonies/script.lua` adds `is_being_assimilated` (the
  group's citizenship type has `is_assimilation`; the script layer answered yes for every group, so
  no group generated crime).
- A pop group the capture has no node for borrows a sibling's on the same colony (counted).

Not modelled: habitability (`NHabitability::CalcHabitability`), `can_vote` (kept from the save),
the ethics drift and factions (section 6), the triggered and category-scaled modifiers (the modifier
graph), the jobs (`NPlanetJobs::UpdatePopJobs`), auto-migration's candidates, the colony flags of
section 2, `IsColony`'s country type flag.

### For the other modules

- `pops.monthly` could call `colonies.micro_update(cid)` for every colony whose sizes it changed
  (the game's `OnAddPops` / `OnRemovePops`): the month's save then has the colony values of the
  groups' same-day values, as the game's.
- `systems.lua`'s `daily.pop_groups` could call `colonies.pop_groups_daily` (and set
  `colonies.pop_groups_in_serial = false`), next to `pops.daily`.
- `pops.daily` writes the colonies' housing in the pop group phase; the game's colony housing is
  `MicroUpdateCachedValues`' (the colonies' phase, from the groups' values of the day before), which
  colonies.lua now writes too: `pops.daily` could leave the colony to it.
