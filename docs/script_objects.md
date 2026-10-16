# Script effects that make the game's objects

The engine effects a new game's start script runs (docs/newgame.md section 8): a colony's
districts, zones, buildings and pops; fleets, ships and their designs; leaders and policies;
species and countries (guardians, enclaves, pre-FTL civilizations); ambient objects,
megastructures, wormholes. Read from the 4.5.2 Linux build (`/root/re452/game/stellaris`, with
its symbols; the addresses below are Linux addresses, not the GOG RVAs of the other docs).
[V] = read in the disassembly or checked in the 2200.01.11 save, [I] = inferred or approximated.

Code:

- `sim/lua/simscript/handlers/objects.lua`: the script side's shared helpers, `carrier_is_type`,
  `last_created_*` held game-wide, the modifier refresh before `check_modifier_value`; it loads
  `objects_colony.lua`, `objects_fleets.lua`, `objects_leaders.lua` and `objects_galaxy.lua`
  (parameters, scope resolution, the scope random's draws, `effect = { }` blocks).
- `sim/lua/engine/script/objects.lua`: the engine side's helpers (ids, stores a generated save
  lacks, the report, the modifier refresh); the appliers in `objects_colony.lua`,
  `objects_fleets.lua`, `objects_leaders.lua`, `objects_countries.lua`, `objects_galaxy.lua`,
  registered in `engine.systems.effects`.
- `sim/lua/engine/newgame/init.lua`: `newgame.start_script` runs them (see the end of this doc).

An effect whose result the script reads next (a `last_created_*`, a count, a `while` on
`pop_amount`) or that draws from the game's generator is applied at once (`sync`), so the draws
come where the game's do. Global draws go through `RUST.rand` (`objects.draw`); the scope
random's (CEventScope +0x68) through `eval.scope_draw` / `scope_random.int64_mod` (GetFixedPoint:
two positions, `% 100000`). A non-empty `effect = { }` block of a creating effect runs in a scope
made from one draw (`eval.seed_scope`): the scope random's for create_fleet, create_ship,
create_leader, create_pop_group, create_species, create_country, create_ambient_object; the game's
generator's for spawn_megastructure's and spawn_natural_wormhole's init_effect [V].

`last_created_fleet`, `_ship`, `_leader`, `_design` are game-state fields (CGameState +0x920,
+0x924, +0x928, +0x930) [V], as are the species', country's and ambient object's: one table
(`eval.last_created`) that every context's own `created` falls back to.

## Colonies

