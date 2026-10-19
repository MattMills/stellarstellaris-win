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

## The checker's examples that cannot act

These rows stay `silent` or `refused` because the docs mod's use names something the 2210 save does
not have; the game does nothing for them either:
- `= from`, with no from: abort_situation, destroy_situation, destroy_archaeological_site, destroy_astral_rift.
- A relic the country does not have: remove_relic.
- A chain that is not active: end_event_chain, add_event_chain_counter, reset_event_chain_counter.
- `set_event_locked = no` on a fleet that is not locked.
- An approach of another situation type: set_situation_approach.
- A fleet with no observation mission: add_mission_progress.
- A country scope: add_anomaly.

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
