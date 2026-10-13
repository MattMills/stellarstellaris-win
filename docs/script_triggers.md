# Script triggers, iterators, links and effects read from the save

What `sim/lua/simscript/eval.lua` (TRIG, LISTS, LINKS, EFF) and `sim/lua/engine/interface.lua` (`E`)
answer for the keywords the 180-day run hit without an implementation, and where the game keeps
what each reads. Reverse engineered from the GOG 4.5.2 build and its PDB; addresses are GOG RVAs.
**[V]** marks what was read in the disassembly, **[I]** what is inferred (from the save, the script
files, the names, or by analogy).

How a keyword was tied to its class: the token id of the keyword (`tokens452.tsv`) is the `edx` of
the registration that stores a `CTriggerEntry<C...>` / `CEffectEntry<C...>` vtable
(`docs/script_engine.md`, "Entries"); `tmp_trig/trigclass.py` does it for a list of keywords.
Where a save field is named, it was found in the class's `WriteMembers` (the token written next to
the member's offset).

## `if` / `else_if` / `else` inside a trigger

`common/scripted_triggers/00_scripted_triggers_ai.txt` (`country_uses_food`,
`country_uses_consumer_goods`) writes an `if = { limit = { } } else = { }` chain inside an `OR`.
The script layer handled the chain only in an AND block (`eval.trigger`); `OR`, `NOT`/`NOR` and
`calc_true_if` evaluated each statement through `trigger1`, which knows no `if`, so both showed as
unimplemented and evaluated false. A gap of the evaluator, not of the parser.

- `CTriggerCollectionBase::ReadMember` chains an `else_if` / `else` onto the `if` before it with
  `CIfTrigger::AddElse` (`0x1993910`): it walks `_pElse` (`+0x180`) to the end and refuses a second
  `else` (token 18384) **[V]**. The chain is one trigger of its block, in any collection.
- `CIfTrigger::ActualEvaluate` (`0x1993380`): the limit (`+0xc0`, a `CAndTrigger`) holds -> the
  if's own children (`CAndTrigger::ActualEvaluate` on the if); else the `_pElse` object's
  evaluation (an `else_if` is another `CIfTrigger`, an `else` one whose limit is empty); no `_pElse`
  -> **true** **[V]**.
- So `OR = { if = { limit = { A } } else = { B } C }` is `(A or B) or C` when the if's body is empty
  (`A ? true : B`), and an `if` whose limit fails with no else counts as true, also in an OR.

`eval.lua`: `if_chain(b, i, ctx)` evaluates the chain at `b[i]` and returns its result and the
index after it; `holding(b, ctx, first_only, skip)` counts the statements of a block that hold
with a chain as one, used by `OR`, `NOT`/`NOR` and `calc_true_if`. AND blocks keep their own loop
(the same result).

## Scope context

