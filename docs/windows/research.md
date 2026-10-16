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
  `view_close`, `view_set:KEY=VALUE;...` (the view's state: `select`, `researched`). Escape (the
  close buttons' `shortcut = "ESCAPE"`; the GUI has the input before the idler,
  CGameIdler::Idle) closes the open view's side window first, then the view: the game's frames
  after `key escape` with the researched window open show the window closed and the view still
  there **[V: frames]**.
- **Clicks** (with render-controls' real input on both, `click X Y`): the left bar's technology
  icon (`click 15 221` at 1600x900) and traditions icon (`click 15 181`) open the views in the
  game and in the renderer; the left bar's icons are iconTypes, which take the click when an
  action names them (gui.lua).
- **The left bar's icons** are inside the bar in the game's frames (their left edge at x = 5, with
  and without a view open) **[V: measured]**; the renderer had them 27 px right of that, under an
  open view. Moved by the measurement **[I: what places them is not read]**. The open view's
  button (CMainGuiLeftBarButton::Update 0x2f3add0) **[V]**: its icons' frame 2 x shown + 1 (3,
  the outlined icon of navbar_icons_*.dds) and one more child shown, the `highlight`
  (GFX_navbar_highlight, the arrow at the bar's edge) **[I: which members, by the frame]**. A
  button keeps a frame the game sets (not 1) under the mouse: hover and press change only a
  button in its first frame (scene.rs) **[V: frames]**.

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
  else the cost; the `unlocks` list (below).
- **The unlocks** (TechnologyViewAddUnlocks 0x32e2d80; `technology_unlocks.lua`) **[V]** unless
  marked: the list cleared, then the modifier block (one technology_view_unlock_entry, a line a
  modifier: CPdxModifier::GetFullDescription, the name, ": ", the value coloured, a sign for a
  positive value, a percentage x 100 with "%", at most 2 decimals and none for a whole number, cut
  not rounded; green when good, red when not, yellow when neutral). The modifiers' flags are the
  engine's (CPdxModifierDefinition, not in the files): here `_mult`, `_speed`, `_chance` ones are
  percentages and costs, upkeeps and damage taken are bad **[I]**. Then the kinds in ETechUnlock
  order: ship sizes (one TECH_UNLOCK_SHIP entry with the list, then TECH_UNLOCK_STATION for the
  stations), planet classes, armies, edicts (`edict_KEY`), buildings, districts, policy options
  and groups (`policy_KEY`), feature flags (the technology's `feature_flags`, `feature_FLAG`),
  diplomatic actions, components, resources, deposit blockers, intel, megastructures (with
  `show_prereqs`), starbase modules and buildings (TECH_UNLOCK_STARBASE / ORBITAL / ARKSHIP /
  WAYSTATION by `starbase_type`), decisions, zones (TECH_UNLOCK_ZONE "Unlocks Specialization"),
  then the technology's custom `prereqfor_desc` titles. What a technology unlocks is the objects
  whose `prerequisites` name it (AND/OR recursing), and for starbase modules, buildings and zones
  their `show_in_tech` (buildings both). A typed `prereqfor_desc` (`ship = { title desc }`)
  replaces its kind's lines with its title; `hide_prereq_for_desc = KIND` hides a kind.
  Components: one technology_view_unlock_entry_component per component set (TECH_UNLOCK_COMPONENT
  with the set's key), its members' size icons (GFX_component_slot_icons, frame = the slot size +
  1: point_defence 1, small 2, medium 3, large 4, ...; strike craft 12; a core set 11) in its box,
  26 apart, or the single_component_icon for one member; weapons, then utilities, then strike
  craft. Each object's `show_tech_unlock_if` is the local country's: not evaluated here, `KEY =
  yes` is taken as false, `KEY = no` as true, a DLC check (`has_*_dlc`) as the DLC owned,
  AND/OR/NOT/NOR combined **[I: the player's ordinary empire; the vanilla conditions name nomads,
  bio-ships, origins]**. Entries are stacked without spacing, a text entry 16 a line **[I:
  measured]**, a component entry 35 (18 with one member). The area card's list is not resized (its
  66; the rest scrolls: not drawn); a row's list and bg_container grow by what passes 54 and the
  row with them **[I: by the frames]**. Not done: lines wrapping at the desc box's 345 (they are
  cut with " ..."), resources' and deposit blockers' icon entries, a list's partly shown last row.
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
  **[I]**). Researched toggles it and hides select_window; while it shows, Researched is active
  (UpdatePopOutButtonStates, NGuiUtil::SetButtonActive 0x2ee8fd0: the frame 4 x active - 1, 3,
  the orange one).
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
  numbers. Differences: the portrait.
