# Script coverage: the research package

`sim/lua/simscript/handlers/research.lua` implements the 54 keywords of the research package
(docs/script_coverage.md): technologies, traditions and ascension perks, the planetary ascension
tiers, the crisis (ambitions), and the research side of the council, the patrons' accords and the
research stations.

Each handler's comment names the game's class in the Linux 4.5.2 build and its address. The tags mean:

- **[V]** read in the binary (`/opt/stellaris-headless/re` on 10.5.0.24: `full.asm`, `nm.txt`, the token table);
- **[I]** inferred from the documentation and the save's fields.

The handlers write the save's own fields (the classes' WriteMembers names), so a save written after them carries the change.

## Technologies

The fields are the country's `tech_status = { technology level ... alternatives = { physics society
engineering } always_available_tech stored_techpoints_for_tech <area>_queue last_increased_tech }`.

| keyword | what it does | source |
|---|---|---|
| add_research_option | AddAlwaysAvailableTech when the country can research the tech: added to `always_available_tech` and to its area's `alternatives`, then on_research_option_added | [V calls] |
| add_tech_progress | progress must be in 0..1. Makes the tech an option, then adds progress x cost through IncreaseTechnologyProgress: to its queue item (completed at the cost), else to `stored_techpoints_for_tech` | [V calls] |
| add_random_research_option | a tech drawn among those matching category, area and tier, with the rare, insight and prereqs filters; made an option, add_progress x cost stored; none matching runs fail_effects | [V calls; I: a uniform draw] |
| copy_techs_from | the target's techs and levels, minus the exceptions, where the country can research them | [V calls; I: the ship designs not reset] |
| copy_random_tech_from / can_copy_random_tech_from | the target's techs the country can research (category, area); one drawn, researched, or with `progress` an option with stored points | [V calls] |
| finish_all_researches / progress_all_researches | each area's current research given the progress it needs, or f x its cost | [V calls; I: completion left to the day] |
| num_researched_techs | all levels (CalcTotalTechLevels) | [V] |
| num_dangerous/insight/custom_1..3_techs | the techs with `is_dangerous`, `is_insight`, `is_custom_tech_1..3` (CTechnology +0x9d8 bits 5..8) | [V] |
| num_researched_techs_of_tier | the techs of the tier | [V calls] |
| can_research_tier | true for tiers below 2 and tiers without `previously_unlocked`; otherwise at least that many researched techs of the tier below in the area, `hidden` ones (bit 2) not counted | [V] |
| count_tech_options | the area's alternatives | [V] |
| is_researching_technology / is_researching_any_technology | the queues | [V calls] |
| is_last_increased_tech_category / _rare / _repeatable | `last_increased_tech` | [V calls] |
| tech_unlocked_ratio | the researched techs' total cost over the target's | [V calls; I: the costs, the comparison] |
| has_highest_technology_score | no country has a higher `tech_power` | [V] |
| scientist_count | owned leaders of class scientist | [V; I: the class flag] |

## Traditions and ascension perks

These use engine.traditions on `traditions`, `tradition_categories` and `ascension_perks`.

- **add_tradition / add_ascension_perk:** ActivateTradition and ActivateAscensionPerk, without cost or slot checks. They add the category when new, set last_picked_tradition for a tradition, and run OnEnabled and its on_action.
- **remove_tradition / remove_ascension_perk:** the name is taken out of its list.
- **remove_tradition_tree:** the category and its traditions are taken out.
- **copy_traditions_from / copy_ascension_perks_from:** the target's names, minus the exceptions, are added where the potential and possible triggers hold. [I]

## Planetary ascension, the crisis, the council

- **set_planetary_ascension_tier / has_planetary_ascension_tier:** the colony's `ascension_tier` (CColony +0x110). [V]
- **num_planetary_ascension_tiers:** the sum of that field over the country's colonies. [V]
- **multiply_crisis_strength / additional_crisis_strength:** the game state's `additional_crisis_strength` (+0x130). [V]
- **set_crisis_sound / stop_crisis_sound:** `crisis_sound`, set to empty when stopped. [V]
- **allowed_crisis_type:** the galaxy's `crisis_type` must equal the value. The six values (any, prethoryn, unbidden, contingency, synth_queen, all) are distinct, so `all` is not `any`. [V]
- **can_be_crisis_terraformed:** the star class's `can_be_crisis_terraformed`, yes by default. [I]
- **activate_crisis_progression:** sets `crisis_progression = { path level }` [V: it replaces the old one]. The levels' unlocking is not modelled [I].
- **complete_crisis_objective:** when the path lists the objective, its `reward` value block in the path's `crisis_currency` goes to the stockpile, and the progression's `objective` is set. [V calls]
- **set_leader_tier:** the leader's `tier`. [V]
- **unlock_council_selection:** DetermineCouncilorTypes (engine.script.objects_leaders `council.determine`). [V]
- **has_unlocked_council_positions:** `unlocked_civic_council_slots`. [V]
- **count_unlocked_active_accords / patron_has_all_accords_unlocked:** the patron relations' `unlocked_active_accords` and `unlocked_passive_accords_count`, against the patron type's accord blocks. [I]

## Stations, frontier, debris, agreements

- **create_research_station:** CDepositHolder::CreateOrbitalStation, on a planet without a station. It makes a `shipclass_research_station` fleet owned by `owner`, with its research_station ship, in orbit, and sets the planet's `shipclass_orbital_station`. [V calls; I: the fleet's fields as the save's stations]
- **research_station (link):** the planet's station fleet of that class.
- **is_in_frontier_space:** the system belongs to no sector. [V]
- **must_research:** the debris' `must_research`. [V]
- **has_specialist_perk / specialist_tier:** the agreement's fields. [I]

The 2210 save has no debris and no agreement, so the checker cannot run these three.

## Checked

The checker (docs/script_coverage.md) runs every use with this = from = the player. In that run the
docs mod's uses of several effects change nothing, and the game would change nothing either:

- the copy effects copy from the country itself;
- the player has no research queue;
- `add_random_research_option` asks for biology in engineering, and no tech matches;
- the objective `crisobj_research_thesis` is not on `defender_path`.

`/root/cr/probe.lua` on 10.5.0.24 runs them with real targets on the 2210 save, and each acts:

- **copy_techs_from:** 31 to 40 techs.
- **copy_random_tech_from:** +1 tech.
- **copy_traditions_from:** 4 traditions.
- **remove_tradition:** -1.
- **remove_tradition_tree:** the category and all its traditions removed.
- **add/remove/copy perks:** as expected.
- **progress_all_researches 0.1:** 959.3 to 1097.9 of 1386.
- **finish_all_researches:** 1386.
- **add_random_research_option:** society options 3 to 4.
- **cosmogenesis objective:** +8000 advanced_logic.
- **create_research_station:** fleet 804, and the link resolves it.
