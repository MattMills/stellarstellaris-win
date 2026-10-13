# The AI's economy (4.5.2): budget, economic plan, build plan, construction orders

What the game's AI does with its resources and its planets, read off the GOG 4.5.2 build and its
PDB on hippo (`/root/fnm_tmp`: `annotate.py`, `pdbtype.py`), and how `sim/lua/engine/ai/` ports it.
Addresses are GOG RVAs. **[V]** marks what was read in the disassembly, **[I]** what is inferred
(from names, call lists, the script files or the saves). CFixedPoint is int64 with 1.0 = 100000;
its multiply and divide truncate toward zero. The overview of the AI is [ai.md](ai.md) (its
section 5 is the short version of this file); the tick order is [simulation.md](simulation.md)
section 1. The disassembly notes behind sections 4 and 5 are in `tmp_aieco/planre_*.asm` and
`tmp_aieco/bpre_*.asm` on the share.

## In short

- **Monthly** (the AI's own month: a counter started at `id % 30` after a load), in
  `CCountryAI::MonthlyUpdate` (`0xb6ddc0`): the **budget**, a split of each resource among the
  economic categories of `common/ai_budget`: *expenditure* budgets split the stockpile, *upkeep*
  budgets split last month's income. Then the interior minister's `MonthlyUpdate` (`0xbb40f0`)
  picks the **economic plan** (`common/economic_plans`) and makes the **build plan**: the
  districts, zones and buildings the AI could build on its colonies, weighted and sorted.
- **Weekly** (`id % 7`), `CAIInteriorMinister::BuildAndUpgradeDistrictsAndBuildings`
  (`0xbc1f90`): the build plan from the top: an item whose colony already builds a district or a
  building, or that the budget cannot pay, **stops the week**; otherwise it is posted as a
  `CAddBuildableToQueueCommand` and its cost withdrawn from the budget. A district lets the next
  item go; anything else ends the week. The plan is then **emptied**: one plan, one week of orders.
- **The order** executes after every AI decided: the item goes at the end of the planet's build
  queue and its cost leaves the stockpile at once (`CConstructionQueueItem::TakeResources`); the
  queue builds it (`engine/construction.lua`).
- **Nothing of it is saved but the income target records**: the budgets, the plan and the build
  plan are rebuilt on the AI's first month after a load, so a loaded AI orders nothing before its
  first month (its budget arrays are empty and `CanAffordExpenditure` fails on them). The save's
  `ai.budget = { 0 0 0 0 }` is `CAICore::_Budget` (+0x358, 32 bytes), a legacy field that only
  `CAICore::CreateBudget` writes (zeros). `ai_resource_target_records` and its dates are written.
- **Random draws** (the unsynced AI generator, `CAICore::_Random`): one per economic plan choice,
  one per build plan candidate that passes the first gates, one per specialization task; none in
  the budget or the weekly orders (section 8).
- **Check** (section 10): from 2210.01.01 to 2210.07.01 the minerals stockpiles go from -85.7% to
  +51.9% of the game's change explained; of the game's 7 planet orders, 3 come out the same
  (country, item, colony and week), 3 more are the same item ordered one to three months early,
  and one is another item in the same week; the 11 AI empires' income target records equal the
  game's but for a one-day offset of the AI's month.

## 1. Order of calls

`CAICore::Update` (`0x1af84e0`) on each AI day: `DailyUpdate`, then `WeeklyUpdate` when the week
counter runs out, then `MonthlyUpdate`, then `YearlyUpdate` (ai.md section 1) **[V]**. So on a day
where both are due, the week's orders use the previous month's budget and plan.

| when | function | what |
|---|---|---|
| month | `CCountryAI::MonthlyUpdate` (`0xb6ddc0`) | `SetBudgetArraySize` (`0xb70980`: one `CFixedResourceTable` per economic category in `_ExpenditureBudget` +0x568 and `_UpkeepBudget` +0x580, zeroed when the count changes), `UpdateUpkeepBudget` (`0xb70af0`), `UpdateExpenditureBudget` (`0xb716b0`); agreement renegotiation; `CAICore::MonthlyUpdate` -> the modules **[V]** |
| month | `CAIInteriorMinister::MonthlyUpdate` (`0xbb40f0`) | if the country type's AI has `construction` (`CCountryType +0x8c` bit 7): `strategy->_pEconomicPlan = CalcBestEconomicPlan()` (`0xb4c190`), `CreateBuildPlan()` (`0xb423e0`), not gated by `WasHumanRecently`; then threatened systems, slaves, species rights, factions, jobs, edicts, ..., traditions; at the end `+128 = 1` (the minister has had a month) **[V]** |
| week | `CAIInteriorMinister::WeeklyUpdate` (`0xbb3d10`) | with `construction` or `limited_construction` (bits 7, 8); with `construction`: if `+128` is set, `DemolishDistrictsAndBuildings` (`0xbc1a00`), and when that posted nothing `BuildAndUpgradeDistrictsAndBuildings` (`0xbc1f90`); then `HandleStarbases`; if not human recently `CancelQueueDistrictsAndBuildings`, `HandleStarbasesDefenses` **[V]** |

`CCountryAI::CreateBudget` (`0xb70940`, vtable +0x78) makes the budget at once when
`_bInitializedBudget` (`CAICore +0x37a`) is not set; it runs at the end of
`CCountryAI::CreateStrategicData` (`0xb6e0a0`), for a new AI (`CCountry::SetAI` when the strategy
is not initialized) or through the `CAIUpdateStrategicData` command. A loaded AI has
`initialized=yes`, so the budget waits for the AI's month **[V]**.

## 2. The budget

### Data **[V]**

`common/ai_budget` entries (`CAIBudgetEntry`, 576 bytes): `_Type` +0x48 (`EAIBudgetEntryType`:
upkeep 1, expenditure 2), `potential` +0x50 (country scope), `weight` +0x128, `desired_min`
+0x160, `desired_max` +0x198 (`CScriptableValue`s: `weight`/`base`, then `modifier = { factor add
<triggers> }`), `resource` +0x1d0, `category` +0x208.

Economic categories (`CEconomicCategory`): `_pParent` +0x90, `_Children` +0x78, `_Settings` +0x130
(bit 1 `use_for_ai_budget`), `_UseParentForResourcesUpkeepIndexes` +0x188
(`ai_use_parent_for_resources_upkeep`), `_UseParentForResourcesExpenditureIndexes` +0x1a0
(`ai_use_parent_for_resources_expenditure`, unused in vanilla).

### `UpdateUpkeepBudget` (`0xb70af0`), `UpdateExpenditureBudget` (`0xb716b0`) **[V]**

The same code with another type, source and table. For each strategic resource `r`
(`CStrategicResourceDatabase` order):

```
W[c], MAX[c], MIN[c] = 0 per economic category;  total = 0
for each entry e (database order) with a valid category and resource, e.type == T,
        e.resource == r and IsPotential(e, country):
    W[e.category] += weight;  total += weight;  MAX[e.category] += desired_max;  MIN[...] += desired_min
upkeep only: total <= 0 -> next resource (the budget stays 0)
S = expenditure: CEconomyCountryModule::GetResource(r)                          (the stockpile)
    upkeep:      CCountry +0x22d0 = _Budget._LastMonth._Total._SummedIncome[r]  (gross income)
pass 1, each category c with W[c] > 0 or MIN[c] > 0:
    S <= 0: f[c] = 0
    else:   share = W[c] / total               (expenditure with total 0: the raw 0xffffffff)
            a = share * S
            r has a maximum (CStrategicResource +0x110 >= 0): a = min(a, GetMaximumForCountry(r) * share)
            MAX[c] <= 0: MAX[c] = a
            a = a < MIN[c] ? MIN[c] : min(a, MAX[c]);   a = min(a, S)
            f[c] = a / S;  F += f[c]
pass 2, each category c:  budget[c][r] = f[c] > 0 ? max(S * (f[c] / F), min(MIN[c], S)) : 0
```

The clamps only move shares: all of `S` is handed out in proportion to the clamped amounts, each
category getting at least its minimum (up to `S`). Then `UpdateInternalUpkeepCache` (`0xb72220`):
per category, `CalcCurrentUpkeep` (`0xb79850`) = `AddBudgetCategoryExpense` (`0xb79740`: last
month's `_Standard._Expenses` of the category and, recursively, its children) + the upkeep of the
country's queued construction of that category (`ProcessItemForUpkeep`), into
`_CachedUpkeepInternalOnly` (+0x5b0).

Example (2210.01.01, country 16777217, 729.8 minerals): the potential expenditure entries are
buffer 0.05, planets 1.0, stations 0.2, armies 0.1, ... so `planets` gets 540.6 minerals, enough
for a 500-mineral city district; country 16777218 (423 minerals) gets 313 and orders nothing,
as in the game.

### Spending **[V]**

```
GetEconomicCategoryToUse(c) (0xb78e80): c with use_for_ai_budget, else the nearest such ancestor
    (at most 100 steps; without one, the last ancestor)
GetBudgetCategoryFor{Expenditure,Upkeep}(c, r) (0xb79a40, 0xb79af0): walking up from c, a category
    listing r in its ai_use_parent_for_resources_<kind> passes to its parent, else the first one
    with use_for_ai_budget
CanAffordExpenditure(category, cost) (0xb78f00): c = GetEconomicCategoryToUse(category), inside
    the array; a zero cost: true; else false when some r has
    _ExpenditureBudget[GetBudgetCategoryForResourceExpenditure(c, r)][r] < cost[r] (a negative
    budget with a cost <= 0 is no obstacle)
WithdrawCost(category, cost) (0xb79ba0): _ExpenditureBudget[bc(r)][r] -= cost[r]
CanAffordUpkeep(category, upkeep) (0xb791c0): c inside _UpkeepBudget and the cache; a zero upkeep:
    true; U[r] = upkeep[r] != 0 ? upkeep[r] + cache[c][r] : 0; no r with a positive new upkeep:
    true; else false when some r has B[r] >= 0 and B[r] < U[r], or B[r] < 0 and U[r] > 0, with
    B[r] = _UpkeepBudget[GetBudgetCategoryForResourceUpkeep(c, r)][r]
```

A city district (`planet_districts_cities` -> `planets`) pays its minerals from the `planets`
expenditure budget; its energy upkeep is checked against the `country` upkeep budget (`planets`
lists energy and consumer goods in `ai_use_parent_for_resources_upkeep`), with last month's
energy expenses of `planets` and everything under it plus the queued items' upkeep.

## 3. The economic plan and the income targets

### `CAIEconomicPlan` (`common/economic_plans`) **[V]**

496 bytes: `_Income` +0x48 and `_Focus` +0x68 (resource tables), `_Pops` +0x88, `_NavalCap` +0x8c,
`_Potential` +0x90 (an empty trigger is true), `_AIWeight` +0x168 (a `CMeanTimeToHappen`),
`_Scaling` +0x1a0, `_Optional` +0x1a1, `_SubPlans` +0x1a8 (plans of the same kind, script order),
`_Name` +0x1c0 (`set_name`). `ReadMember` (`0xb50da0`) keys: `ai_weight`, `pops`, `potential`,
`naval_cap`, `set_name`, `scaling`, `optional`, `focus`, `income`, `subplan` (recursive; a subplan
with a name already there replaces it: the last one moves into its slot and the new one is
appended). The database is extendable; plans are visited in database order. A subplan's
`ai_weight` is never evaluated.

### `CAIEconomicStrategy::CalcBestEconomicPlan` (`0xb4c190`) **[V]**

```
one draw of the unsynced AI generator: it seeds the scope of the ai_weight modifiers (the
    potentials use the default seed and no draw)
for each plan (database order) with IsPotential:
    w = ai_weight;  w <= 0: skip
    low = the first plan with the lowest w
    not IsFulfilled and w > best's: best = plan
return best or low        (vanilla: basic 1000, intermediate 200, advanced 50, mature 25,
                           endgame 10, beyond_endgame 1)
```

`IsFulfilled` (`0xb51520`): `t = CalculateIncomeTarget(plan, nil, noScale)`; no target and no
subplan: fulfilled; else every `t[r] > 0` must be covered by last month's net income (`CCountry
+0x2310` = `_Budget._LastMonth._Total._SummedBalance`).

### `CalculateIncomeTarget(plan, country, forecast, noScale)` (`0xb51600`) **[V]**

```
out = plan.income + the targets of the potential subplans with neither flag
passes = 0
if forecast and not noScale:
    while the forecast covers out (each out[r] > 0 has forecast[r] >= out[r]) and the last pass added:
        for each potential scaling, not optional, subplan (potentials evaluated again each pass):
            t = its target; some t[r] > 0: out += t
        passes += 1
out += the potential optional (not scaling) subplans' targets
not noScale: out += passes * the potential optional scaling subplans' targets
```

`GetFocus` (`0xb52b60`): `focus` plus every potential subplan's, whatever its flags. `GetPops`
(`0xb52c90`) / `GetNavalCap` (`0xb52f80`): the plan's amount and its plain potential subplans',
then each scaling subplan's added until the amount passes the country's
(`_CachedSapientPopAmount` +0x2f7c; `CalcNavalCapacity`).

### `CAIEconomicStrategy::CreateBuildPlan` (`0xb423e0`) **[V]**

1. The build plan (`_BuildPlan` +0x30: pairs of a `CBuildableBase*` and a weight), the orbital
   plan (+0x48) and the explanations are cleared; no valid economic plan: done (and no orders).
2. `CalculateIncomeTargetBasedOnForecast` (`0xb44050`): `F` = this month's net income
   (`_CurrentMonth._Total._SummedBalance`, +0x1f90) plus what the free jobs and the queued
   buildings and districts will make, minus their upkeep (`CalculateEffectsOfFreeJobsAndBuildQueue`
   `0xb438e0`); `T = CalculateIncomeTarget(plan, F)`. The tables the weights read: target `T`,
   needed `N = T - F`, current `F`, focus `GetFocus`, deficit `-F`.
3. `CCountryAI::UpdateIncomeTargetRecords(T)` (`0xb7be60`), `NAI
   AI_RESOURCE_TARGET_VALID_THRESHOLD` 0.75, `AI_RESOURCE_TARGET_EXPIRATION_MONTHS` 24:
   ```
   per resource (a date list of the wrong size is reset to "0.01.01" x n):
     rec[r] > 0 or T[r] > 0:
       rec[r] * 0.75 <= T[r]: rec[r] = max(rec[r], T[r]); recDate[r] = today
       elif months(recDate[r], today) > 24: rec[r] = max(T[r], 0)
     flo[r] < 0 or T[r] < 0: the same downwards with min
   months(a, b) = 12 (Yb - Ya) + (Mb - Ma)
   ```
   The save's `ai_resource_target_records` (+0x408), `last_valid_resource_targets` (+0x428),
   `ai_resource_target_floors` (+0x440), `last_valid_resource_floors` (+0x460). Only the debug
   tooltip reads them.
4. The upkeep of the wartime edicts is taken out of `N`.
5. The colonies (`CCountry::_OwnedColonies`): list A, no zone and no district queued (it goes to
   `UpdatePlanetDesignations`); list C, no building and no district queued
   (`HasQueuedBuildingOrDistrictConstruction`) and not vulnerable; list B, the same but in
   `CCountryAI::_VulnerableColonies` with the game rule `ShouldAIBuildStrongholdOnVulnerableColony`:
   `building_stronghold` at weight 100 each, before the rest.
6. `FillBuildPlan(tables, listC, listA)` (section 4), then `DestroySuperfluousDistrictsAndBuildings`
   (`0xb47890`: for a colony that only makes superfluous resources, `CDestroyDistrictCommand` /
   `CDestroyBuildingCommand` are posted).
7. An essential building (`CBuildingType` property 128, `is_essential`) in the plan: everything
   but the essential buildings is removed.
8. The plan is stable-sorted by weight, highest first; no cap on its length.

## 4. The build plan: `CAIEconomicStrategy::FillBuildPlan` (`0xb45610`) **[V]**

Eight tasks run in parallel: the orbital buildings; `EstimateAndAppendToBuildPlan<Building>`
(`0xb54de0`), `<District>` (`0xb55f60`) and `<Zone>` (`0xb58d00`) over every type of the database
and every colony of list C; `EstimateUpgradesAndRepairs`; `SpecializeBuildables<CDistrictType>`
and `<SAiBuildingBuildable>`; `EstimateZoneSpecialization`. Meanwhile `UpdatePlanetDesignations`
(list A) when the country was not human recently. Then `ApplyOpportunityCostsToBuildPlan` and, if
the plan is empty, `SpecializeAllBuildables`. Items are appended under a mutex, so the order of
equal weights follows the threads.

### A candidate, per colony and type, in the code's order

1. the type's technologies (`prerequisites`);
2. it can be built: a district `CDistrictType::CanBuild` (`CColony::CanAddDistrict` `0xdc8430`:
   not under colonization; the district levels with the queued ones below
   `CColonyCarrier::CalcMaxDistricts` = planet size * `NUM_DISTRICTS_FROM_PLANET_SIZE` +
   `NUM_DISTRICTS_BASE` + the country's `pc_<class>_max_districts_add` + `planet_max_districts_add`
   + `planet_(non_)artificial_max_districts_add`; a capped type (an `is_uncapped` trigger that
   fails) below `district_<type>_max_add`); a building `CBuildingType::CanBuild`; a zone some
   empty district slot where `CZoneType::CanBuild` holds;
3. the cost gate: no resource with an income `<= 0` and a stockpile below the cost;
4. a `destroy_trigger` that holds: rejected;
5. unless `ai_estimate_without_unemployment`, `CColony::HasAvailablePopsForAI` (`0xdaf270`: a job
   of a type with `count_as_available_for_ai` and workforce);
6. **one unsynced AI draw** (it seeds the candidate's script scope);
7. the approximation (below);
8. the deficit gate (not for essential types, nor buildings with `custom_storm_ai_weight > 0`):
   some upkeep above `max(income, 0)` rejects the candidate unless `DecreasesTotalDeficits`
   (`0xb41300`: the net production closes a deficit of a resource with a target `>= 0`, with more
   production than upkeep, or cuts a surplus the plan wants negative) or, for a nomad, the
   stockpile covers 60 months of a rare resource;
9. the weight (below); a building needs a slot (`NPlanetBuildingUtil::FindBestBuildingSlot`
   `0xe50660`: of the zones where `CColony::CanAddBuilding` holds, the first with the highest zone
   `ai_priority`), a zone its first free slot (`FindZoneSlots`);
10. `AppendToBuildPlan` (`0xb54290`): kept only with a weight above 1.0.

### The approximation (`ApproximateProductionAndUpkeepFor*`, `Internal` `0xb4d890`)

Production: the `ai_resource_production` blocks whose trigger holds, plus the type's `produces`;
upkeep: its `upkeep`. The modifier set `M`: a district's planet modifiers (and the zones its slots
would get); a building's planet and country modifiers; a zone's district planet modifiers times
the district's level plus its planet modifiers. From `M`, with the colony's modifiers `C`
(`CalcAndApproximateNewModifier` `0xb4d2a0`: `C.adds * M.mults + M.adds * (1 + C.mults) + M.adds *
M.mults`): amenities (`planet_amenities_add`, `..._no_happiness_add`), housing
(`planet_housing_add`), crime reduction (`planet_crime_add`, ...), naval capacity
(`country_naval_cap_add`), a pop growth flag (`logistic_growth_mult >= AI_POP_GROWTH_JOB_TRESHOLD`
0.05 or pop assembly). Each `job_<job>_add` of `M` adds that job's tables and modifiers times
amount / `POP_BULK_UNIT_SIZE` (`ApproximateProductionAndUpkeepForJob` `0xb4fd70`).

### The weight (`CalcBuildWeight` `0xb3f920`, `CalcResourceProductionWeight` `0xb51b50`)

```
WF(need, gain) = need <= 0 or gain <= 0 ? 0 : 100 * min(gain / need, 1) + min(need, gain)
w = 1 + resources
      + 3 WF(amenity need, amenities)           AI_AMENITIES_SCORE_MULT; need = max(0, 200 - free amenities)
      + 3 WF(housing need, housing)             AI_HOUSING_SCORE_MULT; need = 0.1 * housing usage - free housing
      + [crime > 15] 1.5 WF(crime, reduction)   AI_CRIME_REDUCTION_*
      + [pop growth] 0.01 max(1, plan pops - pops)
      + 3 WF(plan naval cap - naval cap, naval)
resources = sum over r of
      [focus Fo > F and P - U > 0]  100 min((P-U)/(Fo-F), 1) + (P-U)
    + v, where with s = (T > 0 ? T * 1.15 : T) - F       (AI_INCOME_TARGET_BUFFER_FACTOR)
          s > 0 and P > 0:          v = 100 min(P/s, 1) + P
          T < 0, N < 0 and U > 0:   v = 100 min(U/-N, 1) + U
          P > 0 and F < 0:          v = 100 min(P/-F, 1) + P
      v * 100 (AI_DEFICIT_SCORE_MULT) when the resource is in deficit (F < 0) and wanted
      (T > 0, or T == 0 with a focus), or when T < 0 and F > 0
    (times 10 once if a rare resource is made; times AI_RESOURCE_PRODUCTION_SCORE_MULT 1)
district: (w + 1000 essential + additional_ai_weight) * ai_weight_coefficient
          * designation affinity * 2 when unbuilt (colony pops >= 2500, none of the type, a zone
          possible) * 0.25 when a district of the type has an empty slot that can take a zone
building: (w + 1000 essential + additional_ai_weight + custom_storm_ai_weight + storage boost)
          * ai_weight_coefficient * the designation's best ai_building_set_affinity of its sets
zone:     (w + additional_ai_weight) * ai_weight_coefficient * the designation's affinity
```

### Opportunity costs (`0xb45010`, `0xb446f0`)

Districts grouped per planet (free = max districts - districts with the queued ones; factor 0.3,
falloff 0.75, at most 3 free, a hypothetical second best of 50), new buildings per zone (free =
the zone's free building slots; 0.5, 0.5, 3, 100): with few free slots the best item loses
`second * factor * falloff^(free - 1)` and the others are multiplied by 0.001.

### Specialization

`SpecializeBuildables<CDistrictType>` / `<SAiBuildingBuildable>`: over the non-vulnerable
colonies with two or more non-exempt district types (building types), when more than one: **one
AI draw** seeding a `CCrudeRandom` that shuffles them, then the first pair of colonies that could
swap a type yields two replacement items at weight 2.0. `SpecializeAllBuildables` (only with an
empty plan): one draw, a shuffle, and at the first swap it posts `CDestroyDistrictCommand` and
`CDestroyBuildingCommand` and appends the replacements at 2.0.

## 5. The weekly orders **[V]**

`BuildAndUpgradeDistrictsAndBuildings` (`0xbc1f90`):

```
nothing without a valid economic plan, or with both the build plan and the orbital plan empty
for each (buildable, weight) of the build plan, in order:
    lambda_1 (0xbc25c0) fails: stop
    continue_after = a district, or a zone into a slot that holds a zone
    post CAddBuildableToQueueCommand(country, the planet's build queue, buildable)
        through CCountryAI::AddAICommandWithCostForPosting (0xbe5c20)
    not continue_after: stop
the build plan is emptied (RemoveAll)
```

`lambda_1`: the colony is valid; `CColony::HasQueuedBuildingOrDistrictConstruction` (`0xdd0ab0`)
is false (no building, upgrade or district in the planet's queue); the queue is valid and not
disabled; the buildable can be built; `CanAffordExpenditure(category, cost)`; and for the upkeep
of the resources the buildable does not make itself (`HandleCalcProduces`: a resource with a
production `>= 0` is left out), `CanAffordUpkeep` or `CanTradeForResources(upkeep - last month's
net income)` (`0xb4c5c0`: every resource short is in `NAI AI_ALLOWED_TO_BUY` and the market sells
a unit of it for energy).

`AddAICommandWithCostForPosting`: `IsValid` (`0xaca570`: the cost, the queue,
`CConstructionQueue::CanAddItem`), then a zero cost posts; else `CanAffordExpenditure` posts and
`WithdrawCost`s. So a week posts at most one non-district item after any number of districts, and
only while the top of the plan is affordable and on colonies that build nothing yet: in the
game's saves the 11 AI empires ordered 7 planet items in 180 days.

`DemolishDistrictsAndBuildings` (`0xbc1a00`), before the orders once the minister had a month: a
building whose `CBuildingType::CalcAIWeight` is under `NAI BUILDING_DEMOLISH_THRESHOLD` is
destroyed (`CDestroyBuildingCommand`) and the week builds nothing. None in the 2210 saves.

## 6. The order's execution **[V]**

`CAddBuildableToQueueCommand::Execute` (`0xaca200`) -> `ExecuteLocal` (`0xaca340`) ->
`CConstructionQueue::AddItemInternal` (`0x7b7c30`):

1. `CConstructionQueueItemManager::CreateItem` (`0x8fc1a0`): the item database's free list head
   (+44) gives the slot; the new id is `index | (the slot's old generation + 1) << 24`; without a
   free slot the lookup grows. The saves fit a free list in ascending index order at load with
   freed slots pushed in front [I].
2. The item id is appended to the queue's items.
3. `CConstructionQueueItem::TakeResources` (`0x7b8760`): the cost (`CalcCost`, into the item's
   `resources`) leaves the paying country's stockpile at once.
4. The buildable's on-queued vfunc (+48) and build time (+88) -> `progress_needed`.

```
<id> = { queue=<queue> paying_country=<country> progress=0 progress_needed=<base_buildtime>
         resources = { minerals=500 }
         buildable_district = { district="district_city" planet=<colony> } }
buildable_planet_building = { building="building_physics_lab_1" planet=<colony> zone=<zone> }
buildable_zone = { zone="zone_fortress" planet=<colony> district=<district> zone_slot=<0-based> }
```

The cost: the definition's `resources` cost blocks (their triggers in the planet's scope with the
country as `from`, `inline_scripts/buildings/nomadic_cost_switcher`) times the colony's cost
mults of the category chain. For the game's 7 orders this gives its costs exactly (city districts
500, 425, 625; physics lab 400; sentinel posts 360). The command runs on the AI's tick (tick 4):
the item first progresses on the next day.

## 7. What else spends minerals

The rest of the minerals the game spends between the 2210 saves (about 1,500 of the 2,600 the
simulation does not spend yet) is not planet construction: 21 orbital stations appear in the
game's 2210.07.01 save (`planet_orbitals`, `shipclass_orbital_station`;
`CAIInteriorMinister::BuildStation`, the `stations` budget), civilian ships
(`BuildShipOfOwnerType`) and armies (`BuildArmies`, the `armies` budget). Military ships and
starbase upgrades (alloys) are the military minister's and `HandleStarbases`; they share the
budget path (`AddAICommandWithCostForPosting<CAddBuildableToQueueCommand>`,
`CanAffordExpenditure`) but are not ported.

## 8. Random draws

All on the unsynced generator (`CAICore::_Random`, `CAICore::GetRandomInt` `0xb871d0`: position
`+0x32c`, seed `+0x330`, reset to the country id at load):

| where | draws |
|---|---|
| `CalcBestEconomicPlan` | 1 per AI month |
| `EstimateAndAppendToBuildPlan<*>` | 1 per candidate past gate 5, before its approximation |
| `SpecializeBuildables<CDistrictType>`, `<SAiBuildingBuildable>` | 1 each when more than one colony qualifies (the shuffle then uses a `CCrudeRandom`) |
| `SpecializeAllBuildables` | 1 (only with an empty plan) |
| `EstimateUpgradesAndRepairs`, `UpdatePlanetDesignations` | draw sites not read |

The estimation tasks run in parallel and increment the counter without synchronization, so the
interleaving, and with it which draw seeds which scope, is not deterministic in the game. The
draws only seed script scopes (`random` in the scripts' triggers), so the plan itself does not
depend on them; what matters for the other AI modules is their number.

## 9. The Lua port (`sim/lua/engine/ai/`)

| file | |
|---|---|
| `budget.lua` | `budget.monthly` (called by `engine/ai/init.lua` on the AI's month): `UpdateUpkeepBudget`, the upkeep cache, `UpdateExpenditureBudget` in the game's fixed point; `can_afford_expenditure`, `can_afford_upkeep`, `withdraw`, `get`; `last_month` (the simulation's `engine.economy.last_month`, else the save's `budget.last_month`). Kept in Lua (`budget.state`): the game saves none of it |
| `economy.lua` | the interior minister's `monthly` (the plan) and `weekly` (the orders, `lambda_1`, `CanTradeForResources`, the command), `queued_upkeep` (for the cache) |
| `economy/fixed.lua` | CFixedPoint multiply and divide |
| `economy/categories.lua` | economic categories: the category to use, the budget category of a resource |
| `economy/plans.lua` | the economic plans, `CalcBestEconomicPlan` (with its draw), `CalculateIncomeTarget`, focus, pops, naval cap, the tables, `UpdateIncomeTargetRecords` (written to the save) |
| `economy/plan.lua` | `CreateBuildPlan`: the lists, the fill, the essential filter, the sort; `can_build` for the week |
| `economy/fill.lua` | `FillBuildPlan` for districts, buildings and zones: the gates, the draws, the approximation, the weight, the building slot, the opportunity costs; the two specialization draws |
| `economy/slots.lua` | `CanAddDistrict`, `CalcMaxDistricts`, the district caps, prerequisites |
| `economy/buildables.lua` | a buildable's cost, upkeep, production (with the colony's modifiers), build time, item fields, queue |
| `economy/orders.lua` | the command's execution: the item in the save's form, its id from the free list, the queue, `TakeResources` |
| `economy/script.lua` | triggers the script layer does not answer yet, installed while the budget and the plans evaluate: `has_monthly_income`, `resource_expenses_compare`, `country_uses_food`, `country_uses_consumer_goods` (an `if`/`else` chain in a trigger), `uses_district_set`, `is_ai` |

Not ported yet: the orbital task, upgrades and repairs, zone specialization and the swaps,
`SpecializeAllBuildables`, planet designations, `DestroySuperfluousDistrictsAndBuildings`,
`DemolishDistrictsAndBuildings`, strongholds on vulnerable colonies, the wartime edicts' upkeep,
the free jobs and build queue in the forecast, the zones a new district would get in its
modifiers, `CalculateEffectOfPopCategoryModifierOnColony`, rare resources (x10), the triggers
`exploitable_planets` and `highest_threat` of the minerals budget (false here), building
`CanBuild` beyond potential / allow / planet and empire limits, zone building slots without a
`max_buildings` (3 assumed).

## 10. Check against the game's saves

2210.01.01 + 180 days against the game's 2210.07.01 (`examples/diff`, the world-built modifiers,
`STELLAR_MODIFIER_TYPES=/opt/stellaris-captures/modifiers-2210.log`):

| | without the AI economy | with it |
|---|---|---|
| minerals, share of the game's change explained | -85.7% (off by 4,823) | +51.9% (off by 1,248) |
| alloys | 44.7% | 44.7% (not spent by this module) |
| fields equal | 697,949 | 697,960 |
| construction items in both saves | 7 | 15 |

**Orders** (the game's from its 2210.07.01 queues, dated by progress / build speed; the
simulation's dates are one day early, below):

| country | game | simulation |
|---|---|---|
| 16777217 | city district, colony 1, 2210.01.24 | the same, 01.23 (progress 158 vs 157 at 07.01; stockpile 495.3 vs 495.4) |
| 49 | physics lab, colony 33, zone 118, 03.26 | the same, 03.25 |
| 50 | city district, colony 34, 05.22 | the same, 05.21 |
| 6 | sentinel posts, colony 6, 05.13 | nexus district, colony 6, 05.12 (the same AI week) |
| 16777225 | city district, colony 39, 03.28 | the same item, 02.29 |
| 16777219 | city district, colony 3, 05.25 | the same item, 03.21, and a physics lab with it |
| 16777220 | city district, colony 4, 06.24 | the same item, 03.22 |
| 16777225 | | commercial zone building, colony 44, 05.30 |

Three of the early orders come with more minerals in the simulation than in the game at that
time: the game spends minerals on stations, ships and armies first (section 7), which this port
does not do yet, and two minerals entries depend on triggers not answered yet.

**Income target records**: for the 11 AI empires, `ai_resource_target_records` and
`last_valid_resource_targets` come out as in the game's 2210.07.01 save (the same resources
renewed, the same targets), with every date one day early: the game renews 16777217's on
2210.06.18 (`id % 30 = 17`), the simulation on 2210.06.17. The AI's month counter of
`engine/ai/init.lua` runs a day ahead of the game's after a load (the weekly orders too).

**The budget of unity** (used by `engine/ai/traditions.lua`): 83 of 88 category budgets equal
its own split; the 5 others are fallen empires with 30,000 unity, within 0.05% (fixed point
against doubles).

## 11. Open points

- The forecast's free jobs and build queue (`CalculateEffectsOfFreeJobsAndBuildQueue`): without
  them a country whose current net income of a resource is negative gets the x100 deficit weight
  on anything that makes it (16777220's food: its city district weighs 14,272).
- `exploitable_planets` and `highest_threat` (the `stations_expand` and `armies_threatened`
  minerals entries, the second with a minimum of 100) lower the planets' share in the game.
- `iLog2` / `iExp2` of the opportunity cost's power (doubles here).
- The draw sites of `EstimateUpgradesAndRepairs` and `UpdatePlanetDesignations`.
- Where the game writes `ai_resource_target_floors` when it has some (none in the 2210 saves).