- `prevprevprev`, `prevprevprevprev`: the context now keeps four `prev`s. Without them
  `is_same_value = prevprevprev` (action.85, "planets in mixed-ownership systems") never named a
  scope, so `NOR = { is_same_value = prevprevprev ... }` held for every planet once `starbase`
  existed. **[I]** (the game's links of that name, scopes.log)

## Scope links

| link | from | reads | marks |
|---|---|---|---|
| `overlord` | country | `overlord = <country>` (`CCountry +0x2630`, written by `CCountry::WriteMembers` `0x6e1390` when not -1); `CHasAnyOverlord` (`0x19b1df0`) reads it as a country ref | **[V]** |
| `federation` | country (a federation: itself) | `federation = <id>` (`CCountry +0x1c38`, the federation ref `CIsFederationLeaderTrigger` reads) | **[V]** |
| `starbase` | system, planet (its system's), starbase | the system's first `starbases` entry (the primary one, see `owned_nonprimary_starbase`) | **[I]** |
| `owner` / `controller` of a starbase, ship, fleet | | the fleet's owner (`world.fleet_owner`, from the countries' `fleets_manager.owned_fleets`); a starbase's: its `station` ship's fleet's | **[I]** |

`exists = overlord / starbase / federation` were unimplemented only because the links were.

## Diplomacy: relations

A country's relations are `relations_manager = { relation = { owner country ... } }`. The relation's
flags (`CRelation +0x120`, a bit field) are written by `CRelation::WriteMembers` (`0x669d30`) as
`<name> = yes` **[V]**:

| bit | written | bit | written |
|---|---|---|---|
| 0 | hostile | 12 | research_agreement |
| 1 | neutral | 13 | migration_access |
| 2 | friendly | 14 | is_rival |
| 3 | communications (written later in the block) | 16 | contact |
| 4 | borders | 18 | embassy |
| 5 | defensive_pact | 19, 20 | capitals_connected_through_relay_network(_before) |
| 6 | alliance | 21 | secret_fealty |
| 7 | subject | 22 | acquainted_with |
| 8 | guarantee | 23 | is_under_societal_enlightenment |
| 9 | support_independence | 24 | is_under_open_technological_enlightenment |
| 10 | non_aggression_pledge | 25 | is_under_stratified_technological_enlightenment |
| 11 | commercial_pact | 26, 27 | has_pre_ftl_trade, waystation_pact |

| keyword | class | semantics | marks |
|---|---|---|---|
| `is_under_societal_enlightenment = <c>` | `CIsUnderSocietalEnlightenmentTrigger` `0x1a13120` | the scope country's relation towards `<c>` (`CCountryRelationsManager::GetRelation` on the scope's diplomacy module), bit 23 | **[V]** |
| `is_under_open_technological_enlightenment = <c>` | `0x1a13440` | bit 24 (`byte +0x123 & 1`) | **[V]** |
| `is_under_stratified_technological_enlightenment = <c>` | `0x1a13760` | bit 25 | **[V]** |
| `has_pre_ftl_trade = <c>` | `CHasPreFtlTradeTrigger` `0x1a13a80` | bit 26 | **[V]** |
| `has_waystation_pact = <c>` | `CHasWaystationPactTrigger` `0x19a2740` -> `CRelation::HasWaystationPact(true)` `0x66bd00` | false for an invalid target; bit 27, or both countries in the same federation (`CCountry +0x1c38`) whose progression grants the pacts (`+0x80 -> +0x2c4`): the save's `federation_progression = { waystation_pact = yes }`, which `set_federation_settings` sets | **[V]** (the save field **[I]**) |
| `has_communications = <c>` | `CHasCommunicationsTrigger` `0x198d8c0` | bit 3 (`CCountry::GetRelationFlag`); false towards itself | **[V]** |
| `num_communications <op> n` | `CNumCommunicationsTrigger::GetTriggerValue` `0x198df10` | the country's relations (`CCountry +0x2b90`, `CRelation *`) whose other country (`+0xc`) exists, with bit 3 | **[V]** |
| `any_relation`, `count_relation` | `CRelationListBuilder::BuildIDArray` `0x1812e00` | every relation of the country whose other country exists (the relation's own validity check is the shared `return true`) | **[V]** |

The diplomacy_economy upkeeps (`common/diplomacy_economy`) are written `from = { has_pre_ftl_trade =
root }`: the relation of `from` towards `root`.

## Federations, subjects

| keyword | class | semantics | marks |
|---|---|---|---|
| `any_member` | `CFederationListMembersBuilder` | the federation's `members = { ... }` (from a country: its federation's) | **[I]** |
| `any_subject` | `CSubjectListBuilder` | `subjects = { ... }` (`CCountry +0x2670`, a `TPdxRef` array written by `CCountry::WriteMembers`) | **[V]** field, **[I]** list |
| `is_federation_leader = yes/no` | `CIsFederationLeaderTrigger` `0x1971120` | false when the country or its federation is invalid; else (federation `leader` (`+0x100`) == the country) == yes | **[V]** |
| `is_subject`, `is_overlord`, `has_federation` (property triggers) | | now derived from `overlord`, `subjects`, `federation` | **[I]** |

