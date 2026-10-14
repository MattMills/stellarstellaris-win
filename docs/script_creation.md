# Script effects that create or change things

The script layer's effects that make or change world objects, the event machinery's random
model, and the save's event state. GOG 4.5.2 exe + PDB is the reference; [V] = verified against
the disassembly or the standard saves, [I] = inferred or approximated.

Code:

- `sim/lua/simscript/handlers/creation.lua`: the script side (EFF entries, scope random wiring).
- `sim/lua/engine/script/creation.lua`: the engine side, the appliers in `engine.systems.effects`,
  applied at the barrier (`E.flush`) in the save's own form.
- `sim/lua/engine/script/scope_random.lua`: the scope random (CEventScope's CNoiseRandom).
- `sim/lua/engine/script/event_save.lua`: delayed events and global event targets in the save.
- `sim/lua/simscript/events.lua`: event firing, options, on_actions, delayed events.

## Scope random [V]

Each CEventScope holds a random state at +0x68 (position) and +0x6c (seed), written to the save
as `random = { seed position }`. A draw is `noise32(position, seed)`, then the position advances.
H(x) = noise32(x, 1587985055).

- Default constructor (CEventScope::Init(0)): position H(0) = 3991148998, seed 0.
- Constructor from an int x: position H(x), seed 0. A fresh scope seeded from a draw uses this.
- Child scopes (scope changes, `CEventTarget::GetScope` / Copy) copy the parent's state; the
  draws a child makes do not advance the parent.
- `every_*`: the iteration runs on a copy of the scope's state; for each element the position
  becomes H(position + 1) and the element's scope gets that state.
- `random_*` iterator: one draw from the loop copy, `% n`.
- `random = { chance = }`: draw % 100 < chance (CIntVariableValue, default 0, no modifiers).
- `random_list`: integer weights (the fixed-point weight after modifiers, truncated);
  draw % total, then subtract the weights in order until the value goes below 0.
- `locked_random_list`: the scope's position read as an int32, no draw.
- A fired event's scope (CFireEventEffect::InitializeScope): position H(draw(current) + this.id);
  each entry in `scopes` costs one more draw (a from scope built with the int constructor).
  A delay with `random = n` adds draw(current) % n days.

Checked against country.258's chain in standard A's saves.

## Global draws the event machinery makes [V]

These all come from the game's global stream (`RUST.rand`):

- The AI's option choice: draw % 100 against cumulative percentages
  pct = trunc(chance * 100000 / (total / 100)) / 100000, picked when r <= cumulative.
- on_action `random_events`: valid events plus the empty `0` entries, draw % total.
- Pulses: CCountry::MonthlyUpdateSerial makes one draw per living country.
  on_monthly_pulse makes one draw. YearlyUpdate makes one draw for the global pulses and one
  per country with `has_pulse_events`. Only country types with `has_pulse_events = yes` get
  country pulses (the default, plus shroud).
- Human countries take their first valid option without a draw [I]. The game waits for the
  player; the headless oracle has no humans.

## Delayed events [V]

CDelayedEventManager: DailyUpdateThreaded counts down from the end of the list, fired entries
are removed with SwapToTailRemoveAt, and the serial pass fires them after a trigger check. AddEvent
copies the scope with its from chain (TrimFroms 7). The save's delayed events are loaded:
a country's are in `modules.standard_event_module.delayed_event`, a planet's in `delayed_event`.
They load with their scope blocks (type, id, random, root, from, saved_event_target), and their
due day counts from the save's date. New ones are written back in the same form, `days` is kept up
to date, and fired ones are removed. The top-level `saved_event_target` entries become the global
event targets.

## Modifier timing [V]

CRootEffect::Execute ends with CModifierNodeManager::Update. After an event's immediate, option or
after block, `creation.after_root_effect` rebuilds the modifier graph
(`engine.modifier_source.rebuild`) when a timed modifier or a planet class changed. Without this,
the change would wait until the month's update.

## Effects

| effect | semantics | draws |
|---|---|---|
| `add_deposit` | CGameState::CreateNewDeposit. Holder: planet type 0, astral rift 1, ship 2 (an unknown holder is skipped). The id comes from the deposit store's free list (the save's `id = none` slots ascending, freed slots pushed to the front; the first new id is 16777321, matching the game [V]). The block is `{ type [swap_type] deposit_holder = { type id } }`, the id is appended to the holder's `deposits`, and `carrier_binary_flags \|= 2` when the deposit has a country or habitat modifier. | blocker swap: draw % n. Weighted or `_Randomize` modes are pushed as unmodelled. |
| `remove_deposit` | Removes the scoped deposit, or the holder's first deposit of that type. Sets the holder's carrier flag. | none |
| `clear_deposits` | Deletes every deposit of the holder without setting the flag. | none |
| `add_monthly_resource_mult` | CalcGained: last month's income × value, clamped to min/max and the stockpile floor, × mult (default 1.0), rounded half away from zero. Research goes to `tech_status.stored_techpoints`; other resources go to the stockpile within `economy.capacity`. | none |
| `add_modifier` (timed) / `remove_modifier` | days/months/years as ints, multiplier, time_multiplier, clear_on_owner_change. Adding keeps the larger day count and sets the multiplier. Holders: a colony maps to its planet, a fleet to its ships unless it is a starbase or station. An unknown static modifier is a miss. | none |
| `add_opinion_modifier` / `remove_opinion_modifier` | The owner's `relations_manager` relation (a minimal one is created if needed). Accumulative/unique, `months` sets `date`, decay sets `start_date`, min/max. Removal swaps with the last entry. | none |
| `change_pc` | CPlanet::SetPlanetClass; fires `on_planet_class_changed` (scope seeded from the draw). | 1 |
| `set_surveyed` | Adds or removes the surveyed state through `engine.fleets.survey`; also takes the system form. | none |
| `add_timeline_event` | Appends `{ date data types definition }` to the country's `timeline_events`. | none |
| `export_trigger_value_to_variable` | Bisects fresh `<trigger> > v` blocks. A trigger with parameters is a miss. | none |
| `begin_event_chain` / `end_event_chain` / `add_event_chain_counter` | In the country's `events` block, with a scope block (`event_save.ctx_block`). The counter's form is `counter = { key = value }` [I]. | none |
| `enable_special_project` | `next_special_project_id`, the scope, a coordinate (planet type 2, ship 1, system 0 [I]), the carrier, and `ai_research_date`. | draw % AI_COMMUNICATIONS_RANDOM_VALUE |
| `abort_special_project` | Removes the project and its research. | none |
| `set_site_progress_locked` | The site's `locked = yes` [I]; for a first contact, the contact's status. | none |
| `add_experience` | CLeader::AddExperience through `engine.leaders`. | none |
| `random`, `random_list`, `locked_random_list`, `switch`, `inverted_switch` | Scope random as described above. | scope |
| `run_ai_strategic_war_data` | No-op (an AI data refresh). | none |

