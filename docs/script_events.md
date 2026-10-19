# Script coverage: events, situations, archaeology, relics, astral rifts, storms, missions

The `events` package of the script coverage work ([script_coverage.md](script_coverage.md)): the
triggers, effects and scope links of events, situations, anomalies, archaeological sites, relics,
special projects, first contacts, astral rifts, cosmic storms, the grand archive's exhibits and
specimens, missions and event chains. Code: `sim/lua/simscript/handlers/events.lua` (scopes,
lists, links, triggers) and `handlers/events_effects.lua` (effects).

**[V]**: read in the Linux 4.5.2 binary (`/opt/stellaris-headless/re` on 10.5.0.24: the class's
`ExecuteActual` / `ActualEvaluate` / `GetTriggerValue` and what it calls, a `WriteMembers`' save
keys). **[I]**: from the documentation and the save's fields.

## The scopes and their stores

| scope | the save | id |
|---|---|---|
| archaeological_site | `archaeological_sites = { sites = { id = { location type index clues last_roll days_left difficulty locked completed log events ... } } }` (CArchaeologicalSite::WriteMembers [V]) | store id |
| astral_rift | `astral_rifts = { rifts = { id = { coordinate owner explorer_fleet leader explorer clues last_roll days_left difficulty ... } } }` (CAstralRift::WriteMembers [V]) | store id |
| cosmic_storm | `storms = { storms = { id = { type cosmic_storm_start_position storm_min_radius ... } } }` | store id |
| cosmic_storm_influence_field | `storm_influence_fields = { storm_influence_fields = { id = { center radius influence ... } } }` (CCosmicStormInfluenceField::WriteMembers [V]) | store id |
| mission | `missions = { id = { mission scope days_left status operator issuer ... } }` (CMission::WriteMembers [V]) | store id |
| exhibit | `exhibits = { id = { exhibit_state activated specimen } }` (CExhibit::WriteMembers [V]); a country's `modules = { grand_archive_module = { exhibits = { ids } last_acquired_exhibit ... } }` (CGrandArchiveCountryModule::WriteMembers [V]) | store id |
| first_contact, situation | engine/first_contact.lua, engine/situations.lua | |

Two of the stores are nested in the save (`astral_rifts.rifts`, `storms.storms`): engine.world's
`ensure_store` only finds top-level ones, so `handlers/events.lua` registers them (`M.holder`).

A galactic object's storm is its `storm` (an id, 4294967295 for none); the save's top-level
`last_created_cosmic_storm` and `last_created_cosmic_storm_influence_field` are the links.

## Lists (each gives every_, random_, ordered_, any_ and count_)

| list | its items |
|---|---|
| astral_rift, cosmic_storm | every one in the galaxy (CCosmicStormManager::GetStorms [V]) |
| cosmic_storm_start_position, cosmic_storm_end_position | the systems with no storm [I: the list builders' own conditions not read] |
| exhibit | the country's collected exhibits (CExhibitListBuilder: GetCollectedExhibits [V]) |
| first_contact | the contacts the country owns, active and complete |
| issued_mission, owned_mission | the missions whose `issuer` / `operator` is the country |
| system_in_cosmic_storm_influence_field | the systems within the field's radius of its center's system [I] |
| targeting_situation | the situations whose `target` is the planet or ship (CTargetingSituationListBuilder [V]) |

## Notes on the triggers and effects

- **First contact difficulty:** `is_current_stage_difficulty` on a first contact is CFirstContact::GetCurrentStageDifficulty. That is the save's `difficulty` plus the contact country's malus (engine/first_contact.lua's `malus`, now exported) [V].
- **Clues:** `add_stage_clues` adds to an arc site's, an astral rift's or a first contact's clues (CAddStageCluesEffect calls each one's AddClues [V]). A first contact's go through engine/first_contact.lua's new `add_clues`, which keeps the day's newly added clues.
- **Situations:**
  - `add_situation_progress` and `set_situation_progress` call CSituation::AddProgress / SetProgress, then engine/situations.lua's `progress_changed`: the clamp, the stage update, on_fail and on_progress_complete [V].
  - `start_situation` builds the situation as the game's own does. The comparison is with the console's `Effect start_situation = { type = situation_energy_deficit target = this }`, whose save has:
    - progress 15;
    - the default approach;
    - the stage durations from the stages;
    - `stage_flags = { yes no no no }`;
    - the flag set by on_start.
  
    Ids come from the store's next index (the game's generation of a reused index is not modelled).
- **Relics:** `add_relic`, `remove_relic` and `steal_relic` edit the country's `relics` list and set `last_received_relic` / `last_lost_relic` (CCountry::AddRelic / RemoveRelic [V]).
- **Astral action cooldowns:** the country's `astral_actions_usage_states_array = { <action> = { ... next_usable_date } }` (SAstralActionUsageState::WriteMembers [V]).

