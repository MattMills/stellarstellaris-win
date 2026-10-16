# The AI's fleets (4.5.2): the ships it wants, its budget for them, its designer, its orders

How the country AI decides which ships to build and builds them: the monthly list of the ships it
wants (the strategy's list 9), the alloys and upkeep budgets that gate an order, the ship designer
that makes its designs, the daily order, and the fleet templates the new ships join. Read from the
Linux 4.5.2 build with its symbols (`/root/re452`, `dec.py`: r2ghidra over the binary, Linux
addresses), and measured in the real game run headless (`headless/run.sh`; under gdb, section 9).
**[V]** = read in the code or measured in the game; **[I]** = inferred. The orders' mechanics
(queues, items, the ship and fleet made) are docs/shipbuilding.md; the budget's split is
docs/ai_economy.md section 2; the strategy lists docs/ai.md section 9.

Ported in `sim/lua/engine/ai/navy.lua` (list 9), `engine/ai/designer.lua` (the designer),
`engine/ai/shipbuilding.lua` (the daily order), `engine/ai/budget.lua` (the upkeep cache),
`engine/ai/strategy.lua` (the monthly rebuild), `engine/fleets/create.lua` (the template count),
the script layer (`simscript/eval.lua`, `simscript/handlers/runtime.lua`).

## In short

- **List 9** (BUILD_SHIP) is rebuilt every calendar month (`CCountryAI::CreateNavyBuildData`): per
  AI ship size the country can build, the ships wanted (a share of the naval capacity by the size's
  `ai_ship_data.fraction`, or `min + planet_mult x planets + system_mult x systems`, at most `max`)
  less the ships it has. It was the save's, decremented by the orders, before **[V]**.
- **An order a day at most** (`BuildShipOfOwnerType`): per size wanted, a design
  (`GetOrRequestDesign`: the AI's own per-role designs), its cost within the ships category's
  alloys budget, the shipyard with the lowest fill ratio; then the item's cost and **upkeep** within
  the budgets (`AddAICommandWithCostAndUpkeepForPosting`), else nothing **[V]**.
- **What holds the AIs back** (docs/shipbuilding.md section 9's open question) is the budget, as the
  game computes it: the alloys stockpile is split ships : ship upgrades : starbases : planets =
  0.6 : 0.2 : 0.6 : 0.1, with 200 for colony ships first while the AI has a colonization target;
  and energy upkeep is weighed in the country's shared pool, which several AIs already overspend.
  Measured in the game with gdb (section 3): the simulation's ships budgets now equal the game's to
  the cent for the eight AI empires checked **[V]**.
- **The designer** (`RequestNewShipDesign`, `CCountry::CreateShipDesign`): sections by role (rolled
  with seed 0), weapons scored by the weapon preference, role tags and stacking, armor or shields by
  the country's ratios, the best required components; a new design is posted as a command and
  ordered the next day. It reproduces the 8 AI designs the game made in 180 days, component for
  component **[V]**.
- **Fleet templates**: the AI builds plain ships (not template reinforcements); a ship built where
  a fleet of the country is in orbit joins it and its template gets the design (`count` + 1) while
  the template stays within the fleet's command limit **[V]**. The Fleet Manager's reinforcements
  (`CReinforceFleetCommand`) come only from the player's buttons **[V]**.
- **Checked** over 30, 180 and 360 days from 2210.01.01 against the headless game: 88/88, 82/88 and
  72/88 table cells equal (section 8); the five ship orders of the game's first 180 days that the
  simulation makes come on the game's days; every difference is located (section 8).

## 1. Where it runs **[V]**

| when | game | Lua |
|---|---|---|
| calendar month | `CCountry::MonthlyUpdateStrategy` (0x235a5a0) -> `CCountryAI::CreateStrategicData` (0x26ec7d0) -> `CreateNavyBuildData` (0x26ec970) | `strategy.monthly` -> `navy.compute` |
| AI month | `CCountryAI::MonthlyUpdate` -> `UpdateUpkeepBudget`, `UpdateExpenditureBudget` (0x26f2230) | `budget.monthly` |
| AI month | `CAIMilitaryMinister::MonthlyUpdate` (0x27a3540): `UpdateFleetCompositions` (0x27a35b0: cloaked ships split off), `TrimFleetGroups`, `ReinforceFleetGroups` (0x27a40b0: idle fleets assigned to fleet groups by power) | not ported (no ship is built there) |
| daily | `CAIInteriorMinister::DailyUpdate` (0x2751e20): research, armies, `BuildShips` (0x2753350) | `shipbuilding.daily` |
| commands | `CAddBuildableToQueueCommand`, `CCreateOrUpdateShipDesignCommand` (0x431f9a0), `CAIAddStrategyCommand` | `ship_command`, `design_command` (after every AI decided) |

## 2. The ships wanted: `CreateNavyBuildData` (0x26ec970) **[V]**

```
the type has ai.construction or ai.limited_military_construction (SCountryAISettings & 0x20080)
clear list 9; N = the ship size database's count; owned[3N] = wanted[3N] = 0
AddShipsFromFleets(country's fleets): each fleet (vfunc +0x60) that is mobile: each ship's growth
    stage's size: owned[owner x N + size index] += 1, owner = CFleet::GetOwnerType (the ships'
    design's ship_owner_type: federation 1, galactic community 2, else 0)
    (a member of a federation whose leader is another and whose progression flag +0x2b4 is clear
    also counts the leader's federation fleets)
AddQueuedShipsToOwned(the country's two construction queue caches): each ship item:
    owned[slot] += 1 only when owned[slot] > 0
each AI ship size (CShipSizeDatabase +0xb8: the sizes with ai_ship_data, database order):
    factor = CAIShipData::GetRawFactor (the `fraction` block, a mean-time-to-happen weight)
    NUtil::CanBuildShipOfSize(size, 0, country) (0x268fbe0: CountryHasPrereqs, IsAvailableForCulture
        unless `graphical_culture = no`, CanUseShipCategory, potential_country, possible_country):
        tuple (size, 0, factor); total[0] += factor
    (the same for owner 1 when the country leads a federation, 2 when it owns the galactic
    community's defense force)
cap[0] = CCountry::CalcNavalCapacity(false, WasHumanRecently); cap[1], cap[2] the federation's,
    the community's
each tuple: factor > 0: n = GetRounded(factor / total[owner] x cap[owner] / max(size +0x630, 1))
                        (size +0x630: the size_multiplier), at most GetShipOfSizeLimit
            else:       n = max(min, 0) + floor(planet_mult x CCountry +0x269c [owned planets])
                            + floor(system_mult x CCountry +0x2e84 [systems]); with max > 0:
                            n = (n == 0) ? max : min(n, max)
    wanted[slot] = n - owned[slot]
AddStrategy(9, slot, 0, wanted, noMerge) for each wanted > 0, in slot order
```

`CAIShipData::ReadMember` (0x2b1ddf0): `min` +0x8, `max` +0x230, `planet_mult` +0x458 (token
0x34ba), `system_mult` +0x680 (0x3ac5), `fraction` +0x8a8. GetRounded rounds to the nearest
**[I]** (16777223's 9.57 corvettes are 10 in the save).

**Naval capacity** (`CCountry::CalcNavalCapacity` 0x23a4090) **[V]**: `NGameplay.NAVAL_CAPACITY_BASE`
+ the pops' part (`NAVAL_CAPACITY_POP_MULT` = 0) + `country_naval_cap_add`, times 1 +
`country_naval_cap_mult` (skipped for a country human recently), + the subjects' contribution,
times the galaxy's `naval_capacity_mult`, a federation member's times 1 - max(the federation's
`federation_fleet_contribution_factor` x (1 + `country_federation_fleet_contribution_discount`) -
`country_federation_fleet_contribution_naval_cap_reduction_discount`, 0)
(`CCountry::CalcFederationFleetContributionCost` 0x23a5d10, `CFederation::GetFleetContribution`
0x25919d0), at most `NAVAL_CAPACITY_MAX`, times 1 + `NAVAL_CAPACITY_NO_LEADER_PENALTY` without a
naval head (`CGovernment::GetNavalHead` 0x1c14290: a filled position of
`NGameplay.COUNCIL_NAVAL_POSITIONS`). The modifier values the simulation builds agree with the
game's capture (`/opt/stellaris-captures/modifier-nodes-2210.tsv`: 16777217 add 8.8, mult 0.1 ->
64.68). The 2210 saves' federation 0 (a hegemony: 16777223 leads, 49 and 50 contribute 0.1 each)
is why 16777223's own corvettes are 8 of its 11.

At load the computed list equals the 2210.01.01 save's for 25 of the 27 entries of the AI empires
(`navy.compare()`); the two others are 16777218's science ships (1 wanted in the save, 0 here) and
49's corvettes (1, 2 here), lists the game made a month before the save.

Script-layer pieces this needed: `set` inside a script value's `modifier` (VALUE_OPS) and the
trigger `controlled_systems` (desired_constructors_min), both in `simscript/eval.lua`.

## 3. The budget that gates an order **[V]** (measured)

`CCountryAI::CanAffordExpenditure` (0x26f8cf0) and `CanAffordUpkeep` (0x26f9400) read the arrays the
AI month fills: the expenditure budget (`CCountryAI +0x558`, one `CFixedResourceTable` of 32 bytes
per economic category, index = the category's database index: 0 buffer, 1 country, 21 ships, 22
colonies, 25 ship_upgrades, 31 starbases, 41 planets), the upkeep budget (+0x570) and the upkeep
cache (+0x5a0); resource 10 is alloys, 0 energy. Read with gdb in the headless game (section 9):

| country (2210, its first AI month) | game: alloys budget ships / ship_upgrades / starbases / planets / colonies | simulation before | after |
|---|---|---|---|
| 6 (01.07) | 242.34 / 80.78 / 92.34 / 40.39 / 201.95 | 269.27 / - / 19.27 / 44.86 / 224.38 | 242.34 / 80.78 / 92.34 / 40.39 / 201.95 |
| 16777217 (01.18) | 147.30 / 49.09 / 196.40 / 24.54 / - | 166.94 / - / 222.59 / 27.82 / - | 147.30 / 49.09 / 96.40 / 24.54 / - |
| 16777218 (01.19) | 57.23 / 19.07 / 57.23 / 9.54 / 200 | 111.46 / - / 150.00 / 18.57 / - | 57.23 / 19.07 / 57.23 / 9.54 / 200 |
| 16777219 (01.20) | 80.46 / 26.82 / 80.46 / 13.41 / 200 | | 80.46 / 26.82 / 80.46 / 13.41 / 200 |
| 16777220 (01.21) | 118.52 / 39.50 / 118.52 / 19.75 / - | | 118.52 / 39.50 / 118.52 / 19.75 / - |
| 16777221 (01.22) | 118.20 / 39.39 / 157.59 / 19.69 / - | | 118.20 / 39.39 / 57.59 / 19.69 / - |
| 16777224 (01.25) | 88.87 / 29.62 / 88.87 / 14.81 / - | | 88.87 / 29.62 / 88.87 / 14.81 / - |
| 16777225 (01.26) | 76.89 / 25.62 / 150.00 / 12.81 / - | | 76.89 / 25.62 / 150.00 / 12.81 / - |

(the starbases column of the simulation is read after its own starbase upgrade withdrew 100;
the game's lines are read before its first order). What was missing in the simulation:

- **ship_upgrades**: `alloys_expenditure_ship_upgrades` is potential with `any_owned_fleet = {
  can_be_upgraded = yes }`; the script runtime left a fleet's `can_be_upgraded` unanswered. A ship
  can be upgraded (`CShip::CanBeUpgraded` 0x2ac59c0) when its flag +0x478 & 0x80 is set, its
  fleet's `CanUpgrade` flag +0x1270 is set and `CalcLatestUpgradableDesign` is a design; a fleet
  when one of its ships can (`CFleet::HasShipsThatCanBeUpgraded` 0x29426d0). The runtime now answers
  it from the ship's `ship_design_implementation.upgrade` (another existing design) **[I: the two
  flags taken as set]**.
- **colonies**: `alloys_expenditure_colonies_expand` (`desired_min` 200) is potential with
  `ai_colonize_plans > 0` (`CAIColonizePlans` 0x3bdddf0: the size of list 1, COLONIZE). The runtime
  left it a miss while list 1 is not rebuilt; it now answers from list 1 as the world holds it
  (`STELLAR_AI_LIST1=off`: the miss again), and the monthly rebuild drops the targets that got an
  owner or a colony since (`strategy.monthly`; `AddColonyData` itself is not ported).
- **the upkeep cache of a pooled resource**: `CanAffordUpkeep` adds the new upkeep to the cache of
  the category to use (ships) and compares with the budget of the category the resource goes to
  (the country, for the ships' energy: `ai_use_parent_for_resources_upkeep`). The game's cache of
  ships for energy is the country's (country 6: 202.13 of a 193.91 budget: it can't add a corvette
  and orders none in 360 days); the simulation's was the ships' own (21.89). `budget.lua` now gives
  a pooled resource its pool's cache.

## 4. The designer **[V]**

`CAIInteriorMinister::GetOrRequestDesign(size, owner, cap)` (0x2766270):

```
r = AI draw; role = SShipDesignPreferences::GetEffectiveRoleForShipSize(size, personality, r)
    (0x26cac00: the country's ai_ship_role_overrides of the size, the first whose running weight
    exceeds r % their total; else the personality's ship_roles; else none)
no role and no cap: CCountry::GetLatestShipDesign(size, owner)
the minister's SShipSizeDesignInfo of the size (+0x90, 0x90 bytes: size, name, date +0x60,
    a cost cap; not saved): while CalcDiffMonths(date) < NAI.SHIP_DESIGN_STALE_MONTHS (24) the
    country's design of that name and size, when it exists
none yet: r = AI draw; the name = CNameListManager::TakeRandomShipClassNameForDesign(size, r)
    (0x1dc2eb0: up to 100 names of the name list from r, the first no design of the country has)
RequestNewShipDesign(info) (0x2765d20):
    r1 = AI draw; CCountry::CreateShipDesign(size, class, owner, r1, cap) (0x233f4a0): "Temp
        <size>", sections from CCrudeRandom(r1) with no role, required and section components;
        IsValidToSaveForCountry, else nothing
    r2 = AI draw; role = GetEffectiveRoleForShipSize(..., r2)
    a role: the design's role; its sections cleared; AddRandomSectionsToShipDesign(0) (the
        sections rolled again with seed 0, with the role); AddRandomSectionsToShipDesign(r3 = AI
        draw) (no slot left); AddRequiredComponentsToShipDesign; r4 = AI draw;
        AddSectionComponentsToShipDesign(r4)
    the country's design of the info's name and size with identical components: it (dated today)
    else the newest of its designs of the size with identical components: it, its name the info's
    else: the design named, CCreateOrUpdateShipDesignCommand posted, nothing returned
```

`CCrudeRandom(v)` (0x422b070) is a CNoiseRandom { position = noise(v, 0x5ea6ba9f), seed 0 }; its
`GetInteger` is `(h & 0x7ffffffe) ^ h >> 8` of the hash before its last round (`RUST.noise_raw`).

**Sections** (`CShipDesignTemplatesDatabase::FindRandomSectionTemplate` 0x2b091d0): the section
templates in database order that fit the size and the slot and whose prerequisites the country
has, with the role in their `ai_tags` (any without a role); each with `ai_weight` w > 0 draws
crude % w and the highest wins (the first on a tie), preferring the sections whose weapon slots can
all be filled (`SectionWeaponSlotsFillable`); none with the role: again without.

**Weapons** (`AddWeaponsToShipDesignSection` 0x23757a0, `FindBestWeaponTemplate` 0x2b097a0): each
weapon slot; every weapon of the slot's size with `ai_weight` > 0, not of a space fauna component
set (`is_space_fauna_component_set`, the set's flag +0xa4), buildable (`CanBeBuiltBy`: hidden no,
prerequisites; `IsAllowed`: `potential`, `possible` in the design's scope) scores
`(10 - power) x DESIGNER_WEAPON_PREF_MUL (1.33; 5.33 for stations) when its tags hold the weapon
preference x DESIGNER_WEAPON_ROLE_MUL (5.33) when its ai_tags hold the role /
(1 + DESIGNER_WEAPON_STACKING_DIV (0.05) x the placed components sharing a tag) x ai_weight`;
the highest, a tie to the later one when (country id ^ its index in the weapon list) is even.

**Utilities** (`AddUtilities` 0x23743a0, `FindBestUtility` 0x2b0b330): armor or shields, the one
further below the country's ratio (`ai_armor_ratio_override` / `ai_shields_ratio_override`, else
the personality's), armor on a tie **[I: the function's comparisons not followed in full; the rule
reproduces every design of the 180 days]**, then the best component of that kind by ai_weight
(x DESIGNER_UTILITY_ROLE_MUL for the role); aux slots the best aux utility.

**Required components** (`AddRequiredComponentsToShipDesign` 0x2340050,
`CComponentSet::FindBestRequiredComponent` 0x22f3a60): per `required_component_set` of the size,
the buildable component of the set with the highest ai_weight (x DESIGNER_UTILITY_ROLE_MUL with the
role in its ai_tags), the first on a tie (picket and swarm combat computers for screens and
gunships once researched).

`CCreateOrUpdateShipDesignCommand::Execute` (0x431f9a0): `CShipDesignCollection::
CreateOrUpdateShipDesign` (a design of the same name replaced and its templates retrofitted), one
draw of the synchronized generator for the scope, `on_ship_designed` (this = the country).

**Check** (`designer.generate` on the 2210.01.01 world against the AI designs the game made in 180
days): 8 of 8 identical, sections, components and required components in order: 16777218's and
16777219's screens (flak / point defence by the weapon preference, armor-shield-armor and
shield-armor-shield by the ratios), 16777221's swarm gunship, 16777225's missile screen with the
fusion reactor and the picket computer, 16777224's screen and constructor, 16777220's constructor,
16777217's gunship.

The same pipeline with the synchronized generator is `CCountry::CreateAndAddDefaultShipDesign`
(0x233f230: four `CRandom` draws: the seed, the role, the sections, the components), which
`CCountry::SetDefaultShipDesigns` (0x2340cf0) runs for each size with a default design (new games,
and the `auto_gen_design` designs made after research). Ported as `designer.design_for(country,
size)` and `designer.set_default_designs(country, stations)` for the new-game effects; not run
during play (the game refreshed them twice in the 2210 saves' first 180 days, 61 draws). **[V]**
for the sizes made (`is_designable = no` sizes too: the constructors) and the sections' slots
(`fits_on_slot` is a repeated key: a military station's sections go west and east); the game's
designs at load (16779215 constructor, 16779216 military_station_small) have the same structure
and the same armor/shield alternation. **[I]** which of two equally tagged sections is picked
(LIGHT_ or MEDIUM_MILITARY_STATION_SECTION) follows the draw, which a probe from a loaded save
cannot align with the one the game made at the empire's creation.

## 5. The daily order **[V]**

`BuildShips` (0x2753350): with `ai.construction`, `BuildColonizer` (when list 1 is not empty;
no AI draws; not ported), then `BuildShipOfOwnerType` for the federation's fleet (owner 1: the
federation's leader, or any member while the progression's flag +0x2b4 is clear) or the galactic
community's (2), and for the country's own (0). Traced in the game: the 2210 hegemony's three
members call both every day. With only `ai.limited_military_construction`, the own.

`BuildShipOfOwnerType(owner)` (0x2764b40), one ship at most:

```
the country's two construction queue caches (CGameState construction manager +0x108 by country)
owned, queued = CountOwnedShips, CountQueuedShips; offset = GetShipSizeBuildStrategyOffset(N, owner)
each AI ship size (database order): wanted = GetStrategyValue(9, size index + offset, 0) > 0:
    design = GetOrRequestDesign(size, owner); valid and of the size
    cost = its growth stage's economic unit with the country's modifiers (+0x3150)
    CanAffordExpenditure(size +0x198 category, cost, &short), else: a short strategic resource
        (CStrategicResource +0x3f8 = 4 or 8): GetOrRequestDesign(size, owner, cap) once more,
        another kind: next size
    not a colonizer (class 2); not a constructor or science ship (class & 0xfd == 1) when human
        recently; CShipDesign::CanCountryBuild
    have = owned + queued of the size (a size family: the family's sizes by naval capacity)
    ratio = have / (have + wanted)
    each queue of the caches with room (count < capacity): the buildable (a cloaking fleet of the
        owner under its command limit gets a template reinforcement, else a plain ship);
        CConstructionQueue::CanAddItem: the lowest ratio wins, a tie the queue with fewer items
the winner: PostBuildCommand (0x2764670): CreateAddBuildableCommand, AddAICommandWithCostAnd-
    UpkeepForPosting (0x27897d0): IsValid (the cost at the shipyard), CanAffordExpenditure,
    CalcUpkeep, CanAffordUpkeep, else nothing; posted, WithdrawCost; CAIAddStrategyCommand(9,
    slot, 0, -1)
```

## 6. Fleet templates **[V]**

- `CFleetTemplateManager::OnShipAdded` -> `CreateOrAddToTemplate` (0x2a1b130): a military fleet's
  template gets the ship's design (`CFleetTemplateDesign::GetDesignToUse`) through
  `CFleetTemplate::AddDesign(design, 1)` (0x2a163b0: the entry's count + 1, a new entry with count
  1; fleet_size + the size's naval capacity) while fleet_size + the size's stays within the fleet's
  command limit; a fleet without a template gets a new one (`CGameState::CreateNewFleetTemplate`,
  or `CreateNewEmptyTemplate` for a fleet that uses no template). `create.lua` wrote new entries
  without their count: they read as 0 (16777217's 16777369 x2 in the game, x0 before).
- A ship that joins a fleet by a merge enters its template with count 0 (16777218's and
  16777221's corvettes in the game, fleet_size + 5): the military minister's merges, not ported.
- `CReinforceFleetCommand` (0x22e5700: `CalcShipsToReinforce`, one `CBuildableShipReinforcement`
  per missing ship of the template at its home base) is made only by the Fleet Manager's buttons
  (`CFleetManagerView::ReinforceAll` 0x2d7f440, `CFleetActionReinforceButton`) and the template
  tooltip (`CalcAllShipsToReinforce`): there is no automatic reinforcement, for players or AIs.
- `CAIMilitaryMinister::ReinforceFleetGroups` assigns idle military fleets to fleet groups until
  the offensive and defensive power allotments are met: it builds nothing.

## 7. Random draws

- The AI's unsynced stream, per country, in the order above: the role draw per size wanted each
  day; a new design info's class name; RequestNewShipDesign's two (no role) or four.
- The synchronized stream: one per design made (`on_ship_designed`'s scope).
- The game's AIs draw 12,700 to 23,000 unsynced values in 180 days, the simulation's 1,300 to 1,900
  (diplomacy, the military minister, war, and the rest of the interior minister are not ported), so
  the stream's position differs from the first unported draw and the role picks differ: 16777219
  reuses its gunship design in June where the game drew a screen.

## 8. Checks

The real game from 2210.01.01 with `-loadrandomseed -threads=1` for 298, 1798 and 3598 ticks
(2210.02.01, 2210.07.01, 2211.01.01; `/root/aif/ref` on .24), against `examples/diff` over the
same days with the world written out (`STELLAR_DIFF_SAVE`), summarized per AI empire
(`fleets.py`, `fcompare.py`); game / simulation, a single number where equal and unchanged.

Before (the baseline, 180 days): 75 of 88 cells equal.

**2210.07.01** (180 days): 82 of 88.

| country | corvette | constructor | science | colonizer | military fleets (ships) | ship items queued | templates (fleet_size) |
|---|---|---|---|---|---|---|---|
| 6 | 14 | 3 | 4 | 0 | 10 4 | - | 50 20 |
| 49 | 8 | 2 | 4 | 0 | 8 | - | 40 |
| 50 | 9 | 2 | 4 | 0 | 9 | - | 45 |
| 16777217 | 6 / 6 | 1 | 4 | 0 | 6 | constructor | 30 |
| 16777218 | 3 | 1 | 3 | 0 / 1 **x** | 3 | corvette / - **x** | 15 |
| 16777219 | 9 | 3 / 3 | 4 | 1 | 9 | corvette | 45 |
| 16777220 | 2 | 2 | 3 | 0 | 2 | - / corvette **x** | 10 |
| 16777221 | 18 / 18 | 3 | 4 | 0 | 14 4 / 15 3 **x** | - | 70 20 / 70 15 **x** |
| 16777223 | 11 | 2 | 4 | 0 | 8 3 | - | 40 15 |
| 16777224 | 4 | 3 | 5 | 0 | 4 | corvette | 20 |
| 16777225 | 15 | 4 | 4 | 0 | 10 5 | - / corvette **x** | 50 25 |

**2210.02.01** (30 days): 88 of 88 (16777221's and 16777217's orders of January and February on the
game's days). **2211.01.01** (360 days): 72 of 88 (the cells above plus their consequences).

The orders of the first 180 days:

| country | game | simulation |
|---|---|---|
| 16777221 | 2210.01.23 corvette (a new gunship design) | 2210.01.23 corvette (its existing design) |
| 16777217 | 2210.02.06 corvette | 2210.02.06 corvette |
| 16777224 | ~2210.05.26 corvette (a new screen) | 2210.05.26 corvette |
| 16777217 | ~2210.06.19 constructor | 2210.06.19 constructor |
| 16777218 | 2210.06.20 corvette | - |
| 16777219 | 2210.06.21 corvette (a new screen) | 2210.06.21 corvette (its gunship design) |
| 16777220 | - | 2210.05.22 corvette |
| 16777225 | - (~2210.11.27) | 2210.06.27 corvette |

The differences, located:

- **16777218** (no June corvette, a colony ship left): the game's colony ship settles its target,
  list 1 empties, the 200 alloys of the colonies entry go back to the ships (its ships budget 127.8
  on 06.18) and it orders on 06.20. The simulation's AI does not use colony ships (the colonizers'
  orders are not ported), so the reserve stays.
- **16777220** (an extra corvette on 05.22): the game's ships budget on 05.21 is 116.4, below the
  corvette's 130.62; the simulation's is above it: a difference in the alloys stockpile (the economy
  over 140 days), not in the rule.
- **16777225** (an extra corvette on 06.27): the game bought a starbase upgrade on 06.13 (its
  starbases budget 152.7 -> 62.7) and its June ships budget fell to 79.6; the simulation's starbase
  AI did not buy it (`engine.ai.starbases`), so the alloys went to a corvette.
- **16777221's fleets** (14 + 4 in the game, 15 + 3 here): the January corvette joins fleet 307 in
  orbit of the shipyard here; in the game it went to fleet 666, entering its template with count 0
  (a merge by the military minister, not ported).
- The designs: the role draws differ once the unsynced stream does (section 7); the counts don't.

## 9. Measuring the game's AI with gdb

`run.sh` with the launch line replaced by `gdb -batch -ex "set environment LD_PRELOAD=<so>" -x
SCRIPT --args ./stellaris <args>` (a copy in `/root/aif/run_gdb.sh` on .24, private
`HEADLESS_ROOT`); the script `set startup-with-shell off`, passes the game's signals, `starti`, sets
breakpoints by symbol (`'CCountryAI::CanAffordExpenditure(...) const'`, `+offset` for a result after
a call), prints with `printf` in `commands`, and `continue`s. 180 days take 1 to 5 minutes. Gotchas:
`$bp`, `$sp`, `$pc`, `$fp` are registers, not variables (setting `$bp` corrupted the game); the AI
runs on 4 threads (`$_thread` to follow one country); read guarded pointers only (an error ends the
script and the game). The country of a `CCountryAI*` is at +0x3a0, the minister's AI at
`*(this + 8)`, the game date `*(int*)(g_CurrentGameState + 0xc0)` (24 a day).

## 10. Not modelled

The colonizers (`BuildColonizer`, list 1's `AddColonyData`), the federation's and the galactic
community's ships (their designs, wanted ships and orders), the cheaper design for a short strategic
resource, the size families, `CanCountryBuild`, the ship size limits, `DisbandShips`, the military
minister (fleet groups, merges, movements), the default and auto-generated designs
(`SetDefaultShipDesigns`), the design's name list draw (a deterministic pick from the draw **[I]**),
`RemoveNonPoweredComponentsInShipDesign` and `UpgradeComponents` in the designer (no tier 1 design
needs them).