## Not done, and why

- `create_leader`: the 24-96 calls in the test runs are spurious. The `is_councilor_type` trigger
  is not implemented (the runtime-trigger area), so paragon.605 fires for gestalt countries. These
  calls stay queued and unapplied. The real CreateLeader chain (anonymous 0x1768180) is not ported.
- `add_trait` / `remove_trait` (leaders): reverse-engineered but not implemented:
  - CLeader::AddTrait and IsForceAddLeaderTraitPossible check is_opposite_of, already_exists,
    has_better_version (the `_pNextTier` chain from `replace_traits`), the leader class, and the
    game rules can_leader_get_council_trait / can_leader_get_normal_trait.
  - The trait's replace_traits are removed, then the new trait is inserted in sorted order.
    CTrait::TraitSorter sorts by sorting_priority descending, subclass type first, councilor
    traits first, cost 0 first then higher cost first, then index.
  - consume_selection decrements `available_trait_selections`. With none left, the picks are
    cleared.
  - on_gained_effect costs one global draw and runs in a scope at H(draw).
  - Both effects end with CLeader::RerollInvalidTraitPicks, which calls AssignTraitPicks when the
    leader has `available_trait` picks. Trait picks are not modelled, so leaders with picks need
    that first.
  - `ETraitFlags` bit 14 = force_councilor_trait; ELeaderTraitType is basic 0, veteran 1,
    subclass 2, destiny 3, negative 4. `remove_trait = all_negative` removes the type-4 traits.
- `create_fleet` / `create_ship` / `create_army` / `set_owner` / `set_location`: reverse-engineered
  only partly:
  - CCreateFleet::ExecuteActual calls CreateNewFleet (no owner), then SetUpFleet (the name), then
    RunPostCreationEffect. RunPostCreationEffect makes one draw from the scope to build the
    fleet's own scope, runs the `effect` block in it, then InvalidateModifier and
    UpdateCachedValues.
  - The ship and fleet constructors exist in `engine/fleets/create.lua`. CCreateShipEffect,
    set_location (positions and their draws) and CFleet::ChangeOwner are not ported.
- MTTH events are not ported (CStandardEventCountryModule's pool stream).
- Species traits (modify_species), `create_pop_group`, and the random deposit modes are not ported.
