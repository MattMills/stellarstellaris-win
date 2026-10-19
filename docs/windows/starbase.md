# The starbase windows

The renderer's starbase family of windows: the selected starbase's **starbase_view**
(`interface/starbase_view.gui`), a megastructure's **megastructure_view**
(`interface/megastructure_view.gui`), a waystation's **waystation_view**
(`interface/waystation_view.gui`) and a waystation network's **waystation_network_view**
(`interface/waystation_network_view.gui`), drawn from the game's GUI files with what the save holds.

| file | |
|---|---|
| `sim/render/src/starbase.rs` | what is open (the tab, the megastructure, the network), `open_starbase`, the `starbase:...` clicks, the flags put on the windows' flag sprites |
| `sim/render/lua/render/windows/starbase_data.lua` | the save's values, read where the world is (`galaxy::extract`: the map's runtime) as a Lua chunk (`Galaxy::starbases`, so it travels in snapshots) |
| `sim/render/lua/render/windows/starbase.lua` | the starbase window's layout (render.gui) and what the game computes from its definitions |
| `sim/render/lua/render/windows/megastructure.lua`, `waystation.lua`, `network.lua` | the other three windows |
| `headless/headless.c` `open_starbase_cmd` | the game side: `open_starbase [starbase\|waystation\|megastructure\|network] ID [tab N]` |

Marks as in docs/render.md: **[V]** read in the game's code or files, or measured in its frames;
**[I]** inferred. Functions are the Linux 4.5.2 build's (`/opt/stellaris-headless/re` on
10.5.0.24). Comparisons: the 2210.01.01 autosave at 1600x900, the same command file run by
`headless/view.sh` and the renderer, the game left and the renderer right
(`.24:/root/sbw/c_*.png`, made by `/root/sbw/cmp.py GAME RENDER OUT x0 y0 x1 y1`).

## 1. Opening them

| how | game | renderer |
|---|---|---|
| a starbase's station fleet selected (outliner, map, `select fleet ID`) | `CInGameIdler::Select` on the CSelectable at CFleet+0x18, then `ShowStarbaseView` [V] | starbase_view for a fleet that is a station (`windows.lua`'s starbase branch) |
| a starbase whose type is `is_waystation` | `ShowWaystationView` instead of the starbase view [V] | waystation_view (`starbase.lua` hands it to `waystation.lua`) |
| a megastructure | Select on CMegaStructure+0x28, `ShowMegaStructureView` [V] | `open_starbase megastructure ID`: its own state (the renderer has no megastructure selection); a selection replaces it |
| a waystation network | Select on CWaystationNetwork+0x18, `ShowWaystationNetworkView` [V] | `open_starbase network ID`, the waystation window's network box, a connected network's entry |
| close, previous / next, goto | the header's buttons (`CStarbaseView::OnPrevStarbaseClick` / `OnNextStarbaseClick`, `CAbstractStarbaseView::Goto`) [V] | `close`, `starbase:prev` / `next` (the owner's starbases by id [I]: the game's order not read), `starbase:goto` (the system entered, the station followed) |

**The views hide unless their object is selected** [V]: `open_starbase` in headless.c selects first
(the CSelectable offsets above), then calls the Show function; `tab N` clicks the tab's button.
Objects are found in their TPdxRef databases (+0x18 entries of 16 bytes, the object at +8; +0x20 the
count) [V].

## 2. The data (`starbase_data.lua`)

