# Script keywords of no single window

`sim/lua/simscript/handlers/general.lua` and `general_systems.lua` hold the triggers, effects and scope links that belong to
no single window:
- the links of every scope;
- control flow and tooltip wrappers;
- the galaxy's setup;
- the country's own fields;
- the galactic community's custodian, emperor, defense force and emergency fund;
- the later DLCs' systems that keep their state in the country.

Each keyword's comment names the game's class in the Linux 4.5.2 build, with:
- **[V]**: read in the binary (`/opt/stellaris-headless/re` on 10.5.0.24);
- **[I]**: taken from the script documentation and the save's fields.

A handler writes the fields the game itself writes (the names in `CCountry::WriteMembers`,
`CGalacticCommunity::WriteMembers`, `CGameState::WriteMembers`), so a save written afterwards
holds the change. Coverage is measured by `simscript/scriptcheck.lua` ([script_coverage.md](script_coverage.md)).

## Scope links

| link | what it gives |
|---|---|
| `fromfromfrom`, `fromfromfromfrom` | The third and fourth entries of the from chain an event's scope keeps (`from_rec`, the game's from scopes trimmed to 7). The empty scope without one. |
| `galactic_custodian`, `galactic_emperor` | The community's `leader`: the emperor when `empire = yes`, the custodian otherwise [V: SetCustodian, SetEmperor]. |
| `last_created_country` | This context's `create_country`, else the save's `last_created_country`. |
| `no_scope` | The empty scope. |

`this`, `root`, `from`, `fromfrom` and `prev` to `prevprevprevprev` were already in eval.

## Control flow and tooltips

- **`break = yes`** sets the scope's break flag (CEventScope +0x168). CEffect's statement loop stops after any statement that leaves it set [V]. eval's effect walker does the same (`eval.set_broke`, `eval.broke`):
  - the rest of the scope's statements are skipped, including in the blocks that hold the `if`;
  - a scripted effect is the same scope as its caller;
  - a scope change starts a new scope, without the flag.
- **`reroll_random`** draws from the game's generator and seeds the scope's random position with it: `H(draw)`, CCrudeRandom::Seed [V].
- **The iterators' `weights` and `inverse`:**
  - `random_x = { weights = { base modifier } }` picks an element in proportion to its weight, each weight evaluated in that element's scope [I: weights in thousandths, as random_list's].
  - `ordered_x = { inverse = yes }` orders from the lowest value.
- **Tooltip wrappers** are the AND of their triggers. Their texts are parameters:
  - `custom_tooltip_icon`, `custom_tooltip_success`, `fail_text`, `success_text`, `hidden_progress`, `simple_progress`, `custom_progress`;
  - `conditional_tooltip` is true when its `trigger` fails;
  - `inverted_switch` is the NOT of `switch`;
  - `text`, `log`, `debug_break` and `logged_in_to_pdx_account` (no account in a headless game) give their fixed results.
- **Effects that only touch the interface** change nothing:
  - `play_sound`, `open_shroud_tab`, `complete_tutorial_step`, `endgame_telemetry`;
  - the tooltip effects `custom_tooltip_with_params`, `country_list_tooltip`;
  - `debug_break`.

  The checker counts them as containers.
- **`fire_on_action`** takes `scopes = { from fromfrom }` for the on_action's from scopes.

## The galaxy's setup

- **Triggers on the setup:**
  - `galaxy_shape` reads the save's `galaxy = { shape }`;
  - `caravaneers_enabled`, `voidworms_scaling` and `cutholoids_scaling` read their setup fields;
  - `is_crises_allowed` is true when `crises` is above 0;
  - `galaxy_radius` reads `galaxy_radius`;
  - `local_has_dlc` is `host_has_dlc` (a game of one).
- **`date_distortion = yes/no`** writes the game state's `date_distortion` [V].

## The galactic community

All of these live in `galactic_community = { }` in the save.

- **`set_galactic_custodian = yes`:**
  - unsets the emperor;
  - writes `leader` = the country;
  - sets `custodian_term` to CUSTODIAN_TERM_LIMIT_DAYS.

  `no` unsets the custodian when it is this country [V].
