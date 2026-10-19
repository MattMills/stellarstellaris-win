# Script layer: the empire

The empire's script keywords: species and their traits, leaders, the council and its agendas,
policies and edicts, ethics, civics and the government, pop factions and pop groups. They are the
`empire` package of the script coverage work ([script_coverage.md](script_coverage.md)).

- **[V]**: read in the 4.5.2 Linux build's disassembly (`/opt/stellaris-headless/re`), its data,
  or a save.
- **[I]**: inferred, from the documentation, the save, the script files or the names.

## The files

| file | what it holds |
|---|---|
| `sim/lua/simscript/handlers/empire.lua` | The helpers (scopes to countries, species, pop groups, leaders; the species rights entries; trait definitions), the lists of the empire's iterators and its scope links. It loads the two files below. |
| `sim/lua/simscript/handlers/empire_triggers.lua` | The triggers. Numeric ones are also values (`trigger:<name>`, `eval.TVAL`). |
| `sim/lua/simscript/handlers/empire_effects.lua` | The effects, and the `random_` / `ordered_` iterators over the empire's lists with their `weights` and `inverse` (the walker's own iterator in `eval.lua` reads neither). |

The world is read and written through `engine.world`, the game's definitions through
`engine.defs`. The save keys each keyword reads or writes are in its comment.

## Lists and links

| keyword | what it is |
|---|---|
| `existing_species_traits` | every species trait (`common/traits` without `leader_class`), by key [I: the database's order] |
| `owned_pop_species` | the species of a country's pop groups with pops, each once |
| `pool_leader` | a country's recruitable leaders (`modules.standard_leader_module.leaders`) |
| `trait_of_species` | the traits of the scope's species |
| `trait_available_for_species` | the species traits the species has not, allowed for its archetype (`allowed_archetypes`) [I: the DLC lock not read] |
| `species` / `exact_species` | the species of the scope's pops by base species / each sub-species (`count_species`, `count_exact_species`) |
| link `heir` | the government's `heir` [I key] |
| link `built_species` | the country's `built_species_ref` |
| link `creator` | the leader's `creator` |
| link `pop_faction` | a pop group's first faction, the faction a leader leads |
| links `growing_species`, `assembling_species`, `declining_species` | the planet's pop group with the largest last month growth (organic, robotic) or decline [I: the colony's own growth fields are not in the save] |
| link `unhappiest_pop` | the scope's pop group with the lowest `happiness` |
| link `last_created_pop_faction` | the created faction's handle (`CREATED_KIND.pop_faction`) |

`leader`, `ruler`, `species`, `founder_species`, `owner_species`, `owner_main_species` and
`last_created_leader` were already in `eval.lua`. The checker reports them missing because the docs
mod's `<link> = { always = yes }` in `events/sdc_links.txt` runs as an effect, and `always` is not
an effect: the miss is the example's, after the link resolved.

## Triggers

Each trigger's comment in `empire_triggers.lua` names its class and what it reads. In brief:

- **Leaders:** `leader_age` (`age`), `has_experience` (`experience`), `has_total_skill` (`level` +
  `bonus_skill_level`), `leader_years_of_service` (years since `recruitment_date`), `leader_lifespan`,
  `gender`, `has_ruler_trait`, `is_idle` (no `location`, no `council_location` [I]),
  `num_candidate_supported` [I key], `num_leader_traits` (its filters).
- **Traits:** `num_positive_traits`, `num_negative_traits`, `num_trait_points` (a leader's own; a
  species', a pop group's species', a country's founder species' [I]), `count_species_traits`,
  `trait_has_all_tags`, `trait_has_any_tag` (a trait's `tags`).
- **Species:** `species_gender`, `uplift_is_archetype`, `species_has_happiness_with_owner`,
  `inherits_parent_rights`, `is_robot_pop` (the archetype's `robotic`), `is_default_species`
  (`default_species`, `built_species_ref`, the base).
- **Planets and pops:** `is_majority_species`, `nb_pop_exact_species`, `is_original_owner`
  (`original_owner`), `has_current_purge` (a group in the `purge` category), the last month's
  organic and artificial growth, `pop_ethics_divergence`, `happiness`, `pop_has_happiness`,
  `can_join_factions`, `member_of_faction`, the `former_*_type` rights, `last_changed_species_rights_type`
  (`last_changed_value`), `has_migration_control`, `pop_maintenance_cost` (the category's upkeep
  [I: without modifiers]), `pop_amount_percentage`, `pop_ethic_amount`, `pop_ethic_percentage`,
  `num_species`, `num_ethics`.
- **Countries:** `civics_count`, `has_total_civic_points`, `has_unused_civic_points`,
  `has_civic_in_slot`, `has_invalid_civic` (the civic's `possible` requirement lists),
  `can_change_policy` (POLICY_YEARS), `can_set_policy` (the group's and option's potential),
  `last_changed_policy` [I key], the agenda's progress and its percent, `has_agenda_selected`,
  `council_legitimacy` [I key], `get_councilor_level`, `is_ethic_represented_on_council`,
  `num_owned_leaders` (not the envoy classes), `empire_sprawl` and its cap (EMPIRE_SIZE_BASE and
  the admin cap modifiers), `opposing_ethics_divergence` [I: the steps' rule],
  `has_extorted_faction`, `faction_approval`.
- **The galaxy:** the setup's `num_empires`, `num_fallen_empires`, `num_marauder_empires`,
  `fallen_empire_strength_scale`; the regular and fallen empires; the years since the galactic
  council was established [I key].
- **Flags:** `timed_flag_days_left` (engine.scriptstate's `{ flag_date flag_days }`).
- `name_list_category` is the empire creator's (a `dlc_recommendation` scope): false here.

## Effects

- **Leaders:** age, skill (within 1 and LEADER_MAX_SKILL_CAP), traits (`random_common` /
  `random_negative` from the class's traits of that rarity, one draw [I]), timed traits
  [I key: `timed_traits`], the background ethic, class, portrait, gender, cooldown, years served,
  the council seat, the heir; `kill_leader` with its class and ability parameters (replacing
  `eval.lua`'s).
- **The government:** `force_add_civic`, `force_remove_civic` (a key or a 1-based index [I]),
  `set_origin`, `set_country_type`, `set_government_cooldown`, policy cooldowns, the council's
  agenda (`set_council_agenda`, its progress percent, `finish_council_agenda`: the finish modifier,
  the effect, the cooldown).
- **Species:** the built species, the homeworld, the portrait, `change_species` per scope, and the
  species rights (`set_living_standard`, `set_migration_controls`, `set_population_controls`,
  `set_purge_type`: the entry, its former value, `last_changed_value`, the lock date).
- **Names and titles:** `set_empire_name`, `set_name`, the ruler's and heir's titles,
  the council positions' titles [I keys], `clear_custom_ruler_and_heir_titles`.

## Left to other areas

The galactic community's council belongs to the diplomacy area:
`add_imperial_authority`, `add_permanent_councillor`, `remove_permanent_councillor`,
`add_to_galactic_council`, `remove_from_galactic_council`, `increase_council_size`,
`decrease_council_size`, `set_council_size`, `set_council_veto`, `set_council_emergency_measures`,
`set_emperor_can_change_council_members`, and the federation's `set_free_migration`.