| effect | semantics | draws |
|---|---|---|
| `add_district` | CAddDistrictEffect 0x373f340 -> CColony::CanAddDistrict 0x2860980, AddDistrict 0x2860f10: the first district of the type gains a level; else a new district at the end of the colony's list, level 1, `zones` one entry per zone slot of the type, the slot's `start` zone made (slot_city_government: zone_default), else 4294967295 [V]. Without `ignore_cap`: levels < CalcMaxDistricts and the type's cap [I for the cap's modifier] | none |
| `remove_district` | CColony::RemoveDistrict 0x2860650: a level; the government district never below 1; level 1 goes with its zones and buildings | one per level (on_destroy's scope) |
| `add_zone` | CAddZoneEffect 0x3849560: the district named (type or index), else the first with a free allowed slot; the slot given, else the first free one allowing the zone; occupied: fails, `replace` moves the buildings [V] | none |
| `add_building` | SAddBuildingImpl / CColony::AddBuilding 0x2884320: the zone named, else the first zone (districts, slots) with room that lists the building, else a zone made in the first free slot allowing one, else a new district (TryToAddDistrictFor [I]); inserted after the buildings whose line's base has a position_priority not above its own, positions renumbered, buildings_cache rebuilt [V]. A zone's `max_buildings` defaults to DEFAULT_MAX_PLANET_BUILDINGS_PER_ZONE (3) [V] | none |
| `remove_building` | the first building of the type, positions renumbered [V] | none |
| `create_pop_group` | CCreatePopGroupEffect 0x3813210: size ceil(size), then GetInteger(size - random, size + random); joins the colony's first group of (species, category), else a new group; without a category the pops go where engine.pops puts new pops (NPlanetJobs::AssignPopsToJobs is not ported) [I]; ethics the owner's, split evenly (CPopGroup::RandomizeEthics splits by attraction, not ported) [I] | one scope draw (+1 for `effect`) |
| `clear_blockers` | CColonyCarrier::ClearBlockers(false) 0x28da140: each blocker deposit's on_cleared, then its `swap_type` takes its place or it goes [V] | one per blocker |
| `add_blocker` | a blocker deposit; `blocked_deposit = random` takes the first deposit it can block (no draw) [V] | none |
| `change_planet_size` | planet_size + n (0x3740500) [V] | none |
| `free_district_slots` | CalcMaxDistricts (size x NUM_DISTRICTS_FROM_PLANET_SIZE + NUM_DISTRICTS_BASE + the district modifiers [I names]) less the levels | - |
| `carrier_is_type` | the scope's colony carrier's type token [V] | - |
| `export_modifier_to_variable`, `check_modifier_value` | the scope's modifier value (0 without one), after the graph is refreshed when an object changed it | - |

## Fleets and ships

| effect | semantics | draws |
|---|---|---|
| `create_fleet` | CCreateFleet 0x36e6070: CreateNewFleet without an owner, SetUpFleet (name, `settings`), the effect in a scope made from one scope draw [V] | one scope draw for `effect` |
| `set_owner` (fleet) | CFleet::ChangeOwner: the country's owned fleet [V] | none |
| `create_ship` | CCreateShipEffect 0x36ed2a0: the fleet's controller's; `random_existing_design = <size>`: FindRandomShipDesignFromSize (the collection's (design, stage) pairs of that size, one draw), none: a default design made first; `design = NAME`: the global design (made in the store when first used); CreateNewShip (its name drawn), `name = random` drawn again, AddShip (two draws, on_ship_enter_fleet), the first ship making the fleet civilian (evasive) [V]. A fleet without an owner (its country not made) gets no ship [I] | design 1, names 2 a try (twice for random), AddShip 2 |
| `set_fleet_stance` | supported stances only (no evasive military, no aggressive civilian) [V] | none |
| `set_location` (fleet) | a planet target alone: EnterOrbit (teleport, the formation facing the planet, OnEnteredOrbit's three draws); else the target's place moved by distance / angle (random: one draw); then two draws and on_entering_system_fleet [V] | 3 or 0-1, then 2 |
| `set_leader` | the leader at the flagship (`location = { type = ship }`), the fleet's `leader`, on_leader_assigned | one |

The designs: the game's designer (CCountry::CreateAndAddDefaultShipDesign) is not ported.
`designs.default(country, size)` makes a design of the start's shape, as the 2200.01.11 save's
auto-generated designs: the size's section of the highest ai_weight per section slot, in each
weapon slot the first researched weapon of its size, armor in the utility slots (a shield in the
second), REACTOR_BOOSTER_1 in the auxiliary ones, and per `required_component_set` the last
researched component of the size's family (corvette, STARBASE_, PLATFORM_) [I]. No draws. The
generated empires' starbase stations get their level's design this way too.

## Leaders and policies

| effect | semantics | draws |
|---|---|---|
| `create_leader` | anon::CreateLeader 0x36d32a0 in the game's order: the class (drawn when not given), the ethic (over the country's ethics: RandomizeBackground needs the jobs, not ported [I]), the gender (drawn unless the species is indeterminable), the name twice (CNameListCharacter::GetRandomName: the set by weight, full or first + second, the names), the first level-up (two draws, on_leader_level_up), the age (two fixed-point draws, triangular over LEADER_AGE_MIN..MAX), the owned leader, OnSpawned (two draws, on_leader_spawned). Trait picks and `random_*` trait adders are not ported [I] | as listed |
| `assign_leader` | a planet's or colony's governor (`location = { type = planet id = <colony> }`), a fleet's leader [V] | one |
| `set_policy` | CCountry::ChangePolicy 0x2399b40: the entry's option (`date` only with cooldown); a change: on_disabled / on_enabled (a draw each when non-empty), on_policy_changed (one draw) [V] | as listed |
| `add_council_agenda_progress` | the government's council_agenda_progress, floored at 0 [V] | none |

A new country's policies (CCountry::InitializePolicy 0x23999f0): for each policy group it has no
entry of, the potential and valid option with the highest ai_weight (the first of equals), no
draw; its on_enabled [V]. When the game first runs this for a new country is not traced: the
start script does it with the ruler, before the empire's on_actions [I].

## Countries and species

| effect | semantics | draws |
|---|---|---|
| `create_species` | CCreateSpecies 0x36e2b00: the class (random: one draw over the randomized playable classes [I: uniform]), the name (random: one draw, the next unused name of the class's species_names), the portrait (random: one draw over the class's portrait sets), the archetype's trait, the given traits, the homeworld's habitability trait (or one draw); `random_traits` (CTraitSet::Randomize) is not ported | as listed |
| `create_country` | CCreateCountry 0x3700620: the type, name (`random`: `%ADJECTIVE%` of the species), species, ethics and authority (`random`: drawn [I: the government solver is not ported]), civics, origin; a planet scope and a type that needs a colony: the planet owned, controlled, its colony the capital; two draws for a type with a government; a ruler and the policies; then the effect (one scope draw) and on_country_created (one scope draw, always) [V for the order] | as listed |
| `set_owner` / `set_controller` (planet) | CPlanet::SetOwner 0x2a628e0 (a colony made when there is none, three draws and on_colony_transfer), only for a planet with pops or a type with `can_own_empty_planets` [V]; SetController (draws only when an old controller changes) | 3 / 0 |
| `set_capital` | CCountry::SetCapital 0x2343490: one draw per valid old and new capital, a change two more and on_capital_changed [V] | 1-4 |
| `create_colony` | owner and controller (the colonization data not ported) | 3 |

## Galaxy objects

| effect | semantics | draws |
|---|---|---|
| `prevent_anomaly` | bit 3 of the planet's binary_flags (64 by default) [V] | none |
| `add_anomaly` | the planet's `anomaly` [V] | none |
| `set_planet_entity` | `entity_name`, `picture` [V] | none |
| `set_deposit` | every deposit cleared, one of the type added; `random` draws once and is not ported further | 0 / 1 |
| `create_ambient_object` | a system: a random angle and a triangular radius within inner_radius (six scope positions); a planet: its orbital slot 7 (planet + d - 2, planet + d + 2, d = max(0, (size - 10) x 0.33) + 10) [V on the save]; the entity offset (two scope draws when its max is above 0), the height (one scope draw, always); the system's `ambient_object` list | scope only |
| `set_location` (ambient object) | the target's place moved by distance at the angle (random: one draw of the game's generator), the system lists [V] | 0 / 1 |
| `spawn_megastructure` | the place (coords_from's / the scope's / the planet's moved by orbit_distance at orbit_angle; random_pos: two fixed-point scope draws, the radius between inner and outer radius [I for the type's other placement modes]), the system's list, the planet's `megastructure`, a bypass for a type with one (the gateways connected to each other [I]); OnBuildComplete's five draws, init_effect's one [V] | 5 (+1) |
| `spawn_natural_wormhole` | random_pos: inner + fp x span, angle fp x orbit_angle (two fixed-point scope draws; the hyperlane distance check that retries is not ported); the wormhole and its bypass (owner type 7) [V] | init_effect 1 |
| `link_wormholes` | the two bypasses' linked_to and connections [V] | none |
| `get_galaxy_setup_value` | the save's `galaxy` setting (an int as fixed point) x scale_by into the variable (0x37d0410) [V]; a variable of a scope without an object is the event scope's own | none |
| `starting_system`, `distance` (hyperlane) | a country's `starting_system`; the shortest hyperlane path, the lanes' lengths summed (CGalacticDistanceCache::GetDistance [I: the metric]) | - |