- **`set_galactic_emperor = yes`** writes `leader` and `empire = yes`, and sets `imperial_authority` to GALACTIC_EMPIRE_BASE_AUTHORITY. `no` unsets [V].
- **`add_custodian_term_days` / `set_custodian_term_days`** change `custodian_term`; a negative result is -1 (permanent). Without a custodian they do nothing; in the game, an error is logged [V]. The 2210 save has none, so the check shows them silent.
- **`set_galactic_defense_force`** adds or removes `galactic_defense_force = { owner }` [V names, I content]. `galactic_defense_force_exists` reads it.
- **`set_emergency_fund_active` / `set_emergency_fund_contribution_rate`** write `emergency_fund = { is_active contribution_rate }` [V].

## The country's own fields

| keyword | save field / source |
|---|---|
| `set_adjective` | `adjective = { key }`, or a copy of the target's [V] |
| `set_city_graphical_culture`, `city_graphical_culture` | `city_graphical_culture` (the trigger also compares with a target) [V] |
| `change_country_flag` | `flag = { icon background colors }` [V]. `random` draws a new flag (below). |
| `set_ai_{armor,shields}_ratio`, `set_ai_weapon_preference`, the `platform` ones, `clear_ai_*` | `ai_<x>_override` (SShipDesignPreferences) [V] |
| `ai_armor_ratio`, `ai_shields_ratio` | The override, else the personality's ratio (GetEffectiveArmorRatio) [V] |
| `is_preferred_platform_weapons` | Platform override, else empire override, else the personality's `weapon_preferences` |
| `set_ai_personality` | `personality` (CCountry::ForcePersonality) [V] |
| `set_advisor_active`, `is_advisor_active` | `has_advisor` (CCountry +0x2a40) [V] |
| `set_country_code_flags` | The listed code flags as `<flag> = yes/no` [I] |
| `set_tutorial_level`, `is_tutorial_level` | The primary human's setting, not saved: script state [V] |
| `add_victory_score` | `victory_score`, and the source's part in `score_from_effects` [V names] |
| `win`, `won_the_game` | The game state's `winner` [V] |
| `balance`, `running_balance`, `expenses` | Last month's energy balance and expense sums (`budget.last_month`). running_balance reads the same sum as balance [V]. |
| `stored_{physics,society,engineering}_points` | `tech_status.stored_techpoints` [I: the order] |
| `command_limit` | The `country_command_limit` modifiers (CCountry::CalcCommandLimit) [V call; I sum] |
| `set_visited` | `visited_objects` (CCountry::AddVisited) [V] |
| `reset_years_of_peace` | `last_date_at_war` set to today [I] |
| `is_country`, `has_same_ethos` | The target country; the same set of ethics [V] |

## Names that were not the game's

These were removed, because the game does not document them:
- the effects `abs_variable`, `clamp_variable`, `remove_variable`, `add_to_temp_list`, `remove_from_temp_list` and `optimize_memory` (in vanilla, `optimize_memory` is a bare word with no value, so the walker skips it);
- the triggers `num_colonies`, `num_pops` and `num_leaders`;
- the lists `pop_group`, `leader` and `galaxy_system`.

`has_dlc` became `host_has_dlc`. No vanilla file uses any of these names.

## The checker

In `scriptcheck.lua`:
- A scope link's use inside `trigger = { }` (the docs mod's links file) is run as a trigger. Before this, all of them ran as effects and missed on `always`.
- The interface-only effects above count as containers.

## Relations, resolutions, trade deals

`handlers/general_systems.lua` holds part 2 of the package.