- **A test save** (2210.01.01 with country 0 researching Blue Lasers at 412.5 and Planetary
  Unification at 1250, Expansion and Discovery adopted with three traditions, a perk):
  Blue Lasers 438/1375 (the game 437), 38 months (the game 34), +4% (the game +14%: the
  simulation's modifiers do not have Discovery's adoption bonus), Planetary Unification done in
  both; traditions 606 unity, 1 / 5 and 0 / 5, the same trees, overlays and greyed traditions.
- **The unlock lists** (the test save: Blue Lasers' card, the engineering offers, the researched
  physics technologies): the same lines in the same order ("Army Damage: +5%", "Unlocks
  Component: Blue Laser" with S M L, "Unlocks Orbital Ring Module: Laser Battery", "Unlocks
  Starbase Module: Hangar Bays", the buildings and districts of High-Energy Capacitors), the rows'
  heights as the game's. Differences: Powered Exoskeletons' job modifier is one line ("Job
  Efficiency for Workers & Menial Drones") where the game shows two, a long line is cut where the
  game wraps it, the researched list's fifth row (partly visible in the game) is not drawn.

## The buttons

Every element the game takes clicks on in the two views, what the game does (the 4.5.2 Linux
build: the handlers named) and what the renderer does. A view's command is the action
`cmd:VIEW:ARG...` (views.rs `command`): the view module's `command(...)` run in the simulation's
runtime between days (the simulation started first when only the save's world is loaded), then a
snapshot published, so the view shows the result at once; `#K=V` after it sets the view's state
(a side window closed). Escape goes to the view module's `escape(state)` (its innermost window:
a popup, then its dialog), then closes the view; the wheel to its `wheel(...)` (its lists).

| element | the game | the renderer |
|---|---|---|
| left bar icon | CInGameIdler::ToggleTopBarView | wired (`view:NAME`) |
| view's close (X), Escape | the view hidden | wired (`view_close`; Escape: side window first) |
| research: an area's Select Research | OnSelect: select_window for the area, toggled | wired (`view_set:select=AREA`) |
| research: an offer (select_window row) | CResearchTechnologyCommand (CanQueueResearch 0x20afa60, QueueResearch 0x20afb70): appended to the area's queue `{progress=0 technology date}`, refused while the area researches; select_window hidden | wired, the command in technology.lua (`cmd:technology:research:AREA:TECH`) |
| research: Cancel (the card's) | CCancelResearchTechnologyCommand (CancelTechnologyResearch 0x20aff20): the item out of the queue, its progress added to stored_techpoints_for_tech (done when that reaches the cost); select_window opened | wired (`cmd:technology:cancel:AREA`) |
| research: Auto research | CAutoResearchTechnologyCommand: auto_researching_AREA flipped (frame 3 on, 2 off) | wired (`cmd:technology:auto:AREA`); the daily pick (CCountry::DailyUpdateSerial: GetTechToResearch's weighted choice from the alternatives for a human country with unlocks_auto_research) **[not done here]**: it is the simulation's day |
| research: Researched, its tabs, its close | OnResearched / OnResearchedTab: researched_window toggled, its area | wired (`view_set:researched=AREA`); Researched active (frame 3) while it shows |
| research: select_window's close | OnSelect(): hidden | wired |
| research: the head of research's portrait | Reload::$_1: the view closed, the council view opened (AccessTopBarView(1)) | wired (`view:council`, on the portrait's window) |
| research: Policies | CCategoryPoliciesView for the research category | **not done**: the policy popup is not a window here |
| research: the lists | smooth listboxes, the wheel scrolls them | wired: a row a notch (`sel_scroll`, `res_scroll`) **[I: the game scrolls by pixels]** |
| research: the "technology researched" dialog | from the notification (CTechnologyResearchedDialog: close, new_research opens the area's select_window) | **not done**: no notifications here |
| traditions: an empty slot's Select | enabled when the next tradition is affordable; CTraditionCategorySelectionView shown | wired (`view_set:dialog=categories`), disabled (greyed, no click) when not affordable |
| traditions: the selection's Adopt | enabled when the adoption tradition is possible and affordable; the yes/no popup (TRADITION_ADOPT_CONFIRM) | wired (`view_set:confirm=ADOPTION`), disabled otherwise |
| traditions: a tradition in an adopted tree | clickable where CanActivate: the yes/no popup | wired (`view_set:confirm=TRADITION`) |
| traditions: the popup's Yes / No | Yes: CCountryActivateTraditionCommand (the cost paid, CCountry::ActivateTradition; a category adopted with its adoption tradition), the selection closed; No: the popup closed | wired: `cmd:traditions:adopt:NAME` (engine.traditions.activate) / `view_set:confirm=` |
| traditions: the selection's close, wheel | hidden (its scroll reset); the grid scrolls | wired (`view_set:dialog=`); a row of four a notch (`cat_scroll`) |
| traditions: an untaken perk slot (free or locked) | CAscensionPerksView shown | wired (`view_set:perks=1`) |
| traditions: the perk list's entry | enabled when CCountryActivateAscensionPerkCommand is valid (a free slot); CConfirmAscensionPerkDialog | wired (`view_set:perk_confirm=PERK`), disabled entries greyed |
| traditions: the perk dialog's Yes / No | Yes: CCountryActivateAscensionPerkCommand, the list hidden; No: the dialog closed | wired: `cmd:traditions:perk:PERK` / `view_set:perk_confirm=` |
| traditions: Show Unavailable, the list's close, wheel | the filter (potential instead of possible, the available first); hidden | wired (`unavailable`, `perks=`, `perk_scroll`: a perk's height a notch) |
| traditions: the Ambition tab | enabled with the country's crisis data | disabled (the player has none in these saves); its window is not drawn |

The commands, in the simulation's Lua:

- `technology.command` (lua/render/windows/technology.lua) does CResearchTechnologyCommand,
  CCancelResearchTechnologyCommand and CAutoResearchTechnologyCommand on the save's tech_status
  as the game's code does (research_commands notes: a technology per area in the queue, appended
  at progress 0; the alternatives untouched until it completes).
- `traditions.command` (traditions.lua) calls engine.traditions.activate for a tradition (a
  category's adoption tradition adopts the category) and for a perk.
- The simulation's research (engine/research.lua) compares an item's progress alone with its cost;
  the game adds the points stored for the technology (GetProgress 0x20a6de0, IsDone) and takes the
  stored entry when the technology gains a level (0x20aaa6b). The card shows progress + stored
  here; the completion **[not done here]** (the simulation's day).

The dialogs (lua/render/windows/traditions_dialogs.lua) **[V]** from the code: the category
selection (`tradition_category_selection_dialog`, centred: the potential categories not adopted
in the database's order, 314 x 266 slots four a row, the description the first `desc` whose
trigger holds, else KEY_desc; the tree on hover not drawn: no hover state in the layout), the
yes/no popup (popup.gui `yes_no_popup_window`: TRADITION_ADOPT_CONFIRM, its description with the
tradition's name and COST_VALUE), the perk list (ascension_perks_view.gui: the possible perks, or
the potential ones with Show Unavailable, sorted by name and grouped Ascensions, Ambitions,
General; a group's header 40 and its perks 86 each, 10 apart) and its dialog (standard_dialog.gui:
ASCENSION_PERK_CONFIRM_TITLE / _DESC, Yes, No).

Checked in a real window (the windowed renderer under Xvfb at 1600x900, the 2210.01.01 save loaded
from Load Game; clicks and keys by xdotool): the left bar's icons, Select on an empty slot, Adopt
(Adaptability), Yes (300 unity paid, the tree in the first slot, the next cost 343), a tradition of
the tree, Yes (1 / 5, the cost 448), the perk list and Escape (the list, then the view), the
research offers, an offer chosen (its card at 0/1650), Cancel (the offers again), Auto research's
frame, the Researched list scrolled by the wheel, the category selection scrolled. Not compared
with the game's frames this time (no headless game on the test box during the button work).

## Not done

- The unlock lists' line wrapping, resource and deposit blocker entries, the modifiers' engine
  flags; the leader's portrait; the research view's Policies popup; special projects in the
  queues; the technology researched dialog; auto research's daily pick and the stored points in
  the completion check (the simulation's).
- The crisis (Ambition) tab's window; the category selection's tree on hover; tooltips.
- The views' slide in; the hover box over a left bar button.
