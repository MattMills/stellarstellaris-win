# Modifier node sources: what each node adds itself (4.5.2)

What a Country, Planet, Colony or PopGroup modifier node holds **from its own sources** (the parts of
`CModifier::_Added` that are not a parent's clone), where each comes from in the save and the
vanilla files, and its condition or scale. The node machinery (categories, `AddModifierNode`,
invalidation) is in [modifiers.md](modifiers.md); this page is the per-source detail under
"Computing a node".

Addresses are GOG 4.5.2 RVAs, read with `/root/fnm_tmp/annotate.py` on hippo. **[V]** marks what was
read in the disassembly or in a function's call list (the address is given); **[I]** what is
inferred from names, the script files, or by matching the 2210 capture
(`modifier-nodes-2210.tsv`: every node's parts) against the `autosave_2210.01.01` save and the
vanilla files. A source marked [I] here reproduced the captured parts: computing every listed
source and comparing node values (parents kept from the capture) gave, within 0.001: Country 97.3%,
Planet 97.5%, Colony 99.5%, PopGroup 98.8% of the captured values (country, planet, colony, pop
group nodes: 55, 6,080, 49, 171).

## Common rules

- **A part** is a whole value set added with a multiplier (fixed point, 1.0 = 100000, each entry
  truncated toward zero) and a category filter. Own parts carry the node's own filter
  (`_Categories`): Country `1354747902`, Planet `1074432514`, Colony `1074430466`, PopGroup `688130`
  in every own part of the capture **[I]**. A type passes when its `ModifierCategory` meets the
  filter, so a source's entries of other categories vanish in that node.
- **Several objects of a kind are summed into one part** before they are added: a species' traits,
  a planet's deposits, its buildings, districts, zones and worked jobs each arrive as one part, not
  one per object **[I]**. `CTraitSet::CalculateModifier` (`0x3dae00`) **[V]** clears a cached
  `CModifier` and adds each trait into it (`AddModifierInternal`); the colony keeps similar caches
  for buildings, districts and zones (`CColony::UpdateTriggeredModifiersInternal` `0xddac40`:
  `UpdateCachedModifier<CBuildingType>`, `<CDistrictType>`, `CreateZoneValueArrays`) **[V]** (call
  list).
- **Triggered blocks** (`triggered_*_modifier = { potential = { } <entries> }`, entries sometimes in
  an inner `modifier = { }`) are evaluated in the owner's scope and added with multiplier 1 when the
  potential holds and **multiplier 0 when it does not** (the capture has 671 such zero parts on pop
  groups) **[I]**. Their `mult` is a number, or another modifier's current value on the object
  (`mult = modifier:pop_non_noxious_happiness`) or its planet (`planet.modifier:x`): a part scaled
  by another node value **[I]**. Evaluation: `CModifierWithTooltipData::AddTriggeredModifiers`
  (`0x372f60`), `CModifier::AddTriggeredModifiers<CTriggeredModifierBase<CStaticModifier>>` **[V]**
  (call lists of the callers below).
- **Inline scripts** at the top level of a definition (a trait's `inline_script =
  traits/psionic_effects`, a pop category's `pop_categories/social_classes_triggered_modifiers`, a
  district's `jobs/farmers_add`) are expanded before its modifier blocks are read **[I]**.
- **A key that is not a modifier type but names a static modifier** adds that static modifier's
  entries times the value: `researcher_jobs_bonus_workforce_mult = 0.1` adds the twelve
  `pop_*_bonus_workforce_mult` of `common/static_modifiers/24_static_modifiers_jobs.txt` at 0.1 each
  (likewise `worker_and_simple_drone_cat_...`, `trader_jobs_...`, `influential_jobs_...`) **[I]**.
  These are the "keys in `common/static_modifiers` that are not types" of the open points in
  modifiers.md: they are groups, not invalid modifiers.
- **Values**: script numbers to fixed point rounded half away from zero; `@variables` from the
  file, then `common/scripted_variables`; type names case-insensitive **[I]**.

## Save fields (4.5.2 saves)

- `pop_groups.<id>.planet` is the pop group's **colony** id (the `colony` store), not a planet id;
  a planet points at its colony with `planets.planet.<id>.colony`, and `colony.<id>.pop_groups` lists
  the groups **[I]**. Country `capital` likely refers to a colony too (country 0 has `capital=0`,
  colony 0's planet is 5, and planet 0 is a star) **[I]**.
- Colony: `pop_jobs`, `districts` (each `{ type level zones }`), `buildings_cache` (ids in the
  `buildings` store, `{ type position }`), `governor`, `final_designation`, and the status inputs
  `stability`, `amenities`, `amenities_usage`, `total_housing`, `housing_usage`, `unemploy_pop`.
- Pop job: `type`, `workforce`, `bonus_workforce`, `workforce_limit`, `max_workforce`, `pop_groups`.
- Sector: `systems`, `local_capital` (a colony id) **[I]**.
- Species rights: `country.modules.standard_species_rights_module` with `species_rights = { {
  species_index living_standard citizenship slavery purge population_control ... } }`, `primary`
  (the founder species) and `default` **[I]**.

## Country (`CCountry::CalculateModifier` `0x7091f0`)

Call list **[V]**: `AddStaticModifier<...>` (cached sets), `CTimedModifierCollection::CollectModifier`,
`CTraitSet::ApplyTriggeredModifier`, `CSituation::AddCountryModifiers`,
`CColony::ApplyBuildingUntriggeredModifiersToCountry`, `CColony::ApplyZonesUntriggeredModifiersToCountry`,
`CPopJob::CalcAmountMultiplier`, `CPopGroup::CalcAmountMultiplier`,
`CFederationProgression::ApplyUntriggeredCountryFederationModifiers`,
`CCountry::ApplyDifficultyAdjustedAIModifier`, `CLeader::CalculateGalComModifier`,
`CalculateAgreementModifiersForCountry`, `AddWaystationNetworkCountryModifiers`, `AddModifierNode`.
Related: `CEthic::AddTriggeredCountryModifiers` `0x459210`, `CEdict::AddTriggeredCountryModifiers`
`0x4aa400`, `CGovernmentCouncilorType::AddTriggeredModifiers` `0x535ec0` **[V]** (names).

| source | from | block | scale / condition |
|---|---|---|---|
| technologies | `tech_status` (`technology` / `level` pairs) | `common/technology` `modifier` | multiplier = level x 1.0 (repeatables) **[I]** |
| traditions, ascension perks | `traditions`, `ascension_perks` | `modifier` | **[I]** |
| government, civics, origin | `government.type`, `.civics`, `.origin` | `modifier` | **[I]** |
| authority | `government.authority` | `country_modifier` | **[I]** |
| ethics | `ethos.ethics` | `country_modifier` | **[I]** |
| council agenda in progress | `government.council_agenda` | `common/council_agendas` `modifier` | while in progress **[I]** |
| policies | `active_policies` `{ policy selected }` | the selected `option`'s `modifier` | **[I]** |
| edicts | `edicts` `{ edict }` | `modifier` | **[I]** |
| triggered blocks of the above | the same definitions | `triggered_modifier`, `triggered_country_modifier` | potential in country scope **[I]** |
| timed modifiers | `timed_modifier.items` `{ modifier days }` | `common/static_modifiers` | **[I]** |
| country type | `type` | `common/country_types` `modifier` | **[I]** |
| council positions | top-level `council_positions` `{ country type leader }`; the ruler when no `councilor_ruler_*` position | `common/governments/councilors` `modifier` (`councilor_ruler_<authority>` for the ruler) | multiplier = skill = leader `level` + `bonus_skill_level` + the country's `councilor_skill_add` **[I]**; plus the position's `triggered_country_modifier` |
| councilor and ruler traits | the leader's `traits` | `common/traits` `councilor_modifier`, `triggered_councilor_modifier` (leader scope) | **[I]** |
| engine statics | | `empire_base` (all), `playable_ai_empire` (AI `default` countries), `fallen_empire_base` | **[I]** |
| naval capacity exceeded | `navy_coverage` < 1 | `navy_coverage_shortage` | multiplier 1 - navy_coverage **[I]** |
| federation | federation `members` (the leader too) | `federation_tax` | **[I]** |

Not attributed yet (about 3% of country values): colony and starbase contributions to
`country_naval_cap_add` and `country_edict_fund_add` (the `Apply...ToCountry` calls above, scaled by
job and pop amounts), fallen empires' `ship_*_mult` parts, a few `planet_jobs_produces_mult` and
`country_ruler_influence_produces_add` parts.

## Planet (`CPlanet::CalculateModifier` `0xe02880`)

Call list **[V]**: `CColonyCarrier::CalculateModifier` (`0xcca630`: statics scaled by
`CColonyCarrier::CalcDevastationScale`), `CTimedModifierCollection::CollectModifier`,
`CPlanet::CalculateModifiersFromSystem`, `CPlanet::CalculateModifiersFromLeaders`,
`CSituation::AddTargetModifiers`, **`CColony::AddCarrierModifiers`** (`0xdcb180`: the colony's
contributions; it calls `CColony::CalculateModifiersFromLeaders`, `CPopJob::CalcAmountMultiplier`,
`CPopGroup::CalcAmountMultiplier`, `AddModifierValueOnly`), `AddModifierNode`, then
`CPlanet::UpdateEconomicResources`. The colony's triggered sets are computed beforehand by
`CColony::CalculatePopTriggeredModifiersForAll` (`0xdc2e70`: `CBuilding::CalcTriggeredModifier`,
the districts, `CDeposit::CalcTriggeredModifier`, `CColony::CalcDesignationTriggeredModifiers`,
`CColony::CalcDoubleScaledTriggeredModifiers`, `CPopJob::CalcTriggeredModifier`) **[V]** (call list).
So buildings, districts, zones and jobs are parts of the **Planet** node, not the Colony node.

| source | from | block | scale / condition |
|---|---|---|---|
| planet class | `planet_class` | `common/planet_classes` `modifier` | **[I]** |
| timed modifiers | `timed_modifier.items` | static modifiers | the random planet modifier (`planet_modifier = pm_x`) arrives this way as a permanent item; `pm_x` itself adds nothing **[I]** |
| deposits | `deposits` (ids in `deposit`) | `common/deposits` `planet_modifier` | one part, summed **[I]** |
| designation | colony `final_designation` | `common/colony_types` `planet_modifier` (+ `triggered_planet_modifier`) | **[I]** |
| buildings | colony `buildings_cache` | `common/buildings` `planet_modifier` | one part, summed; their active `triggered_planet_modifier`s (the building's jobs) a second part **[I]** |
| districts | colony `districts` `{ type level }` | `common/districts` `planet_modifier` + active `triggered_planet_modifier` (the jobs inline scripts) | one part, each district times its `level` **[I]** |
| zones | the districts' `zones` (ids in `zones`) | `common/zones` `planet_modifier` x1 and `triggered_planet_modifier` x1; `triggered_district_planet_modifier` x the district's level | one part **[I]** |
| worked jobs | colony `pop_jobs` with `workforce` > 0 | `common/pop_jobs` `planet_modifier` + active `triggered_planet_modifier` | one part, each job times (`workforce` + `bonus_workforce`) / 100 (`CPopJob::CalcAmountMultiplier` `0x836470`) **[I]** |
| governor | colony `governor`; without one, the governor of the sector's `local_capital` colony | static `skill_<leader class>_planet_governor` | multiplier = skill level; half for the sector's governor **[I]** |

Not attributed yet: the spiritualist fallen empire's acolyte jobs and primitives' jobs (their
triggers), an unidentified `planet_amenities_add` +400 / +600 part on capitals.

## Colony (folded function at `0xdac090`)

The Colony node's calculate function has a hash name (identical-code folding) **[V]**: it calls
`CColony::IsColony`, `CColony::IsUnderColonization`, `CStaticModifierDatabase::GetStaticModifier`,
`AddStaticModifier`, `CColony::GetStabilityEffectScale` (`0xdb4800`),
`CColony::GetAmenitiesEffectScale` (`0xdb25c0`), `CColony::GetHousingEffectScale` (`0xdb21e0`),
`CColony::CalcVacantWorkspaces` (`0xdda210`), and `0xdab7d0` (its parents: `AddModifierNode`, the
waystation networks). Its own parts are the colony's **status** static modifiers, each scaled by how
far the colony is past a threshold:

| static (gestalt owners use the `_no_happiness_` ones) | scale | |
|---|---|---|
| `planet_stability_high` / `_low` | stability `s`: above `BASE_PLANET_STABILITY` (50): (s - 50) / (`MAX_PLANET_STABILITY` - 50), 1 at or past the max; below: (50 - s) / 50, 1 at s <= 0 | **[V]** (`0xdb4800`) |
| `planet_amenities_high` / `_low` | r = amenities / amenities_usage: (r - 1) / (`MAX_PLANET_AMENITIES` - 1), at most 1; low presumably (1 - r) / (1 - `MIN_PLANET_AMENITIES`) (the one low case in the capture was not matched) | defines read in `0xdb25c0` **[V]**, the formula **[I]** |
| `planet_housing_high` / `_low` | r = total_housing / housing_usage: (r - 1) / (`MAX_PLANET_RELATIVE_HOUSING` - 1) = (r - 1) / 3; low: (1 - r) / (1 - `MIN_PLANET_RELATIVE_HOUSING`) = (1 - r) / 0.5 | define read in `0xdb21e0` **[V]**, the formula **[I]** |
| `planet_overcrowded` | housing < usage | **[I]** |
| `planet_employment_low` | x the unemployed pops: `unemploy_pop` / 100, whole | **[I]** |
| `planet_employment_high` | x the vacant workforce: the sum over the colony's jobs of `workforce_limit` - `workforce` (`CalcVacantWorkspaces`) | **[I]** |

Defines in `common/defines/00_defines.txt`: stability 0 / 50 / 100, amenities 0.25 / 2.0, relative
housing 0.5 / 4.0. The capture's multipliers match the save's fields to its 5 decimals (e.g. colony
0: stability 63.2456 gives 26491).

## PopGroup (folded function at `0x67af60`)

The calculate function (hash name) **[V]**: `AddStaticModifier`, `AddModifierInternal`,
`CTimedModifierCollection::CollectModifier`, `CPopJob::CalcAmountMultiplier`,
`CPopGroup::CalcAmountMultiplier`, `NPopUtil::GetPopRatio`, `SAutoModTraitData::CalcEfficiency`,
`AddModifierNode` (the colony; the country with a Habitability filter). The cached triggered set is
built by `CPopGroup::UpdateTriggeredModifiers` (`0x679290`): `CTraitSet::ApplyTriggeredPopGroupModifiers`,
`CModifier::AddTriggeredModifiers`, `CSpeciesRightsModule::GetSpeciesRights`,
`CSpeciesRightBase::ApplyPopGroupModifiers`, `CPopGroup::GetPurgeType`, `GetSlaveryType` **[V]**
(call list).

| source | from | block | scale / condition |
|---|---|---|---|
| pop category | `key.category` | `common/pop_categories` `pop_group_modifier`, `triggered_pop_group_modifier` (pop group scope; many with `mult = modifier:x`) | **[I]** |
| species traits | `key.species` -> `species_db.<id>.traits` | `common/traits` `modifier` | one part, the trait set's cached sum (`CTraitSet::CalculateModifier`) **[V]**/**[I]**; then each trait's `triggered_pop_group_modifier` (e.g. aquatic on an ocean planet) as parts of their own **[I]** |
| species rights | the owner's species rights module (entry for the species, else `primary`, else `default`) | `common/species_rights/living_standards`, `citizenship_types`, `slavery_types` (when citizenship is slavery), `purge_types` (when purge), `population_controls`: `pop_group_modifier` + `triggered_pop_group_modifier` | none for a fallen empire's pops; none for primitives (no module) **[I]** |
| low habitability | `habitability` < 1 | static `pop_low_habitability` | multiplier 1 - habitability **[I]** |
| killed groups | `killed = yes` | | no own parts **[I]** |

Not attributed yet: primitives' pops (triggered blocks of
`pop_categories/social_classes_triggered_modifiers_no_happiness`), clone-vat
`bonus_pop_growth` (`triggered_planet_pop_group_modifier_for_species` of the building, scaled).

## Open points

- The Colony and PopGroup calculate functions have folded (hash) names: confirm `0xdac090` and
  `0x67af60` as `_CalculateFunction` of their nodes at runtime (or from the node constructors).
- The amenities and housing scale formulas: read the rest of `0xdb25c0` and `0xdb21e0` (the
  capture fits the formulas above).
- Where the country's technology, tradition, civic, ... sets are cached before
  `AddStaticModifier<CModifier &>` adds them (one part per source in the capture).
- The governor's skill: level + bonus levels matched; whether leader skill modifiers
  (`leader_skill_levels`) add to it was not tested.
