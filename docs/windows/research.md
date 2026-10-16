# The research and traditions views

The game's research view (`interface/technology_view.gui`, CTechnologyView) and traditions view
(`interface/topbar_traditions_view.gui`, CTraditionsView), as the 4.5.2 Linux build fills them,
and how the renderer draws them: `sim/render/lua/render/windows/technology.lua` and
`traditions.lua`, opened by the left bar through `sim/render/src/views.rs`. **[V]**: read in the
game's code (address) or files, or measured on its frames; **[I]**: inferred.

## Opening a view

- **The game** **[V]**: a left bar button calls `CInGameIdler::ToggleTopBarView(ETopBarView)`
  (0x1c8ac70). The views are at idler +0xd38, one per ETopBarView (19); a shown view is hidden,
  else `CloseTopBarViews` hides every other and the view is shown (its vfunc +0x48 with true),
  idler +0xdc8 = the view. So one top bar view is open at a time. The views' names are their
  tokens (`EnumToToken<ETopBarView>` 0x1ac6450, a table of 19 lexer tokens at 0x45efbe8;
  `TokenToString`): `technology`, `traditions`, `situation`, ... as the left bar's
  `GFX_topbar_NAME_button` sprites.
- **headless.c** (view mode): `open_view NAME` calls that toggle for the view whose token is NAME;
  `open_view technology select|researched AREA` shows the research view and calls
  `CTechnologyView::Show(ETechArea)` (0x32d7f00: select_window for the area) or
  `OnResearched(ETechArea)` (0x32d7c70), after checking the view's vtable.
- **The renderer**: the left bar's icons carry `view:NAME`; `App::toggle_view` keeps one view open;
  `open_view NAME [KEY VALUE]` in the command protocol. A view is the module
  `lua/render/windows/NAME.lua`: `extract(game_dir)` where the galaxy is read (the simulation's
  thread, or the save's world before it runs), its data carried in the snapshot
  (`Galaxy::views`, a `views::Value` tree); `build(ctx, data, state)` on the UI thread. Buttons:
  `view_close`, `view_set:KEY=VALUE;...` (the view's state: `select`, `researched`). Escape closes
  the open view first (the close buttons' `shortcut = "ESCAPE"`; the GUI has the input before the
  idler, CGameIdler::Idle).
- **The left bar's icons** are inside the bar in the game's frames (their left edge at x = 5, with
  and without a view open) **[V: measured]**; the renderer had them 27 px right of that, under an
  open view. Moved by the measurement **[I: what places them is not read]**. Not drawn: the open
  view's button state in the bar (its icon outlined, an arrow at the bar's edge).

## The research view (CTechnologyView)

`technology_view_window` at its show_position (30, 35) (it slides from (-1070, 35) in 200 ms,
decelerated, when shown **[V gui]**; the renderer draws it in place).

- **Reload** (0x32d70e0) **[V]**: select_window and researched_window hidden; three
  CTechnologyViewAreaEntry (`technology_view_area_window`) added to `areas_window/grid` in
  ETechArea order: **physics 0, society 1, engineering 2**, top to bottom (slots 480 x 160).
- **research_container**: `CParagonPortraitContainer::Instantiate` with the define
  NInterface.PORTRAIT_GUI_NAME_TECH_VIEW = `paragon_portrait_container_research`
  (interface/paragon_ui_types.gui) **[V]**; every Update sets its leader to
  `CGovernment::GetHeadScientist()` **[V]**: the leader of the country's council position whose
  type is one of NGameplay.COUNCIL_RESEARCH_POSITIONS. Drawn: `bg_head_of_research`, the
  position's icon (`common/governments/councilors` `icon`: GFX_icon_councilor_research), the
  leader's name (`name.full_names`, `%LEADER_2%`: its two parts) and the position's name ("Head of
  Research"). Not drawn: the portrait, rarity, class, skill and trait icons.
- **The areas** (CTechnologyViewAreaEntry ctor 0x32d9ae0, UpdateEntry 0x32db240) **[V]**:
  `area_name` the area's name, `area_icon` GFX_resource_AREA, `topbar`
  GFX_scientist_top_bar_AREA; `modifier_icon` ApplyModifierToButton(ModifierType 0xae): the
  game's frame shows GFX_mod_country_all_tech_research_speed **[V: by image; the enum's name I]**;
  `modifier_value` CreateGreenRedPercentDiff(CalcResearchEfficiency(area)): "+4%" green, a
  negative value red **[V; the exact format I]**. `auto_research` frame 3 when the area
  auto-researches (`auto_researching_AREA`), else 2. `bottom_line` (y 212) is outside the
  150-high, clipped window: not drawn.
- **choose or research** **[V]**: the area's queue (`tech_status.AREA_queue`, CTechQueueItems:
  technologies and special projects) is searched for its first valid technology. None: `research`
  hidden, `choose` shown ("Select Research", its button drawn at the sprite's 411 x 58 although
  its `size` says 411 x 85 **[V: the frame]**). Found: the technology's card (below) in
  `research`, `progress_value` = progress + "/" + CTechQueueItem::CalcProgressNeeded (no spaces,
  integers), `tech_progress/progress` the bar at progress / needed, `eta`
  TECH_MONTHS_REMAINING ("N months remaining") of CalcMonthsLeft, or NO_PROGRESS when negative.
  A special project halting research would hide `tech_progress` and show `special_project`
  (TECH_BUSY_SPECIAL_PROJECT): not handled here.
