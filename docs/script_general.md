# Script keywords of no single window

`sim/lua/simscript/handlers/general.lua` holds the triggers, effects and scope links that belong to
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
| `change_country_flag` | `flag = { icon background colors }` [V]. `random` (CCountry::RandomizeFlag) is recorded as unmodelled. |
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

## Not done yet

The rest of this package: the shroud patrons (attunement, covenants, accords, deeds, auras), contracts, the vivarium and DNA, focus cards, pre-FTL ages, favors, loyalty, sensor links, resolutions in breach, cosmic storms, clusters, messages, country backups and destruction, carriers, `effect_on_blob`, special offers, `set_hostile`, `set_player`, `clear_uncharted_space` and the fog machine.