| keyword | how |
|---|---|
| `add_favors`, `remove_favors`, `num_favors` | The relation's `num_favors`, capped at FAVOR_CAP. `remove_favors` only acts when the relation holds at least that many [V]. The game also fires its favor on_actions on add; that is not done here. |
| `has_secret_fealty_with`, `remove_secret_fealty` | `secret_fealty`, either way [V] |
| `set_hostile` | `hostile` in both relations [V calls, I both ways] |
| `end_all_treaties_with` | The agreement flags of both relations (CRelation::ClearAgreements) [I: the list] |
| `num_support_independence` | Relations with `support_independence` |
| `can_control_access_for` | A country with borders controls itself and its subjects [I] |
| `has_loyalty` | A subject's `loyalty` [V]. `has_monthly_loyalty` reads the subject_loyalty modifiers [I]. |
| `is_action_active`, `has_sensor_link_from` | The trade deals between the two (`trade_deal`: first, second) [V the deals, I the item keys] |
| `can_afford_special_offer`, `is_offer_terms_actual` | Only in the AI's trade-facility script (`ctx.special_offer`); false elsewhere |
| `in_breach_of` | The resolution's `breach = { }` triggers [V call] |
| `is_in_breach_of_any` | The code flag `is_in_breach_of_any` (+0x2a40 bit 0x10) [V] |

## The Shroud's patrons

The save holds them in two places:
- the shroud module: `attunement = { x y }`, `covenant`, `covenant_excluded_patrons`, `patron_relations`;
- the `patron_relations` store [V names].

**The model:**
- The attunement is a point on the wheel. A patron's position is its relation's `position`, else its type's.
- **Towards a patron**, the attunement is 1 minus the distance from the point (divided by MAX_ATTUNEMENT_VALUE) to that position, clamped to 0..1 (or -1..1) [V: GetAttunement].
- **The game's extra scaling** of cardinal patrons is not done.
- **Adding attunement** moves the point along the patron's direction (towards the centre for the End of the Cycle) and caps its length [I].
- **`set_attunement`** puts the point where the attunement towards the patron is the given value [I].
- **`has_most_attunement`:** the centre patrons are nearest when the point is small, so they win then [I].

| keyword | how |
|---|---|
| `attunement` | The point's distance from the centre [I] |
| `get_attunement_points_for` | The attunement times MAX_ATTUNEMENT_VALUE |
| `is_cardinal_patron` | A position on an axis |
| `has_patron_aura` | The top-level `psionic_auras` [I fields] |
| `accept_covenant` | `covenant = { patron level }`, then on_covenant_formed [V] |
| `refuse_covenant` | `covenant_excluded_patrons`; vanilla's `{ patron reset_attunement }` form included |
| `complete_deed` | The deed's `attunement` to its patron |
| `add_patron_objective_counter`, `has_patron_counter` | The deeds' counters; at their `max` a deed completes. The counts are in the script state [I] |
| `refresh_accords` | `unlocked_passive_accords_count` [I] |
| `revert_accords` | The accords' `on_revert` |
| `remove_patron`, `replace_patron` | The relations |
| `set_ai_preferred_patron`, `roll_ai_preferred_patron` | `is_preferred_patron` |

## Contracts, the Grand Archive, focus, pre-FTL ages

