# Script coverage: fleets, ships, armies, designs, combat

The `fleet` package of [script_coverage.md](script_coverage.md): 214 keywords. The handlers are
in `sim/lua/simscript/handlers/`:

- **`fleet.lua`**: the iterator lists and scope links.
- **`fleet_triggers.lua`**: the triggers.
- **`fleet_effects.lua`**: the effects that change fields: hit points, armies, removal, orders, stances, MIA, leases, rights.
- **`fleet_create.lua`**: the effects that make fleets, ships, armies and designs.

Their engine appliers are in `sim/lua/engine/fleets/script.lua`: `create_army` and
`create_ship_design`. Fleets and ships are made through the objects module's `create_fleet`,
`create_ship` and `set_fleet_owner`.

Each handler's comment says what it reads and writes. **[V]** marks what the 4.5.2 Linux binary's
class shows. **[I]** marks what comes from the documentation and the save's fields.

## The world they read

| object | where |
|---|---|
| ships | `ships`: hit points, `ship_design_implementation`, `disable_at_health`, `is_being_repaired`, `growth` |
| fleets | `fleet`: `ships`, `movement_manager.orbit.orbitable`, `combat.in_combat_with`, `auto_movement`, `settings`, `aggro_range`, `mia_type`, `return_date`, `contract` |
| armies | `army`: `owner`, `colony`, `ship`, `type`, `health`; the country's `owned_armies` and the colony's `army` list them |
| ground combats | `ground_combat`: `attackers` and `defenders`, made by `engine.fleets.armies` |
| designs | `ship_design`; a country's own are in `ship_design_collection.ship_design`, the global ones in `ship_designs.global_ship_design` |
| planets | `shipclass_orbital_station` and `orbital_defence` (fleets), `orbit` |
| colonies | `army` and `carrier = { type reference }` (a ship colony's carrier) |

A design scope is `ship_design`; the checker also calls it `design`. A growth stage scope is
`ship_growth_stage`, with the id `"<design>/<stage>"`.

## Shared iterator parameters

`eval.lua`'s iterators now read the documented `weights` of `random_*` and `inverse` of
`ordered_*`:
- `weights`: one draw over the elements' summed `M.weight` [I the draw].
- `inverse`: the lowest first.

Before this, the body walker treated both as effects. That made every package's `random_*` and
`ordered_*` example "missing".

## Not modelled, or approximated

These are noted in the handlers [I]:
- **Combat states.** `has_status` (the colossus), `confused` and `terrified_by` are stored as fields only. Nothing reads them yet.
- **Leases.** They are a fleet `contract = { controller end_date }`. The controller does not change hands.
- **MIA.** `set_mia` sets `mia_type` and `return_date` (the MIA type's `days`). The movement while MIA is not modelled.
- **Fleets made by script.**
  - `create_military_fleet` sizes the fleet at a tenth of the owner's naval capacity × `scaled_size`.
  - `create_balanced_fleet` and `create_fleet_from_naval_cap` fill by `size_multiplier`, each ship going to the design furthest under its `ai_ship_data.fraction` share.
- **Designs.**
  - `create_ship_design` copies the global design. The FTL drive of the `ftl` country is not applied.
  - `rebuild_owned_starbase_designs` and `refresh_auto_generated_ship_designs` only set `ship_designs_dirty`, because the designer is not ported.
- **Killed ships.** `num_killed_ships` reads a country's `killed_ships = { { country count } }`, which nothing writes yet.
- **Damaging countries.** `first_`, `second_` and `third_damaging_country` read a fleet's `damaging_countries`, which nothing records yet.

## Checker results on the 2210.01.01 save

**Statically**, every keyword of the package has a handler.

**Dynamically:**
- 74 triggers evaluated.
- 42 effects acted.
- 33 iterators ran as containers.

**Silent (36 effects).** The docs mod's example names `from`, which the checker's context does not
set, or the scope's first object is the wrong kind. Planet 0 is a star, with no colony; fleet 0
is a starbase; ship 0 is a starbase's station. The game would do nothing for these either.

**Refused (1).** `set_fleet_stance = aggressive` on that immobile starbase fleet, as in the game.

**Missing (1).** `create_random_fleet`: its example's size is a script value using
`complex_trigger_modifier`, which is the general area's.

The links show `missing` dynamically for every link that resolves. The checker runs
`sdc_links.txt`'s uses as an effect block, so their `always = yes` counts as a missed effect.
`capital_scope`, `leader` and `planet` show the same.
