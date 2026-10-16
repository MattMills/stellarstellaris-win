# The economy windows: the market, the expansion planner, trade, the slave market

The renderer's economy windows, from the game's own files (4.5.2) and the views' code in the
Linux build (the classes and addresses below), bound to the save's world or to the running
simulation. **[V]**: read in the game's code or files, or measured on its frames; **[I]**:
inferred. Code: `sim/render/src/economy.rs`, `sim/render/lua/render/windows/market.lua`,
`expansion.lua`, `text.lua` (localisation texts with values), `serial.lua` (a window's data
between runtimes). The full reverse-engineering notes: `code_working/tmp_sim/economy_market_re.md`,
`economy_expansion_re.md`, `economy_gridbox_re.md`.

Checked against the game's frames of 2210.01.01 at 1600x900 (`headless/view.sh`, the game left,
the renderer right): `code_working/tmp_sym/render3d/parity/economy_market.png` (`open_view market`)
and `economy_planner.png` (`open_view expansion_planner`, then the Surveyed box clicked off).

## Opening a view

- The left bar's entries (main.gui `maingui_left_bar_button`) take clicks on their `button`
  element: `view:NAME`, NAME the view's ETopBarView token, the stem of its GFX_topbar_NAME_button
  (market, expansion_planner, technology, ...). A click opens the view, a second closes it, as
  CInGameIdler::ToggleTopBarView does (one view at a time) **[V]**. Escape closes the open view
  first (its close button's `shortcut = "ESCAPE"`) **[V]**.
- The command `open_view NAME [KEY=VALUE ...]` opens it (KEY=VALUE: the view's state, below);
  `open_view` alone closes it. The headless game's `open_view NAME` (headless.c, from
  win-research) toggles the same view in the game, so one command file takes both frames.
- A view's own buttons change its state with `state:KEY=VALUE;KEY=VALUE` (App::view_state): the
  market's resource and tab, the planner's checkboxes and sort column. The state starts anew
  when a view opens **[I: the game keeps the market's selected resource while it stays valid,
  and the planner's filters, across openings]**.
- App::view_items dispatches on the view's name to the module that draws it (one match arm per
  window's owner).

## Where the values come from

A view's module has `data(country, state, game_dir)`, run where the save's world is: in the
map's runtime after `load` (it holds the world), in the simulation's after `load-sim`
(Clock::view: the request, a Lua chunk, is evaluated with every snapshot the simulation
publishes and the snapshot carries the answer). The data are plain values, serialised as a
table constructor (`serial.lua`) and laid out by `build(...)` in the front end's runtime, which
has the localisation and the .gfx database.

## The market (interface/market_view.gui, CMarketView)

**[V]** CMarketView::UpdateMarketTab (0x2f68fb0) and its entries (CMarketViewResourcesGridEntry,
CMarketViewTradeResourcesGridEntry, CMarketViewMonthlyTradeGridEntry); CMarket's price functions.

- Title `windows_title`: MARKET_VIEW ("Market") on the market tab, SLAVE_MARKET on the other.
  The tabs (CGameGraphics::UpdateTabVisibility): the active tab's `X_active` button shows, the
  other's plain `X`; the slave market's two only with Megacorp among the save's DLCs; its tab
  takes clicks only with access to the galactic market (CMarketView::Update).
- Resources (`resources_grid`, `market_resource_grid_entry`): CMarket::GetValidAndVisibleResources,
  the resources in their definition order that are `tradable` with `market_amount` and
  `market_price` above 0, not the currency (`MARKET_RESOURCE`, trade); on the internal market
  only those with an income this month (the budget's current_month income) **[V; I: the
  expenses rule for some resource categories not applied]**. The entry's `resource_amount`: the
  resource's text icon then its stockpile, under 1000 whole, else one decimal cut with K, M, G
  (CreateSIValueNoColor: 9084 "9.0K"). The selected one's `selected_overlay` shows; the first
  valid resource is selected when the view opens. `disabled_bg` never shows (only the currency
  would, and it is not listed).
- Prices (CMarket::CalcResourcePriceForAmount, NMarketUtil::CalcFluctuation and
  CalcPriceWithSimulatedFluctuation, AddTradeFeeToPrice), in the game's fixed point (1.0 =
  100000, products and quotients truncated): k = amount / market_amount base amounts; the first
  at market_price + fluctuation, each further one after the fluctuation moves by
  MARKET_FLUCTUATION_ABOVE_BASE_PRICE (1) at or above the base, BELOW (0.3) under it, both x2 on
  the internal market (INTERNAL_MARKET_FLUCTUATION_MULT), capped at 400 and -80, at most 200
  base amounts; then the fee: x (1 + fee) to buy, x (1 - fee) to sell, fee = max(0.05, 0.3 +
  country_trade_fee). The fluctuation: the galactic market's per resource, else the country's
  `internal_market_fluctuations` (0 when absent). **[I: the country's trade fee modifier is not
  evaluated: 30%]**.
- Buy and sell grids (`market_trade_resource_grid_entry`): one per TRADE_AMOUNT_MULTIPLIER
  (1 5 10 50 100) x market_amount; GFX_resource_KEY_large; "+N" to buy, "-N" to sell (red when
  the stockpile has less); the price after the currency's icon, a buy rounded up ("-130", red
  when the trade stockpile cannot pay it), a sell rounded down ("+70"). The unit prices
  (RESOURCE_UNIT_PRICE, two decimals cut): "1 = 1.30" and "0.70". Disabled entries are drawn
  grey by the game (its button shader) **[not done: the renderer has no grey]**.
