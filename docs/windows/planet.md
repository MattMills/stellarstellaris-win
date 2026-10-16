# The planet view

The window a planet opens (`interface/planet_view.gui`, the game's `CPlanetView` and its tabs) and
the colonize window it opens (`interface/colonize_planet_view.gui`, `CSurfaceView`), as the renderer
draws them:

- `sim/render/lua/render/windows/planet.lua`: `planet.data` reads the planet from the save's world
  (the map's runtime), `planet.build` lays the windows out (the front end's runtime);
- `sim/render/src/planet.rs`: the window's state (the planet, its tab, the colonize window), the
  data handed between the runtimes (`RENDER_PLANET`), the portraits and the textures it composes;
- hooks in `app.rs` (the state, the actions `planet_tab:TAB`, `planet_colonize`, `colonize_close`),
  `engine.rs` (`open_planet`), `render/windows.lua` (the planet branch).

Marks as in [render.md](../render.md): **[V]** read in the game's code or files, or measured in its
frames; **[I]** inferred. Addresses are the 4.5.2 Linux build's.

## Opening it, its tabs

- The game opens it with `CInGameIdler::ShowPlanetView(CColonyCarrier const&, EPlanetViewTab)`
  @0x1c88d20 (the empire view's planet entry: `CEmpireViewPlanetEntry::OpenPlanetView` @0x2d0b550,
  tab 0); the carrier from `CColonyCarrier::LookupCarrierRef(variant<TPdxRef<CPlanet>,
  TPdxRef<CShip>>)` @0x28d5bb0; the view is `CInGameIdler` +0xb30 **[V]**. Clicking the outliner's
  colony row opens it too (the game's frames, by `click`).
- The tab is `CPlanetView` +0xc3a0: 1 summary ("Infrastructure"), 2 management, 3 population
  ("Economy"), 4 armies, 5 corporate ("Holdings"), 6 arkship **[V]**. Tab 0 keeps the current tab:
  another planet opens on the same tab, the summary where that tab cannot open
  (`CPlanetView::CanOpenTab` @0x30645f0: management for any planet whose details the player sees,
  population, armies and holdings for a completed colony) **[V]**, as the game's frames show (the
  holdings tab kept for the next colony, management for an uncolonised planet, the summary for a
  gas giant after the armies tab).
- `CSharedPlanetView::Show` opens only if `ShouldDisplayPlanetInfo(observed)`: the game's
  `open_planet 15` (another empire's colony, far away) leaves the window as it was **[V]**. Not done:
  the renderer opens any planet.
- Headless (`headless/headless.c`): `open_planet ID [TAB]` calls ShowPlanetView, then a frame later
  the tab's own click handler (`CPlanetView::OnManagementTab` ...); `colonize` and `resettle` call the
  buttons' handlers (`OnColonize`, `OnResettle`); `open_planet close` is `CloseClick`.
- The renderer: `open_planet ID [TAB]` (without a tab: the current one), `open_planet ID colonize`,
  `open_planet close`; the tab buttons, the close buttons, the outliner's rows and the map's planets
  by clicking.
- The game's buttons take a click only with the press and the release in different frames: a
  `click` (both in one frame) opens the planet view from the outliner but does not switch its tabs;
  `mouse X Y left down`, `tick 3`, `mouse X Y left up` does **[V]** (the game's frames).

## Data

From the save's world (the map's runtime, `planet.data`):

- the planet (`planets.planet.<id>`): class, size, owner, controller, colonize date, `surveyed_by`,
  deposits (`deposit.<id>`: type, swap type);
- its colony (`colony.<id>`, 4.5: `planet.colony` names it): `stability`, `crime`,
  `free_housing`, `free_amenities`, `final_designation`, `designation` (a chosen one), `produces`,
  `upkeep`, `districts` (-> `districts.<id>`: type, level, zones -> `zones.<id>`: type, buildings
  -> `buildings.<id>`: type), `pop_groups` (size, key.species, key.category, habitability),
  `pop_jobs` (type, workforce, max_workforce, workforce_limit, `pop_groups` with amounts), `army`
  (-> `army.<id>`: name, type, health, morale, species), the month's growth details;
- the owner (`country.<id>`): capital, city set, technologies, `budget.current_month.income.
  country_base` (the empire's base production on its capital), the sector (`sectors.<id>`:
  systems, name, type, local capital).

The save keeps the colony's values as the game computed them and the window shows the same
**[V]** (the frames of 2210.01.01 match). A running simulation's world is on its own thread:
there the window has the planet's name only (not done yet).

The definitions it reads (`common/...`: planet classes, deposits and their categories, districts,
zones, zone slots, buildings, colony types, pop jobs and categories, armies, ship sizes, traits,
strategic resources, scripted variables) in load order (the database index: the files by name,
each top to bottom).

### The game's triggers

District names (`triggered_name`), the districts a planet can have (`potential`,
`show_on_uncolonized` with the observer as FROM), `is_uncapped`, zone slot `unlock`s, job swap types
(`swappable_data`, the highest weight that holds), army `potential` / `potential_country`, cost
triggers: all evaluated by the simulation's script layer (`simscript.eval.trigger`) over the world
in the map's runtime. What it needs there, set up on first use (`trigger` in planet.lua):

- `simscript.db`'s scripted triggers and script values (the table starts empty, not nil);
- `engine.scriptstate.install()`: the save's flags and variables (else `has_flag` fails);
- `engine.defs`: a folder read when first asked for (the runtime loads none: `E.district_set`);
- the planet climate triggers it lacks (`is_wet`, `is_dry`, `is_cold`: the class's `climate`),
  added only where it has none.

`PLANET_TRIGGER_DEBUG=1` prints each false trigger's statements with their own results;
`PLANET_DUMP=<text>` prints the window's items whose path has the text.

## The header (UpdatePlanetTopBar @0x3066270, UpdatePlanetTabState @0x306b190)

- A "completed colony": a colony whose details the player sees (`CanSeeColonyDetails` @0x2a92640:
  the player's own; another country's with intel level 3 or more on its system) **[V]**; then
  `colony_type` (the final designation's `icon` and name) and the stats row's numbers show.
- The stats row (`planet_actions_window`, always shown for planets; its numbers only for a
  completed colony) **[V]**:

  | box | value | format | colour |
  |---|---|---|---|
  | stability | `stability` | whole %, cut: 63.2456 -> 63% | green > 50, yellow 50, red < 50 |
  | pops | the pops | SI | white |
  | crime | `crime` | whole %, cut | red > 50, yellow > 0, green 0 |
  | housing | `free_housing` | SI, 1 decimal cut: 1188.2 -> 1.1K | red < 0, yellow 0, green > 0 |
  | amenities | `free_amenities` | SI | as housing |
  | jobs | vacant jobs | SI integer | yellow when 0 |
  | unemployed | colony +0xfcc (the civilian pops **[I]**: 945, the frame's) | SI integer | green < 500 |

  SI numbers (`CreateValueNoColor` @0x42ca5b0): from 1000 divided by 1000, 1e6, 1e9 with K, M, G,
  decimals cut, not rounded; under 1000 integers plain **[V]**.
- The flag: the owner's; an unowned planet's the pre-communications flag
  (`flags/special/unknown.dds` on a black field **[I]**), composed as the owner's are.
- The header's buttons **[V]**: previous / next with an owner; `move_capital` on the player's planet
  that is not its capital; `open_orbital_ring` with a ring; close and zoom always.
- `colonize_button_container`: an unowned planet of a colonizable class; the button drawn disabled
  (the game's frames of 2210: the player cannot colonize yet **[I]**), its handler opens the
  colonize window (below).
- The portrait: the planet's picture (`picture`, else the class's) composed from
  `gfx/portraits/environments/<picture>_sky.dds` and its layers `_l01`.., each followed by the
  owner's city set layer of the same number (`gfx/portraits/city_sets/<city culture>_city_lNN.dds`)
  up to the main district's level **[I]**, the rows the window's `portrait` container shows (the
  800 x 400 picture is clipped). The game's frame of the capital shows a few more spires.
- The tabs **[V]**: `X_tab` when not current, `X_tab_active` when current; the armies pair on
  planets; the corporate tab never hidden.

## Infrastructure (UpdateSummaryTab @0x306d260 and its parts)

- A completed colony: `colonized_planet_window` + `colonizable_planet_window` (no description); an
  unowned colonizable planet: `colonizable_planet_window` with its description; else
  `uncolonizable_planet_window` (the description, the resources it would give: 2 decimals) **[V]**.
- Districts: the main district (the colony's first; uncolonised: the first type shown on
  uncolonized planets) in the wide entry; the others (the colony's types and every potential one,
  in database order) narrow **[V]**. Each: the plural name, the first triggered name that holds,
  the icon (`gfx/interface/icons/districts/<icon or key>.dds`), its overlay, its own background
  (`GFX_<district_background or icon>_bg`) and box sprites (`GFX_<gridbox>_box_icon_rectangle`,
  `grid_box/<gridbox>_big.dds`), "built/max" with max the cap plus the blocked slots **[V]**.
- Caps: an uncapped type (no `is_uncapped`, an empty one, or one that holds): the planet's slots
  (size and the deposits' `planet_max_districts_add`: 18 - 3 = 15) plus the blocked ones (3/18);
  a capped type: its deposits' `district_<type>_max_add` (generator 1 + 2 + 3 = 6) **[I]** from
  the files and the frames (the modifier system is not used).
- Boxes: built frame 1, buildable frame 2, the rest frame 3 **[V]**.
- Zones: slot 1 in the entry's zone, the others as zone entries; a zone's buildings
  (`gfx/interface/icons/buildings/<icon or key>.dds`) then empty slots up to its `max_buildings`
  (default 3: `DEFAULT_MAX_PLANET_BUILDINGS_PER_ZONE`); an open slot "Specialization Available", a
  locked one "Specialization Requires:" and its unlock's `fail_text` **[V]**.
- The header's free slots: `max - built` (green), the available-district boxes **[V]**.
- Colony production / deficit: produces - upkeep (+ the empire's base on the capital), each
  resource rounded up, `+` on gains, in the resources' database order, wrapped **[V]**. The
  research resources' text icons are £physics£ etc. The capital's unity shows +40 where the game
  has +38 (the save's country_base unity 12, the game's tooltip 10) and trade +74 for +75: not
  resolved.
- The side: class (its large icon), habitability (the best of the colony's pop groups **[I]**; 0%
  for an uncolonizable class), "Colonized:", "Size:", the designation chosen or "Auto Designated"
  (its icon, `COLONY_TYPE_DEFAULT_SPRITE`, not found: not drawn) **[V]**.

## Management (UpdatePlanetTabManagement @0x30699a0)

- Blockers "x3", rare "x0"; "?" and "We need more Intel" until the player surveys a planet not its
  own **[V]**.
- Deposits: every blocker, the others once a type with "(xN)"; blockers first, then important,
  then by database index **[V]**; the icon, the blocker frame (clearable 1), the clear cost
  (`time` and the cost: £time£120 £energy£300), the swap type's icon; effects: produced resources
  and the planet modifier (the district caps' icon £district£ **[I]**).
- Species: the pop groups by species id, the size and last month's growth **[V]**; the pie's legend
  in the order of the pop groups, the species palette **[V]**.
- Monthly pop summary: last month's growth, GROWTH_CAT_GROWTH + DECLINE, IMMIGRATION - EMIGRATION,
  ASSEMBLY, `+` and colours **[V]**.
- Sector: its name and type, its button by capital / member / none; Colony Ascension **[V]**.

## Economy (UpdatePopulationTab @0x306f170)

- The jobs kept: workforce >= 0 or pops in them **[V]** ("14 Job Types").
- Categories by the display category's rank (high first), then its index; jobs within by their own
  category's rank, then the save's order **[V]**: Elites 200, Specialists 1.5K, Workers 2.6K,
  Civilians.
- Job icons: the active swap type's `icon` (`gfx/interface/icons/jobs/job_<icon>.dds`): the
  bureaucrat a priest, the artisan's own **[V]**; amounts the pops working them; the workforce bar.
- The arrow between upkeep and production is `rotation = 1.56`: planet.rs turns its texture.

## Armies (UpdateArmiesTabDefenses @0x3079010)

- Garrison / assault: the defensive / other armies' power, `((health + morale/2) x damage a
  day)^0.65 x 0.25` (NArmy; damage 2.25 x the type's) **[V]** the formula: 33.8 a defense army, 169.
- Armies in the save's order: "1st Hardshell Defenders" (`%SEQ%`, render.names), species, power,
  health % **[V]**; both checkboxes checked by default **[V]**.
- Recruitment: army types not pop-spawned nor defensive **[I]**, with the owner's technologies,
  `potential_country` and `potential` holding, for each of the colony's species not enslaved **[I]**;
  by name then species; cost "£time£ 90 £minerals£ 100" **[V]**.

## Holdings (UpdatePlanetTabCorporate @0x306ae60)

Corporate (with Megacorp) and Overlord side by side (a horizontal list), "No ... holdings" **[V]**.

## The colonize window (CSurfaceView::ShowWithPlanet @0x2bcabb0)

Opened by `CPlanetView::OnColonize` -> `NExpansionView::OpenColoniseView` **[V]**. Drawn: "Colonize
<planet>", the founder species (**[I]**: `ListColonizerSpecies` not read) with its habitability (its
traits' `pc_<class>_habitability`, the traits file's own `@primary`; aquatic +0.2 on a wet planet,
-0.2 elsewhere **[I]**: 100% and 0% in the frames), its traits' icons overlapping, the colony ship's
cost (the colonizer ship size's costs whose triggers hold: 200 food, consumer goods, alloys), the
districts shown on uncolonized planets ("?" until surveyed), class and size, the deposits (a
blocker's frame 2), "Auto Designated", the planet's picture. The game leaves it open behind the
planet view when another planet opens; the renderer shows it for its own planet only.

The manual resettlement window (`manual_resettlement_view.gui`) needs two resettleable colonies
(`CPlanetView::OnResettle` @0x3059eb0): this save's player never has two, and the game opens
nothing (its frame) **[V]**; not drawn.

## Texts (planet.lua `settle_texts`, the window's own items)

- An instantTextBox with neither `size` nor `maxWidth` and one line high is as wide as its text
  (render.gui gives it 100 and the renderer cuts it at 100: "Colony Summary" whole in the frame)
  **[I]**.
- A box of several lines wraps at its width, a word fitting only with the space after it
  (379 + 4 > 380 and 280 + 4 > 282 wrap in the frames) **[V]**; `\n` a new line; centred vertically
  with `vertical_alignment = center`; icons as wide as their frame.
- Smooth list entries are at their slot without their own `position`; grid box entries keep it
  (the deposits list's first entry at its top; the colonize districts at +10, +12) **[V]** the frames.
- A sprite set at run time keeps the element's scale (`scale = 0.65`: 50 px district icons).

## Compared with the game

`autosave_2210.01.01.sav`, 1600x900, the game by `headless/view.sh`, the renderer by the same
command files (`open_planet`; then by clicks: the outliner's row, each tab, close):

- the capital: every tab, by `open_planet` and by clicking: the texts and numbers match (stats row,
  3/18 5/18 2/6 1/6, "Space Age Industry", "Basic Fishing", +37 +57 ... -7, Industrial Wasteland,
  2.6K +2, 14 Job Types, 60 60 60 320 100 200 150 600, Garrison 169, 1st Hardshell Defenders 34
  100%, Assault Army 90 100, No Corporate holdings); mean pixel difference in the window's area
  4-7 / 255, the parts below;
- a gas giant, a barren moon, an unsurveyed ocean world, a desert world (summary and management),
  the colonize window of the ocean and the desert world: the same layout, texts and numbers.

Not drawn yet: the governor's and species' portraits and the governor's name (paragon portrait
containers), the pie charts, the Economy tab's upkeep and production boxes (the modifier system),
the planet modifiers row, the build queues, the side bar's other windows (building, district,
decisions, terraform), ShouldDisplayPlanetInfo, the window during a running simulation, scrolling
and clipping of long lists (an entry is drawn while it fits).

## Buttons (wire-planet)

Clicks send `planet:` actions to `planet::act` (planet.rs). Changes to the game go through
`render.windows.planet.command` (planet.lua), which runs on the simulation's thread. A click on a
save loaded world-only starts the simulation and runs the command once it is ready. The window
then reads its data again. What each button does in the game comes from the RE of its handlers
(`CButtonObserverGlue` members, `/root/wp/re_buttons.md` on .24).

The script verb `open_planet act ACTION` sends one action the way a button does, and the reply is
the simulation's answer (for example `ok queued district district_city item N`).

| Element | In the game | Here |
| --- | --- | --- |
| Tabs (infrastructure, management, economy, armies, holdings) | the tab (`On*Tab`) | wired `planet:tab:X`, closes the side bar **[V]** |
| header close | closes the view | wired **[V]** |
| previous / next planet | `JumpToColony`, the owner's colonies | wired: the player's colonies (`galaxy.planets`) **[I]** for another owner's planet |
| zoom_to_planet_button | camera focus | wired: the system, then the planet |
| move_capital | `CMoveCapitalDialog` → `CMoveCapitalCommand` | shown as in the game; **[not done here]** |
| rename (planet name) | `CColonyRenameDialog` | **[not done here]** (no text input) |
| header colonize button | the colonize window | wired `planet:colonize`; disabled as in the game's frames |
| colonize window close | closes it | wired, and Escape too **[V]** |
| colonize window colonize / designation tiles | `CFleetColonizePlanetCommand` / `CCountryExpansionCommand`; tiles select a designation | **[not done here]** |
| resettle | the manual resettlement window | **[not done here]** (needs two colonies) |
| district tile (`district_button`) | side bar 9, district details | wired `planet:side:district:TYPE`, selection highlight **[V]** |
| district Build (tile and details) | `CAddBuildableToQueueCommand` | wired `planet:cmd:build_district:TYPE`: cost paid, queued **[V]** |
| district Downgrade / Replace / Clear Blocker | confirm dialog / side bar 10 / queue a blocker | frames as the game's **[V]**; effects **[not done here]** |
| empty building slot "+" | side bar 7, construction | wired `planet:side:construction:ZONE:SLOT` **[V]** |
| construction entry (`button_build`) | `CAddBuildableToQueueCommand` | wired `planet:cmd:build_building:ZONE:TYPE` **[V]** (list: see below) |
| building | side bar 8, building details | wired `planet:side:building:ID` **[V]** |
| building upgrade entry | `CAddBuildableToQueueCommand` (upgrade) | wired `planet:cmd:upgrade_building:ID:TYPE`; the list only with the upgrade's technologies **[V]** |
| building Disable / Downgrade-Demolish / Replace / Repair | `CToggleBuildingEnabledCommand` / `CDestroyBuildingDialog` / side bar 7 / queue a repair | frames and labels as the game's **[V]**; effects **[not done here]** |
| open zone slot (`zone_button`) | side bar 5, zone construction | wired `planet:side:zone_construction:DISTRICT:SLOT` |
| zone construction entry | `CAddBuildableToQueueCommand` | wired `planet:cmd:build_zone:DISTRICT:SLOT:TYPE` |
| designation button | side bar 4 (toggles) | wired `planet:side:designation` **[V]** |
| designation entry | `CSetColonyTypeCommand` | wired `planet:cmd:designation:TYPE` (`auto`: the automatic one) |
| automation gear | side bar 1, automation settings (toggles) | wired `planet:side:automation` **[V]**; its settings list **[not done here]** |
| decisions button | side bar 3 (toggles) | wired `planet:side:decisions` **[V]** |
| decision entry | `CEnactDecisionCommand` | UI only; **[not done here]** |
| terraform button | side bar 2 (toggles); greyed without a link | greyed without tech_terraforming **[V]** (the capital at 2210) **[I]** the rule |
| terraform entry / abort | `CStartTerraformationCommand` / `CCancelTerraformationCommand` | **[not done here]** |
| side bar close | side bar 0 | wired, and Escape closes the side bar before the view **[V]** |
| build queue rows | cancel `CRemoveBuildableFromQueueCommand`; priority arrows | rows shown (title, days left or position, progress) **[V]**; cancel and priority **[not done here]** |
| deposits clear blocker | `CAddBuildableToQueueCommand` | **[not done here]** |
| jobs +/-, slider, restore jobs, favourite job | `CChangeJobWorkforceLimitCommand` and others | **[not done here]** |
| pop / pop group rows | side bar 11, pop details | **[not done here]** |
| species view | species view | **[not done here]** |
| armies: deploy in orbit checkbox | `planet->ToggleDeployArmiesInOrbit()` (no command) | wired `planet:cmd:deploy_in_orbit` (the planet's `deploy_armies_in_orbit`) |
| armies: army builder checkbox | `CToggleIncludeInArmyBuilderCommand` | wired `planet:cmd:army_builder` (the colony's `include_in_army_builder`) |
| armies: recruit entry | `CAddBuildableToQueueCommand` (army) | wired `planet:cmd:recruit:TYPE:SPECIES` |
| armies: disband | confirm, then `CDisbandArmyCommand` | wired `planet:cmd:disband:ID`, without the confirm **[I]** |
| armies: embark all, land, army rows | `CMoveArmyToOrbitCommand`, `CFleetLandArmiesCommand` | **[not done here]** |
| governor / general portraits | assign-leader widget; right click unassigns | **[not done here]** |
| sector buttons, ascension, branch offices | sector commands and views, dialogs | **[not done here]** |

Commands refuse a planet that isn't the player's colony, and a cost the player can't pay
(`invalid: cannot pay`). **[I]** The game greys Build instead.

Known gaps in the side bar lists:
- **[I]** The construction list includes buildings whose potential the trigger engine can't
  decide; at 2210 that adds Aid Agency and Bone Garrison.
- **[I]** Its days lack the colony's modifiers (360 here against the game's 314).
- **[I]** The decisions list holds Expel Excess Population and misses the crime decisions, and
  Distribute Luxury Goods costs 100 against the game's 600.
- Effects texts, the category tabs and wheel scrolling of the side bar's lists are
  **[not done here]**.

Checked:
- **Headless game against the renderer, same clicks** (press and release in separate frames):
  outliner → capital, district tile, an empty slot, a building, Auto Designated, Decisions,
  Terraform, the gear, then Escape twice. The side bar's windows, placement, buttons, labels and
  the Escape order match.
- **Real window** (Xvfb, Load Game, world-only), the same path: Build queued the district (680 →
  230 minerals, queue row, days counting down) and a second Build was refused. Escape closed the
  side bar, then the view.