- The starbase: its level and ship size (the station's growth stage), next level and size
  (`common/starbase_levels` `next_level`), owner (`world.fleet_owner`), system
  (`galactic_object.starbases`), modules and buildings by slot, the slots (the most any level of
  the chain has) and the capacities (`starbase_module_capacity_add`, `_building_capacity_add`,
  from the simulation's modifier node when it runs, else the parts' modifiers summed [I]), sensor
  and hyperlane ranges, design (`is_designable` sizes), the platforms (the fleet's ships less the
  station), the queues (the store's `construction.item_mgr.items`, an upgrade shown as its next
  size) [V for the keys].
- The tabs' facts: shipyard = a shipyard queue and `construction_type` starbase_shipyard
  (`IsShipyard`) [V]; hatchery and beastport the same with their types [I]; the army hub enabled
  for a system in a sector [I: the rest of `IsEnabled` not read]; the cloaking row only with First
  Contact (`NGameDLC::IsEnabled(0x400000)`, from the save's `required_dlcs`) [V].
- Megastructures: name (its own, else the type's), type, portrait, owner, system, planet, upgrade
  (a type's `upgrade_from`) [V for the keys].
- Waystation networks: the save's `waystation_networks`, whose members are written by
  `CWaystationNetwork::WriteMembers`: `name`, `waystations` = { starbase ids }, `networks` = {
  connected network ids } (tokens 0x1b, 0x45b8, 0x45b9: `CToken::CToken` in the token table's
  constructor names 0x45b8 "waystations", 0x45b9 "networks") [V]; the owner the stations' [I].
  **No save at hand has a waystation or a network** (every `waystation_networks_manager` empty).

## 3. starbase_view

- **Header** (`CAbstractStarbaseView::Update`): STARBASE_NAME with the name, the level's picture
  [V]; the planet button for a system with a colony of the owner [I].
- **Tabs** 0 Command, 1 Defenses, 2 Shipyard, 3 Army Hub (`SetupSpecialized`: AddTab 0..3) [V]:
  the chosen tab's `_active` button; Shipyard shown when enabled, else Command
  (`UpdateSpecialized`: `ShowTabView<0>`) [V]; the shipyard tab reads STARBASE_HATCHERY_TAB /
  STARBASE_BEASTPORT_TAB for those [V].
- **Command**: the class, upgrade (shown with a next level; enabled for its own with the next size's
  prerequisites researched and no upgrade queued [I]), dismantle (Return occupied, Dismantle the
  lowest level, Downgrade above [I]), details and retrofit (its own [I]); the design or the module
  and building grids (`CStarbaseComponentGridController::UpdateCustom`: slots unlocked below the
  capacity, locked from it on) [V]; the modifiers' text (sensor, hyperlane detection); the build
  queue (`CConstructionQueueListItem`: icon frame 8 for an upgrade, 22 for a module or building,
  the ship class's for a ship; STARBASE_UPGRADE / STARBASE_UPGRADE_NAMED, BUILD_TIME_REMAINING,
  QUEUED_NUMBER; the priority buttons enabled up from the second, down before the last) [V].
- **Defenses**: platforms count and capacity, `no_orbitals` while empty, disband_all with
  platforms; the upgrade disabled (`CalcCanUpgradeDefensePlatforms` not evaluated) [I]. The game's
  frame has no "Docked" label: hidden here [I].
- **Shipyard**: the shipyards' count, the fleets in orbit (the owner's in the system), the queue,
  the modifier grid (types 285 cost, 283 speed, 284 time: `GetModifiersToDisplay`) [V].
- **Army Hub**: the sector's planets (the owner's colonies in the sector) [I].
- **Disabled buttons are greyed** as buttonstate_onlydisable.shader's Disable effect (luminance
  0.212671, 0.715160, 0.072169; greyness 0.85; brightness 0.75) [V]: a negative alpha on the quad
  (`scene.rs` mode 4); their labels in the nearest text colour [I].
- Fleet class icons (GFX_ship_class_small): science 1, construction 2, military 3, starbase 8
  (matched to the game's frames by pixels; `CFleet::GetIconFrame` not read through) [V by frame].

## 4. megastructure_view

The title (its name, else the type's), the main tab only (`UpdateSelectableTabs`: no shipyard or
overclocking here [I]), the description (`%s_DESC`), the portrait; Upgrade with a potential upgrade,
else Complete; both and Dismantle greyed unless its own [I]. The header's flag: the owner's country
flag; no owner flags/special/abandoned.dds, an owner without communications flags/special/unknown.dds
(`CCountry::GetLocalEmpireFlag`) [V by the frames].

## 5. waystation_view

The header as the starbase's, one tab (`CGuiButtonTabController<EWaystationsViewTabType, 1>`) [V];
the portrait's network box (with a network), the system's colonies, the owner box (hidden on the
player's own, its flag the country's or the unknown one) [V by the frames]; the class, cloaking and
design rows; `no_intel_text` for another's waystation (`NWaystationUtil::PlayerHasWaystationIntel`:
intel itself not read [I]), else the modules grid and the build queue. The stockpile boxes are
hidden (no collection known) [I]. `open_starbase waystation ID` shows any starbase in it, as
headless.c's ShowWaystationView does, which is how it was compared.

## 6. waystation_network_view

`CWaystationNetworkView::Update` [V for the order]: the name, the modifiers' text (country and
system modifiers, else waystation_network_no_modifiers: the modifiers not read, so always that [I]),
the list: a waystation_view_entry per station joined by the connection line, then with connected
networks (`FindConnectedNetworksForCountry`: the save's `networks` [I]) a separator and a
waystation_network_view_entry each; previous / next the owner's networks by id [I]. Checked only
with a test network put in by hand (no save has one).

## 7. GUI rules added to render.gui (all windows)

Read from the game's code and noted in the commits (cd33956, b293409): a negative size is the
parent's less the position plus the size (`CGuiSize::InternalGetX` 0x436d9a0) [V]; `if_resolution`
blocks like `if_scaled_resolution`, and the elements inside the matching block laid out [V]; the
last duplicate field wins [V]; a button's label buttonText else text [V]; a buttonType with a plain
spriteType drawn at its frame's size [I]; `£mod_x£` icons from gfx/interface/icons/modifiers
(`CModifier::InitDefinitionIcons`) [V]; text wraps at spaces unless `multiline = no` [I]. Clipping by
default was tried and dropped: main.gui's topbar draws outside its 200 px.

## 8. Checked against the game

| what | result |
|---|---|
| starbase 0 (the player's starport), all four tabs | same layout, texts and values; the side panels missing |
| starbases 1, 10, 11, 13, 32, 106, Command tab (outposts to starholds, others') | same |
| megastructures 0 to 5 | same; flags Ø / ? as the game |
| clicks: the Defenses and Shipyard tabs, next starbase, close (the controls protocol) | the same window in both |
| waystation_view on starbases 0 and 1 | same (the game's frame still fading out the starbase view) |
| the main screen with no window | unchanged but the outliner toggle (closer to the game) |

## 9. The buttons

What each clickable element does, as the game's handlers do (the 4.5.2 Linux build) **[V]**,
and how the renderer does it. A change to the world is a command run in the simulation between
days: `starbase:cmd:VERB:ARG...` (starbase.rs `run_command`: `render.windows.starbase_commands`
`.run` through `Clock::query`, then a snapshot published and taken), the item made as the game's
CAddBuildableToQueueCommand does (engine.ai.economy.orders: the free item slot, the queue, the
cost from the stockpile). Commands the engine has no model for say so (`not done: ...`).

| element | game | renderer |
|---|---|---|
| tabs | ShowTab: the tab's view and its own side view | `starbase:tab:N`; the side view and the lists' scroll reset |
| previous / next / goto / planet / close | OnPrev/NextStarbaseClick, Goto, OnOpenPlanetClick | as before (section 1) |
| Upgrade | CStarbaseAbstractStarbaseTabController::Upgrade: CreateAddBuildableCommand(country, starbase, next level), PostCommandToSession; a designable size: CDesignSelectionWindow | `upgrade SB`: a starbase_upgrade item in the build queue, its cost the next size's (engine.fleets.stations.size_table), its time the size's base_buildtime; checked: the game's queue shows the same "Upgrade / Upgrade to Starport / 288". The design selection: not done |
| Dismantle (class row) | Dismantle: STARBASE_DISMANTLE_DIALOG (an outpost) or STARBASE_DOWNGRADE_DIALOG | its dialog; Agree: `not done` (the engine removes no starbase, rebuilds no station design) |
| Details | CShip::CanInspectShip: the station's ship view | `fleet:ship:STATION` (fleetwin.rs) |
| Retrofit | OpenRetrofitWindow (CDesignSelectionWindow) | not done |
| rename (the name; the waystation's too) | CAbstractStarbaseView::OnRename: CStarbase::CanRename, CShipRenameDialog on the station | rename_dialog.gui, its title RENAME_SHIP_TITLE (the game's frame), the box starting with the station's name; typing (app.rs: the keyboard goes to the box while it is open), Backspace, Return (OK), Escape (Cancel); OK: `rename SB NAME`, the station ship's name |
| a module / building slot | the tab controller (CStarbaseComponentGridEntry's observer): the side view of the slot | `starbase:slot:KIND:N`: the side view (the slot's overlay shown); again: closed |
| a side view component | CStarbaseBuildableComponentEntry: the component in the slot (CAddBuildableToQueueCommand) | `module|building SB SLOT KEY`: a starbase_module/_building item, its cost the definition's (economy template, the starbase's modifiers), its time construction_days; checked: the game's queue shows "Transit Hub / Transit Hub 180" and greys the slot's other choices |
| a side view's current component: Dismantle | STARBASE_DISMANTLE_COMPONENT_DIALOG | its dialog; Agree: `dismantle_component SB KIND SLOT` (the slot emptied; no refund [I]) |
| a side view design | CBuildableShipListItem::Build | `ship SB DESIGN`: a ship item in the shipyard queue (a defense platform's size: the build queue), cost engine.ai.shipbuilding.ship_table, time build_time; checked against the game's queue |
| a sublist header | CBuildableShipListSubList::ToggleOpenStatus | `starbase:sub:KEY`: open / closed (its arrow) |
| a queue entry (cancel_button) | CConstructionQueueListItem::OnCancel | `cancel ITEM`: out of its queue, its resources back [I: the game's refund rules] |
| priority up / down | OnPriorityUp / OnPriorityDown | `priority ITEM up|down`; disabled at the ends and for others' |
| Disband All (defenses) | DisbandAll: MULTIPLE_SHIPS_DISBAND dialog | its dialog (checked against the game's: "Disband these 2 ship(s)?"), Agree: `disband_all SB` |
| a platform's disband / details / upgrade | CStarbaseShipItem::Disband (SHIP_DISBAND dialog), details, Upgrade | the dialog and `disband_ship SB SHIP`; details `fleet:ship:ID`; upgrade disabled (CalcCanUpgradeDefensePlatforms not evaluated) [I] |
| platforms' Upgrade (capacity row) | CStarbaseDefensesTabController::Upgrade | disabled [I] |
| Ship Designs / Defense Designs | OpenShipDesigns / OpenDefenseDesigns: the ship designer | the designer opened (no design chosen) [I] |
| Army Hub: Army Types, recruit | CBuildableShipListController::UpdateStarbaseMacroBuilder, recruit_button | the side view's title only; not done |
| megastructure Upgrade / Complete | OnUpgrade: CCountryUpgradeMegaStructureCommand | `mega_upgrade`: not done (no megastructure construction in the engine) |
| megastructure Dismantle / Abort | OnDismantle: MEGASTRUCTURE_DISMANTLE_DIALOG; OnAbortDismantle | its dialog; Agree and Abort: not done |
| waystation Upgrade / Details / Dismantle | as the starbase's | as the starbase's |
| waystation cloaking | CStarbaseWaystationTabController::OnCloakClick | `cloak`: not done |
| network window | close, previous / next, a connected network | as before (section 6) |

- **The side view** (CStarbaseSideView, `starbase_side_view` beside the window): the Shipyard and
  Defenses tabs show theirs at once (the game's frames), the Command tab's after a slot is
  clicked, for the player's own starbase. Designs: each of the country's collection and the
  special buildable global designs (`is_special_buildable`) whose `allow_buildable_trigger` (a
  scripted trigger, country scope) holds (CShipDesign::CanCountryBuildPotential); kept when the
  size's construction types take the queue's (starbase_shipyard or the beastport's;
  starbase_defenses), its prerequisites are researched and its potential_construction holds
  (CanBuildAtPotential); sorted as SShipyardEntrySorter (civilian first, then
  SSortShipSizeBySizeMultiplier, then the size's place in the files [I]). Civilian sizes under
  OUTLINER_CIVILIAN_FLEETS ("Utility Ships"), shown by their size's name; the others under
  `<size>_plural`, as BUILDABLE_SHIP_NAME ("<name>-class") with AUTO_GENERATED_BEST for an
  auto-generated design; the class icon (GFX_ship_class_medium: constructor 2, science 1,
  colonizer 14, military 3, defense platform 27, matched to the game's frame by pixels); the build
  time over the starbase's speed, whole days down (54 for 60 at +10%); the cost. Components: the
  definitions whose potential holds, by category (the categories by their names, the components
  by cost then name: the game's frames), "£alloys£ 38 £time£ 180" (half up). Greyed: what the
  owner cannot pay for, a building the starbase has or has queued, every choice of a slot with an
  item queued [I: read off the game's frames]. `possible` is not used: the script layer evaluates
  some of its scopes false (a solar_system count) where the game lets the component be built [I].
- **Rows' places** (the game's frames): a design list's rows 8 px above the listbox's position, 3
  apart; a component list's categories 10 px below the current component or the top, rows 5 apart
  (each category in a starbase_view_panel_buildables_entry). Rows partly outside a list are not
  drawn (the game clips them) [I].
- **The queue**: the days left over the item's speed, rounded up (55 for 60 at +10%); a ship's
  entry: its size's name, then a civilian's size name or the design's "<name>-class"; a module's
  or building's name twice; the progress bar is render.gui's startend bar (GFX_queue_progressbar,
  progress_startend.shader), the same pixels as the game's on a ship at 27%.
- **Escape**: the dialog, then the slot's side view, then the window (app.rs Action::Back).
  **The wheel** over the side view, the build queues, the fleets in orbit or the platforms scrolls
  that list, 20 px a notch (the game's frames).
- **Checked** in the real window (winsteps under Xvfb, the save loaded from Load Game; a copy of
  the 2210.01.01 autosave whose player is the fallen empire 16777226, for free slots, outposts and
  platforms): the outliner row opening the window, the tabs, a building slot's side view, the
  wheel, queuing a building, Disband All and a platform's disband with their dialogs (Agree: 12 to
  11 platforms), Escape twice. Against the game (headless view.sh, the same clicks): the ship and
  defense lists, a slot's lists, queuing a construction ship, a defense platform, an upgrade and a
  building, the queue entries, the dialog, the scroll per notch.
- **A new game's starbase** (#48: the station's `properties`, its queues, modules and design): checked in the real window (New Game, Select, Play, the outliner's Shipyards row): its window, the rename, a module slot's list and a replacement queued, a construction ship queued and built after 60 days (in orbit and in the outliner), the queue's startend progress bar; the upgrade greyed (the next level's technology not researched at the start).
- **Not done**: the Devastator design greyed in the game (and its 360 days, 300 here): its reason
  is not read; Army Hub's army types; retrofit and the upgrade's design selection; the
  starbase's dismantle and downgrade; megastructure commands; cloaking; tooltips.

## Not done yet

- Text icons drawn larger than the game's; the fleet health bar's look; progress bars stretched,
  not cropped; the shipyard speed without the simulation misses the country modifiers.
- The waystation stockpile, intel and network modifiers; networks against a frame of the game.
