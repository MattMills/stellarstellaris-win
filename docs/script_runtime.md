# Script keywords the simulation hits at run time, and the most used ones of vanilla

What `sim/lua/simscript/handlers/runtime.lua` evaluates, how the game evaluates each keyword, and
where the save keeps what it reads (`sim/lua/engine/script/runtime.lua` reads it). It began with
the triggers, links, lists and value forms a 180-day run from `autosave_2210.01.01` reached
without an implementation ("not implemented, hit while running", "reads the save does not answer
yet"), and went on with the most used ones in vanilla that are neither diplomacy (war, peace,
rivals, pacts, hostility, opinion, access, espionage and intel: `simscript/handlers/diplomacy.lua`)
nor effects (`simscript/handlers/creation.lua`).

Reverse engineered from the GOG 4.5.2 build and its PDB on hippo (`/root/fnm_tmp`: `annotate.py`,
`pdbtype.py`, `tokens452.tsv`, `types452.txt`; `tmp_trig/trigclass.py` ties a keyword to its
class; `tmp_sim/rt/` has the working notes `re_*.md` and the helpers). Addresses are GOG RVAs.
**[V]** marks what was read in the trigger class's `ActualEvaluate` (or `GetTriggerValue`) and the
classes it calls, with save field names from their `WriteMembers`; **[I]** what is inferred (from
the save, the script files, the names, the documentation).