- **Contracts** are the nomads' missions (`common/missions/missions`).
  - `issue_contract` adds one to the script state [I: the mission objects' save form was not read].
  - The `owned_contract` list (issued by the country or worked on by it) and the counts read it, as do `has_contract` and `has_contract_of_category`.
- **DNA** is `standard_grand_archive_module.rarity = { <ship category> = <rarity> }`, with rarities common < rare < epic < exceptional.
  - `give_dna` writes it, never lowering a rarity.
  - `has_dna` reads it, at the given rarity or above.
- **The vivarium** is the module's `vivarium_critters` plus the top-level store.
  - `add_to_vivarium` adds critters: given a rarity, or drawn from WILD_CRITTERS_RARITY_TABLE.
  - `num_vivarium_slots` counts them.
  - `release_vivarium_fauna` and `release_vivarium_fauna_count` remove them (rarest first for the count). The wild fleets they become are recorded as unmodelled.
- **Focus:**
  - `add_focus_progress` adds to `focus.reward.rewards`' category progress. At the reward's `cost`, its `on_success` runs and the next reward becomes current [I].
  - `has_completed_focus` reads `focus.completed`, or an active card with status 1.
- **Pre-FTL ages:** `preftl_age` and the ages' `next_age`: `has_next_pre_ftl_age`, `go_to_next_pre_ftl_age`, `set_pre_ftl_age` [V].

## The country's other state, the galaxy

- **Country flags and blocks:**
  - `add_notification_modifier` and `remove_notification_modifier` write `notification_modifiers`;
  - `activate_fog_machine` and `deactivate_fog_machine` write `fog_machine.cloud_type`;
  - `destroy_country` sets the `killed` flag (CCountry::SetToBeKilled);
  - `set_player` moves the save's `player` entry.
- **Backups:** `store_country_backup_data` and `restore_country_backup_data` copy the flag, room, name, ethos and government into and out of `backup_data`.
- **Script state:** `copy_flags_and_variables_from` copies the target's flags and variables.
- **Values read from the country:**
  - `triumph_days_left` is the days of the timed `relic_activation_cooldown` [V];
  - `enclave_capacity_left` comes from the enclave modifiers and defines [I];
  - `has_surveyed_class` reads `surveyed_deposit_holders`' planets;
  - `is_in_sensor_range` is true for a system within the borders, or one that holds a fleet of the country [I: the sensor radii].
- **The galaxy:**
  - `create_cluster` adds a cluster to `clusters`;
  - `create_message` adds a message to `message`;
  - `storm_apply_aftermath_modifier` picks a severity by chance and adds its modifier and effect;
  - `effect_on_blob` runs its effect on the nearest systems until the share of matching colonies is covered.
- **Interface and recompute only:** `start_storm_area_placing`, `refresh_psionic_aura_type`, `run_ai_strategic_data`. They change nothing of the game's state; the checker shows them silent until its container list names them.
- **`spawn_random_storm`:**
  - a crude random seeded by one draw of the game's generator [I: CCosmicStorm::CalcRandomCosmicStormSeed's seed];
  - a storm type by its `spawn_weight`, in database order (GetRandomStormTypeBasedOnSpawnChance);
  - a random start system;
  - the storm made there by `create_cosmic_storm` and forced active [V calls].
- **`transfer_carrier`:**
  - finds the source's colony;
  - points the colony's `carrier = { type reference }` at the target planet or ship;
  - sets the old carrier's `colony` to none and the new one's to the colony [V calls];
  - when the target already carries a colony, `merge_pops` moves the pop groups and `destroy_colony` removes the source [I].
- **`clear_uncharted_space`** adds the system to the country's sorted `terra_incognita.systems` (CTerraIncognitaMap::ClearSystem) [V]. The map's pixel `data` comes from the galaxy's pixel-ownership table and is not redrawn here [I].
- **`change_country_flag = random`** (CCountry::RandomizeFlag, CEmpireFlag::Randomize), in the game's draw order [V]:
  - one game draw seeds a crude random;
  - a symbol is drawn from `flags/` (those other countries use left out while any is free);
  - then a background;
  - then a `randomizable_combo` from `flags/colors.txt` whose primary colour is not yet in the save's `used_color`; the primary is then added there.

  The lists' order is [I]: the files by name, the combos in file order.
- **Recorded as unmodelled:** the fleets of released fauna.

## Values

`complex_trigger_modifier` reads these through `eval.TVAL`:
- `is_difficulty` is the setup's level, civilian 0 to grand admiral 6 [V: CIsDifficultyTrigger::GetTriggerValue];
- `get_attunement_points_for` takes `parameters = { patron negative }`.

## Probes

`sim/tools/scriptprobe_general.txt` (run by `tools/scriptprobe.lua`) runs the package's silent and newly modelled rows with real targets, on the 2210 autosave and on rich_2212. `sim/tools/general_fealty_probe.lua` covers `remove_secret_fealty`, which needs a relation with the flag; no script effect sets it.

`remove_modifier`: the starbase probe's `artificial_planet_modifier` is not a vanilla static modifier, so `add_modifier` refuses it, as the game's reader would. With `relic_activation_cooldown`, the add stores the timed modifier and the remove takes it out (the case file's last lines).
