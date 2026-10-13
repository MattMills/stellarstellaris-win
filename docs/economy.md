# The economy, unit by unit (4.5.2)

What each kind of economic unit contributes to a country's monthly budget: the game's classes, the
save fields the unit is read from, its scale, the modifier node it reads, its economic categories
and its special cases. The categories, the `ApplyModifiersToTable` formula and when the budget is
computed are in [modifiers.md](modifiers.md#the-economy); this document is the rest. The
implementation is `sim/lua/engine/economy.lua` (the formula, budgets, `monthly`, the check),
`sim/lua/engine/economy/units.lua` (one function per unit kind, in the order below) and
`sim/lua/engine/economy/script.lua` (what the resource tables ask of the script layer that it does
not answer yet).

Addresses are GOG 4.5.2 RVAs, names from its PDB (`/root/fnm_tmp/names452.tsv` on hippo, read with
`annotate.py`). **[V]** marks what was read in the disassembly; a class or function name with its
address alone is read from the PDB. **[I]** marks what is inferred: from names, from the script
files, or from fitting the budgets of the 2210.01.01 save (`budget.current_month` of every
country; `sim/tests/economy.rs`). With the game's capture of its modifier nodes at that moment
(`/opt/stellaris-captures/modifier-nodes-2210.tsv`) as the modifiers, **1,254 of the 1,319
(country, side, category, resource) entries are within 0.1%** (95.1%). Fixed point: `CFixedPoint`,
int64, 1.0 = 100000.

## In short

- **A unit is a resource table on an object, with a scale, read with one modifier node.** The
  game's unit classes are `CStandardEconomicUnit<Type, Owner, CEconomicUnitScopeRef<Owner>>` (for
  example `<CJobType, CColony>`, `<CBuildingType, CColony>`, `<CDepositType, CPlanet>`,
  `<CStarbaseModule, CStarbase>`, `<CCountryType, CCountry>`), `CLocalObjectEconomicUnit<CShipSize,
  CShipGrowthStage>` and the objects that are units themselves (`CEconomicUnitBase<X>` for `CPopJob`,
  `CPopGroup`, `CLeader`, `CShip`, `CArmy`, `CColony`, `CPlanet`, `CMegaStructure`, `CSector`,
  `CRelation`, `CEconomicContainer`, `CDiplomacyCountryModule`, ...: 25 in the PDB). The second
  template argument is the object the unit belongs to; the unit reads that object's modifier node
  **[I]** (each fits the save with that node).
- **Tables and sides.** `produces` goes to income and `upkeep` to expenses. `cost` (building,
  recruiting) is not in the monthly budget. Ships also have a `logistics` table (trade paid by
  fleets away from a dock, below).