- `total_bought_text`, `total_sold_text`: MARKET_TOTAL_BOUGHT/SOLD with the market's
  `resources_bought`/`resources_sold` for the country (by its index, the id's low 24 bits, when
  `id[index]` is its id). `trade_fee_value` "§Y30%§!" (built in code); the trade stockpile
  (MARKET_TRADE_STOCKPILE_HEADER/VALUE).
- `market_state`: GALACTIC_MARKET with access (`market_info` hidden; `market_leader`, flag and
  name, when the market has a leader), else INTERNAL_MARKET with `market_info`:
  GALACTIC_MARKET_NOT_FOUNDED_DESC or _FOUNDED_NO_ACCESS_DESC.
- Monthly trades (`market_monthly_trade_grid_entry`): MARKET_BUY/SELL, the resource's icon, the
  amount, MAX_PRICE/MIN_PRICE and the limit **[I: their save fields; none in the saves read]**.
- The buy and sell boxes clip their `empire_list` (300 wide) at their 240 **[V gui; drawn at
  240 here: no clipping in the renderer]**.

2210.01.01 (country 0, internal market, no fluctuation): energy 9.0K, minerals 680, food 7.2K,
consumer goods 4.8K, alloys 1.4K; buy +100 -130, +500 -676, +1000 -1417, +5000 -9685 (red),
+10000 -25870 (red); sell -100 +70, -500 +345, -1000 +681, -5000 +2985, -10000 (red) +4921;
fee 30%, trade 4413: as the game's frame. After 30 simulated days: 9.1K energy, 683 minerals,
4449 trade.

## The expansion planner (interface/expansion_planner_view.gui, CExpansionPlannerView)

**[V]** RefreshModel (0x2d39070), ValidatePlanetFilters (0x2d35d00), RefreshPlanetData,
SortModel, CExpansionTargetEntry::UpdateEntry (0x2d3b500).

- Title "Expansion Planner", the list's "Habitable Planets" (the second `text` of
  expansion_target_title). The filters: Surveyed on, Colonizable and Terraforming Candidate
  off (the constructor's); the minimum habitability 0 ("§R0%§!": red under 40, yellow under
  70, else green); the species All.
- The rows: every planet of the systems the player knows at medium intel or better
  (`intel_level` by system id >= 2) that has no owner and a `colonizable` class, or carries an
  important modifier (the terraforming candidates'); not in a system owned by a country the
  player has communications with; an unsurveyed planet (not in `surveyed_deposit_holders`) only
  while every box is off. The habitability (surveyed only): the most over the colonising species
  (the pop groups' species whose rights allow colonisation), each the sum of its traits'
  `<class>_habitability` modifiers plus 0.3 on its homeworld, clamped to 0..1, as a whole
  percentage **[I: the generic habitability modifiers and the colony's and country's not added;
  the Colonizable filter's CanColonize taken as a habitability above 0; a terraforming
  candidate needs tech_terrestrial_sculpting; rare deposits counted by their type's name]**.
- A row (`expansion_target_entry`, 55 apart **[I: measured]**): the class icon (the class's
  `icon`), the habitability, the name and class (grey "§g...§!" and "?" when unsurveyed), the
  rare deposits ("-" unsurveyed), the size, the distance to the capital along the hyperlanes
  (their `length`s), the terraforming candidate's status. Sorted by distance, nearest first,
  ties in planet id order; a column's button sorts by it, again the other way (OnClickSort).
  The district grids, the modifiers, the anomaly and hostile icons are not drawn yet.

2210.01.01: none with Surveyed on (only the home system is surveyed; its one habitable planet is
the capital); off: Runa III (Desert World, 20, 13), Toarus I (Ocean, 15, 22), Toarus II (Arctic,
14, 22), Toarus III (Tomb, 19, 22): the game's rows, at the game's places.

## The layout rules this needed (render/gui.lua, scene.rs), read from the game

- A gridBoxType places its items by CGridBoxBase::GetSlotPosition **[V]** (gui.grid_slot): by
  rows unless `add_horizontal = no`, wrapping at max_slots_horizontal; the default format
  centres one slot across the grid's width (x = col x slot + trunc((width - slot) / 2)), the
  others as their names say (the full table in economy_gridbox_re.md). The market's grids are
  4 and 17 pixels right of their corners, as in the game.
- A field given twice takes its later value **[V: the planner's title]**.
- A text wider than its box wraps at its spaces; a box with fixedSize keeps the lines its height
  holds (one line: cut with " ..."), one without grows **[V: the market's info on three lines,
  "Terraforming Candidate" on two]**.
- A plain sprite is drawn at its frame's size times its scale whatever the element's `size`; a
  cornered tile fills the size **[V: the planner's row frames, the outliner's rearrange button]**.
- checkboxType and expandButton are buttons; a background is hidden by its own name too; a
  sprite set at run time keeps its own frame; a text icon without a GFX_text_ sprite uses the
  resource's GFX_resource_ one **[I: the two prefixes side by side in the game's strings]**.

## Not done yet

- The trade window (trade_view.gui, CTradeView), the slave market tab and the slave pool
  (slave_pool_view.gui): not drawn.
- Disabled buttons grey (the game's buttonstate shaders); the animated overlays of the planner's
  rows (brighter frames in the game).
- The market's trade fee modifiers; the expenses rule of the internal market's resources.
- The planner's district grids, modifiers, hostile and anomaly icons, the drop-downs' lists
  (closed: their selected value only), the colonize click.