## What the start script does around them

`newgame.start_script`: the init_effects of one system share its event targets (the tree's scope;
`exists = event_target:GuardiansTradersPlanet` keeps an enclave's planets from each making one)
[I]; per empire, before its on_actions: the stand-in stockpile emptied (give_starting_resources_effect
gives it), the ruler (CCountry::CreateRulerFromDesign: an official [I]), the policies, the starbase
station's design; the capital colony emptied of the generator's stand-in pops and given to
empire_init_capital_colony as its planet (the simulation's colony scope), from = the founder species.

## Checks

Tiny, seed 1234 (3 AI empires and the human): the capital of every empire has the real start's
shape (the 2200.01.11 save's empires: city 3 with zone_default, research and industrial zones,
building_capital first, rural districts by origin, the anglers zone for anglers), 4,800-5,200 pops,
a starport station, a science ship with its scientist, a constructor, three corvettes with their
commander, ruler and governor; 38 countries made in all (pre-FTL, enclaves, guardians and space
fauna); 30 days run from the started save without errors. Medium, 9 AI empires: every empire
likewise; 14 megastructures (the save 15), 22 bypasses (22), 10 natural wormholes (13), 411 ambient
objects (301).

Not equal yet: pop categories and jobs (NPlanetJobs is not ported: every pop is a civilian),
envoys (the leader pool), the ship names' prefix (a generated country has no `ship_prefix`), and the
counts the generator decides: it places some unique initializers more than once (ai_sol_system,
toxic_knights_finish: 4 UNE empires and 6 Toxic Gods in these runs) and more pre-FTL systems than the
game (24 pre-FTL countries against the save's 10).