## The country's own data

| keyword | class | reads | marks |
|---|---|---|---|
| `has_menace_perk = <perk>` (and `has_crisis_perk`, the same class) | `CHasCrisisPerkTrigger` `0x1a1cab0` -> `CCountry::HasCrisisPerk` `0x72f020` | `CCountry +0x30e8` -> `CCrisisProgression`; its unlocked levels (`+0x18`, `CCrisisLevelType *`) and each level's `perks` (`+0x58`). Save: `crisis_progression = { path = "x" level = "crisis_level_1" ... objective = { } }` (`CCrisisProgression::WriteMembers` `0x569820`), the perks of each level in `common/crisis_levels` | **[V]** |
| `has_relic = <relic>` | `CHasRelicTrigger` `0x19b2990` | `CCountry +0x3030` array: `relics = { "r_x" ... }` | **[V]** |
| `has_active_focus = <card type>` | `CHasActiveFocusTrigger` `0x1a19860` | only a country scope; the focus card ids at `CCountry +0x3690` (`focus = { active = { ids } }`), each card (`focus_cards` store) skipped when its byte `+0x20` is set, else its type (`+0x18`) compared. The save's card has `type` and `status`; `status` is taken as that byte (0 = active, 1 = done) | **[V]** code, **[I]** `status` |
| `has_completed_special_project_in_log = <key>` | `CHasSpecialProjectStatusTrigger<CHasCompletedSpecialProjectImpl>` `0x19e5740` | the country's special projects (`CCountry +0x24d0`) of that key whose status (`+0x1c8`) is 2; `CSpecialProjectInstance::WriteMembers` `0x820450` writes status 0..3 as `available`, `in_progress`, `completed`, `failed`. Read from `events = { special_project = { special_project = "KEY" status = completed } }` | **[V]** code and enum, **[I]** that the log is the `events` list |
| `num_repeatable_techs <op> n` | `CNumRepeatableTechsTrigger::GetTriggerValue` `0x1990580` | the country's technologies (`+0x1640`, 40-byte entries): the sum of the levels (`+0x8`) of those whose definition's levels (`CTechnology +0x588`, unsigned) is > 1: `levels = -1` or more than one level. Save: `tech_status = { technology = "x" level = n ... }` | **[V]** |
| `has_built_species = yes/no` | `CHasBuiltSpecies` `0x19949c0` | (`CCountry +0x1598`, `built_species_ref`, names a species) == yes | **[V]** |
| `num_unique_species <op> n` | `CNumSpeciesTrigger<SExactNumSpeciesCounter>::GetTriggerValue` `0x19e5000` | a country: `CCountry::ListExactSpecies` `0x6f99c0`, the distinct species of the pop groups of its colonies (`+0x26c0`); a colony: `CColony::_ListSpecies`; other scopes 0 | **[V]** (a filter later in `ListExactSpecies` not read: **[I]** none) |
| `has_monthly_income = { resource = r value <op> x }` | `CHasMonthlyIncomeTrigger` `0x1992c90` | a per-resource array at `CCountry +0x2310`, compared with the value (the token of the op picks `= > < >= <= !=`). Taken as last month's net income: the budget's `last_month` income minus expenses (the trade tables included), or the simulation's last month once it ran one | **[V]** compare, **[I]** which array |
| `resource_income_compare`, `resource_expenses_compare = { resource value [category] }` | `CResourceCompareTrigger<SResourceIncomeCompare / SResourceExpensesCompare>` `0x19e3b70`; `GetResourceAmount` `0x19ae6e0` / `0x19ae780` | the income one reads the balance, income minus expenses (`+0x1f90`, `_Budget._CurrentMonth._Total._SummedBalance`; a category's with one), not the gross income: a food deficit situation's `monthly_progress` comes out as the game's (-1) only so; the expenses one reads the expenses (`+0x1f08`, `+0x1f70`); from `budget.current_month` | **[V]** shape and member, **[I]** page |
| `num_owned_colonies <op> n` | `CNumOwnedColoniesTrigger::GetTriggerValue` `0x1959a30` | a country: the count of its colonies array (`+0x26cc`), `owned_planets`; a sector: `+0x164` (not done) | **[V]** |
| `is_ai = yes/no` (property) | `CAiTrigger` `0x1949750` | (`CCountry +0x314c` == 0) == yes: no player controls it. Every country of the saves has `ai = { initialized = yes }`, the player's too: is_ai is now "not in the save's `player = { { country } }`" | **[V]** code, **[I]** field |
| `is_galactic_community_formed = yes/no` | `CIsGalacticCommunityFormedTrigger` `0x1a062f0` | the community's formation date (`+0x8`) is not the end of time; `CGalacticCommunity::WriteMembers` `0x622c50` writes it as `galactic_community = { community_formed = <date> }` only then | **[V]** |
| `days_passed <op> n` | `CDaysPassedTrigger::GetTriggerValue` `0x1959010` | (year - `START_YEAR`) * 360 + the day of the year: the days since 2200.01.01 (3600 on 2210.01.01) | **[V]** |
| `any_situation` | `CSituationListBuilder` | the situations (`situations = { situations = { id = { country = x ... } } }`) whose `country` is the scope | **[I]** |

## Colonies and planets

`NScriptUtil::GetColonyFromScope` (`0x9f4ad0`) gives the colony of a planet, a pop group or a colony.

| keyword | class | reads | marks |
|---|---|---|---|
| `has_branch_office = yes / no / <country>` | `CHasBranchOfficeTrigger` `0x19a0dc0`; `CColony::HasBranchOffice` `0xdcd9c0`, `GetBranchOfficeOwner` `0xdcd9f0` | invalid colony -> false. The colony's `externally_owned_buildings` (`CColony +0x70`, `SBuildingArrayData`, written by its serializer `0xda3e60` as `{ building_owner = c owner_type = normal / corporate / subject_holding / none buildings = { } }`): a branch office is an entry of type 1, `corporate`. yes / no: whether there is one; a country: the first corporate entry's owner | **[V]** |
| `has_district = yes / no / <type>` | `CHasDistrictTrigger` `0x196ed70` | invalid colony -> false; yes/no: (`CColony::CalcNumDistricts` `0xdc95b0`, the sum of the `level`s of the colony's `districts`) > 0; a type: `CColony::HasDistrict` `0xdc8010`, a district of the colony of that type, whatever its level | **[V]** |
| `num_zones <op> n`, `num_zones = { type = z value <op> n }` | `CNumZonesTrigger::GetTriggerValue` `0x196fed0` -> `CColony::CalcNumZonesOfType` `0xda8960` | the zones (not 4294967295) of the colony's districts, of the type or all. A country: the game loops over its colonies but **stores each count over the previous one**, so the value is the last colony's | **[V]** |
| `is_under_colonization = yes/no` | `CIsUnderColonizationTrigger` `0x1966c10` | invalid colony -> false (also for `no`); else (the colony's `colonizing_species` (`+0x48`) names a species) == yes | **[V]** |
| `uses_district_set = <set>` | `CPlanetDistrictSetTrigger` `0x1a09320` | the planet's (or colony's, or carrier's) class definition string at `+0x130`: `district_set` in `common/planet_classes`, empty when the class has none | **[V]** |
| `is_controlled_by = <country>` | `CIsControlledByTrigger` `0x194c0c0` | the carrier's controller (`NScriptUtil::GetCarrierFromScope`, virtual `+0x60`): a planet's `controller`; a fleet's owner (`+0x448`), a starbase's `CStarbase::GetController`, an astral rift's | **[V]** |
| `any_system_within_border` | `CSystemWithinBorderListBuilder::BuildIDArray` `0x1817430` | a country: its owned systems (`CCountry +0x2ea8`, not saved: here the systems whose starbase it owns, `world.system_owner`); a sector: its systems (`+0x140`) (not done) | **[V]** list, **[I]** the save's form |
| `any_planet_within_border` | `CPlanetWithinBorderListBuilder::BuildIDArray` `0x18148a0` | the planets of those systems | **[V]** |
| `any_system_planet` | | a system's `planet = <id>` entries | **[I]** |
| `any_owned_starbase` | `COwnedStarbaseListBuilder::BuildIDArray` `0x1816d50` | the starbases of the country's systems whose `CStarbase::GetOwner` is the country | **[V]** |
| `any_owned_nonprimary_starbase` | `COwnedNonprimaryStarbaseListBuilder::BuildIDArray` `0x1816ee0` | the same over another system list (`+0x2ed8`), without the primary ones (`CStarbase::IsPrimaryStarbase` `0x7dcb00`: the starbase its system holds as primary, here the first of the system's `starbases`) | **[V]** code, **[I]** primary = first |

## Species

| keyword | class | reads | marks |
|---|---|---|---|
| `has_slavery_type = { country = c type = t }` | `CHasSpeciesRightsTrigger<SHasSlaveryType>` `0x1a2a270` | as `has_citizenship_type`: the species rights the country (or the scope's owner) gives the scope's species, key `slavery` of the `standard_species_rights_module` entry | **[I]** by analogy |
| `is_being_integrated_by = <country>` | `CSpeciesBeingIntegratedTrigger` `0x1a27aa0` -> `CSpecies::CheckRightsBeingIntegrated` `0x3e6e30` | the country's species rights module is enabled (`+0x18`, `enabled = yes`) and the species' rights entry's type at `+0x50` (the ninth right, `subspecies_integration`) has its flag `+0x710` set: `integration = yes` in `common/species_rights/subspecies_integration_types` | **[V]** code, **[I]** that `+0x50` is subspecies_integration |

## merge_species

`merge_species = yes` (`CMergeSpeciesEffect::ExecuteActual` `0x17b9840`): only with `yes` (`+0xc0`)
and a country scope, `CCountry::HandleIdenticalSpeciesMerge` (`0x71a160`) **[V]**. For each species
A of the country's species list (`CCountry +0x3478`, taken as `owned_species_refs` **[I]**) that is
neither its founder species (`+0x1574`) nor its default species (`CCountry::GetDefaultSpecies`),
and each other species B of the list: both valid, the same base species (`CSpecies::GetBaseSpecies`),
the same name (`+0x190`, compared bytewise), the same traits in the same order (`+0x1b8`), and the
same rights in the country (`CSpeciesRightsCountryConfiguration::SameRightsAs`): A merges into B
**[V]**. The rest of the function re-keys the pop groups of the merged species in the country's
colonies, may move the founder species (`CCountry::SetFounderSpecies`) and sets a flag **[V]**
(calls), not read in detail.

The simulation finds the merges (`E.identical_species`: base species, name, traits in order, the
nine rights). No country of the 2210.01.01 save has one, so the effect does nothing there, which is
what the game does. When there is one it is pushed as an unmodelled engine effect: modelling it
needs the pop groups of the merged species re-keyed to the other species and joined with the groups
of the same key on each colony (sizes summed, the colony's `pop_groups` and `species_refs`
updated), and the founder species moved if it was merged.

## Not done here

- `num_owned_colonies` for a sector, `any_system_within_border` for a sector.
- Triggers the run reaches now that it did not before (behind the ones above): `has_megastructure`,
  `has_hyperlane_to`, `any_neighbor_system`, `is_capital_system`, `is_inside_nebula`,
  `has_special_project`, `num_rare_techs`.
- The AI budget's `used_naval_capacity_percent`, `num_uncleared_blockers`, `ai_colonize_plans`,
  `has_ai_expansion_plan`, `any_spynetwork`, `exploitable_planets`, `highest_threat`, and the
  planet's `has_deposit` (`CHasDepositTrigger` `0x1984910` has special deposit types for "any" and
  "none" that were not read).