- **Each block of a table** has an optional `trigger`, resources and an optional `multiplier` /
  `mult` (a number, a script value, or a `trigger:` value such as `trigger:has_base_skill`); the
  triggers and values are evaluated in the unit's scope (the planet for colony units, the pop
  group, the leader, the ship, the country, ...) **[I]**. Inline scripts are expanded, those at the
  top level of a definition too (a job's whole `resources` can come from one).
- **After the units, two costs computed from the budgets**: planetary deficits (trade paid for
  each colony's local deficits) and the trade policy (the month's net trade spent and converted).
- **The save's moment**: the budget is computed in `MonthlyUpdate` before the month's pop growth,
  and the save is written after it. Checking against a save takes the growth back out (below).

| kind | the game's unit | read from (save) | scale | modifier node | categories |
|---|---|---|---|---|---|
| jobs | `CPopJob`, `<CJobType, CColony>` | `pop_jobs`, `colony.pop_jobs` | `max(0, (workforce + bonus_workforce) / 100)` | Colony | the job's `resources.category` (`planet_*`) |
| job automation | (the pop category's `automation_resources`) | `pop_jobs.automated_workforce` | `automated_workforce / 100` | Colony | `planet_automated_jobs` |
| buildings | `<CBuildingType, CColony>` | `colony.buildings_cache`, `buildings` | 1 | Colony | `planet_buildings*` |
| districts | `<CDistrictType, CColony>` | `colony.districts`, `districts` | the district's `level` | Colony | `planet_districts_*` |
| zones | `<CZoneType, CColony>` | `districts.zones`, `zones` | 1 | Colony | `planet_zones` |
| pop groups | `CPopGroup` | `pop_groups`, `species_db` | `size / 100` | PopGroup | `planet_pops`, `planet_pops_traits`, `pop_category_*` |
| country type | `<CCountryType, CCountry>` | `country.type` | 1 | Country | `country_base` |
| country container | `CEconomicContainer` | (`common/country_container`) | 1 | Country | `country_*` (adds only) |
| leaders | `CLeader` | `country.owned_leaders`, `leaders` | 1 (the tables multiply by the skill) | Leader | `leader_*` |
| deposits | `<CDepositType, CPlanet>` (orbital), `<CDepositType, CColony>` | `deposit`, `planet.shipclass_orbital_station` | 1 | Planet | `orbital_*_deposits`, `deposit_blockers_*` |
| starbase modules, buildings | `<CStarbaseModule, CStarbase>`, `<CStarbaseBuilding, CStarbase>` | `starbase_mgr.starbases` | 1 | Starbase | `starbase_modules`, `starbase_buildings` |
| ships | `CShip`, `<CShipSize, CShipGrowthStage>`, `CComponentTemplateEconomicUnit` | `ships`, `ship_design`, `fleet` | 1, times the ship's upkeep factor | Ship | `ships`, `ship_components`, `starbases`, `station_*` |
| armies | `CArmy` | `army` | 1 | Army | `armies` |
| diplomacy | `CDiplomacyCountryModule`, `<CDiplomacyEconomicAppliedUnit, CCountry>` | `country.relations_manager`, `federation` | 1 per relation | Country | `federation`, `rivalries`, `*_pacts`, `envoy_costs`, ... |
| planetary deficits | (computed) | the colonies' own tables | | | `planet_resource_deficit` |
| trade policy | (computed) | `country.trade_conversions` | | | `trade_policy` |

## The budget and the stockpile

- **Save fields**: `country.budget = { current_month = { income = { <category> = { <resource> = v
  } } expenses = { ... } balance = { ... } } last_month = { ... } }`, written by
  `CCountryBudget::WriteMembers` (`0xacda20`), read by `CCountryBudget::ReadMember` (`0xacdad0`),
  a page per month (`CCountryBudgetPage`, `0xacd880`; `UpdateTotal` `0xaccd10`).
  `CCountryBudget::EndMonthlyUpdate<0>` (`0xacdf60`) closes the month; `<1>` (`0xacdd50`) is the
  load and new-game pass without the stockpile ([modifiers.md](modifiers.md#when-it-is-computed)).
- **The stockpile** is `country.modules.standard_economy_module.resources = { <resource> = v }`
  (`CEconomyCountryModule`: `AddResources` `0x7fdd90`, `AddResource` `0x7fe0d0`, `GetResource`
  `0x7fdfe0`, `CapTable` `0x7fe4a0`). Countries without that module (enclaves, space fauna,
  primitives, ...) still have budgets but no stockpile.
- **The caps** **[I]** (`economy.capacity`): a resource's `max` in `common/strategic_resources`,
  plus its `dynamic_capacity` (`base`, and the `add` of each `modifier` block whose trigger holds
  for the country), plus `country_resource_max_add` and `country_resource_max_<r>_add`; `fixed_max_amount
  = yes` keeps the written `max` (influence: 1000). A cap stops growth; it does not take away what
  is above it. Research is not stockpiled: it goes to the technologies being researched
  ([simulation.md](simulation.md) section 6, research).
- **Deficits of the country** (a stockpile going below zero) are handled daily
  (`CCountry::DailyUpdateSafePrivate_UpdateDeficits` `0x6eff70`, `CCountry::CancelEdictsDuringDeficit`
  `0x6f6100`; the resources' `deficit_situation`); not described here.

## Jobs

- **Classes**: `CPopJob::UpdateEconomicResources` (`0x835f90`, rebuilds the job's templates),
  `CPopJob::CalcEconomicMultiplier<1/2>` (`0xde47a0`), `CPopJob::GetWorkforce` (`0x40e390`),
  `GetMaxWorkforce` (`0x9f7ea0`), `GetAssignedWorkforce` (`0x837940`);
  `CEconomicUnitCollection<CPopJob>::CalcResource<1>` (`0xde8770`) and `<2>` (`0xde9fb0`); the job
  type's tables `CEconomicUnit<CStandardEconomicUnit<CJobType, CColony, ...>>::CalcTable<1>`
  (`0x41d0d0`) and `<2>` (`0x41db50`).
- **Save fields**: `pop_jobs = { <id> = { type workforce bonus_workforce automated_workforce
  max_workforce workforce_limit pop_groups = { { pop_group amount } ... } planet pop_group } }`.
  The job's `planet` is the **colony** id (the `colony` store), not a planet's. A colony lists its
  jobs (`colony.pop_jobs`); a planet points to its colony (`planet.colony`). Unfilled job slots are
  written with `workforce = -1`.
- **Scale**: `max(0, (workforce + bonus_workforce) / 100)` (`POP_BULK_UNIT_SIZE` = 100), 0 when
  the colony is occupied ([modifiers.md](modifiers.md#the-formula-applymodifierstotablen)). The
  save's `workforce` already holds the automated part (`workforce = 2600` with `automated_workforce
  = 1300` and 1,300 pops assigned) **[I]**.
- **Node**: the colony's (`Colony`, owned by the colony id) **[I]**: technicians on colony 0 give
  `6.2 * 6 * (1 + 0.07947 + 0.04) = 41.64428`, the save's value, with
  `planet_jobs_produces_mult` and `planet_jobs_energy_produces_mult` of that node.
- **Scope of the triggers**: the planet **[I]** (`has_carrier_flag`, `owner?`, `colony?` in the
  vanilla tables; `colony` of a planet is the planet itself).
- **Categories**: `resources = { category = planet_<x> ... }` of `common/pop_jobs`; the job's
  `overlord_resources` (paid to the overlord) are not modelled.
- **Automation** **[I]**: the automated workforce pays its pop category's `automation_resources`
  (`common/pop_categories`: `category = planet_automated_jobs`, `upkeep = { energy =
  @automation_upkeep_worker }`, 4, 8 or 12 per 100), scale `automated_workforce / 100`, the
  colony's node. Fits both entries of the save (the two fallen empires: 1,403.28 and 631.76
  energy).
- **Special cases**: a job's resources may come from an inline script at the definition's top level
  (`colonist = { inline_script = { script = shroud/jobs/colonist_job ... } }`), so the definition is
  expanded before its `resources` are read.

## Buildings, districts and zones

- **Classes**: `CColony::UpdateEconomicResources` (`0xdb34f0`); the tables
  `CEconomicUnit<CStandardEconomicUnit<CBuildingType, CColony, ...>>::CalcTable<1>` (`0x476c80`) and
  `<2>` (`0x477840`); `<CDistrictType, CColony>` `0x4948b0`, `0x495470`; `<CZoneType, CColony>`
  `0x483cb0`, `0x484870`. The colony's snapshot (`CColony::CalcTableIncludePops<1>` `0xddf650`,
  `<2>` `0xddfac0`) sums them with the jobs and pop groups.
- **Save fields**: `colony.buildings_cache = { <building ids> }`, `buildings = { <id> = { type
  position } }`; `colony.districts = { <district ids> }`, `districts = { <id> = { type level zones =
  { <zone ids, 4294967295 for none> } } }`; `zones = { <id> = { type buildings = { ... } } }`.
- **Scales** **[I]**: a building 1, a district its `level`, a zone 1 (all 50 building, 65 district
  entries of the save match).
- **Node**: the colony's; **scope**: the planet.
- **Categories**: `planet_buildings`, `planet_buildings_strongholds`, `planet_buildings_clone_vats`,
  ...; `planet_districts_cities`, `_farming`, `_mining`, `_generator`, ...; `planet_zones`.

## Pop groups

- **Classes**: `CPopGroup::UpdateEconomicResources` (`0x67cd00`),
  `CEconomicUnitCollection<CPopGroup>::CalcResource<1>` (`0xde8f00`) and `<2>` (`0xdea860`).
- **Save fields**: `pop_groups = { <id> = { key = { species category } planet size
  last_month_growth last_month_growth_details = { key = "GROWTH_CAT_GROWTH" value = n key =
  "GROWTH_CAT_PROMOTION" ... key = "GROWTH_CAT_RESETTLE" ... } month_start_size ... } }`; `planet` is
  the colony id. `species_db = { <id> = { class traits = { trait = "x" ... } } }`; the archetype is
  the species class's (`common/species_classes`: `archetype = BIOLOGICAL`).
- **Tables** **[I]**: the species archetype's (`common/species_archetypes`, category `planet_pops`),
  each trait's (`common/traits`, category `planet_pops_traits`), and the pop category's
  (`common/pop_categories` by `key.category`, categories `pop_category_workers`, `_specialists`,
  `_rulers`, `_civilians`, `_precursor`, ...). The README of `common/economic_categories` explains
  why the traits have their own hidden category: an `_add` modifier applies once per table of its
  own category on the object.
- **Scale**: `size / 100` ([modifiers.md](modifiers.md#the-formula-applymodifierstotablen)).
- **Node**: the pop group's own (`PopGroup`); **scope**: the pop group.
- **Most of the consumer goods upkeep is an add** **[I]**: `pop_category_workers_consumer_goods_upkeep_add`
  and the like on the pop group's node (from the living standard), with the triggered mult
  `planet_pops_enslaved_consumer_goods_upkeep_mult` (`is_enslaved = yes`) on the chain.
- **The triggers read the species rights** **[I]**: `country.modules.standard_species_rights_module
  = { species_rights = { { species_index living_standard citizenship ... } ... } primary = { ... }
  default = { ... } built_species = { ... } }`; a species' entry, else `primary` for the founder
  species, else `built_species` for robots, else `default`. `has_living_standard = { type }`,
  `has_citizenship_type`, `is_enslaved` (`citizenship_slavery`) and `is_being_purged` come from
  there.

## Country types and the country container

- **Classes**: `CEconomicUnit<CStandardEconomicUnit<CCountryType, CCountry, ...>>::CalcTable<1>`
  (`0x1680450`), `<2>` (`0x1680ca0`), `CEconomicUnitBase<...CCountryType...>::SumEconomicAddModifiers<1>`
  (`0xacfdd0`); `CEconomicContainer::UpdateEconomicResources` (`0x1659880`),
  `CEconomicUnitCollection<CEconomicContainer>::CalcTable<1>` (`0x168da20`) and `<2>` (`0x168e710`).
  The same pattern exists for edicts (`<CEdict, CCountry>` `0x16814f0`), crisis perks and relics.
- **Save fields**: `country.type` (`common/country_types`).
- **The country type's table**: `resources = { category = country_base produces = { ... } }` with
  triggers (`NOT = { has_origin = origin_nomadic_purger }`, `is_gestalt = no`, ...); 1,000 energy,
  250 minerals and so on for fallen empires. Scale 1, the country's node, scope the country.
- **The country container** (`common/country_container`: `collection = { <name>_unit = { resources
  = { category = country_<x> } } }`, 23 units): tables with a category and no amounts, so that an
  add modifier shows in the top bar under its own name (the file's comment). Each gives
  `country_<x>_<resource>_produces_add` (and `_upkeep_add` where generated) of the country's node
  **[I]**: `country_power_projection`, `country_civics`, `country_tech`, `country_ethic`,
  `country_ruler`, ... (52 of 55 and 6 of 6 entries match).
- **Not modelled**: edicts. Most countries with perpetual edicts have no `edicts` entry in the
  budget; one fallen empire pays 84.36 unity. The edict fund (`country_edict_fund_add`) pays for
  them first **[I]**.

## Leaders

- **Classes**: `CEconomicUnitBase<CLeader>::CalcUpkeep` (`0xa76640`), `CalcCost` (`0x75b140`);
  `CEconomicUnit<CLeader>::CalcResource<0>` (`0x111e7f0`) and `<2>` (`0x111f060`);
  `CLeader::CalcResource<0>` (`0x111e570`) and `<2>` (`0x111e6b0`).
- **Save fields**: `country.owned_leaders`, `country.ruler`; `leaders = { <id> = { class level
  bonus_skill_level traits = "x" (repeated) location = { type assignment id } country species ... }
  }`. The save writes no `heir`.
- **Tables**: the leader class's `resources` (`common/leader_classes`, category `leader_commanders`,
  `leader_scientists`, `leader_officials`, ...), with `inline_script = "paragon/leader_base_upkeep"`:
  2 unity per skill level, `mult = trigger:has_base_skill`. **[I]** `trigger:has_base_skill` is the
  leader's `level`, `trigger:has_total_skill` its `level + bonus_skill_level`.
- **Node**: the leader's (`Leader`); **scope**: the leader.
- **Special cases** **[I]**:
  - imperial heirs: the script exempts `trait_imperial_heir` holders that are the ruler or the heir;
    with no `heir` in the save, the heir is the holder that is not the ruler;
  - a gestalt country's ruler and councilors pay nothing (country 6, a machine intelligence:
    commanders 12 not 22, officials 4 not 14, scientists 12 not 16); not explained;
  - some upkeeps are fractions of a month's (9 against 10.8, 10.667 against 8), as if the budget
    counted a leader changed during the month for part of it; not explained.

## Deposits

- **Classes**: `CDepositHolder::GetEconomicUnitTemplateCollection` (`0x2322d0`); the deposit units
  `CStandardEconomicUnit<CDepositType, CPlanet, ...>` (`CalcTable<1>` `0x4a0c30`, `CalcResource<1>`
  `0x6afe50`), `<CDepositType, CColony>` (`CalcTable<0>` `0xac7a30`, `<2>` `0xac6fb0`),
  `<CDepositType, CShip>` and `<CDepositType, CAstralRift>`.
- **Save fields**: `deposit = { <id> = { type deposit_holder = { type = 0 id = <planet> } } }`;
  `planet.shipclass_orbital_station` is the **fleet** id of the planet's orbital station (a mining or
  research station), whose owner is in `country.fleets_manager.owned_fleets` (the save writes no
  owner on fleets or ships; `world.fleet_owner`).
- **Rule** **[I]**: an orbital deposit (its definition has `station = shipclass_mining_station` or
  `_research_station`) produces for the owner of the planet's station; the others for the owner of
  the colony they are on. Scale 1. Node: the planet's (`Planet`, owned by the planet id). All 46
  `orbital_mining_deposits`, 37 `orbital_research_deposits` and 2 `deposit_blockers_natural`
  entries match.

## Starbases

- **Classes**: `CEconomicUnit<CStandardEconomicUnit<CStarbaseModule, CStarbase, ...>>::CalcTable<1>`
  (`0xa2ce70`) and `<2>` (`0x8ca900`), the same functions for `CStarbaseBuilding`.
- **Save fields**: `starbase_mgr = { starbases = { <id> = { level modules = { 0 = shipyard 1 = ... }
  buildings = { 0 = crew_quarters } station = <ship id> orbitals ... } } }`; the owner is the
  station ship's fleet's.
- **Tables**: `common/starbase_modules` and `common/starbase_buildings` (`category =
  starbase_modules`, `starbase_buildings`). Scale 1, the starbase's node (`Starbase`), scope the
  starbase **[I]** (30 of 30 and 18 of 18 entries).
- **The station itself is a ship**: the level (`common/starbase_levels`: `ship_size =
  starbase_starport`) is a ship size whose table has `category = starbases`; it is paid with the
  ships, below.

## Ships

- **Classes**:
  - `CShip::CalcUpkeep` (`0xcb8e50`) **[V]**: builds the ship's upkeep context, a flag byte (a fleet
    flag, `CFleet::IsFederationFleet` 2, `CFleet::IsGalacticCommunityFleet` 16, `CFleet::IsDocked`
    4), the logistics multiplier (`CFleet::CalcLogisticsMult`, `0xc83f50`) and the owner's
    `CCountry::CalcNavyCapacityExceededMult` (`0x748ea0`), then calls the inner `CShip::CalcUpkeep`
    (`0xcb8fa0`);
  - `CShip::ApplySpecialUpkeepModifiers` (`0xc9dd20`) **[V]**: the ship's upkeep factor, starting
    at 1.0: `+ ship_orbit_upkeep_mult` (modifier type 83) of the ship's node when the context is
    docked; `+ space_fauna_ship_upkeep_mult` (type 537) when a flag of the ship size is set; times
    the navy-capacity multiplier when the context's state byte is 0 or 11; times
    `NDefines.NEconomy.SPACE_FAUNA_PREFERRED_PLANET_ORBIT_UPKEEP_MULT` (0.5) when
    `NShipUtil::IsSpaceFaunaOrbitingPreferredHabitat`;
  - `CCountry::CalcNavyCapacityExceededMult` (`0x748ea0`) **[V]**: the country's used naval
    capacity (`CCountry +12128`) against `CCountry::CalcNavalCapacity` (`0x73cf50`): used / capacity
    when over it (fixed point), else 1.0;
  - `CFleet::IsDocked` (`0xc83ea0`) **[V]**: in orbit (`CFleetMovementManager::IsInOrbit`), a fleet
    state byte (`+1660`) equal to 2, and `ship_orbit_upkeep_mult` present in the fleet's node;
  - `CShip::CalcProductionUpkeepData` (`0x165fd30`), `CShip::CalcLogisticFleetUpkeep` (`0xcb9210`),
    `CShipGrowthStageEconomicUnit::CalcUpkeep` (`0xd6acd0`), the hull's table
    `CEconomicUnit<CLocalObjectEconomicUnit<CShipSize, CShipGrowthStage>>::CalcTable<2>` (`0x8c7e90`),
    `CEconomicUnitCollection<CShipGrowthStageEconomicUnit>::CalcResource<2>` (`0x772510`, also
    what the UI's design upkeep calls), `CShipGrowthStage::CalcNavalCapUsage` (`0xd6cd40`).
- **Save fields**: `ships = { <id> = { fleet ship_design_implementation = { design growth_stage }
  section = { ... } } }`; `ship_design = { <id> = { growth_stages = { { ship_size section = {
  template slot component = { slot template } ... } required_component = "x" ... } } } }`; `fleet = {
  <id> = { ship_class movement_manager = { orbit = { orbitable = { starbase = n | planet = n } } } } }`;
  `country.used_naval_capacity`.
- **Tables**: the ship size's (`common/ship_sizes`: `category = ships`, `starbases`,
  `station_gatherers`, `station_researchers`, ...), and each component's (`common/component_templates`,
  `category = ship_components`; the templates are repeated `*_component_template = { key = "X" ... }`
  blocks, indexed by `key`), the section components and the `required_component`s of the ship's
  growth stage. A size with `components_add_to_cost = no` (science, construction and colony ships,
  stations, starbases) pays no component upkeep **[I]**: the player's corvettes pay 1.1088 energy of
  components and its science and construction ships nothing.
- **Scale** 1, times the factor above. **Node**: the ship's (`Ship`) **[I]**.
- **What fits the save** **[I]**:
  - docked: a mobile ship of a fleet in orbit of its owner's starbase (or of a planet of its owner
    or in a system it holds) pays `(1 + ship_orbit_upkeep_mult)` (the crew quarters' -0.25 and the
    country's -0.05: 0.7 for the player's ships); stations and starbases do not (their nodes have
    the value, their upkeep has no factor). Fleets in orbit of others' planets (the crystals) are not
    docked;
  - over capacity: military ships (`class = shipclass_military`) pay `used / capacity` with the
    capacity `(NAVAL_CAPACITY_BASE + country_naval_cap_add) * (1 + country_naval_cap_mult)`
    (`NDefines.NCountry.NAVAL_CAPACITY_BASE` = 50): exact for the tiyanki (620 / 50 = 12.4), amoebas
    (11.2, 18.6), crystals (51.4) and caravaneers (4.5);
  - space fauna components (`BIO_AUTO_REPAIR`, ...) take their upkeep from the script value
    `component_dynamic_cost`, whose `complex_trigger_modifier = { trigger =
    ship_size_cost_resource_percent parameters = { resource } mode = mult }` is the share of the
    resource in the hull's cost (a whale's cost is all food: food 1.0, minerals 0);
    `is_design_space_fauna` reads the size's `is_space_fauna_ship = yes`.
- **Not modelled**: the `logistics` table (trade paid by fleets: `LOGISTIC_FLEET_UPKEEP_DOCKED_MULT`
  0, `_FRIENDLY_SPACE_MULT` 0.5, `_NEUTRAL_SPACE_MULT` 1, `_HOSTILE_SPACE_MULT` 2, the galaxy
  setting `LOGISTICS_FLEET_UPKEEP_*`); federation and galactic community fleets.
- **Open**: the tiyanki garrison pays 0.796 of what the rule gives (its usage at the budget was
  lower than the save's?); the marauders' components 1.315 times more while their hulls match; two
  empires' corvettes: country 6's pay 0.75 of their hull where the rule gives 0.70, and country
  16777223's (a federation's leader) 0.77 of what the rule gives.

## Armies

- **Classes**: `CEconomicUnitBase<CArmy>::CalcUpkeep` (`0x1185430`); the recruiting cost
  `CEconomicUnit<CStandardEconomicUnit<CArmyType, CColony, ...>>::CalcTable<0>` (`0x434740`).
- **Save fields**: `army = { <id> = { type owner ship leader ... } }`.
- **Table**: the army type's (`common/armies`, `category = armies`); defense armies can produce
  unity (`has_active_tradition = tr_unyielding_resistance_is_frugal`; the active traditions are the
  save's `country.traditions`). Scale 1, the army's node (`Army`), scope the army **[I]** (10 of 11).

## Diplomacy

- **Classes**: `CDiplomacyCountryModule::UpdateEconomicResources` (`0x69ff90`),
  `CDiplomacyEconomicUnitCollection::ReadMember` (`0x7c3a60`), `CDiplomacyEconomicUnit::ReadMember`
  (`0x7c3de0`), `CDiplomacyEconomicAppliedUnit` (`0x7c3cb0`), its tables
  `CEconomicUnit<CStandardEconomicUnit<CDiplomacyEconomicAppliedUnit, CCountry, ...>>::CalcTable<1>`
  (`0x9cf9f0`) and `<2>` (`0x9d0470`); `CRelation::HasCommercialPact` (`0x66b270`).
- **Definitions**: `common/diplomacy_economy`: `once = { federation = { trigger resources } }` per
  country, and `per_relation = { rivalry non_aggression_pact migration_pact research_agreement
  commercial_pact defensive_pact guarantee improving_relations harming_relations
  diplo_stance_closed_borders embassy ... }` per relation, `this` the country and `from` the other.
  The same name can repeat (`migration_pact` four times).
- **Save fields** **[I]**: `country.relations_manager = { relation = { owner country is_rival
  commercial_pact research_agreement migration_access embassy closed_borders alliance ... } }` (flags
  written `= yes` when set); `federation = { <id> = { members = { ... } federation_progression = {
  laws perks } leader } }`; envoys: a leader's `location = { type = empire assignment =
  improve_relations | harm_relations id = <country> }`; `country.policy_flags` (`diplo_stance_*`).
- **Node**: the country's. All federation, migration, research, envoy and rivalry entries match
  (with `diplomacy_upkeep_mult` -0.5 and `diplomacy_influence_upkeep_mult` -0.25: 0.25 * 0.25 =
  0.0625 influence per envoy).
- **Commercial pacts' trade income** is not in these files. `NDefines.NEconomy.COMMERCIAL_PACTS_INCOME_PERCENTAGE`
  = 0.1, "the amount of trade production that is being added to the pact partner's economy". The
  save's three pact countries fit `0.1657 * the partners' trade` (their trade income without the
  pacts and the trade policy) to 4 digits; the 1.657 is not explained, so it is not modelled. The
  pact effects shown in the diplomacy window are built by `GetCommercialPactEffects` (`0x9a7b90`,
  UI text only).

## Planetary deficits

- `NDefines.NEconomy.COLONY_DEFICIT_ECONOMIC_CATEGORY` = `planet_resource_deficit`; the galaxy
  setting `LOGISTICS_PLANET_DEFICIT_*` ("the trade cost to supply colonies with local deficits",
  `CGameSetupGalaxyLogisticsPlanetDeficitPicker`). The code that pays it was not found (the define's
  string is read only by its `ReadDefine`; the category is resolved at load).
- **Rule** **[I]**: each colony's local deficit of a resource (what its own units use beyond what
  they produce: jobs, buildings, districts, zones, pop groups) costs trade, times the resource's
  `deficit_trade_conversion_mult` (`common/strategic_resources`: 0.125 basic resources, 0.25
  consumer goods, 0.5 alloys, 1.25 rare resources, 2.5 strategic ones; trade has none and costs
  nothing). The capital's deficit is first covered by the country's `country_base` income of the
  resource. Exact for the primitives (2.4 energy short: 0.3 trade; 2 energy and 2.55 food: 0.56875)
  and for a fallen empire (the capital's energy deficit covered by its 1,000 base energy, the
  second colony's 128.24 paid: 16.03).
- **The colony snapshot**: `colony = { <id> = { produces upkeep profits ... } }`, the colony's
  tables of the month (`NColonyUpdate::MonthlyParallelUpdate`, `0xe3ac40`). The deficits follow it:
  they see the pop groups before the month's resettlement, while the budget's pop group entries see
  them after it (below).
- **Open**: the remaining entries are 0.1 to 3% off, following small differences in the colonies'
  jobs (the capture's moment).

## The trade policy

- `NDefines.NEconomy.TRADE_POLICY_ECONOMIC_CATEGORY` = `trade_policy`; the effect
  `set_trade_conversions` (`CSetTradeConversions::ExecuteActual`, `0x17bb0d0`) sets
  `country.trade_conversions = { energy = 0.5 trade = 0.5 }` (the policy's rates).
- **Rule** **[I]**: the month's net trade (trade income minus trade expenses in every category but
  `trade_policy`, the planetary deficits included), when positive, is an expense of
  `trade_policy` and an income of `net * rate` of each converted resource. The player: 73.07879
  trade from its colony, 0.89146 of deficits, 72.18733 spent, 36.09366 energy and 36.09366 trade
  back. 41 of 50 entries match; the others are the three pact countries.

## Not modelled: the other units

The PDB has economic units for astral rifts, branch offices (`CBranchOfficeEconomicUnit`),
espionage operations, exhibits (specimens), extraterritorial buildings, fleet and observation
missions, megastructures (`CMegaStructure::UpdateEconomicResources` `0xd81fd0`, overclocks), the
overlord's share of pops (`COverlordPopResourceEconomicUnit`, jobs' `overlord_resources`), planets
(`CPlanet::UpdateEconomicResources` `0xe05e50`), pop factions, sectors, situations, specialist
subject conversions, edicts, relics, crisis perks, patrons' accords, terraforming, space fauna
culling. None of them has a budget entry in the 2210.01.01 save except one country's edicts.

## The save's moment

The budget of a save is computed in `MonthlyUpdate` before the month's pop growth; the save holds
the state after it. To check a budget against a save (`economy.check` sets
`economy.before_growth`) **[I]**:

- a pop group's size for the budget is `size` minus the month's `GROWTH_CAT_GROWTH` and
  `GROWTH_CAT_PROMOTION` (`last_month_growth_details`); resettlement (`GROWTH_CAT_RESETTLE`) happened
  before the budget. For the colonies' own tables (the deficits) the whole `last_month_growth` is
  taken out;
- a job with room (`max_workforce = -1`: civilians, peasants, unemployment; or `workforce` under
  its max) took its pop groups' growth: its scale is scaled back by `(amount - growth) / amount`, a
  pop group's growth counted once;
- countries created after the budget (the two factions of 2210.01.01) have empty budgets;
- the capture of the modifier nodes is of the loaded save, not of the budget's moment: one
  empire's jobs are uniformly 1.5% lower in the save, another's technicians 3.8% higher.

`economy.monthly()` (in the tick) computes from the world as it is, adds each balance to the
stockpile within 0 and its cap, and keeps the budgets as `economy.last_month`.

## What the tables ask of the script layer

`sim/lua/engine/economy/script.lua` installs, only while the economy evaluates, what the vanilla
tables need and the script layer (`simscript/eval.lua`, `engine/interface.lua`) does not answer
yet: the owner and planet of a pop group (its `planet` is a colony id), a planet's owner when it is
country 0, `colony` of a planet, `species`, `owner_species`, `federation`; `has_trait`,
`is_enslaved`, `is_being_purged`, `is_sapient`, `is_robot_pop_group`, `is_robotic`,
`is_archetype`, `is_pop_category`, `is_unemployed`, `has_living_standard`,
`has_citizenship_type`; `is_ruler`, `is_heir`, `is_councilor`; `has_ethic` and `is_gestalt` (the
save's `ethos = { ethics = { ... } }`), `has_policy_flag` (taken by eval for a script flag),
`has_active_tradition`; `has_climate`, `is_ringworld`, `has_active_building`, `num_zones = { type
value }`; `has_starbase_building`, `is_scope_valid`, `is_scope_type`, `is_space_fauna`,
`has_component`; the relation triggers (`has_rival`, `has_commercial_pact`, ...,
`is_improving_relations_with`), `has_federation`, `has_federation_perk`, `has_federation_law`;
`trigger:` values (`has_base_skill`, `has_total_skill`, `num_ascension_perks`,
`num_owned_planets`); script values called with a caller's `@variable` (resolved in the caller's
file) and the `complex_trigger_modifier` op.
