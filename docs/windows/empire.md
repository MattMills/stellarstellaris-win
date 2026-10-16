# The empire and government windows

The left bar's views of the empire, as Stellaris 4.5.2 (Linux) shows them, and how the renderer
(`sim/render`) draws them from the save. **[V]** marks what was read in the game's code (the
Linux build's symbols and disassembly: `/opt/stellaris-headless/re`), its files or a save, or
measured on its frames; **[I]** marks what is inferred. Checked against the game's frames of
`autosave_2210.01.01.sav` at 1600x900, each view opened by the same command in both
(`open_view NAME`): side by side, the game left, in
`H:\code_working\tmp_sym\render3d\parity\win_empire\win_empire_*.png`.

Code: the shared left-bar views (`sim/render/src/views.rs`, win-research's; its API in
docs/windows) and, one per view,
`sim/render/lua/render/windows/{government,leaders,empire,council,edicts,factions,species}.lua`
with what they share in `empire_common.lua` (layout helpers, number formats, the game's
definitions, a small country-trigger evaluator) and `leaders_common.lua` (leaders, their cards,
trait icons).

## 1. Opening the views

- The game keeps its left bar views in `CInGameIdler`'s array at +0xd38, indexed by
  `ETopBarView` (read from the `CInGameIdler::Access*View` getters) **[V]**: 0 situation,
  1 council, 2 traditions, 3 technology, 4 leaders, 5 species, 6 empire, 8 fleet manager,
  10 factions, 11 edicts, 14 government, 15 discoveries, 16 claims, 17 market (7, 9, 12, 13
  named from the left bar's order **[I]**).
- `CInGameIdler::ToggleTopBarView(ETopBarView)` @0x1c8ac70 **[V]**: a shown view is hidden; else
  `CloseTopBarViews()`, the view shown, its number kept at +0xdc8. `CMainGuiLeftBarButton::OnClick`
  @0x2f3acd0 calls it with the button's view (+0x80); the top bar's flag
  (`CMainGui::ToggleGovernmentView` @0x2f32c40) with 14.
- Renderer (render-windows-1's views.rs, app.rs, engine.rs): the left bar's icons carry
  `view:NAME`, the top bar's flag `view:government` (topbar.lua); `view_close`; a view's buttons
  set what it remembers (`view_set:KEY=VALUE`: a tab, the leader or species selected, a sector
  expanded). `open_view NAME` in both the renderer and the game (headless.c's: ToggleTopBarView,
  the reply 4 frames later with the view then current).
- The view is drawn over the alerts and under the left bar, as in the game's frames **[V]**.
- Data: each module's `M.extract(game_dir)` runs where the galaxy is read (the save's world, or
  the simulation's thread), returning `M.data(player, {})`; `M.build(ctx, data, state)` lays the
  view out on the UI thread.

## 2. Government view (`government_view.gui`, CGovernmentView)

- Tabs (UpdateTabs @0x2eb5450) **[V]**: Empire (`government_window/info_window`), Budget (never:
  `CGovernmentViewBudgetTab::ShouldBeAvailable` returns 0), Demographics, Advisor (only with
  more than one playable voice type: not drawn). The tab shown has its `_active` button.
- `heading`: the country's name. `government_authority`: the authority's icon file on
  GFX_government_authority (`gfx/interface/icons/governments/authorities/<key>.dds` **[I]**).
  `government_title`: the government type's name.
- Ethics and civics (UpdateEthics @0x2ebb8f0, UpdateCivics @0x2ebbd20) **[V]**: an `object_icon`
  (game_setup/species.gui) per ethic / civic in saved order, the icon's file on GFX_ethic /
  GFX_government_civic (`icons/ethics/<key>.dds`; a civic's `icon` or
  `icons/governments/civics/<key>.dds` **[I]**), 34 apart in the overlapping box.
- Origin: its name and `icon` file. Elections (UpdateElections @0x2ebaf00): shown when the
  authority has an election type; `ELECTIONS_ON_RULER_DEATH` when its term is 0; the button
  disabled without emergency or democratic elections. The heir window only with `has_heir`.
- Right panel: the temporary modifiers (`empty_mods` "The Empire has no temporary Modifiers."
  when none) or, after `relations_button`, the relations.
- The ruler's card: `paragon_portrait_container_ruler_government` (NInterface
  PORTRAIT_GUI_NAME_GOVERNMENT_VIEW_RULER) in `ruler_container`, see 3.2.
- Diplomatic weight: `§Y<n>§!`, the country's cached value **[V]** (not in the save). The
  renderer sums NDiplomacy's factors of the economy, technology and naval power and the pops
  (155 here; the game's 187 also has the pops' happiness and the weight's modifiers) **[I]**.
- Demographics (UpdatePops): the founder species' name, class, ideal planet
  (`IDEAL_PLANET_CLASS` of its planet preference), `POPS_IN_WORLD`. The pie chart, the traits and
  the pop effects are not drawn.

## 3. Leaders (`topbar_leaders_view.gui`, CTopBarLeadersView)

### 3.1 The view
- Tabs (AddClassButton @0x3318370): `all_tab_container` ("£leader£ All") at (6, 40), then a
  `leader_class_tab_container` per class, each its container's width further (100, then 182)
  **[V]**; a class tab reads `<class>_plural_with_icon`, a line break, used/cap coloured W below
  the cap, Y up to twice it, R beyond (GetClassLeaderCapColor @0x23a3ed0) **[V]**. Envoys have no
  tab and are not listed (`can_be_envoy`) **[I]**. The cap is the class's `leader_capacity` (3);
  its modifiers are not added **[I]**.
- Owned leaders (BuildLeadersToShow @0x3319a90): saved order, sorted by NGuiUtil::SortLeader:
  those without a location first, then by skill **[V]**: Snagg, Voyl, Oilskin, Farshore.
  Header `CURRENT_LEADERS` + " (4)".
- Recruitable leaders: grouped by class; header `AVAILABLE_LEADERS` with
  `DAYS_UNTIL_LEADER_POOL_REFRESH` (the next multiple of LEADER_POOL_REFRESH_TIME, 1800 days,
  from 2200.01.01 **[I]**): "Refreshes 2215.01.01 (5 Years left)".
- Rows: `leaders_view_gridbox_entry` (93 high) with a
  `paragon_portrait_container_horizontal_slim` card; the selected row's `selected_overlay`.
  A click selects. Default selection: the first owned row **[V]**.
- The selected leader's big card: `paragon_portrait_container_expanded` in
  `leader_portrait_container`; the dismiss and assign buttons (hire for a recruitable leader)
  are drawn after it (over it, as in the game).

### 3.2 The cards (CParagonPortraitContainer::Update @0x303d5b0)
- Elements set by name, wherever the template has them: `name_without_title_text`;
  `name_with_title_text` (`NAME_WITH_TITLE_FORMAT` with the government's `ruler_title` for the
  ruler); `leader_type` and `leader_class_banner` frame = the class's `icon`; `skill_icon`
  frame = skill + 1; `leader_rarity_icon` = the tier's index; `councilor_title` = the ruler's
  title or the council position's name (else `leader_class_text`); `council_position_icon`.
- The leader's status: `busy_container` (the ruler, a councillor, or a leader with a location),
  `available_container`, or `in_player_pool_container` (recruitable: age, cost) **[V names; I
  choice]**. In `busy_container`: `activity_text` (`LEADER_RULING` "Ruling From $LOCATION$",
  `LEADER_GOVERNING_PLANET`, a fleet's `NO_ORDERS`) and `location_text`; its icon the planet
  class's `icon` or GFX_fleet_status_icon frame 3 (in orbit) **[I]**. A leader's location
  `type = planet` and a country's `capital` are colony ids: the planet is the colony's carrier
  **[V save]**.
- `upkeep_text`: unity, 2 x skill (`leader_base_upkeep`) **[V data]**.
- Traits: layered icons from the trait's `icon` block (its inline scripts expanded): GFX_trait_bg
  tinted `trait_bg_default`, the trait's sprite tinted `trait_icon_default`, the councillor and
  tier layers (the tier's roman numeral); layers with a `visible` trigger left out **[I]**; a
  trait without an icon: `gfx/interface/icons/traits/<key>.dds` **[I]**.
- `on_hover_*` containers (the council cards' names, ages ...) show while the mouse is over the
  card: not drawn **[I]**.
- Not drawn: the 3D portraits (CPortraitObject: the species' portrait mesh, e.g.
  molluscoid_17_portrait.mesh; there is no 2D still), the leader's background text, the
  experience bar.

## 4. Empire view, "Colonies and Sectors" (`empire_view.gui`, CEmpireView)

- One `planet_list_sector_entry` per owned sector (`country.sectors.owned`), 100 high, 4 apart
  (the list's spacing) **[V]**. The governor: the sector capital's colony's (`local_capital` ->
  `colony.governor`) in a `paragon_portrait_container_horizontal` card **[V]**.
- `sector_name`, `sector_type` ("Core Sector"), `systems` (the sector's systems), `colonies`,
  `pops` (the colonies' `num_sapient_pops`, SI: 5.3K).
- The resource groups (`sectors_*_group`, in the .gui's order: energy, minerals, alloys, food,
  consumer goods, unity, research = physics + society + engineering, others = the strategic
  resources and trade) **[V]**: the colonies' monthly `profits` summed,
  `RESOURCE_GROUP_BALANCE_ONLY` "§W+N§!" or the _NEG key in red (energy red only with less than
  1000 stored), cut toward zero **[V]**. The game's sector table adds the starbases in the
  sector's systems: energy +16 here against the game's +20 **[I]**.
- Sectors start collapsed (the expanded list starts empty **[V]**); a click on a sector's entry
  expands it into `planet_list_planet_entry` rows (name, class, size, balance, districts by type
  with their levels summed **[I]**); a click on a colony selects its planet. The rows' pop
  portraits are not drawn.
- Delete sector and Create Vassal are disabled for a core sector **[V]** (their grey not drawn).

## 5. Council (`council_view.gui`, CCouncilView)

- Background (COUNCIL_DYNAMIC_BACKGROUND, scripted loc GetScriptedCouncilBackground):
  `GFX_council_room_common` without Galactic Paragons, else the authority's room **[V data]**;
  the save's `required_dlcs` has no Galactic Paragons, as the game's frame shows.
- `government_name`: the country's name. The sidebar: GFX_icon_ethics and the ethics under it.
- Councillors: slots 198 apart from (142, 80) (council_view_original_council_grid_position, the
  grid at y -30) **[V]**; the list [ruler placeholder, government.council_positions...] padded
  to 6 and put in the order { 4, 2, 0, 1, 3, 5 } **[V]**: Minister of Defense, the ruler
  (Patriarch, `paragon_portrait_container_ruler_council`), Head of Research, Minister of State.
  Each a `council_position_entry` (its position's name and icon) with a
  `paragon_portrait_container_council` card. Empty slots are not drawn without Paragons **[V]**.
- Agenda: `GFX_council_agenda_icon_<agenda>`, `council_agenda_<agenda>_name`; the early launch
  disabled (frame 4) **[I]**. "You have no active Edicts" without `edicts`. The edict fund: see 9.

## 6. Policies and edicts (`edicts_view.gui`, CEdictsView, CPoliciesView)

- Policy categories (UpdatePolicies @0x30e5390): `policy_category_header_entry` per category but
  `uncategorized`, sorted by `policy_category_<key>`'s text, all collapsed at first **[V]**.
- Edicts (ReloadCountryEdicts @0x2cfb320): common/edicts in database order, those whose
  `potential` holds and whose `prerequisites` are researched **[V]**. The renderer evaluates the
  country triggers they use (is_nomadic, is_gestalt, is_hive_empire, is_<ethic>, has_origin,
  has_civic, has_technology, has_tradition, has_comms_with_alien_empire, AND/OR/NOT ...; any other
  is false) **[I]**: Fortify the Border, Veneration of Saints, as the game lists them.
- Entry `empire_edicts_entry`: the checkbox frame (2 active, 3 can be taken), the edict's icon,
  `edict_<key>`, cost and upkeep in unity: the resource's amount (10); the game's 5 has the cost
  modifiers **[I]**.
- The tabs: Council and Factions open those views; Policies & Edicts is this one.

## 7. Factions (`topbar_factions_view.gui`, CTopBarFactionsViewImp)

- No pop factions: `selected_faction_name_label` "No Factions", no stats, no icon **[V]**.
- The header (Update @0x3306661): the 8 regular ethics in common/ethics' order with the pops
  holding them (`ethics_distribution`) and their monthly change (`pops_ethics_change`), sorted by
  pops, most first, stable **[V]**; label "N\n(+c)", empty when both are 0, its icon then centred
  in its slot **[V]**; the change green / yellow / red **[I]**.

## 8. Species (`topbar_species_view.gui`, CTopBarSpeciesViewImp)

- The species with pops on the country's colonies, by population, most first (sort type 3,
  descending) **[V]**; the first selected **[V]**. Each `species_entry`: "§E<name>§!\n<template
  type>" (`TEMPLATE_TYPE_FOUNDER` for the founder, else `_DEFAULT` **[I]**), `SPECIES_VIEW_TOTAL_POP`,
  `SPECIES_VIEW_VARIANTS` (1), the traits but the planet preference (positive first **[I]**), the
  preference's icon, population, rights: citizenship, or the slavery type for a slave
  (Full Citizenship, Chattel Slavery) from `standard_species_rights_module` **[V]**.
- The selected species' panel: `GFX_species_selected_background_<preference trait>`, name,
  class, home planet, traits, pops, preference ("Ocean"), rights, template, the actions' texts.
  The portraits are not drawn. `species_traits.gui` is not used by this view **[V]**.

## 9. General rules added to the layout (gui.lua, scene.rs)

- An iconType the code makes clickable is a button (the left bar's icons).
- A button's text: its `buttonText`, else its `text` (government_view's buttons), else what the
  game sets on it, in its `format` within its `borderSize` (the leaders list's headers).
- `opts.textures[path]`: an icon's texture set at run time (a file, or a sprite name).
- Texts break at "\n" and wrap at words when their box has room for more lines; a box without
  `fixedSize` grows to fit its lines, a fixed one cuts its text with " ..." **[I: from the
  frames]**.

## 10. Not done yet

- Values the game takes from the modifier graph: the edict fund (40 in the game, 10 here: only
  `empire_base`'s part), the edicts' costs (5 / 10), the diplomatic weight, the leader caps'
  modifiers. The sim's `engine.modifiers` computes country modifiers from the world and the
  game's definitions; the views' data runtime has the world only.
- The 3D portraits (leaders, councillors, species) and the government's city background (a
  layered 2D picture: gfx/portraits/city_sets, environments by planet class).
- A disabled button's grey (the game's disabled effect desaturates).
- List clipping: a row the game's list cuts is left out (the recruitable leader under the owned
  ones).
- The leader's background text, the experience bars, the Demographics tab's pie chart and pop
  effects, the expanded colony rows' pop counts, the districts' maxima.
- Tooltips.

## 11. The buttons

What each clickable element does in the game (the views' handlers and commands, read in the 4.5.2
Linux build: **[V]** with the function in sections 2 to 8 and in the shared notes'
`empire_re/commands.md`) and in the renderer. Three kinds of action:
- the view's state (`view_set:KEY=VALUE`): tabs, sorting, rows expanded or selected, popups;
- a simulation command (`cmd:VIEW:VERB:ARG...`, render-buttons-1's views.rs: the module's
  `command(VERB, ARG...)` runs `render.windows.empire_commands.run` in the simulation's runtime
  between days, then a snapshot shows the result): the game's own command redone on the world;
- another view or window (`view:NAME`, `view_close`, `select:planet:ID`).

Escape closes a view's popup first (its `escape_keys`: the council's agenda list, the species'
rights popup), else the view. A view draws its frame alone until its data has come (every read of
the data guarded). The wheel scrolls the leaders' list (its `wheel`).

| view | element | the game | here |
|---|---|---|---|
| all | close (X), Escape | closes the view | wired |
| left bar, top bar flag | the view's icon | ToggleTopBarView | wired (views.rs) |
| government | Empire / Demographics tabs | TabGovernment / TabDemographics | wired (state) |
| government | Modifiers / Relations | the right panel's mode | wired (state) |
| government | emergency_election_button | an election (democratic only) | disabled as the game's here |
| government | Reform Government | CGovernmentModWindow (authority, civics; costs unity x empire size) | not done (the window is not drawn) |
| government | empire_rename_button | the rename dialog (`name`, `adjective`) | not done (no dialog) |
| government | ruler card | the leader's view | not done |
| leaders | All / class tabs | ShowLeaders: the class filter | wired (state) |
| leaders | a row | the leader selected | wired (state) |
| leaders | section headers (minus / plus) | the section collapsed / expanded | wired (state) |
| leaders | Hire | ShowRecruitLeaderDialog, then CRecruitLeaderCommand: unity paid, pool -> owned_leaders, recruitment_date | wired (command; the dialog not drawn) |
| leaders | Dismiss | ShowFireLeaderDialog, then CFireLeaderCommand (not the ruler) | wired (command; disabled for the ruler; no dialog) |
| leaders | Assign | the job list (CAssignLeaderCommand) | disabled: the job list not done |
| leaders | the list | the wheel scrolls it | wired (wheel) |
| empire | sort buttons | SetSort<N>, again reverses | wired (state) |
| empire | a sector's entry | ToggleExpanded | wired (state) |
| empire | a colony's row | ShowPlanetView | wired (`select:planet`) |
| empire | delete / Create Vassal | disabled for a core sector | disabled as the game's |
| empire | edit / rename / governor card | the sector edit view, the rename dialog, the assign widget | not done |
| council | Factions / Policies & Edicts tabs, Open Edicts | the other views | wired (`view:`) |
| council | agenda list button, its close | ToggleCouncilAgendaView | wired (state; Escape closes it) |
| council | an available agenda | the agenda chosen (council_agenda, progress 0) | wired (command), the list closed |
| council | an unavailable agenda | disabled | disabled |
| council | early launch | CEarlyFinishAgendaCommand | disabled as the game's here |
| council | a councillor's card | the assign widget | not done |
| edicts | Council / Factions tabs | the other views | wired |
| edicts | a category's header, collapse all | ToggleCategoryCollapsed / ToggleAllCategoriesCollapsed | wired (state) |
| edicts | a policy's row | its options shown | wired (state) |
| edicts | an option | the policy set (selected, date; 10 years between changes) | wired (command) |
| edicts | an edict's checkbox | CAddEdictCommand (unity paid; perpetual) / CRemoveEdictCommand | wired (command) |
| factions | tabs | the other views | wired |
| factions | sort buttons, Manage, rename | the factions' list (none in the 2210 save) | not done (no factions to show) |
| species | Empire / All Species tabs | ChangeViewMode | the tab's state only (the galaxy's species not listed) |
| species | sort buttons | OnSetSortTypeSpecies | state (one species group a row: the sort shows no change here) |
| species | a row | the species selected | wired (state) |
| species | Set Species Rights, Default Rights | the rights popup | wired (state; Escape closes it) |
| species | a right's group, an option | its options; CSetSpeciesRightsCommand | wired (state; command) |
| species | Reset To Empire Default | the species' own rights removed | wired (command) |
| species | Set as Default | CSetDefaultSpeciesCommand | not done: its save field is not known (disabled for the default species) |
| species | home planet button | OnHomePlanet | wired (`select:planet`) |
| species | Create Template, Apply This Template | the species' editor | not done |

What the commands leave out [not done here]: the cost multipliers (edict costs, the leader's cost by
level), the edict's `effect` / `on_disabled` and the agenda's effects, the 10-year lock written by
species rights, a hired leader's replacement in the pool.
