# Script coverage: the economy package

`sim/lua/simscript/handlers/economy.lua` implements the 47 keywords of the economy package
(docs/script_coverage.md). They cover:

- the stockpiles and budgets;
- the galactic and internal markets;
- the slave market and slavery;
- trade deals and the enclaves' special trades;
- resource converters and trade conversions;
- the cosmic storms' influence fields.

`sim/lua/engine/market.lua` holds what the market and stockpile keywords share:

- the market's state and prices;
- the budget sums;
- the storage maximum and the stockpile writer;
- the resource converter.

Each handler's comment names the game's class in the Linux 4.5.2 build and its address. The tags mean:

- **[V]** read in the binary (`/opt/stellaris-headless/re` on 10.5.0.24);
- **[I]** inferred from the documentation and the save's fields.

The reverse-engineering notes are `code_working/tmp_sim/cov_market_re.md` and `cov_economy_re.md`. The
handlers write the save's own fields, so a save written after them carries the change.

Fixed point is the game's: values are kept in 1/100000 units, and multiplication and division truncate.

## The market

The market is the top-level `market = { ... }` (CMarket). A country's index is its id's low 24 bits.

| keyword | what it does | source |
|---|---|---|
| is_on_market | `galactic_market_resources[index] == 1`. Any scope; neither the market's `enabled` nor the scope's access is read | [V] |
| can_buy_on_market | CMarket::IsValidResource for buying. The resource must be tradable (a market amount and price, its `tradable_in_market` trigger). Without a country: on the galactic market. Then the converter's can_buy (its `override_trade_restriction` makes it valid). With access: on the galactic market. On the internal market: this month's income of it above 0, else its expenses | [V; I: the resource flag that allows the expenses] |
| is_market_leader | `market.country` is the scope. A scope that is not a country is false for both yes and no | [V] |
| market_resource_price | CalcResourcePriceForAmount. `amount` defaults to 1 and `trade_type` to not_set. not_set has no fee, and its base amounts after the first are at the plain price; market_buy adds the fee and market_sell takes it off | [V] |
| enable_on_market | sets `galactic_market_resources[index] = 1`. When the market is not founded (no `enabled = yes`), it does nothing (the game logs it) | [V] |
| set_market_leader | yes: `market.country` = the scope; no: 4294967295, whoever led | [V] |
| enable_galactic_market | the scope's access (SetGalacticMarketAccess). `galactic_market_access` and `id` grow to its index, `id[ci]` = the country, access = 1 or 0. The market's own `enabled` is the daily update's, once the flag galactic_market_founded exists | [V] |
| is_on_slave_market | the pop group's id among `slave_market_manager.slaves_on_market`; the amount is not read | [V] |
| trade_action_value | the first deal in the scope's `trade_deals` that has with_country on either side and that side's `actions` holding the action. The value is that side's `action_value` | [V] |
| get_trade_data / make_special_trade | these act only while the AI weighs an `ai_trade_facility` option, which is not modelled. Anywhere else the game logs an error and does nothing, and so do the handlers | [V] |

## Budgets

Each country's `budget = { current_month last_month }` has `income`, `expenses` and `balance` per economic category, plus `trade_income`, `trade_expenses` and `trade_balance`. A sum adds both blocks over all categories or over one.

| keyword | value | source |
|---|---|---|
| income | last month's gross energy income | [V] |
| resource_revenue_compare | this month's gross income, of the category or the total | [V] |
| resource_income_to_expenditure_balance_ratio | this month's balance (net, not the gross income of the docs' text) over its expenses, truncated. No expenses gives 2814749767.10655 | [V] |
| export_resource_income_to_variable | this month's balance | [V] |
| export_resource_maximum_to_variable | GetMaximumForCountry: the resource's `max` with its dynamic capacity and the max modifiers (engine.economy.capacity) | [V] |
| export_resource_stockpile_to_variable | the stockpile | [V] |

### Trigger values

`complex_trigger_modifier` uses numeric triggers as values (`eval.TVAL`). Each value function returns the number the trigger compares, and its parameters block is the trigger's:

