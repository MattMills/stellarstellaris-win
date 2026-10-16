# The economy windows: the market, the expansion planner, trade, the slave market

The renderer's economy windows, from the game's own files (4.5.2) and the views' code in the
Linux build (the classes and addresses below), bound to the save's world or to the running
simulation. **[V]**: read in the game's code or files, or measured on its frames; **[I]**:
inferred. Code: `sim/render/lua/render/windows/market.lua` (with the slave market),
`expansion_planner.lua`, `trade.lua`, `sim/render/lua/render/loctext.lua` (localisation texts
with values). The full reverse-engineering notes: `code_working/tmp_sim/economy_market_re.md`,
`economy_expansion_re.md`, `economy_gridbox_re.md`.

Checked against the game's frames of 2210.01.01 at 1600x900 (`headless/view.sh`, the game left,
the renderer right): `code_working/tmp_sym/render3d/parity/economy_market.png` (`open_view market`),
`economy_planner.png` (`open_view expansion_planner`, then the Surveyed box clicked off) and
`economy_planner_dropdown.png` (then the minimum habitability's arrow).

## Opening a view, where its values come from

The windows are win-research's left bar views (`sim/render/src/views.rs`): a Lua module
`lua/render/windows/NAME.lua` for the view's ETopBarView token (the stem of its
GFX_topbar_NAME_button): `market.lua`, `expansion_planner.lua`, and `trade.lua` (opened with a
recipient). `extract(game_dir)` runs where the galaxy is read (the save's world after `load`,
the simulation's thread after `load-sim`: the values come with each snapshot);
`build(ctx, data, state)` lays the window out with the view's state.

- The left bar's entries (main.gui `maingui_left_bar_button`) take clicks on their `button`
  (right_icon is an iconType, never a button): `view:NAME` toggles the view, one at a time, as
  CInGameIdler::ToggleTopBarView **[V]**. Escape (the controls' Back) closes an open view first
  (its close button's `shortcut = "ESCAPE"`) **[V]**.
- `open_view NAME [KEY VALUE]` toggles it (with a state key); the headless game's `open_view
  NAME` (headless.c) toggles the same view in the game, so one command file takes both frames.
- A view's buttons set its state with `view_set:KEY=VALUE;KEY=VALUE` (an empty value removes the
  key) and close it with `view_close`. The state starts anew when a view opens **[I: the game
  keeps the market's selected resource while it stays valid, and the planner's filters, across
  openings]**.

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
  (RESOURCE_UNIT_PRICE, two decimals cut): "1 = 1.30" and "0.70". Disabled entries are grey
  (the button shader's Disable, below).
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
- A disabled button is drawn as buttonstate.shader's Disable effect: GreyOutLuminosity
  (greyness 0.85, brightness 0.75) of the texel, its text the same (TextDisable) **[V]**
  (opts.disabled, GuiItem::Sprite `disabled`, map.wgsl mode 4): the market's unaffordable
  entries and the slave market's tab, as in the game's frame.
- A drop-down's expanded window is laid out when opened (opts.open); the planner's two lists
  match the game's frames.
- A field given twice takes its later value **[V: the planner's title]**.
- A text wider than its box wraps at its spaces; a box with fixedSize keeps the lines its height
  holds (one line: cut with " ..."), one without grows **[V: the market's info on three lines,
  "Terraforming Candidate" on two]**.
- A plain sprite is drawn at its frame's size times its scale whatever the element's `size`; a
  cornered tile fills the size **[V: the planner's row frames, the outliner's rearrange button]**.
- checkboxType and expandButton are buttons; a background is hidden by its own name too; a
  sprite set at run time keeps its own frame; a text icon without a GFX_text_ sprite uses the
  resource's GFX_resource_ one **[I: the two prefixes side by side in the game's strings]**.

## The slave market tab and Sell Slaves (CSlaveMarketView, CSlavePoolView)

**[V]** CSlaveMarketView::Update, CSlaveMarketPopEntry, CSlaveMarketColonyEntry, CSlavePoolView
(the notes: `code_working/tmp_sim/economy_slaves_re.md`). Drawn in market.lua.

- The tab exists with Megacorp and takes clicks only with the galactic market's access (greyed
  otherwise, as in the game's frame). Its slaves (slave_market_manager.slaves_on_market) sorted
  by species name, stable; "No Slaves for sale..." without any; Sell Slaves enabled when the
  country has slaves to sell and the market room (CanSellSlaves: no access check). A slave's
  price: (1000 trade + its species' traits' slave_cost) / 100 a pop **[V]**, times the amount,
  without the country's slave market cost modifier **[I]**. The destinations: the country's
  colonies (owned_planets **[I]**), none selected until one is clicked; a slave's Buy disabled
  without one. A colony shows its free housing (red below 0, yellow at 0, green), its
  unemployment (red above 0) and its jobs, the workforce over the jobs' limits (yellow when
  full, else white).
- Sell Slaves (`view_set:pool=1`): the first species with slaves, its pops (one decimal, K),
  its colonies' groups (the capital first, the others in their order **[I: by distance]**;
  collapsed until clicked), each group's pops (at most 100 a group, priced without the country's
  modifier), disabled without the market's access; the summary hidden and Put on Market disabled
  while nothing is selected. Portraits are not drawn.
- 2210.01.01 (`open_view market tab slave_market`; the game cannot open the tab there): no
  slaves for sale, Sell Slaves enabled, Uthab 100%, 1188 free housing, 5323 / 3600 jobs, 799
  unemployed; Sell Slaves: Qvagh, 2.6K, two groups of 100 at 1600 trade each.

## The trade window (interface/trade_view.gui, CTradeView)

**[V]** CTradeView::Show, SetRecipient, Setup, Update, UpdateAcceptance, CreateCategories (the
notes: `code_working/tmp_sim/economy_trade_re.md`). `trade.lua`, opened with `open_view trade
country ID` (the game: the diplomacy view's Trade action for its selected country).

- The actor (the player) and the recipient: names, "Gives" under each. Above 1470 pixels of width
  (TRADE_VIEW_WIDE_MODE_THRESHHOLD, the game's unchecked interface defines) the window is 1470
  wide, the demands' categories at trade_view_wide_mode_demands_pos (1220, 10), no tabs; else
  the Offer and Demands tabs. Nothing offered: both lists empty, the deal length hidden (no
  treaty), Propose disabled (an empty deal is not proposable), Cancel enabled.
- The categories, ETradeCategory's order (resources, transfer_control, transfer_leader,
  transfer_fleet, action, sensor, loyalty, specimens, join_war, leave_war, allow_to_leave_war),
  each shown when its side has items: here Resources when the side has a tradable resource **[I:
  the others not evaluated]**.
- Not drawn: the recipient's ruler's portrait, the flags, the AI's acceptance and willingness.
- 2210.01.01: the player's one contact (country 6) has no communications and is an exterminator:
  the game cannot open the window there; no game frame to compare.

## The buttons

What each window's clicks do, read in the 4.5.2 binary (`code_working/tmp_sim/wire_market_re.md`,
`wire_clicks_re.md`) and wired in `sim/render/src/economy.rs` (the `economy:` actions) and the
window modules (`view_set:` state). A change to the game state runs where the world is: the map's
runtime while it holds the save's world, else the simulation's thread between days
(`Clock::query`); the view's data and the top bar are then made again.

| window | element | what it does | state |
|---|---|---|---|
| market | resource grid entry | selects the resource (CMarketViewResourcesGridEntry::Click) | wired |
| market | buy / sell entry | CMarketBuyResourceCommand / CMarketSellResourceCommand **[V]**: the currency pays the exact price with the fee, the resource the whole units (a sell credits the price's whole units); the fluctuation one step for the lot (internal_market_fluctuations, or the galactic market's `fluctuations`); the bought and sold totals at the country's index, `id[index]` set. Only when CanClick (greyed otherwise) | wired |
| market | Add new monthly trade | opens the monthly trade window (CMarketView::OpenMonthlyTrade) | wired |
| market | a monthly trade, left click | opens it for editing (ShowMonthlyTradeViewWithData) | wired |
| market | a monthly trade, right click | CRemoveMonthlyTradeCommand | wired (an action `LEFT\|\|RIGHT`) |
| market | tabs | Market; Slave Market only with the galactic market's access (greyed otherwise) | wired |
| market | close, Escape | closes it; Escape closes Sell Slaves first (its own ESCAPE); the monthly trade window has none and goes with the market (CMarketView::Hide) | wired |
| market | the tabs' keys Z and X | the market's and the slave market's tab | not done: the renderer has no way yet to hand a `.gui` button's `shortcut` to it |
| monthly trade | Buy, Sell | the type (its button active), the resource unchosen (SelectBuy / SelectSell) | wired |
| monthly trade | resource | amount ceil(market_amount x 0.1), no limit (SetActiveResource) | wired |
| monthly trade | - + (amount, limit) | a step of 1, never below 0 **[I: the shift and control steps not read]** | wired |
| monthly trade | Add / Edit | CAddMonthlyTradeCommand (IsValid: a resource, amount > 0, at most 200 base amounts; the next id) or CUpdateMonthlyTradeCommand; closes | wired |
| monthly trade | Cancel / Remove | closes; editing, CRemoveMonthlyTradeCommand | wired |
| monthly trade | the trades' monthly execution, the daily drift of the fluctuations | CMarket::MonthlyUpdate, DailyUpdate | not done here: the simulation's monthly and daily updates |
| slave market | sort buttons | name, habitability, traits, cost; the same again the other way (OnSetSortType) | wired |
| slave market | a destination | selects it, again deselects | wired |
| slave market | Buy / Cancel | CBuySlaveFromMarketCommand / CRetractSlaveFromMarketCommand | UI only: the effects not done (no galactic market in the saves: the tab cannot open in the game) |
| slave market | Sell Slaves | opens Sell Slaves | wired |
| Sell Slaves | species drop-down | opens; a species chosen (the chosen one last, disabled) closes it | wired |
| Sell Slaves | a colony group | opens or closes its pops | wired |
| Sell Slaves | a pop | toggled in the selection (only with the market's access: CanClick) | wired (never enabled in the saves) |
| Sell Slaves | Put on Market | with a selection: CPutSlaveOnMarketCommand per group, then closes | UI only: the effect not done |
| Sell Slaves | close, Escape | closes, the selection cleared | wired |
| planner | checkboxes, drop-downs, sort buttons | the filters and the order (as before) | wired |
| planner | a row's zoom button, its class icon | FocusCameraOnObjectOrSystem **[V]**: in the planet's system the camera follows it; from another system that system is entered with the planet followed (the game's frame: Runa from the home system); from the galaxy map the camera slides to the system; the planner stays open | wired |
| planner | a row | the colonize window (OpenColoniseView) or the terraform panel | not done: those windows are not drawn |
| planner | cancel colonize | CCountryCancelExpansionCommand after a confirmation | not done: no planned colonies in the saves |
| planner | the wheel over the list | a row a notch, within the rows that do not fit | wired (views' `wheel`) |
| planner | close, Escape | closes it, an open drop-down with it (the game's frames: a second Escape opens the game's menu) | wired |
| trade | a category | opens or closes its items (several at once) | wired (Resources: the side's tradable stocks) |
| trade | an item | in or out of the side's offer list (its button active) | wired |
| trade | an offered resource's - + and close | its amount (a step of 1 **[I]**), out of the list | wired |
| trade | Propose | with something offered: CDiploActionProposeCommand, the window closed | UI only: the AI's answer not done |
| trade | Cancel, close, Escape | closes, the deal cleared | wired |

Shared, general: Escape closes a view's side windows first when its module lists their state keys
(`M.escape_keys`; else any state, as before), then the view; a GUI button's action `LEFT||RIGHT`
does RIGHT on a right click; the wheel over an open view goes to its module's `wheel` (a list's
scroll) before the map's zoom.

Checked in a real window (the windowed renderer under Xvfb at 1600x900, 2210.01.01 from Load
Game; `winsteps.sh`) and against the game's frames of the same clicks (`headless/view.sh`): +100
energy bought (trade 4413 to 4283, unit prices 1.32 and 0.71, bought 100), -100 sold (4354, 1.30
and 0.70, sold 100); a monthly trade added (Buy 10, Max -) and removed with a right click; the
planner's zoom from the home system into Runa's; Escape on the planner (with its drop-down open)
and on the market (with the monthly window open). The slave market, Sell Slaves and trade cannot
be opened in these saves, in the window or the game: checked with the commands (`open_view market
tab slave_market`, `open_view trade country 6`) and the same clicks.

## Not done yet

- The animated overlays of the planner's rows (brighter frames in the game).
- The market's trade fee modifiers; the expenses rule of the internal market's resources.
- The planner's district grids, modifiers, hostile and anomaly icons, the colonize click.
- Portraits (slave market, Sell Slaves, trade) and flags inside a view (trade, the market
  leader).
- Comparisons with the game for the slave market, Sell Slaves and trade: the saves at hand
  cannot open them (no galactic market, no country to trade with).