- **CalcMonthsLeft** (0x20a7760) **[V]**: CalcMonthsToResearch(country, technology, progress +
  the points stored for the technology, `stored_techpoints_for_tech`) = ceil((cost - that) /
  CTechnologyStatus::CalcResearchPerMonth(area)), -1 when the month's research is not positive.
  The month's research is taken as the area's resource with the efficiency plus as much again of
  the area's stored points (`stored_techpoints`; DailyResearch's A + B) **[I: its fifth argument
  not read; the game's 34 months for 938 left is 27.6 a month = 2.14 x 12.9]**.
- **The card** (CTechEntryWindowUpdate::UpdateEntry 0x32df560, shared by the area, the select
  list and the researched list) **[V]**: `name` the technology's name; `tech_option_bg` by its
  flags, the first that holds: dangerous and rare GFX_tech_entry_dangerous_rare_bg, dangerous,
  rare, insight, the custom ones, else GFX_tech_entry_AREA_bg (the tier never matters); `icon`
  the technology's icon (`gfx/interface/icons/technologies/NAME.dds`, or its `icon`) over
  GFX_technology_unknown's settings; `category_icon` its first category's icon
  (common/technology/category `icon`); `icon_frame` is never changed; `risk_icon` when HasRisk
  (drawn for `is_dangerous` **[I]**); `cost` (rows only) TECH_STARTING for a starting technology,
  else the cost. Not drawn: the `unlocks` list (TechnologyViewAddUnlocks 0x32e2d80: the modifiers,
  prerequisites for, components, ship sizes, ...), so the rows keep the GUI's height.
- **select_window** (UpdateSelected 0x32d7f80) **[V]**: `header` SELECT_TECHNOLOGY ("$AREA$
  Research"), `desc` SELECT_TECHNOLOGY_DESC with NUM = the alternatives' maximum (3; its lines, 17
  apart **[I: measured]**), `list` the area's `alternatives` that CanResearch, one
  technology_view_tech_entry_window each (120 apart **[I]**): `always_available` on the country's
  `always_available_tech`, `gateway_icon` when the technology has a `gateway`, `cost` COST_FREE,
  "stored/cost" when points are stored for it, else the cost. A click on a row posts
  CResearchTechnologyCommand and hides the window (not done: the simulation has no command).
  The area's Select button toggles it; it hides researched_window.
- **researched_window** (OnResearched 0x32d7c70, UpdateResearched 0x32d83f0) **[V]**: `header`
  RESARCHED_TECHNOLOGY, the area's tab active (UpdateTabVisibility: `tab_AREA_active` shown,
  `tab_AREA` hidden), `list` the researched technologies of the area newest first, a
  `technology_view_tech_researched_entry_window` per level from the current one down (105 apart
  **[I]**). Researched toggles it and hides select_window.
- **The costs**: the simulation's `engine.research` cost (CTechnology::GetCost with the
  modifiers) when it runs; before, the base cost with the difficulty's scaling and the galaxy's
  setting **[I: no modifiers, no empire size penalty]**.

## The traditions view (CTraditionsView)

`traditions_view` at (35, 40) (from (-1270, 40) in 200 ms **[V gui]**):