- market_resource_price, resource_revenue_compare, resource_income_to_expenditure_balance_ratio, ship_size_cost_resource_percent, income, trade_action_value and the stockpile triggers below are defined with their triggers.
- has_monthly_income, resource_income_compare, resource_expenses_compare, has_resource and resource_stockpile_compare are implemented in eval.lua. Their values here use the same readers (E.budget_sum, E.resource): last month's balance, this month's balance, this month's expenses, and the stockpile of the scope's country.

## Stockpiles

| keyword | what it does | source |
|---|---|---|
| set_resource | the value is set exactly, then every resource is kept within [0, its max]. A converter's `should_cap = no` resource has no max | [V] |
| clear_resources | every resource is set to 0, also with `= no` | [V] |
| add_resource_from_debris | the resources (x mult) are added to the stockpile, within its max. The debris notification is the interface's | [V] |
| transfer_resources_to_empire | the percentage is clamped to [0, 1] and defaults to 1. For each listed resource, stockpile x percentage (truncated, above 0) goes to the target within its max; the scope loses all of it | [V] |
| add_resource_to_local_stockpile | ships only: a fleet scope does nothing in the game, though the docs list it. A ship that can store gets the table (x mult). A waystation's station keeps each resource within its own max; any other ship fills in resource order up to its total capacity | [V] |
| transfer_resource_stockpile | the ship's stockpile (x mult) goes to a country (within its max) or to a ship that can store, then the ship's stockpile is cleared | [V; I: a target that cannot take it leaves the ship's stockpile] |
| used_stockpile_capacity_percentage | a ship's (a starbase's station's) used share: total over capacity, in [0, 1]. A waystation uses its largest share of a resource's max, and 1 for a resource with no max or over it | [V] |
| waystation_network_stockpile_used | the largest used share of the waystations in the starbase's network; 0 outside a network | [V] |

The ship fields are:

- `ships.<id>.resources`;
- the ship size's `collects_stockpile_from`, `collects_stockpile_to_country` and `ship_stockpile_capacity`;
- `ship_stockpile_capacity_add/_mult`, and for waystations `starbase_stockpile[_<r>]_capacity_add/_mult`.

IsWaystation is the starbase type's `is_waystation` (common/starbase_types). It reads the object at
starbase +0x13b8 [V]; that this object is the type is [I], from the starbase_levels documentation. In
the game, `set_starbase_size = starbase_waystation_1` on a shipyard leaves the type sshipyard, and its
station stores nothing.

## Converters and trade conversions

- **set_resource_converter:** sets the economy module's `resource_conversions = "<key>"`; `none` removes it. It then removes the country's monthly trades the new converter cannot make. [V]
- **set_trade_conversions:** replaces `trade_conversions` with the table's non-zero entries. [V]

The budget books the net trade out and each listed resource in at trade x its fraction. A `trade` entry is what keeps a share as trade; there is no automatic remainder. [V core, I categories]

## Deposits and the colony economy

- **num_energy / num_minerals:** the carrier's deposits' produced amount (the deposit types' `produces`). This is not the colony's economy. [V]
- **has_any_strategic_resource:** a deposit of the carrier produces anything, any resource. [V]
- **planet_resource_compare:** the colony's economy, its units and its pops' jobs (engine.economy's colony tables): produces, upkeep or balance (the default). [V]
- **ship_size_cost_resource_percent:** the resource's share of the ship size's cost table. The game reads it from a block (`= { resource = <key> value ... }`) and the handler also takes the docs' `= <key>`. [V]

## Slavery

The rights are the country's `modules.standard_species_rights_module`. The founder species uses `primary`, the built species uses `built_species`, and the others are in `species_rights`.

- **set_slavery_type:** changes the species' rights in the country (`country`, else the scope's owner). `last_changed_value = slavery` is set even without a change. On a change, `former_slavery` gets the old type and `slavery` the new one. `cooldown = yes` sets `last_changed_slavery_type` to today + SPECIES_POLICY_YEARS. [V]
- **former_slavery_type:** `former_slavery` in the pop owner's rights for its species. [V]
- **enslaved_species lists:** the saved `enslaved_species_refs` of the country, or of the colony of the planet, colony or ship. [V]

## Influence fields

The fields are the top-level `storm_influence_fields = { storm_influence_fields = { <id> = { center radius influence is_timed_influence_field storm_influence_groups } } }`; each system lists its fields. A field has no owner of its own.

- **owned_storm_influence_field lists:** the fields whose center system the country owns. [V]
- **storm_influence_field (link):** the last field in the system's list that is centred on it. [V]
- **is_influence_center:** a field centred on the system that is not timed. The docs' text belongs to another trigger. [V]
- **recalculate_storm_influence_field:** refreshes per-system totals that are not saved, so the save does not change. [V]

## Checked

The checker (docs/script_coverage.md) on autosave_2210.01.01 gives these results for the package:

- 26 evaluated, 11 acted, 6 containers.
- Six effects are silent, and the game would change nothing either:
  - `enable_on_market`: the galactic market is not founded.
  - `add_resource_from_debris`: the use's `mult = sdc_var` is an unset variable, so ×0.
  - `add_resource_to_local_stockpile` / `transfer_resource_stockpile`: no ship in the save can store resources.
  - `get_trade_data` / `make_special_trade`: outside the AI's trade-facility evaluation.
- `recalculate_storm_influence_field` and the `storm_influence_field` link have no field in the save, so the checker cannot run them.
- The docs mod skips `ship_size_cost_resource_percent` (its block form).

The same uses were run in the headless game (`console Effect`, then `save`; scripts
`/root/cecon/g1.txt`, `g2.txt` on 10.5.0.24) and in the sim (`/root/cecon/probe.lua`, `probe2.lua`).
The trigger values went through `export_trigger_value_to_variable`. These match the game:

- **income:** 113.71973.
- **market_resource_price:** energy 100 gives buy 130, sell 70, not_set 100; minerals 1050 buy gives 1495; alloys 330 sell gives 890.148.
- **ratio with no expenses:** 2814749767.10655.
- **resource maximum:** energy 25000, influence 1000.
- **stockpile export:** 9084.51144.
- **planet_resource_compare on the capital:** produces 41.64428, upkeep 25, consumer goods balance 24.63721.
- **num_energy / num_minerals:** 0.
- **can_buy_on_market:** energy, alloys and food yes; rare crystals no.
- **has_any_strategic_resource, is_market_leader = no, count_enslaved_species:** match.
- **set_resource:** energy 123.456; alloys 99999 is capped at 15000.
- **add_resource_from_debris:** minerals 5 × 2 added; alloys stay capped.
- **transfer_resources_to_empire:** 25% of minerals, food and unity, truncated, reaches country 16777225 to the last digit.
- **set_trade_conversions:** sets the table; `{ }` changes nothing.
- **set_resource_converter:** sets the key, and `none` removes it.
- **enable_galactic_market / set_market_leader, yes then no:** access 1 then 0; leader 0 then 4294967295.
- **set_slavery_type on the founder species:** changes `primary`: slavery, former_slavery, last_changed_value, and with the cooldown last_changed_slavery_type 2220.01.01.
- **clear_resources = no:** empties the economy module (no `resources` block) and stored_techpoints.

The current-month budget values (`resource_revenue_compare`, the ratio, `export_resource_income_to_variable`) differ by about 0.01. The game recomputes the month's budget after the load, and the sim reads the saved one.

### The silent rows, with real targets

Seven effects are silent on both autosave_2210 and rich_2212, because the docs mod's uses cannot act there.

`/root/cecon/g3.txt` on 10.5.0.24 runs them with real targets in the headless game, from rich_2212 with the galactic market founded and an influence field at the player's capital. `/root/cecon/probe3.lua` runs them in the sim on the game's save, with these results:

- **add_resource_from_debris:** game and sim match (minerals 762.95154 to 772.95154, alloys +20).
- **enable_on_market:** sets index 12 (exotic gases) in both.
- **recalculate_storm_influence_field:** the game's field block is unchanged.
- **get_trade_data / make_special_trade:** no enclave's or player's stockpile changes in the game.
- **add_resource_to_local_stockpile / transfer_resource_stockpile:** the game has no design for a size that can store (nomads_constructor, nomads_engineer_vessel). Arkships collect to the country, so they store nothing. In the sim, a ship switched to nomads_constructor (cap 2500) fills in resource order up to 2500 (alloys cut to 200), and the ×0.5 transfer reaches the owner and clears the ship.