Contents: [conventions](#conventions-of-the-games-triggers), [the code](#the-code),
[keywords](#keywords) by area, [not implemented](#not-implemented-and-why),
[results](#results).

## Conventions of the game's triggers

- **The scope check.** `CTrigger::Evaluate` (`0x344ff0`) runs `IsScopeOk` (vtable `+184`) before
  `ActualEvaluate`: a scope type outside the trigger's `GetSupportedScopes` mask (0: any), or an
  invalid scope object, gives **false** whatever the yes/no or operator, with an error.log line.
  There is no conversion to the owner. So `has_trait` on a planet, `is_country_type` / `is_ai` on
  a planet and `is_megastructure_type` on a country are false **[V]**.
- **Yes/no triggers** (`CBoolTrigger`, `+0x220 _Status`, `+0x221 _StatusSet`): the evaluation is
  compared with `_Status`. Where a trigger has no object to read inside a supported scope (no
  colony, no carrier), several return `_StatusSet && !_Status`: `= no` holds, `= yes` fails **[V]**.
- **Comparisons** (`CCompareOperator`, an int at the trigger's `+0x78`): `1` `=`, `467` `>`,
  `468` `<`, `971` `>=`, `972` `<=`, `1063` `!=` (`CCompareOperator::Read` `0xa347b0` accepts
  these and nothing else) **[V]**. `CIntTrigger` / `CValueTrigger::ActualEvaluate` (`0x19ec080`,
  `0x19435e0`): a failing `GetTriggerValue` is false for every operator **[V]**.
- **Scopes**: `CScopeObjectReference +8` is the `EScopeType` bit (1 megastructure, 2 planet, 4
  country, 8 ship, 16 pop, 32 pop group, 64 fleet, 128 galactic object, 256 leader, 512 army, 1024
  ambient object, 2048 species, 16384 pop faction, 65536 federation, 131072 starbase, 262144
  deposit, 1048576 sector, 4194304 archaeological site, 8388608 first contact, 536870912
  situation, 8589934592 cosmic storm, 1099511627776 colony) **[V]** (`types452.txt`).
- **Carrier and colony** (`NScriptUtil::GetCarrierFromScope` `0x9f48a0`, `GetColonyFromScope`
  `0x9f4ad0`): a planet is its own carrier, a ship its own, a colony's is `carrier = { type
  reference }`; a planet's colony is its `colony`, a ship's its `colony`, a colony itself; any other
  scope (a pop group too) has none **[V]**. Several planet triggers test `scope & (planet|ship)`
  before the colony type, so a colony scope never reaches its planet there (noted per keyword).
- **Numbers**: `CFixedPoint` is an int64 with 1.0 = 100000; conversions to int round toward zero
  (`free_amenities`, `free_housing`) **[V]**. The simulation keeps doubles.
- **`trigger:<name>` in a value** (`CVariableValue::ReadTriggerModifierOrScriptValue` `0x34c550`):
  the trigger made with no arguments, accepted only for comparison triggers (`CIntTrigger`,
  `CValueTrigger`); its `GetFixedPointTriggerValue`, 0 on a wrong scope or a failing value **[V]**.
- **Value operations** (`EScriptMaths`, `MTTHModifyNumber` `0x340160`): Set, Add, Subtract,
  Multiply, Divide, Modulo, RoundTo, Round, Floor, Ceiling, Max, Min, Abs, Square, **Pow**, Sqrt
  **[V]**. `pow` is `NFixedInt64Internal::ipow` (`0x1b43a50`): 0^0 = 1, 0^x = 0, a positive base
  `exp(x ln b)`, a negative base the same with the sign of the parity of the exponent's raw fixed
  point int (3.0 is 300000, even: `(-2)^3` is +8) **[V]**; the game's ln and exp are fixed-point
  series, so its results differ from doubles in the last digits.

## The code

- `sim/lua/simscript/handlers/runtime.lua` (`return function(eval) ... end`, loaded by
  `simscript/handlers/init.lua`): the handlers in `eval.TRIG`, `eval.LINKS`, `eval.LISTS`, the
  numbers in `eval.TVAL`, value operations in `eval.VALUE_OP`, `eval.pow`. `numeric(name, kinds,
  value)` makes a comparison trigger and its `trigger:` value from one function.
- `sim/lua/engine/script/runtime.lua`: the world readers (systems, carriers, colonies, starbases,
  fleets, storms, megastructures, council positions, sectors, AI strategy lists, ...), and the
  store names it adds to `engine.world.KINDS` (`cosmic_storm`, `council_position`, `colony`,
  `spy_network`, `archaeological_site`, `natural_wormhole`, `bypass`, `pop_faction`,
  `ambient_object`).
- Shared files, each in its own commit: `simscript/eval.lua` and `simscript/compile.lua` take
  `trigger:<name>` from `eval.TVAL`, `pow` from `eval.pow` and other operations from
  `eval.VALUE_OP` (the walker and the compiler alike); `eval.status` counts the `count_*_amount`
  iterators; `engine/interface.lua`'s `E.system_of` finds a fleet's (and ship's) system in its
  movement coordinate (it returned nil for every fleet: `solar_system` of a fleet or ship gave
  nothing); `engine/economy.lua`'s dynamic capacity takes a modifier's `subtract`.
- The `script.with` modules no longer install their own versions of what the script layer now
  answers: `engine/economy/script.lua` (`is_scope_valid`, `is_space_fauna`, `is_councilor`,
  `has_starbase_building`, `has_active_tradition`, `is_robot_pop_group`, `is_pop_category`,
  `is_unemployed`, `has_living_standard`, `is_heir`, `has_climate`, `is_ringworld`,
  `has_active_building`, `is_scope_type`, `has_component`, `has_federation_perk`,
  `has_federation_law`, `has_envoy_task`; `has_ethic` and `has_trait` of a leader or country fall
  through to the script layer) and `engine/ethics/script.lua` (`is_sector_capital`,
  `is_councilor_type`, `has_election_type`, `has_faction`). `engine/situations.lua` and
  `engine/first_contact.lua` install theirs only where the script layer has none:
  `contact_country` stays theirs; `situation_monthly_progress` reads `engine.situations`' computed
  progress as theirs did.
- `STELLAR_RUNTIME_OFF=<name,...|all>` puts the tables back as they were before the module for
  those keywords, to measure what each changes.

## Keywords

### Cosmic storms

| keyword | game | reads | marks |
|---|---|---|---|
| `is_inside_storm = yes / no / <storm type>` (system) | `CIsInsideStormTrigger::ActualEvaluate` `0x19ba4d0`: the galactic object's `_StormRef` (`+0x10d0`) is a valid storm; the argument is a storm type, `no` and `yes` being the storm type database's two sentinels (`+0x88`, `+0x90`): `no` not inside, `yes` inside, a type inside a storm of that type (`CCosmicStorm +0x340`) | the system's `storm = <id>`, the storm in `storms = { storms = { <id> = { type } } }` (`CCosmicStorm::WriteMembers` `0xda00c0`) | **[V]** |
| `is_storm_type = <type>` (cosmic storm) | `CIsStormType` `0x19bbc40`: the storm's type | `type` | **[V]** |

The 2210 save and the 10-year standard's last save have no storms, so `is_inside_storm` holds
only as `= no` there. Its 107,280 hits in 180 days come from the game rule
`can_force_see_fleets_in_system` (`is_inside_storm = solar_storm`): false as before.

### Megastructures

| keyword | game | reads | marks |
|---|---|---|---|
| `has_megastructure = <type>` (country, system) | `CHasMegaStructureTrigger` `0x19a56a0`: a megastructure of the type (`CMegaStructure +0x178`) among a country's `_MegaStructures` (`CCountry +0x2fc0`) or a galactic object's (`+0x508`); another scope logs and is false | `owned_megastructures`, the system's `megastructures`, each one's `type` | **[V]** |
| `has_any_megastructure = yes/no` (planet, system) | `CHasAnyMegastructureTrigger` `0x19a7a50`: a planet: a megastructure of its system at the planet (`planet`), else `= no` holds; a system: it has one | `megastructures`, their `planet` | **[V]** |
| list `system_megastructure` | `CSystemMegaStructureListBuilder`: a system's megastructures | `megastructures` | **[V]** |

The 20,076 hits of `has_megastructure` come from the game rule `has_full_sensor_range` (`spy_orb_4`,
`spy_orb_restored`): nobody has them in 2210, so false as before.

### Starbases

| keyword | game | reads | marks |
|---|---|---|---|
| `has_starbase_size <op> <ship size>` (starbase) | `CHasStarbaseSizeCompareTrigger` `0x19c28f0`; `PostInit` `0x19c2e00`: the first starbase level in the database whose `ship_size` is the size. An invalid starbase or level is false; `=` the same level; on the same level `>=` / `<=` hold, `>` / `<` fail; `>` / `>=` hold when the starbase's level follows the target on the `next_level` chain, the other operators when it precedes it | `level`; `common/starbase_levels` `ship_size`, `next_level` (file and line order) | **[V]** |
| `has_starbase_building` / `has_starbase_module = <key>` (starbase) | `CHasStarbaseComponentTriggerBase<...>` `0x19c57a0` / `0x19c5a70`: a building (module) equal to the key; with `!=`, one that is not the key | `buildings = { <slot> = <key> }`, `modules` | **[V]** |
| `count_starbase_sizes = { starbase_size count }` (country) | `CCountStarbaseSizesTrigger` `0x19c3720`: its starbases at the size's level or after it on the chain | the starbases of the systems it owns | **[V]** |
| `used_starbase_capacity_percent <op> x` (country) | `0x199d0d0`: (capacity used + outposts being upgraded) / capacity; false at capacity 0. Capacity used: the levels' `starbase_capacity_used` (`CalcStarbaseCapacityUsed` `0x749b30`); outposts being upgraded: primary outposts with a queued upgrade (`0x749db0`); capacity: `STARBASE_CAPACITY_BASE` + `STARBASE_CAPACITY_SYSTEM_MULT` per owned system + `STARBASE_CAPACITY_POP_MULT` per pop + `country_starbase_capacity_add`, times 1 + `country_starbase_capacity_mult`, rounded down | `level`, `construction` items `buildable_starbase_upgrade`, the country's modifiers | used, upgrading **[V]**; capacity **[I]**: the formula gives every country's saved `starbase_capacity` at 2210.01.01 (the game recomputes both daily; so does this) |
| `can_be_upgraded = yes/no` (starbase) | `CCanBeUpgradedTrigger` `0x19a60d0`: the level has a `next_level`; not occupied; no upgrade queued; the next level's ship size `potential_country`, `prerequisites`, `possible_country` for the controller; the next level's upgrade trigger | `level`, the station's fleet's owner, `construction`, `tech_status` | **[V]**; the occupier is taken as none (no wars) **[I]**; ships, fleets and megastructures: a miss (below) |
| link `starbase` | `CEventTarget::GetScope` (token 14911): a starbase itself; a system's primary starbase (its first `starbases` entry, none when that one does not exist); a planet's or colony's system's; a starbase fleet's (`ship_class = shipclass_starbase`): the starbase of its first ship; a ship of class shipclass_starbase: the starbase it is the station of | `starbases`, `station`, `ship_class` | **[V]** (replaces eval.lua's, which took the first valid entry) |

The AI budgets read `can_be_upgraded` with `used_starbase_capacity_percent` (`food_expenditure_starbases`
and the like): with both answered, the AI saves for starbase upgrades as the game does (see
[results](#results)).

### Fleets and ships

| keyword | game | reads | marks |
|---|---|---|---|
| `has_fleet_order = <order>` (fleet; a ship: its fleet's) | `CHasFleetOrderTrigger` `0x1992000`: the current order or one of its sub orders, or a top-level queued order, is of that kind | `current_order = { <name> = { sub_order = { } } }`, `order = { <name> = { } }` | **[V]** |
| `is_ship_size = <size>` (ship, fleet, starbase) | `CIsShipSizeTrigger` `0x1955e80`: a ship's (its design's growth stage, the first when the index is out of range), a fleet's first ship's, a starbase's station's | `ship_design_implementation = { design growth_stage }`, the design's `growth_stages` | **[V]** |
| `is_ship_class = <class>` (ship, fleet) | `CIsShipClassTrigger` `0x1955ab0`: a fleet's `ship_class`; a ship's ship size's `class` (an unknown class reads as military) | `ship_class`; `common/ship_sizes` `class` | **[V]** fleet; ship **[I]** (the design's calculated class) |
| `is_ship_category = <category>` (ship, fleet) | `CIsShipCategoryTrigger` `0x1a20f30`: the ship size's `ship_category`; a fleet's first ship's | `common/ship_sizes` | **[V]** |
| `is_space_fauna = yes/no` (ship, fleet) | `CIsSpaceFaunaTrigger` `0x1a207c0`: the ship size's `IsSpaceFaunaShip` (bit 14 of `CShipSize +0xc8`); a fleet's first ship's; no ships: false | `is_space_fauna_ship` | **[V]** |
| `is_reanimated = yes/no` (ship, fleet) | `CIsReanimatedTrigger` `0x1a20a80`: the ship size's `IsReanimated` (65536) | `is_reanimated` | **[V]** |
| `is_cloaked = yes/no` (fleet, ship) | `CIsCloakedTrigger` `0x1a20280`: the fleet's Cloaked flag (bit 13); a ship: its fleet's (`SetIsCloaked` sets both) | `properties = { is_cloaked = yes }` | **[V]**; ship **[I]** |
| `is_mobile` / `is_civilian = yes/no` | `0x19bd0a0` / `0x1a1fc20`: the fleet's properties; a ship's ship size `is_civilian` | `properties = { mobile civilian }` | **[V]** |
| `is_disabled = yes/no` (fleet) | `CIsDisabledTrigger` `0x197a980`: disabled ships > 0 and at least all ships not killed | `cached_disabled_ships`, `cached_killed_ships` | **[V]**; a ship's flag is not read (a miss for ships would be false anyway: no combat) |
| `has_hp_percentage <op> x` (ship, fleet) | `0x1967400`: hit points over max hit points (a fleet: summed) | `hitpoints`, `max_hitpoints` | **[V]**; the fleet's max **[I]** (sum of ships') |
| `has_component = <component>` (ship) | `CHasComponentTrigger` `0x19ab850`: a component (or required component) of the ship's current growth stage | the design's growth stage `section.component.template`, `required_component` | **[V]** (economy/script.lua tested every stage) |
| `num_ships <op> n` (country, fleet, ship) | `CNumShipsTrigger` `0x1986be0`: alive ships (hit points > 0) of its fleets / the fleet / the ship's fleet | `fleets_manager.owned_fleets`, `ships`, `hitpoints` | **[V]** |
| `num_fleets <op> n` (country) | `0x1986a10`: its fleets, stations included | `owned_fleets` | **[V]** |
| `fleet_size <op> x` (fleet) | `0x196c210`: the ships' sizes' `size_multiplier`, summed | `common/ship_sizes` | **[V]** |
| `has_owner = yes/no` on a ship | `CHasOwnerTrigger` `0x1948730`: its fleet's owner exists | the fleet's owner | **[V]** (other scopes stay the property trigger's) |
| link `fleet` | token 11350: a fleet itself; a ship's fleet; a starbase's station's; a colony carried by a ship: that ship's | `fleet`, `station` | **[V]** |
| link `ship` | token 11472: a ship itself; a starbase's station; a colony's carrier when it is a ship | `station`, `carrier` | **[V]** |
| lists `owned_fleet`, `controlled_fleet`, `owned_ship`, `controlled_ship` | `COwnedFleetListBuilder` `0x1813f40` (every owned entry); `_ControlledFleets` as `PostGameStateReadInit` `0x917f20` rebuilds it (a normal entry is its owner's, a leased or lost one its `debtor`'s); the alive ships of those fleets (a fleet scope: its own) | `fleets_manager.owned_fleets = { { fleet ownership_status debtor } }` | **[V]** |

### Systems

| keyword | game | reads | marks |
|---|---|---|---|
| `has_hyperlane_to = <system / country>` (system) | `CHasHyperlaneToTrigger` `0x19ace80`: a system target: a hyperlane goes there; a country: it owns this system or one a hyperlane goes to (`CCountryBorderManager::CalcIsBorderingSystem`, the border cache fresh) | `hyperlane = { { to length } }`, system owners | **[V]**; the country form **[I]** (the border cache reduced) |
| `is_capital_system = yes/no` (system) | `CIsCapitalSystem` `0x1957830`: the system of its owner's capital | the owner's `capital` colony's carrier | **[V]** |
| `has_natural_wormhole = yes/no` | `CHasWormholeTrigger` `0x19b8d00` | `natural_wormholes` | **[V]** |
| `is_star_class = <class / system>` (system, planet, ship) | `CIsStarClassTrigger` `0x1953200`: the star class of the scope's system (a planet's own class is not used) | `star_class` | **[V]** |
| `is_inside_border = <country>` (planet, ship, fleet, system) | `CIsInsideBorder` `0x195c5e0`: the owner of the scope's system (a fleet's first ship; in FTL the last jump's origin) | system owners | **[V]**; the FTL fallback **[I]** |
| link `star` | token 10778: the star (`GetStarPlanetObject` `0x862bb0`: the system's first planet of a `star = yes` class) of a system, or of a planet's, ship's, fleet's, starbase's, megastructure's, ambient object's system | `planet`, `common/planet_classes` | **[V]** |
| link `space_owner` | token 16535: a country itself; a system's owner; a planet's, colony's, megastructure's, starbase's, archaeological site's system's owner; a fleet's (its movement coordinate, in FTL its last jump's origin); a ship's fleet's; a spy network's own `owner` | system owners | **[V]** |
| link `owner_or_space_owner` | token 16536: `owner` when it gives a country, else `space_owner` | | **[V]** |
| link `sector` | token 13120: a system's `sector`; a sector itself; any object in a system: its system's; leaders, countries, species: none | `sector` | **[V]** |
| link `sector_capital` | token 12955 (a sector): its `local_capital` colony, given as its planet (the simulation's scope for a colony) | `local_capital` | **[V]**; as a planet **[I]** |
| lists `neighbor_system`, `system`, `system_planet_colony`, `system_ambient_object`, `fleet_in_system` | `CNeighborSystemListBuilder` `0x18174c0` (hyperlanes in order, not deduplicated); `CSystemListBuilder` `0x1817340` (every system); the planets with a colony; the system's ambient objects; `_PrecalcFleetPresence` (`fleet_presence`, which `engine.fleets.movement` keeps) | | **[V]**; `system_planet_colony`'s order **[I]** |

A system's owner is its primary starbase's owner (the first `starbases` entry -> its station ship
-> that ship's fleet -> the fleet's owner), computed when asked.

### Planets, colonies, deposits

| keyword | game | reads | marks |
|---|---|---|---|
| `is_star`, `is_asteroid` = yes/no | `CIsStarTrigger` `0x195d510`, `CIsAsteroidTrigger` `0x195d970`: the planet class's IsStar / IsAsteroid; a ship, colony or other scope: `= no` holds | `planet_class`, `star = yes`, `asteroid = yes` | **[V]**; class keys **[I]** |
| `is_astral_scar = yes/no` | `0x1a0b120`: a planet's class IsAstralScar; other scopes false | `astral_scar = yes` | **[V]** |
| `is_ringworld`, `has_climate` | `0x195d7a0` (the carrier class's IsRingWorld), `CPlanetClimateTrigger` `0x1a09670` (its `climate`) | `ringworld = yes`, `climate` | **[V]** (economy/script.lua also took a class name with "ringworld") |
| `is_colonizable = yes/no` (planet, ship, colony) | `CIsColonizableTrigger` `0x19669b0`: a planet carrier without an owner whose class is `colonizable`; a ship carrier never; no carrier: false | `owner`, `colonizable` | **[V]** |
| `is_artificial = yes/no` | `CIsArtificalTrigger` `0x195dbe0`: the carrier class's `is_artificial_planet`; other scopes: `= no` | | **[V]** |
| `is_moon = yes/no` | `CIsMoonTrigger` `0x195cb50`: EPlanetFlags IsMoon (512) | `binary_flags` | **[V]** |
| `has_moon` | `CHasMoonTrigger` `0x195cd30`: the planet has moons; the trigger has no yes/no field, so `= no` is `= yes` | `moons` | **[V]** |
| `planet_size <op> n` | `CPlanetSizeTrigger` `0x1986400` | `planet_size` | **[V]** |
| `has_planet_modifier = <modifier>` | `0x19866a0`: among the planet's `planet_modifier` entries | | **[V]** |
| `num_modifiers <op> n` (planet, colony) | `CNumModifiersTrigger` `0x1962520`: the planet's timed modifiers (not its planet modifiers) | `timed_modifier = { items }` | **[V]** |
| `has_mining_station`, `has_research_station`, `has_orbital_station` = yes/no | `0x1971520`, `0x19719b0`, `0x1971e40`: the planet's orbital station fleet (of class mining / research / any); a ship or other scope: `= no` | `shipclass_orbital_station`, the fleet's `ship_class` | **[V]** |
| `has_observation_outpost = yes/no` | `0x1970e60`: the orbital station is an observation station | | **[V]** |
| `has_deposit = yes / no / <deposit>` (planet, ship, colony, deposit) | `CHasDepositTrigger` `0x1984910`: a deposit: its type, or whether it has resources; a carrier: a deposit of the type, or whether one has resources | `deposits`, `deposit.type` | **[V]**; "has resources" **[I]**: the type's `resources = { produces }` read as written, its produce triggers not evaluated |
| `has_strategic_resource = yes / no / <resource>` | `0x1954570`: yes/no as `has_deposit`; a resource: a deposit producing it; no carrier: `= no` | | **[V]** shape, the same **[I]** |
| `has_deposit_for = <ship class>` | `CHasDepositForTrigger` `0x1984ec0`: shipclass_starbase holds; an unowned colonizable planet or no deposits: none; else the first deposit's type's `station` | | **[V]** |
| `is_deposit_type`, `has_deposit_category`, `count_deposits = { type category count }` | `0x1983500`, `0x1983930`, `0x1993950` | `common/deposits` `category` | **[V]**; count_deposits' filters **[I]** |
| `num_uncleared_blockers <op> n` | `0x1a08ed0`: the carrier's deposits whose category has `blocker = yes` | `common/deposit_categories` | **[V]** |
| `original_owner = yes/no` | `COriginalOwnerTrigger` `0x19489e0`: the carrier's owner is its `original_owner`; no carrier or owner: `= no` | `owner`, `original_owner` | **[V]** (there is no `original_owner` link in 4.5.2) |
| `is_homeworld = yes/no` | `CIsHomeworld` `0x1957e00`: the carrier is the home of its owner's founder species; no carrier: `= no` | species `home_planet = { type reference }` | **[V]** |
| `is_terraforming = yes/no` | `0x1a09ca0`: the planet's terraform process | `scripted_terraform_process` | **[V]** reading; present = running **[I]** |
| `has_designation = <designation>` (planet, ship, colony) | `CHasDesignationTrigger` `0x1952050`: the colony's final designation | `final_designation` (`designation` is the manual one) | **[V]** |
| `has_building = yes / no / <building>` | `0x196cbc0`: yes/no: a zone of the colony holds a building; a type: one of the owner's buildings (ruined and disabled count) | `buildings_cache`, `districts` -> `zones` -> `buildings` | **[V]** |
| `has_active_building = <building>` | `0x196d160`: the same without ruined or disabled ones | `ruined`, `disabled` | **[V]** |
| `num_buildings = { type category value owner_type in_construction disabled limit }` | `CNumBuildingsTrigger` `0x196dbf0`: a type: its buildings (disabled as asked; in construction: the queued ones); `any`: the zones' buildings (of the category); a country or system: over its colonies, the limit in each | `buildings_cache`, zones, `construction` items `buildable_planet_building` | **[V]**; holdings and branch offices (owner types other than normal) are not counted **[I]** |
| `num_districts = { type value }` | `0x196f9a0`: `any`: the colony's district levels; a type: its first district of the type's level; a country: over its colonies | `districts`, `level` | **[V]** |
| `free_district_slots <op> n`, `num_free_districts = { type value }` | `0x197cc10`, `0x196f590`: `CColonyCarrier::CalcMaxDistricts` minus the district levels (with the queued ones for the second); a capped type: also under its cap; an uncapped type not there yet: free if its potential and allow hold | `engine.ai.economy.slots` (its port of CalcMaxDistricts and the caps) | **[V]**; the two "max districts add" helpers as `slots` approximates them **[I]** |
| `free_amenities`, `free_housing <op> n` | `0x197c050`, `0x197bdf0`: the colony's cached values, truncated | `free_amenities`, `free_housing` (`engine.colonies` / `engine.pops` keep them) | **[V]** |
| `free_jobs <op> n` | `0x1959b50`: vacancies of the jobs with a workforce, at least 0 | `pop_jobs` `workforce_limit`, `workforce`, `max_workforce` | **[V]** |
| `has_available_jobs`, `has_forbidden_jobs = <job>` | `0x1959f50`, `0x195ab10`: the colony's first job of the type: limit - workforce > 0 / limit < max | | **[V]** |
| `num_assigned_jobs = { job value }` | `0x199b750`: the pop amounts of the colony's first job of the type (a country's or system's colonies summed) | `pop_jobs.pop_groups.amount` | **[V]** |
| `last_district_changed`, `last_building_changed = <type>` | `0x196f090`, `0x196d450` | the colony's fields | **[V]**; the simulation does not set them yet when it builds |
| `has_ground_combat = yes/no` | `0x1958060`: the colony's `ground_combat` set | | **[V]** (no ground combat is simulated) |
| `is_sector_capital = yes/no` | `CIsSectorCapitalTrigger` `0x1957bf0`: the colony is its system's sector's capital; no colony: `= no` | `sector`, `local_capital` | **[V]** |
| `is_owned_by = <country>` | `CIsOwnedByTrigger` `0x194c930`: the scope's owner (the `owner` link) is the country | | **[V]** |
| links `orbital_defence`, `carrier`, `archaeological_site` | tokens 16303 (a planet's `orbital_defence` fleet), 17903 (a colony's carrier), 15661 (the site at the scope's spatial object, a system's at its star) | | **[V]** |
| lists `moon`, `deposit` | `CMoonListBuilder` `0x1814dc0`, `CDepositListBuilder` `0x1814b60` | `moons`, `deposits` | **[V]** |

### Pop groups, jobs, species

| keyword | game | reads | marks |
|---|---|---|---|
| `is_pop_category`, `pop_group_size`, `pop_group_has_trait` | `0x1977e60` (`key.category`), `0x19b3340` (`size`; another scope reads 0 and still compares), `0x196b790` (the species' traits) | | **[V]** |
| `is_robot_pop_group = yes/no` | `0x1994b30`: the species class's archetype is `robotic` | `common/species_classes`, `species_archetypes` | **[V]** |
| `is_unemployed = yes/no` (pop group, pop job) | `0x1978380`: the category's `is_unemployment_job` | | **[V]** |
| `has_job_type = <job>` (pop job) | `0x1a1ecf0` | | **[V]** |
| `has_ethic` of a pop group or leader | `CHasEthicTrigger` `0x194ab80`: the group's `ethos.ethics`; the leader's background `ethic` | | **[V]** |
| `has_trait` | `CHasTrait` `0x194b8c0`: a leader's traits; a species', pop group's species', country's founder species' | | **[V]** |
| `num_traits <op> n` | `0x1987760`: the same lists, counted | | **[V]** |
| `is_exact_same_species = <target>` | `0x194d510`: the same species object | | **[V]** |
| `ideal_planet_class`, `is_ideal_planet_class = { who status }` | `0x195f6c0`, `0x1968600`: the first of the species' traits with an `ideal_planet_class` | `common/traits` | **[V]** |
| `has_purge_type`, `has_living_standard`, `has_military_service_type = { type country }` | `CHasSpeciesRightsTrigger<...>`: the country's rights for the scope's species (by default its owner) | `E.species_right` (the rights module) | **[V]**; the base species recursion and the unread fallback are not modelled **[I]** |
| `is_scope_type = <type>` | `CIsScopeTypeTrigger` `0x19b2630`: the scope's EScopeType name (`galactic_object` for a system, `no_scope` for none) | | **[V]** |
| `army_type`, `is_ambient_object_type` | `0x1972320`, `0x19515a0` | `type`, `data` | **[V]** |

### Countries

| keyword | game | reads | marks |
|---|---|---|---|
| `is_nomadic = yes/no` | `CIsNomadicTrigger` `0x19b7410`: bit 11 (`IsNomadic`) of `CCountry +0x2a70 _Settings` | `is_nomadic = yes` (`Settings_WriteMembers` `0x6dd8f0`) | **[V]** |
| `has_covenant = <patron>` | `0x1a23960`: the shroud module's covenant's patron | `modules.standard_shroud_module.covenant = { patron level }` | **[V]**; the Shroud DLC check left out (no covenant without it) **[I]** |
| `has_crisis_level = <level>` | `0x1a1c790`: among the crisis progression's levels | `crisis_progression = { level }` | **[V]** |
| `resource_stockpile_percent = { resource value }` | `0x19adf80`: the stockpile over `GetMaximumForCountry` (the resource's max, dynamic capacity, max modifiers: `engine.economy.capacity`); no max: false; a max of 0: 42949.67295 | | **[V]** |
| `has_country_resource = { type amount }` | `0x198e780`: the stockpile, research from `tech_status.stored_techpoints` (physics, society, engineering) | | **[V]**; the resource converter path (nomads) not modelled: no country has one |
| `has_awareness <op> x`, `current_awareness_level <op> <level>` | `0x19744d0`, `0x1974790`: a primitive country's `awareness` (else false); stages < 1 none, < 30 low, < 60 medium, < 100 high, full | `awareness`; primitive: the country type's `faction = { primitive = yes }` | **[V]**; primitive **[I]** |
| `has_special_project`, `has_failed_special_project_in_log` | `0x199b010`, `0x19e5460`: a project of the key in `events.special_project` (failed: status aborted, failed, timed out) | | **[V]**; status names **[I]** |
| `has_event_chain`, `has_completed_event_chain_counter` | `0x1977850` (active chains only), `0x1979780` (an active chain's counter reached its max) | `events.event_chain`; counter values by the counter's position **[I]** | **[V]** |
| `has_edict = <edict>` | `0x197e730`: in `edicts`, no date check | | **[V]** |
| `num_ascension_perks`, `num_ascension_perk_slots` | one class, `0x19a8240`: the perks adopted (the documentation's "slots" is wrong) | `ascension_perks` | **[V]** |
| `num_rare_techs`, `has_tech_option`, `can_research_technology` | `0x198fe60` (`is_rare` techs), `0x1954d90` (in the area's `tech_status.alternatives`), `0x72ebb0` (prerequisites recursively, then the technology's `potential`) | | **[V]**; the country type's research-anything flag not read **[I]** |
| `has_active_tradition = <tradition / swap>` | `0x19a7500`: adopted, and its tradition swap for the country (the first whose trigger holds): the swap named, or with the tradition named none applies or it inherits the effects | `traditions`, `common/traditions` `tradition_swap` | **[V]** |
| `num_tradition_categories`, `category_last_picked_tradition` | `0x197eb30`, `0x1a23160` | `tradition_categories`, `last_picked_tradition`, `common/tradition_categories` | **[V]** |
| `has_election_type` | `0x195bb10`: the election type of the authority's `advanced_authority_swap` that applies, else the authority's | `government.authority` | **[V]** (ethics/script.lua had no swaps) |
| `has_pre_ftl_age`, `has_notification_modifier`, `has_valid_ai_personality`, `is_preferred_patron`, `is_preferred_weapons` | `0x195e4d0`, `0x19abb30`, `0x1957600`, `0x1a25530`, `0x199f4c0` | `preftl_age`, `notification_modifiers`, `personality`, `is_preferred_patron`, `ai_weapon_preference_override` / personality `weapon_preferences` | **[V]**; `is_preferred_patron`'s field form **[I]** |
| `galaxy_percentage`, `num_cosmic_storms_encountered`, `empire_size` | `0x19962c0` (owned systems over all), `0x19ba810`, `0x1985850` | `empire_size` is the save's cache (`engine.research` reads it the same; not recomputed yet) | **[V]** |
| `has_active_event` | `0x19b2260`: an open player event of the ids for the country | top-level `player_event` | **[V]** |
| `has_faction` | `0x198b530` | `pop_factions` `country`, `type` | **[V]** |
| `has_ai_expansion_plan = yes/no` | `CAIHasExpansionPlans` `0x19aff20`: the AI's EXPAND_BORDERS (19) list is not empty | `ai = { strategy = { type } }` as `engine.ai.strategy` builds it monthly | **[V]** |
| `is_in_domain`, `has_patron_relation` | `0x1a248c0`, `0x1a22650`: need the Shroud DLC (bit 30 of `_DLCMask`), not installed nor in the saves: false | | **[V]** (the geometry with the DLC is a miss) |

### Galactic community, galaxy setup, situations, federations

| keyword | game | reads | marks |
|---|---|---|---|
| `is_galactic_community_member`, `is_galactic_custodian`, `is_galactic_emperor`, `has_galactic_emperor`, `has_galactic_custodian`, `is_part_of_galactic_council`, `is_galactic_council_established`, `galactic_community_rank`, `imperial_authority` | `0x1a044c0`, `0x1a07170`, `0x1a07250`, `0x1a07440`, `0x1a07330`, `0x1a04830`, `0x1a063e0`, `0x1a06920`, `0x1a07080` | `galactic_community = { members leader empire council council_established imperial_authority }` | **[V]**; no community forms in the saves |
| `is_active_resolution = <resolution>` (any scope) | `0x1a064d0`: the newest passed resolution of the type, unless a newer one of its category supersedes it, and its `can_be_active` | `galactic_community.passed`, the `resolutions` store | **[V]**; the store name and the trigger's scopes **[I]** |
| `galaxy_size`, `num_guaranteed_colonies`, `is_difficulty`, `check_galaxy_setup_value = { setting value }` | `0x19b4fc0`, `0x1959200`, `0x19776d0` (EDifficulty civilian 0 .. grand_admiral 6), `0x196b4c0` (the setup's value; mid/end game and victory years -1: 100/200/300) | the save's `galaxy` block | **[V]** |
| `is_situation_type`, `current_situation_approach`, `current_stage`, `situation_progress`, `situation_monthly_progress` | `0x19c1630`, `0x19c2010`, `0x19c1970` (the type's stage at `stage`), `0x19c10e0`, `0x19c1470` | `type`, `approach`, `stage`, `progress`, `engine.situations`' monthly progress | **[V]** |
| `has_federation_type`, `has_federation_law`, `has_any_federation_law_in_category`, `has_federation_perk`, `federation_cohesion` (federation) | `0x1a17fa0`, `0x1a18a20`, `0x1a18c10`, `0x1a181b0`, `0x1a17d60` | `federation_progression = { federation_type laws perks = { { type } } cohesion }` | **[V]** (economy/script.lua compared the perk blocks themselves: never true) |

### Leaders, councils, factions, sites

| keyword | game | reads | marks |
|---|---|---|---|
| `is_councilor_type = <type>` | `0x19bed10`: a council position of its country's government held by the leader has the type | `government.council_positions`, `council_positions` | **[V]** |
| `is_councilor = yes/no` | `0x19beb90`: the ruler, or `council_location = { type = council_position id }` | | **[V]** |
| `is_heir = yes/no` | `0x19bea00`: `government.heir` | | **[V]** (economy/script.lua read a country `heir` that does not exist, then guessed from a trait) |
| `is_immortal = yes/no` | `CLeader::IsImmortal` `0x895700`: the Immortal flag (2), a trait with `immortal_leaders`, the game rule `are_all_leaders_forced_immortal` | `leader_flags`, `traits` | **[V]**; the species' traits **[I]** |
| `has_envoy_task = { task target }` | `0x1989020`: the location's assignment, and its country with a target | `location = { assignment id }` | **[V]** assignment, target **[I]** |
| `support <op> x` (pop faction, leader) | `0x198b8c0`: `support_percent`; a leader: its country's factions of its ethic | | **[V]** |
| `is_pop_faction_type`, `is_faction_extorted`, list `pop_faction`, list `envoy` | `0x198ba50`, `0x1994a30`, `0x1814fb0` (a country's factions), `COwnedEnvoyListBuilder` `0x18144d0` (its leaders whose class has `can_be_envoy`) | | **[V]** |
| `is_site_completed = yes/no` | `CIsArchaeologicalSiteFinishedTrigger` `0x1a10c00`: the site's stage index reached its type's stage count | `index`, `stage` blocks | **[V]**; the keyword-to-class tie **[I]** |
| lists `archaeological_site`, `galaxy_species`, `spynetwork` | every site; every species; a country's spy networks, else all | | **[V]** |

### Any scope, logic, values

| keyword | game | marks |
|---|---|---|
| `is_scope_valid = yes/no` | `0x1990b20`: the scope object exists | **[V]** |
| `check_variable_arithmetic = { which <ops> value }` | `0x1969910`: `which`, then add / subtract / multiply / divide / modulo / min / max in order, compared with `value` | **[V]**; the operation set **[I]** (engine/ethics/script.lua's own counts councilors itself while the ethics run) |
| `switch = { trigger <case> = { } default = { } }` (trigger) | `CSwitchTriggerBase<0>` `0x19f18b0`: the first case whose `<trigger> = <case>` holds, else the default (none: true) | **[V]**; the empty default **[I]** |
| `trigger:<name>` | eval.lua's numeric triggers (`years_passed`, `mid_game_years_passed`, `end_game_years_passed`, `days_passed`, `has_base_skill`, `fleet_power`, `num_owned_planets`), every `numeric` one here, and a scripted trigger made of one count iterator (`trigger:pop_amount`: its count, as eval compares it **[I]**) | **[V]** |
| `pow = x`, `round_to = x` | `ipow` as above **[V]**; `CFixedPoint::RoundTo`, the nearest multiple **[I]** | |

## Not implemented, and why

- **Diplomacy** (the other agent's area): `recently_lost_war`, `any_war`, `any_rival_country`,
  `trigger:num_non_aggression_pacts`, `years_of_peace`, `is_hostile_to`, `is_domineering_to`,
  `is_rival`, `is_neighbor_of`, `has_potential_claims`, `highest_threat`, `is_at_war`, and the
  attitude, agreement, espionage and intel triggers.
- **Effects** (the other agent's area): `add_experience`, `set_surveyed`,
  `run_ai_strategic_war_data`, `add_monthly_resource_mult`, `create_ambient_object`,
  `destroy_ambient_object`, `remove_modifier`, the effect `switch`, `last_created_ambient_object`.
- **Engine state the simulation does not model** (a miss, not an answer):
  - `can_be_upgraded` on ships, fleets and megastructures: `CShip::CanBeUpgraded` /
    `CFleet::HasShipsThatCanBeUpgraded` walk the design upgrade chain
    (`CShip::CalcLatestUpgradableDesign`: the country's designs and components), which the
    simulation does not have (the ship designer is not ported); the megastructure's
    `IsUpgradeableFrom` / `CanQueue` were not read. 3,673 hits in 180 days, from the AI budgets'
    `any_owned_fleet = { can_be_upgraded = yes }`.
  - `ai_colonize_plans`: the AI's COLONIZE list is the save's (`AddColonyData`, the synced AI draw,
    is not ported in `engine.ai.strategy`), stale after the first month. Answering it from the
    stale list moved minerals and influence closer to the game but alloys and ships away; it
    answers by itself once `engine.ai.strategy` builds the list (`strategy.PORTED[1]`).
  - `distance` with the hyperlane distance or jumps (`CGalacticMapCache`'s all-pairs cache, its
    builder not read) and `same_solar_system` (the in-system coordinates); `bypass_empire` needs
    the country's bypass access. Euclidean distances are answered.
  - `is_in_combat`: combat is not simulated. `has_intel`, `is_spynetwork_level`, intel levels:
    espionage and intel state (and another area).
  - `fromfromfrom`: the evaluation context keeps `from` and `fromfrom` only (`simscript/eval.lua`).

## Results

From sim-engine 5f77db5 to this branch (2026-10-14, 10.5.0.24):

| gate | before | after |
|---|---|---|
| 180-day diff (`examples/diff autosave_2210.01.01.sav t1798.gamestate`) | 723,380 equal / 13,251 differ, 4,725,089 draws | 723,463 equal / 13,050 differ, 4,724,681 draws (the game: 4,755,436) |
| standard A, 1 month | 733,836 / 5,318, 778,614 draws | 733,846 / 5,308, 778,614 draws |
| standard A, 6 months | 723,330 / 13,306, 4,725,081 | 723,469 / 13,059, 4,724,678 |
| standard A, 1 year | 708,696 / 22,129, 9,509,367 | 709,029 / 21,631, 9,507,098 (the game: 9,577,199) |
| not implemented, hit in 180 days | 78 keywords, 141,232 hits | 21 keywords, 6,599 hits (diplomacy, effects, and the two misses above) |
| reads the save does not answer | 25 kinds | 2 (`country.is_at_war`, `modifier`) |
| `STELLAR_SCRIPT_CHECK=1`, 180 days | 0 mismatches | 4,650,824 compared, 0 mismatches |
| `STELLAR_MODIFIER_CHECK=1`, 180 days | 0 differ | 7 rebuilds, 771,585 values, 0 differ |
| `cargo test --release` | passes | passes |
| vanilla trigger uses evaluated (`simscript.coverage`) | 174,015 of 203,154 (85.7%) | 189,880 of 204,232 (93.0%) |
| documented triggers / scope links evaluated (`surface_probe.lua`) | 238 / 23 | 399 / 33 |

What moved the 180-day diff (measured with `STELLAR_RUNTIME_OFF`):

- `can_be_upgraded` with `used_starbase_capacity_percent` (each alone does nothing: the AI budgets'
  starbase expenditure reads both): +66 equal, -154 differ; minerals 56.4% -> 67.8% of the game's
  change explained, influence -5.0% -> 21.5%; country +52, fleet +35, ships +5 equal; the
  construction items -9 equal (the AI's queue progress, now saving for upgrades) and colony -19
  (pop growth figures). 409 fewer draws (fewer ships built).
- The rest of the vanilla keywords: +6 equal, -36 differ.
- `E.system_of` for fleets (fleet events reach their systems): +11 equal, -11 differ.
- `ai_colonize_plans` from the save's stale COLONIZE list was tried and left out (above).

The equal fields that went down (colony -19 to -23, construction items -9, situations, contacts:
a few each) follow AI decisions that now read the game's triggers, with stockpiles closer to the
game's; the draws moved by -408 against a gap of 30,000 to the game.