- **Tabs** **[V]** (SwitchToTab 0x334a460, UpdateTabVisibility): the Traditions tab active
  (`tab_traditions_active` shown), `tab_crisis` shown (the crisis DLC flags), `crisis_window`
  hidden; `header` TRADITIONS.
- **tradition_box** (UpdateNextTradition 0x334ad20, UpdateProgress 0x334afb0) **[V]**: shown while
  a slot is free or an adopted category is not complete. `tradition_cost`: the unity icon and the
  next tradition's cost rounded up (CTraditionType::CalcCost: the simulation's
  `engine.traditions.cost`; before it runs the defines' formula without modifiers **[I]**);
  `progress` the stock over the cost (round, 0..100); `time_to_next_tradition` MONTHS_VALUE "?"
  without unity income, 0 when affordable, else ceil((cost - stock) / income), MONTH_VALUE for 1.
- **The slots** (UpdateTraditionsGridbox 0x334a8f0) **[V]**: TRADITION_CATEGORIES_MAX (7) entries
  in the gridbox (314 x 266, four a row): the adopted categories in their adoption order, then
  empty ones. An adopted category: GFX_tradition_category_bg_KEY, GFX_tradition_hex_bg_KEY,
  GFX_tradition_category_icon_KEY, its name, `adopted_count_value` TRADITION_ADOPTED_COUNT ("N /
  M" without the adoption and finisher), the adopt button and the description hidden, its tree:
  the container `tree_template` names (common/tradition_categories) in `tree`, tradition i in the
  template's i-th container (`tradition_entry`: GFX_ + the tradition's icon key; the
  `available_tradition` overlay where CanActivate; owned ones take no clicks; the others disabled,
  drawn greyed **[I: as a grey tint]**). An empty slot keeps the GUI's "Empty" and "Nothing
  selected", its button TRADITION_SELECT_BUTTON ("Select"); when the next tradition is affordable
  its background and icon are the `_available` ones and the blocker is hidden. The button is drawn
  at its sprite's size, not its `size` **[V: the frame]**; the description is centred in the 200
  below it **[I: measured]**.
- **Ascension perks** (ReloadAscensionPerks 0x3348940, UpdateAscensionPerks 0x334b660) **[V]**:
  ASCENSION_PERKS_SLOTS (8) entries at the positionTypes ap_0 .. ap_7 in `ascension_perks`: the
  taken perks (GFX_ + their icon), then the free points
  (`ascension_perks_add`, the simulation's `engine.traditions.perk_points`) as
  GFX_ascension_perk_slot_available with GFX_flag_64_frame_highlight, the rest
  GFX_ascension_perk_slot_locked.
- Not drawn: the crisis (Ambition) tab, the category selection dialog (an empty slot's Select),
  the adoption popup, the ascension perk list (a free slot's click).

## Checked against the game's frames

`headless/view.sh` and `stellar-render` with the same commands (1600x900; the renderer with
`load-sim`, both after `step 1`): `open_view technology`, `open_view technology select physics`,
`open_view technology researched physics`, `open_view traditions`.

- **2210.01.01**: the research view (head of research, three areas with Select Research and
  +4%), the physics offers (Quantum Computing 1650, Blue Lasers 1375, Field Modulation 1100; the
  game's fourth, Automated Colony Ships 165/1650, is missing after the simulation's day: its
  alternatives lose the always-available technology), the researched list, the traditions view
  (300 unity, 0 months, seven empty slots, eight locked perks): the same places, texts and
  numbers. Differences: the rows' heights and unlock lists, the portrait.
- **A test save** (2210.01.01 with country 0 researching Blue Lasers at 412.5 and Planetary
  Unification at 1250, Expansion and Discovery adopted with three traditions, a perk):
  Blue Lasers 438/1375 (the game 437), 38 months (the game 34), +4% (the game +14%: the
  simulation's modifiers do not have Discovery's adoption bonus), Planetary Unification done in
  both; traditions 606 unity, 1 / 5 and 0 / 5, the same trees, overlays and greyed traditions.

## Not done

- The technologies' unlock lists and the rows' heights from them; the leader's portrait; the
  research view's Policies button's view; special projects in the queues.
- Choosing a technology, cancelling, auto research, adopting a tradition or a perk: the
  simulation has no commands for them yet (`engine.traditions.activate` exists, not wired).
- The crisis tab, the tradition category selection dialog, the ascension perk list.
- The open view's left bar button state; the views' slide in.
