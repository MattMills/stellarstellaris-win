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
| `sim/lua/simscript/handlers/empire.lua` | The helpers (scopes to countries, species, pop groups, leaders; the species rights entries; trait definitions), the lists of the empire's iterators and its scope links. It loads the files below. The iterators over its lists are the walker's, `weights` and `inverse` included. |
| `sim/lua/simscript/handlers/empire_triggers.lua` | The triggers. Numeric ones are also values (`trigger:<name>`, `eval.TVAL`). |
| `sim/lua/simscript/handlers/empire_effects.lua` | The government, policies, the agenda, edicts, names, titles, flags, `kill_leader`. |
| `sim/lua/simscript/handlers/empire_pops.lua` | Pop group sizes, ethics (pop groups and countries), pop factions. |
| `sim/lua/simscript/handlers/empire_leaders.lua` | Leaders: age, skill, traits, flags, the pool, exiled and saved leaders, clones. |
| `sim/lua/simscript/handlers/empire_species.lua` | Species, the founder / built / dominant species, modification and merging, the species rights. |

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
  `can_change_policy` (POLICY_YEARS and `allow`), `can_set_policy` (the option's potential and
  `valid`), `last_changed_policy` (this session's, not saved), the agenda's progress and its percent, `has_agenda_selected`,
  `council_legitimacy` (the pop factions' support x approval), `get_councilor_level`, `is_ethic_represented_on_council`,
  `num_owned_leaders` (not the envoy classes), `empire_sprawl` and its cap (EMPIRE_SIZE_BASE and
  the admin cap modifiers), `opposing_ethics_divergence` (the most category_value steps),
  `has_extorted_faction`, `faction_approval`.
- **The galaxy:** the setup's `num_empires`, `num_fallen_empires`, `num_marauder_empires`,
  `fallen_empire_strength_scale`; the playable and fallen empires; the years since the galactic
  council was established (calendar years).
- **Flags:** `timed_flag_days_left` (engine.scriptstate's `{ flag_date flag_days }`).
- `name_list_category` is the empire creator's (a `dlc_recommendation` scope): false here.

## Effects

The addresses and what each effect writes are in its comment. RNG: "a global draw" is one
`CRandom::GetIntegerForMacro` (`eval.rand`); "the scope random" is the effect scope's
CCrudeRandom (`eval.scope_rng`). An on_action the engine fires costs two global draws (its two
event scopes) unless the comment says otherwise.

- **Pop group sizes** (`empire_pops.lua`): `add_pop_amount` / `remove_pop_amount` (one scope draw,
  made with `random = 0` too), `scale_pop_amount`, `transfer_pop_amount` (MoveSizeFrom),
  `displace_pop_amount` (the size unchanged: `local_pop_amount` and `on_pop_displaced`),
  `kill_assigned_pop_amount` / `sacrifice_assigned_pop_amount` (a job's workers;
  `on_pop_sacrificed`). The amount-or-percentage parameter is the game's SAmountOrPercent: the draw
  applies to the percentage, two scope positions. Sizes change through `engine.pops`'
  `add_size` (the growth details), an emptied group is killed.
- **Ethics** (`empire_pops.lua`): the pop group effects (`pop_change_ethic`, `pop_force_add_ethic`,
  `pop_remove_ethic`, `pop_force_remove_ethic`, `pop_force_transfer_ethic`, `clear_ethos`) are the
  stat operations ConvertPops, DeconvertPops and TransferPops with the largest-remainder resize;
  the country effects (`country_add_ethic`, `country_remove_ethic`, `shift_ethic` with its
  RemoveOrDowngradeEthics loop) end in OnEthosChanged (one global draw for the personality)
  [I: the pops' attraction shift_ethic scores by; the personality and government type not
  recomputed].
- **Factions** (`empire_pops.lua`): `set_pop_faction` (ConvertToFaction), `force_faction_evaluation`
  (`engine.ethics.force_faction`), `enable_faction_of_type` (a `potential` entry),
  `set_faction_extorted`, `set_faction_hostility`, `set_faction_properties` (the
  `faction.properties` bits).
- **The government** (`empire_effects.lua`): every change goes through SetGovernmentAndCivics
  (`on_pre_government_changed`, `on_post_government_changed`, `government_date`, the custom titles
  cleared, the election date's draw): `change_government` (a random authority and civics drawn
  among those whose `potential` / `possible` restrictions hold), `force_add_civic`,
  `force_remove_civic`, `force_remove_civic_by_index`, `set_origin`, `copy_ethos_and_authority`
  [I: the new ruler it makes not modelled]; `set_country_type` (`on_country_type_changed`),
  `set_government_cooldown`, `add_edict` (its cost, effect, `on_edict_activated`, the entry),
  policy cooldowns, the council's agenda (`init_effect`; progress; finishing: modifier, effect,
  cooldown, `on_agenda_finished`). `advanced_authority_refresh` writes nothing [I].
- **Names, titles, flags** (`empire_effects.lua`): `set_empire_name` and a country's `set_name`
  (SetCustomName: `name`, the `%ADJECTIVE%` adjective, `custom_name`), a leader's
  (`full_names`), the four ruler and heir titles (the country's), `set_ruler_title_male` /
  `_female` (the other gender's current title written too), the council positions' titles,
  `room_name_override`, `randomize_flag_symbol`, `set_empire_flag`. `set_name = random` is
  reported, not modelled.
- **Leaders** (`empire_leaders.lua`): age (`date`, `age`, `days_frozen`), LevelSkill (a LevelUp per
  point, `on_leader_level_up` each), `set_skill`, traits in the game's sorted order (random traits
  by one weighted global draw; `on_gained_effect`), timed traits (`timed_trait`), the background
  ethic, class, portrait, gender (the design dropped), `leader_flags` (immortal, age frozen,
  recruitable), cooldown, years served, `recruitable` (the pool, `on_added_to_leader_pool`),
  `unassign_leader`, exiled leaders (the top-level `saved_leaders`: `exile_leader_as`,
  `set_leader`, `return_leader_from_exile`, `kill_exiled_leader`), a country's saved leaders
  (`create_saved_leader`, `activate_saved_leader`, `remove_saved_leader`), `clone_leader`;
  `kill_leader` with its class and ability parameters (`empire_effects.lua`, replacing
  `eval.lua`'s). `refresh_leader_pool` is reported: the pool's generation is not modelled.
- **Species** (`empire_species.lua`): the homeworld, portrait, identity (`base_ref`),
  `change_species_characteristics`, `rename_species` (an entry or a list of
  `common/species_names`; `name = random` reported), `mutate_species` (its two draws and rules),
  `modify_species` (an identical species reused, else a new one), `change_species` per scope, the
  built, founder and dominant species (the rights copied), `merge_species`, the species rights
  (`last_changed_value` first; the `last_changed_*` dates are the cooldowns' ends).
  `integrate_species` and `modify_species`' `add_random_species_trait` are reported, not modelled;
  `refresh_species_rights` writes nothing [I].

## Left to other areas

The galactic community's council belongs to the diplomacy area:
`add_imperial_authority`, `add_permanent_councillor`, `remove_permanent_councillor`,
`add_to_galactic_council`, `remove_from_galactic_council`, `increase_council_size`,
`decrease_council_size`, `set_council_size`, `set_council_veto`, `set_council_emergency_measures`,
`set_emperor_can_change_council_members`, and the federation's `set_free_migration`.