## The effects that make, finish or remove objects (handlers/events_create.lua)

- **Missions** (NMissionUtil):
  - `enable_mission` makes one: `mission`, the effect's `scope`, `status = active`, the scope's country as `operator`, no issuer, a `location` for a type with `location = yes`. The id goes into the country's `events = { missions = { ids } }`, then the type's `on_start` runs. This matches the game's console run of the same effect.
  - `stop_mission` sets the status, runs `on_success` or `on_cancel` and then `on_stop` (this = the operator, prev = the issuer, from = the mission's scope, as 99_README_MISSIONS.txt gives them), and takes the mission out.
  - `add_mission_counter` / `set_mission_counter` keep `counter = { <key> = n }`, clamped to the type's max; a mission whose counters all reach their max succeeds [I].
  - `cancel_contract` refunds the type's `cost` to the issuer.
- **Special projects:**
  - `complete_special_project` takes the projects of the type (at the location) out with their research, sets the country's `last_completed_special_project`, and runs each one's `on_success` in its saved scope.
  - `enable_patron_first_contact_project` enables the project through engine/script/creation.lua's applier and puts the patron relation (`patron_relations`) in progress.
- **Arc sites:**
  - `create_archaeological_site` makes a site at the scope's spatial object: `location = { type id }`, the first stage's difficulty, ARCHAEOLOGY_DISCOVERY_DAYS. `random` picks among the types with weight whose potential holds [I].
  - `finish_current_stage` / `finish_site` complete stages (`completed = { index }`) and fire the stage's event for the excavator's country when `yes`.
- **Cosmic storms:**
  - `create_cosmic_storm` writes the fields the game's own run writes: type, start position, radii, `activated = no`, a cluster over the systems within the minimum radius. The storm manager's path, name and colour are not modelled.
  - Storm influence fields are created and destroyed by their center system (the game's own run wrote `center = 4294967295` from a planet scope [I]).
  - `recalculate_storm_influence_field` (not in the package: another area's list, done here) writes the field's systems.
- **Astral rifts:**
  - `spawn_astral_rift` matches the game's run: `status = waiting_for_explorer`, `event_choice = "astral_rift.1"`, days_left 90, the system as the coordinate's origin, the init_effect, on_astral_rift_spawned.
  - `finish_astral_rift` sets the status and counts the explorer's `astral_rifts_completed` [I].
  - `set_next_astral_rift_event` writes the save's `event_choice`, `on_roll_failed`, `fail_probability` [V].
  - `fill_astral_rift_event_pool`, `perform_astral_action_unlock_check` [I].
- **The grand archive:**
  - `unlock_exhibit` makes an exhibit of the category, up to GRAND_ARCHIVE_EXHIBITS_COUNT.
  - `give_specimen`, `steal_specimens` fill a free exhibit of the specimen's category and set `last_acquired_exhibit`, then on_specimen_acquired.
  - `remove_specimen` empties the exhibit.
  
  The exhibit's own field names are [I]; the game's 2210 country has no grand archive, so its run of `give_specimen` made nothing.
- **Anomalies:** `spawn_random_anomaly` picks a category by its spawn_chance on the planet (one draw [I]) and writes it as add_anomaly does.
- **Events:** `bypass_event` and `pop_faction_event` fire as `country_event` does.
- **Relics:** `add_relic` / `remove_relic` fire on_relic_received / on_relic_lost [I].
- **Patrons** (moved from the diplomacy package):
  - `create_patron_relation`, `set_patron_first_contact_state` and `enable_patron_first_contact_project` use the store and fields of handlers/general_systems.lua's patron effects (`remove_patron`, `replace_patron`, `roll_ai_preferred_patron`): a `patron_relations = { id = { owner patron position contact special_project patron_relation_start_date } }` object, and its id in the country's `standard_shroud_module = { patron_relations = { ids } }` (CPatronRelation / CShroudCountryModule::WriteMembers [V]).
  - The relation's `contact` is set by the first contact state, and `special_project` by the patron project.
- **Pre-FTL awareness:** `set_awareness` / `add_awareness` act only on a pre-FTL country (the game checks CCountry +0x1ab9 and logs otherwise; here its type `primitive` [I]).
  - CCountry::SetAwareness clamps to [AWARENESS_MIN, AWARENESS_MAX].
  - When the stage changes it fires on_awareness_level_increase / _decrease (CheckAwarenessOnActions; the stage bounds are AWARENESS_*_LIMIT) [V].
- **Culling rewards:** `give_culling_rewards = { design mult }` acts only for a country with a grand archive. The design (a ship or fleet's design, a ship size, or a global design's name) leads to its ship size's `space_fauna_values = { culling_value = { produces } }`, multiplied by mult. That is added to the stockpile and to the archive's `culling_value` [I: the rarity draw is not modelled].

## The checker's examples that cannot act

These rows stay `silent` or `refused` because the docs mod's use names something the 2210 save does
not have; the game does nothing for them either:
- `= from`, with no from: abort_situation, destroy_situation, destroy_archaeological_site, destroy_astral_rift.
- A relic the country does not have: remove_relic.
- A chain that is not active: end_event_chain, add_event_chain_counter, reset_event_chain_counter.
- `set_event_locked = no` on a fleet that is not locked.
- An approach of another situation type: set_situation_approach.
- A fleet with no observation mission: add_mission_progress.
- A country scope: add_anomaly, spawn_random_anomaly.
- A mission the country does not have: add_mission_counter, set_mission_counter.
- A project the country does not have: complete_special_project, abort_special_project.
- `from` missing: create_cosmic_storm, destroy_cosmic_storm_influence_field.
- An unset event target: fleet_action_research_special_project.
- No grand archive: give_specimen, remove_specimen, steal_specimens.

Part 2's probe (`/root/ce/p4.txt`, `p5.txt`) runs the same effects with real targets, and each one acts:
- a mission enabled, then counted to success, and another one stopped;
- a gravity storm created (last_created_cosmic_storm);
- an influence field created and destroyed;
- a rift spawned, given its next event and finished;
- the rift pool filled;
- an exhibit unlocked, then a specimen given and removed;
- a site created, then finished stage by stage (`completed = { 0 1 2 3 4 }`);
- a patron state set;
- a random anomaly spawned (AIANOM_LUMP_CAT);
- a special project enabled, then completed.

`/root/ce/probe.sh` on .24 runs them with real targets in the coverage save below. Each one acts:
- the approach switched;
- progress 15 to 35 and stage 1;
- the relic removed (last_lost_relic) and another added;
- the chain's counter set and reset, then the chain ended;
- the site's clues 0 to 2 and its log entry;
- the rift's clues 0 to 3;
- the system's storm set and unset;
- the situation aborted (to_be_killed);
- the rift destroyed.

## The review: every silent and refused row acting on real targets

`sim/tools/scriptprobe.lua` with `sim/tools/scriptprobe_events.txt` runs each of the package's
silent and refused effects on a real target that the probe makes first. That covers 29 rows:
abort_situation, abort_special_project, add_anomaly, add_awareness, add_event_chain_counter,
add_mission_counter, add_mission_progress, complete_special_project, create_cosmic_storm,
destroy_archaeological_site, destroy_astral_rift, destroy_cosmic_storm_influence_field,
destroy_situation, end_event_chain, fleet_action_research_special_project, give_culling_rewards,
give_specimen, remove_patron, remove_relic, remove_specimen, reset_event_chain_counter,
roll_ai_preferred_patron, set_awareness, set_cosmic_storm, set_event_locked, set_mission_counter,
set_situation_approach, spawn_random_anomaly, steal_specimens. The targets it makes:
- a situation;
- an active event chain;
- an enabled special project;
- a pre-FTL country;
- an active mission;
- an observation mission;
- a locked fleet;
- a storm;
- a field;
- a site;
- a rift;
- a relic the country has;
- patron relations;
- a grand archive with a specimen, and a victim country holding one.

On both the 2210.01.01 autosave and `rich_2212.sav`, every one writes the world (the probe counts
the writes).
```
cd sim
PROBE=tools/scriptprobe_events.txt STELLARIS_DIR=/opt/stellaris STELLAR_LUA=tools/scriptprobe.lua \
  <target>/release/examples/run 0 /root/scov/saves/rich_2212.sav
```
The checker's own uses stay silent or refused for the reasons above: the target is missing, so the
game does nothing either.

The probe also showed one miss that belongs to another package: `num_moons`, read as a trigger value
in an anomaly category's spawn_chance.

## The coverage save

The 2210.01.01 save has no cosmic storm, astral rift, mission or exhibit. The headless game makes one: `/root/ce/cov_events/autosave_2210.01.03.sav` on .24 (`/root/ce/gsave.txt`). It is `console Effect` with, on the player's country:
- `begin_event_chain` cs_stormfever_chain;
- `enable_mission` MISSION_CS_STORM_FEVER_CHALLENGE_1;
- `create_cosmic_storm` electric_storm at the capital's system;
- `create_cosmic_storm_influence_field` radius 50 at the capital;
- `spawn_astral_rift` riftworld;
- `unlock_exhibit` and `give_specimen` (no exhibit is made: the country has no grand archive);
- `start_situation` situation_energy_deficit;
- `add_relic` r_khans_throne.

Then `step 2` and `save`.
