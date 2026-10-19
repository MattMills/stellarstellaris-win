# The fleet windows

The renderer's fleet windows: the selected fleet's **fleet_view** (`interface/fleet_view.gui`), a
ship's **ship_view** (`interface/ship_view.gui`) and the **Fleet Manager**
(`interface/fleet_manager_view.gui`), drawn from the game's GUI files with what the save holds.

| file | |
|---|---|
| `sim/render/src/fleetwin.rs` | the fleet and ship views: what is open, `open`, the `fleet:...` clicks, Escape; the derived textures (greyed buttons, filled bars) for every window's items |
| `sim/render/lua/render/windows/fleet_manager.lua` | the Fleet Manager as a left bar view (views.rs: one view at a time) |
| `sim/render/lua/render/windows/fleet_data.lua` | the save's values, read where the world is (the map's runtime, else the simulation's thread through `Clock::query`), as Lua source |
| `sim/render/lua/render/windows/fleet.lua` | the layout (render.gui) and what the game computes from its definitions |

Marks as in docs/render.md: **[V]** read in the game's code or files, or measured in its frames;
**[I]** inferred. Functions are the Linux 4.5.2 build's (`/opt/stellaris-headless/re` on
10.5.0.24). Comparisons: the 2210.01.01 autosave at 1600x900, the same command file run by
`headless/view.sh` and the renderer (`open fleet 3`, `open fleet 1`, `open fleet 2`, `open ship 3`,
`open fleet_manager`; the game left, the renderer right in `.24:/root/fleetcmp/s_*.png`).

## 1. Opening them

| how | game | renderer |
|---|---|---|
| a fleet selected (outliner, map, `select fleet ID`) | `CInGameIdler::Select(CSelectable*)`, the CSelectable at CFleet+0x18 (as `CFleetOrbitalItem::SelectFleet`) [V] | fleet_view for a fleet that is not a station (a station keeps the starbase window) |
| a ship row's inspect button | `CInGameIdler::ShowShipView(CShip*)` → `CShipView::Show` (the view at CInGameIdler+0xb60) [V] | action `fleet:ship:ID`, `open ship ID` |
| the left bar's Fleet Manager | `CInGameIdler::ToggleTopBarView` (ETopBarView 8; the view at CInGameIdler+0xd78) [V] | the shared left bar view (views.rs, `lua/render/windows/fleet_manager.lua`): `view:fleet_manager`, `open_view fleet_manager`; no side panel, as the game |
| the fleet view's and ship view's Fleet Manager buttons | `ShowFleetManagerView(template)` = Show + `SelectTemplate` [V] | `fleet:manager:ID`: the same view with state `fleet=ID side=1` (the Build Queue shown, as the game); the ship and fleet views close |
| close | `header/close`, an entry's `top/deselect`; `CShipView::Close`; `CFleetManagerView::Hide` [V] | `close`, `fleet:close_ship`, the view's `view_close`; Escape closes the ship view, then the open view (views.rs), then the selection |

The headless game has `open fleet ID|ship ID|none` and win-research's `open_view fleet_manager`
(CInGameIdler::ToggleTopBarView, as the left bar button)
(`headless/headless.c`, `open_cmd`, the calls above; `none` = `DeselectAll` + `CShipView::Close` +
`CFleetManagerView::Hide`); `open` replies 20 frames later (fleet_view slides in in 200 ms). Fleets and
ships by `TPdxRef` (the database's slots of 16 bytes at +0x18, count +0x20, the object at +8 of a
slot; CFleet's id at +0x30, CShip's at +0x18) [V].

The windows read the save's world in the map's runtime; while the simulation runs (`load-sim`)
they ask its thread (`Clock::query`: Lua run between days, its string returned).

## 2. fleet_view

**Size** [V: CFleetView::UpdateSize @0x2ddc090]: LOWER_LEFT at (35, -30); the height is `header`'s
(50) plus the `fleets` list's content, at most the screen's less
`fleet_view_max_height_subtraction` (115). An entry is 259 plus its rows: the summary row (43)
when the fleet has 2 ships or more, a row (42) per ship, 1 apart (the list at the entry's y 256)
[V: OnUpdate @0x2deed9c].

**Header** (`top`):
- `header_button`, by EShipClass [V: the entry's ctor @0x2de5699, jump table @0x46e277c;
  `UpdateMilitaryFleetBackground` @0x2deca00]: 0 military and 7 military_station
  `GFX_fleet_view_main_military_bg` (a hero ship's growth stage's, the mercenaries', `_long` for a
  mobile starbase), 3 science `_science_bg`, 4 transport `_transport_bg`, the others
  `_civilian_bg` when the fleet's property bit 1 (civilian) is set, else the .gui's; a fleet the
  observer has no communications with `_precom_bg`.
- EShipClass [V: GetShipClassTokenFromEnum's table @0x45efa4c]: 0 military, 1 constructor,
  2 colonizer, 3 science_ship, 4 transport, 5 mining_station, 6 research_station,
  7 military_station, 8 habitat_station. `icon` frame: GetShipClassIconFrameFromEnum [V
  @0x317e070] 3, 2, 14, 1, 15, 7, 9, 10, 6, 13, 8, 28, 1, 62 (11 without communications).
- `flag`: the controller's (`ApplyCountryToButton`) [V]. `fleet_name`: the name (+
  `seed_pod_fleet_suffix` when seeded) [V]. `fleet_type`: `CFleet::GetTypeName` [V @0x2927770]:
  the first ship's size name, none for classes in the mask 0x771 unless the fleet's property
  bit 9 (mobile [I]); without communications `unknown_faction_name` shows the owner (YELLOW_COLOR).
- Buttons [V]: `open_fleet_manager` for class 0 only; `toggle_armada_commanding_mode` only for a
  fleet that can lead an armada; `disband`'s sprite `GFX_fleetview_destroy_fleet` at command
  points ≤ 1 (CFleet+0x1280 < 100001), else `GFX_delete_template_button` (a leased fleet's
  `_break_fleet_contract`); `rename_button` for the player's (transparent).
- Property bits (CFleet+0x1260): 4 weapon, 10 valid_for_combat, 11 orbital_station [V]; 1 civilian,
  9 mobile [I].

**The leader** (`portrait_container`, CParagonPortraitContainer) [V]: shown for the player's
fleets with a leader (others' when their orders can be seen); the GUI type
`paragon_portrait_container_horizontal` (paragon_ui_types.gui) [I: the define's default is not in
the files; its size fits and the frame matches]: `leader_class_banner` and `leader_type` frame by
class (commander 1, official 2, scientist 3 [I: the textures' colours]), `skill_icon` frame = level
+ 1, the council position's icon and name (`councilor_title`), else `leader_class_text`, the name
(Y); the traits: each trait's layered icon (common/traits `icon`: the trait/icon inline scripts'
layers in their named colours; layers with a `visible` trigger left out [I]). **Not drawn:** the
portrait (the species' animated portrait).

**Another empire's fleet** without communications [V: OnUpdate, CShip::GetLocalNameWithType;
the names' keys I]: `GFX_fleet_view_main_precom_bg`, icon frame 11, the flag of
PRE_COMMUNICATIONS_EMPIRE_FLAG (special/unknown.dds on black [I]), NO_COMMUNICATIONS_FLEET and
`unknown_faction_name` YELLOW UNKNOWN_COUNTRY ("Alien Menace", "Unidentified Empire": the
_XENOPHOBE keys for a xenophobe observer, as the 2210 player), `precommunications` with
Investigate (disabled without an active first contact [I]), no stats nor orders, the rows
NO_COMMUNICATIONS_VESSEL(_XENOPHOBE) with inspect and disband disabled, no upgrade arrow (the
observer's ships only). Compared: fleets 11 and 27 (3 and 10 ships; the 10-ship one taller than
the screen allows, its list shown from its bottom in both).

**Orders** [V: CFleetView::UpdateOrders]: none without communications; `orders_hero_ship` with a
hero ship; `orders_large` (5 a row) for a fleet that cannot have a leader, is not a colonizer nor
class 9 and cannot store resources (a construction ship); `observation_orders` for class 9; else
`orders_small` (4 a row). The buttons: EFleetOrderButtonType 4-25, 29, 31-38 in enum order where
potential [V: types, sprites]; which are potential per class [I: from the game's frames]:
military attack, ground support (`GFX_fleet_order_button_ground_support_<stance>`), stance, home
base, follow friendlies; science survey, research, stance, auto-explore, MIA jump (disabled);
construction the four station builds, auto-construct, stance, megastructure (disabled). The stance
sprite by `fleet_stance` (the save writes it when not passive [I]). The header's fleet-wide grid
(types 0-3, 26-28, 30): merge (disabled), stop (disabled when idle), return, move, jump
(disabled) [I: as the frames show one selected fleet].

**Bottom** [V]: `HULL_STATE`, `ARMOR_STATE`, `SHIELD_STATE` with "§G<percent>%§!"
(CreateGreenRedPercent of the fleet's sums); `size_limit` for the player's military fleets:
FLEET_TEMPLATE_SIZE_WITH_LIMIT "£fleet_template_size£ 15/50 (15)" (command points used: the ships'
size_multiplier; the limit CalcCommandLimit: COMMAND_LIMIT_BASE 50, the country's modifiers not
counted [I]; the template's fleet_size, §E when larger); `fleet_power` "£military_power£ 169"
(SI_NUMBER); `orders` NO_ORDERS. The actions grid (UPPER_RIGHT, the first at the right) [V: types,
sprites, potentials of repair (mobile), transfer (not civilian), split (2 ships), reinforce (a
template)]: repair (disabled undamaged), upgrade (a ship with a newer design [I]), mercenary
enclave (disabled [I]), transfer, split, reinforce (disabled when complete).

**Ships** [V: CNewFleetViewSummary, CNewFleetViewSubEntry]: sorted by size and name; the summary's
entries per ship size: `GFX_<size icon>_top` (`_damaged`), the average health, armor and shield
bars, `upgradable`, "§W3/3§!" against the template; a row per ship: `GFX_<size icon>`, the bars,
the name: CShip::GetNameWithType [V @0x2ab1310]: SHIP_SIZE_NAME ("Corvette UOR Abominable
Abalone") over "\n" + the class's colour (GetShipClassColorFromEnum "RHEBWWWWWWWRB") + the class's
text icon (`£military_ship£`, CShip::GetTextIcon) + SHIP_CLASS ("Ripjaw Angler-class"); the first
line in H [I]. The renderer draws one line a text: the two lines are two texts.

**Progress bars**: their textures (40x10) run along the bar; a vertical bar turned, filled from
its bottom [I]; texture one up to the value, two beyond (progress.shader) [V].
**Disabled buttons**: buttonstate.shader's PixelShaderDisable, GreyOutLuminosity(0.85, 0.75) [V].

Compared: the military fleet Typhoon (3 corvettes, admiral), the science ship and the
construction ship: the same places, texts, buttons and states, but for the leader's portrait
and traits.

## 3. ship_view

[V: CShipView::Update, CShipViewBase::UpdateStats, UpdateComponents]: centred, 650x650. `name`
the ship's; `type` the design's long name (LONG_SHIPCLASS_NAME "$NAME$-class $SIZE$" [I: the
key]); the values `SHIP_STAT_<stat>_VALUE` ("$VALUE|Y0$", evasion "§Y$VALUE|1$%§!", damage "§Y$VALUE|2$
/§! £resource_time£"); rank "§Y<rank>§!" for military ships (Regular [I: the experience
thresholds not read]); the cloaking row and growth box hidden (DLC, bio-ships); the buttons
disabled unless the player's ship can be upgraded; `open_designer`'s text OPEN_DESIGNER.

Components: the core grid is the design's required components in order; armaments and utilities
are every slot of the design's sections (component_slot entries, then `<size>_utility_slots`,
`aux_utility_slots`; empty ones too) by the slot's type (weapon, strike craft → armaments),
sorted by slot size then component (the template's load order [I]); `icon_bg` frame
GetComponentSlotIconFrame: utility size (aux 13), strike craft 13 + size, else size + 4 [V].

Stats from the design [I: the formulas fitted to the game's numbers; the terms in the game's
files]: hull, armor, shields the save's maxima; reactor power made (the positive powers × (1 +
ship_reactor_power_mult)) against used; the excess (made − used) / made, from 0.05
(EXCESS_POWER_BONUS_THRESHOLD_MIN) up to 1, scales `ship_excess_power` (+10% speed, evasion,
weapon damage); speed = the size's max_speed × (1 + ship_speed_mult); evasion = the size's
ship_evasion_add × (1 + ship_evasion_mult); damage a day = over the weapons
(weapon_components.csv) (min + max) / 2 × (1 + ship_weapon_damage) × accuracy × (1 +
ship_fire_rate_mult) / ((cooldown + (min + max windup) / 2) / 10); the fire rate the admiral's
skill_commander_navy × level. The game's numbers are cut, not rounded. The corvette: 90 made,
55 used, excess 0.389: 166, 62.3%, 7.69 / day, as the game. **Not counted:** the country's
modifiers (technologies, traditions; the game's modifier capture of this save has none on the
ships). **Not drawn:** the 3D ship preview (`ship_model`).

## 4. fleet_manager_view

[V: CFleetManagerView::Setup, Update; the controllers]: at (35, 40); the templates of the country
(`fleet_template_manager.fleet_template`) in order, each row the fleet's name,
BuildFleetTemplateCountString ("§Y15§!/§Y50§! (15)"), MILITARY_POWER_YELLOW; the selected one
(the first by default) `selected_overlay`; its name over `GFX_fleet_manager_fleet_bg_horizontal`
(box1's background at its own position: drawn by the renderer's window code); its panel: hull,
armor, shields (FLEET_MANAGER_HEALTH ... "$VALUE|%0$"), template size, strength, stance sprite,
the leader (the same paragon container), NO_ORDERS; the header's stop (disabled idle), return,
take point. NAVY_LIMIT_VALUE "Naval Capacity 15/57": the country's used_naval_capacity against
CalcNavalCapacity = (NAVAL_CAPACITY_BASE 50 + country_naval_cap_add) × (1 +
country_naval_cap_mult) [I: the terms counted are the councilors' traits' councilor_modifier: the
Minister of Defense's fleet organizer, +15%]; the reinforcement line
(FLEET_MANAGER_VIEW_NO_REINFORCE_TEXT when no fleet lacks ships). Ships: COMMAND_LIMIT_VALUE
"Command Limit (15/50)" and its bar (size × 100 / limit); the composition per ship size, centred
("§W3§!/§W3§!"); a row per template design sorted by size then name: the size icon and name,
BUILDABLE_SHIP_NAME, Auto-Generated, the count (FULL, UPGRADABLE_COUNT with the arrow, or
COUNT: ships of the design against ships of the slot), minus disabled at the template's count;
the actions (reinforce disabled when complete, repair undamaged, upgrade without a newer design).
The side panel in its default mode, Build Queue (empty), only when the manager was opened on a
fleet's template (ShowFleetManagerView: the fleet and ship views' buttons); from the left bar
(`open_view fleet_manager`, ToggleTopBarView) the game shows none [V: both frames]. Space Fauna and Reinforce All disabled.

**Not computed:** a design's own strength (NCombatRules::CalcMilitaryPower @0x22a2520 [V]: the
design implementation's stats (+0x10, +0x70, +0x130 hull, armor, shield with the
MILITARY_POWER_*_WEIGHT defines; +0x110 against 100, evasion [I]; +0x380 damage) give
scale x (health x damage)^MILITARY_POWER_EXPONENT plus +0x1d0; the stats' own computation (range,
tracking, penetration weights) not read: no reading of them fits both 163 and 184; the row shows the
fleet's, "169" where the game shows "163/184"); the upgradable count's icon frame (|2) is drawn
as frame 1.

## 5. The buttons

Every button that changes the game posts a CCommand in the game (PostCommandToSession). Here it
calls `render.windows.fleet_commands` in the simulation's runtime (fleetwin.rs
`App::fleet_command`, through `Clock::query`). A map that shows the save's own world starts the
simulation, paused (`step 0`), first. A snapshot is then published and the windows are laid out
again. The actions are:

- `fleet:do:FID:NAME`: an order or action at once.
- `fleet:arm:FID:NAME`: a targeted order. The button shows its `_selected` frame, the next left
  click on the map gives the target (`fleet_commands.target`), and Escape or a click on nothing
  disarms it.
- `fleet:ship_do:SID:NAME`: a ship row's button.
- `fleet:tpl:FID:DESIGN:DELTA`: a Fleet Manager design row's count.
- `fleet:focus:FID`: the camera.
- `fleet:designer[:DESIGN]`: the ship designer.

A missing fleet, ship or template is refused and never an error. Each call returns a line that
goes to the log.

The game's rules, from the RE spec of the handlers [V unless marked]:

- Queue mode: an order replaces the fleet's orders (shift appends, ctrl+shift puts it in front).
  Here an order always replaces them [I: the modifiers are not read].
- Targeted orders: move (point, planet or system), survey (planet or system), research
  (planet), the build-station orders and attack.
- Pickers and popups: home base opens a picker; auto-explore and automate open the automation
  popup.
- Everything else acts at once.

| Button | Window | Here |
|---|---|---|
| move (header) | fleet | wired: armed; a system: move_to_system_point_order to its centre, a planet: orbit_planet_order, a fleet or ship: move to its place |
| right click on the map | map | wired: section 6 (rightclick.rs, fleet_rightclick.lua) |
| survey | science fleet | wired: armed; a planet: survey_planet_order, a system: one per unsurveyed body (orders.survey_system) |
| research | science fleet | wired: armed; a planet: research_anomaly_order (a planet without an anomaly: issued, and the engine cancels it at once; the game does not take such a target [I]) |
| stop | fleet, manager header | wired: the orders cleared (orders.clear); disabled while idle with no orders |
| return | fleet, manager header | wired: return_fleet_order in front (orders.return_to_base) [I: the MIA popup when it is not valid is not done] |
| stance | military, science, constructor; manager's change_stance | wired: passive, aggressive, evasive in turn, skipping what the fleet does not support; passive leaves `fleet_stance` out |
| ground support | military | wired: `ground_support_stance` set to selective or indiscriminate [I: the other bombardment stances' potentials are not evaluated] |
| merge | fleet header | wired: enabled with another of the owner's fleets of the class in the system; their ships are moved in at once (the template's row of their design, or of the design they upgrade to, counted; the naval capacity unchanged) and the emptied fleets removed [I: the game gives them merge_fleet_orders towards the first fleet] |
| split | fleet actions | wired: the second half of the ships go to a new fleet at the same place, with its own template (engine.fleets.create); the old template's rows counted down [I: the game takes about half of each size] |
| disband (fleet) | fleet top, manager actions | wired: the ships, the fleet, its system presence, its owned_fleets entry and its template removed [not done here: the confirmation popup, on_fleet_disbanded, the leader unassigned] |
| disband (ship row) | fleet's ship list | wired: the ship removed from its fleet, and the fleet too when it was the last [not done here: on_ship_disbanded] |
| inspect (ship row) | fleet | wired: the ship view |
| focus_on | fleet top | wired: the camera to the fleet |
| open_fleet_manager | fleet, ship | wired: the manager on the fleet's template |
| open_designer | ship | wired: the designer on the ship's (upgrade) design, the fleet view closed; both ship view buttons greyed for a ship that cannot be upgraded [V] |
| Ship Designer tab | manager | wired: the designer with no design (the designer's own Fleet Manager tab closes it: designer.rs, not here) |
| row select | manager | wired (view_set:fleet=ID) |
| increase / decrease | manager design rows | wired: the template's count +1 / -1 and its fleet_size; decrease is disabled when it would go below the fleet's ships [I: the modifiers' steps of 10 and "all spare" not done; the reinforcement it queues not done] |
| inspect (design row) | manager | wired: the design in the designer |
| close, Escape | all three | wired; Escape disarms an armed order first |
| attack | military | wired: armed; a fleet (or a ship's fleet): follow_order with attack_when_in_range (engine.fleets.follow; the combat itself not ported) |
| build starbase / mining / research | constructor | wired: armed; a planet's station, the outpost on the system's (or the planet's system's) star: build_orbital_station_order (engine.fleets.stations, its cost paid when it starts), refused where CanBuildStation fails |
| home base, jump, MIA jump, build observation, megastructure | fleet | UI only: armed, the target given, then "not done": no home-base picker, no jump drive, observation posts and megastructures not modelled |
| auto-explore, automate construction | fleet | not done here: the automation popup and automate_fleet_order |
| follow / take point | fleet, manager header | not done here: flag bit 0x80 (`settings={friends_should_follow=yes}` [I]) |
| repair, upgrade, reinforce, reinforce all, mercenary, transfer | fleet actions, manager | not done here: the engine has no repair or upgrade order, no shipyard queue for reinforcement, no transfer view |
| overwrite, copy template, create new fleet, retrofit, the design row's disband, policies | manager | not done here: the template edits beyond a count, and the policies popup |
| rename | manager | not done here: the renderer has no text input |

The current order's line (fleet view, the manager's current_order) is now read from the fleet's
`current_order`. move_to_system_point_order and orbit_planet_order show FLEETORDER_MOVE_OTHER_SYSTEM,
survey_planet_order FLEETORDER_SURVEY (planet, progress), return_fleet_order FLEETORDER_RETURN, and
anything else NO_ORDERS [I]. Stop is enabled when the fleet has an order.

Checked in a real window (the windowed renderer under Xvfb on .24, 2210.01.01 save, a click
per step, the result read in the log and the frame after each click):
- Typhoon (military fleet): move armed and targeted on The Mooring ("Moving to the Ithni Zerak
  System"), return ("Returning"), stop ("No orders"), stance three times (its icon each time),
  ground support, attack armed then Escape, inspect and Escape (ship view), a ship row's disband
  (2/3, 10/50), split (Crashing Wave, 10/50), merge (15/50 (15), one row, naval capacity 15/57),
  the fleet's disband (the window and the outliner row gone).
- The Fleet Manager: increase and decrease (3/4, then 3/3), change stance, return ("Returning"),
  stop, a row's inspect (the designer), the Ship Designer tab.
- The ship view: Fleet Manager and Open Designer on an upgradable corvette; greyed on the
  construction ship.
- UOR Hydrozoan (science ship): survey armed and targeted ("Surveying The Mooring: 0%"),
  research, stance, auto-explore ("not done"), MIA jump greyed.
- UOR Drifting Crab (construction ship): build mining armed and targeted ("not done").
Not compared with the headless game this time: no headless game was to run on .24 (the parent's
instruction). The frames before the clicks are the ones compared earlier (sections 2-4).

## 6. Right click

A right click on the map with the player's fleets selected does what the game does
(CInGameIdler::HandleInputEvent's right button @0x1c862a2, CSelectionList::PerformAction,
CFleet::PerformAction 0x2dd36a0 and its PerformActionOnPlanet / PerformActionOnFleet; the RE notes
are summarised here). The code:
- `src/rightclick.rs` (App::fleet_right_click): the target, the order selector's and the popup's
  clicks, closing them.
- `lua/render/windows/fleet_rightclick.lua`: the decision and the commands, run in the
  simulation's runtime.
- `lua/render/windows/fleet.lua` (fleet.order_menu, fleet.order_popup): the layout.
- `lua/engine/fleets/follow.lua`: follow_order.

In order [V unless marked]:
1. An armed order button (section 5) is cancelled by the right click, and nothing else happens.
2. The order selector or popup that is open closes.
3. The target is:
   - a map label's or an outliner row's object (their `select:fleet`, `select:planet`,
     `map:slide` actions; the map icons' OnRightClick act on their object);
   - else what the map picks at the cursor: a system (galaxy view), a planet or star (system
     view), a fleet, or a ship's fleet;
   - else, in a system view, the point of its plane.
   Another GUI element under the cursor keeps its own right click (mainbars.rs). With no fleet
   selected nothing happens (PerformRightClickActionAt only offers mercenary contracts).
4. The fleets: the box selection's, all of them (the game's selection list; mapicons.rs keeps them
   in `fleet.group`), else the selected fleet; only the player's mobile fleets act.
5. The action, by target and fleet:

| target | military | construction | science | others, groups |
|---|---|---|---|---|
| system (galaxy) or point (system view) | an orbit of the system's starbase or star (CalcMoveToOrbitable [I]), else a move | with intel: a menu Move Here + Build Mining / Research Stations, Build Starbase (Outpost) where a body could have one | a menu Move Here + Survey System when a body is unsurveyed | a move; a science group: Move Here + Survey System |
| planet, moon, star | an orbit; a non-hostile colony: the bombardment Yes/No popup first | a menu: the body's station entries (surveyed bodies), Enter Orbit last | a menu: Survey + Survey System (unsurveyed), Research (an anomaly), Enter Orbit last | colony ship: Colonize Planet (section 7) + Enter Orbit; transport: Land Armies (section 8) + Enter Orbit; a group: an orbit each, science: Survey System + Enter Orbit |
| own fleet | follow | follow | follow | follow |
| another country's fleet | hostile (a war, the relation's `hostile`): follow and attack at once; neutral: the "Attack Target" Yes/No popup | follow | follow | follow |
| a static starbase | a menu: Enter Orbit, Set "$PLANET$ Station" as home base, Upgrade Fleet to Latest Designs (section 9) | the same | the same | the same |
| empty galaxy space | nothing | nothing | nothing | nothing |

The menu entries:
- A station entry is listed when the body could ever take that station: CanCreateOrbitalStation
  (the class's design and no station of it yet), a mining or research station only on a body
  whose deposit is of that class, an outpost only on the primary star; observation posts are not
  modelled.
- It is possible when it can be built now (engine.fleets.stations.can_build_station: surveyed,
  the resource known, the borders) and the stockpile pays its cost. Otherwise it is crossed
  (TRIGGER_FAIL) and greyed [I: the game's IsPossible; its frame shows the crossed entries].
- Its label is the class's FLEETORDER_[MULTI_]BUILD_CURRENT_<class>_BUTTON with its cost,
  " (£influence£60 £alloys£90)", in the highlight colour, in the resources' order.
- "Survey System" from a planet surveys that planet first, then the others nearest first
  [V: the game's frame "Surveying Toarus I: 0% (+5 Orders)"].

The order selector:
- It is main.gui's `order_selector`: 380 wide, the "Orders" label, then an `order_window` per
  entry, 28 high, from the list's y (25 below its top); the window's height is 25 + 28 per entry
  + 9 [V: the game's frames with one and three entries, to a pixel or two].
- It opens at the cursor and is pushed back inside the right and bottom screen edges.
- Each entry's button (GFX_event_button_452 from x -25) is cut to the window: the game's frame
  shows it that way [V: 2210.01.01, the window at 815..1194 x 450..512].
- Choosing an entry runs it, with Shift and Ctrl as they are at that click (COrderWindow reads
  them then [V]).
- Escape, a click elsewhere or the next right click closes it [I: SetOpenAutocloseWindow].
- The popups are popup.gui's `yes_no_popup_window`: Yes runs the order without queueing [V]; No
  closes it.

The commands (each per fleet):
- move_to_system_point_order, orbit_planet_order (a planet, a star, a starbase's slot),
  survey_planet_order, research_anomaly_order and build_orbital_station_order go through
  engine.fleets.orders and engine.fleets.stations.
- follow_order (new: engine.fleets.follow): the fleet moves to where the followed fleet is, again
  when that one has moved on, until it is gone. With attack_when_in_range the combat itself is
  not ported [not done here].
- Set home base writes the template's `home_base = { orbitable = { starbase } }`.
- The queue: no Shift replaces the fleet's orders, Shift appends, Shift + Ctrl puts the order in
  front [V: the commands' Execute].

The order line also knows:
- FLEETORDER_ORBIT ("Entering Orbit of X") in the planet's system;
- FLEETORDER_FOLLOW ("Following X") and FLEETORDER_FOLLOW_AND_ATTACK ("Attacking X");
- FLEETORDER_TOP_LEVEL_TEXT ("X (+N Orders)") with queued orders.
The second line of the game's (the estimated arrival, "Idle") is not done.

In galaxy view the game takes the system from its hover cache (FindGalacticObjectUnderMouse:
the star within NCamera.SYSTEM_HOVER_RANGE 0.005 of the pointer's ray, refreshed each frame [V]),
never from the click's position. The renderer uses the map's pick of a system at the cursor
(6 pixels) [I].

Compared with the game (the headless view.sh with the same clicks, 2210.01.01):
- Construction ship on the home star: "Orders / Enter Orbit", the same place and size.
- Science ship on a surveyed planet: "Enter Orbit".
- Science ship on an unsurveyed planet of Toarus: "Survey / Survey System / Enter Orbit"; after
  Survey System, "Surveying Toarus I: 0% (+5 Orders)".
- Typhoon on the home starbase: "Enter Orbit / Set Ithni Zerak A Station as home base. /
  Upgrade Fleet to Latest Designs".
- Construction ship on Typhoon: a direct follow, "Following Typhoon".
- Typhoon on a planet, then Shift + right click on another: "Entering Orbit of The Mooring (+1
  Orders)".
- Construction ship on Toarus's star while the system is still being surveyed: the game lists
  "Build Mining Station (100)" and "Build Starbase (Outpost) (60 90)", both crossed, then Enter
  Orbit.
- After the survey (2211.04.01) the renderer lists "Build Starbase (Outpost) (60 100)" possible
  and Build Mining Station crossed. Choosing it posts build_orbital_station_order (influence 60,
  alloys 100 paid when it starts), and on 2212.05.12 Toarus is a "Frontier Outpost" with its
  starbase. In the game's run of the same clicks the system was still "Unsurveyed" on 2211.04.01
  (its events and tutorial windows held the science ship), so the game's menu showed Enter Orbit
  alone there; the outpost result was not compared.

Checked in a real window (the windowed renderer under Xvfb, 2210.01.01):
- the construction ship's menu on the home star, an entry chosen ("Entering Orbit of Ithni
  Zerak A");
- the science ship's Survey System from a planet of Toarus ("Surveying Toarus I: 0% (+5
  Orders)");
- a box selection of the home system's fleets, one right click: an orbit for each of the
  player's mobile fleets (the stations left out);
- Typhoon's orbit, then Shift + right click on another planet: "(+1 Orders)";
- Typhoon on Runa's foreign science ship: the "Attack Target" popup; Escape and No close it with
  no order; Yes gives "Attacking Seraphic Node";
- a click outside closes the menu.

A fix in engine.fleets.orders came out of these runs: a move from another system ended about
0.6 short of its point (an orbit slot), so a survey or an orbit given from another system never
finished. The move's last leg is now given again inside the system.

Galaxy view, compared with the game (2210.01.01, the same right clicks on Toarus's and Runa's
stars):
- science ship: "Move Here / Survey System"; Survey System from there: "Surveying Toarus I: 0%
  (+5 Orders)". From outside, the survey queue starts with the body nearest where the fleet will
  come in (engine.fleets.path.enter_point, CFTLJump::CalcFTLEnterSystemPoint), not the star;
- construction ship on an unsurveyed system: "Move Here / Build Mining Stations / Build Starbase
  (Outpost)", both crossed and with no cost (the classes the bodies could take, surveyed or not;
  the cost only over those that can be built now);
- Typhoon on Runa: a direct order, "Moving to the Runa System".
Both the game's and the renderer's windows show these. The game's second order line ("Moving to
the Toarus System", "Estimated Arrival Date") and its route line on the map are not done.

These runs needed the harness to reach the game's hover state. The game's hit tests read the GUI's
pointer copy, which it refreshes only when it draws, and the headless game draws far fewer frames
than it updates: a right click right after the pointer's move found no system. `click` now waits
until the game has drawn the pointer (headless/README.md, "The pointer's hit tests"), and `hover`
shows the state.

## 7. Colonize

Engine: `sim/lua/engine/fleets/colonize.lua`. The RE notes (scratchpad re4) are summarised here.

- **The way in.** A colony ship's right click on a planet offers "Colonize Planet". Its click opens
  the colonise view for that ship (`CSurfaceView`, `colonize_planet_view.gui`; here the planet
  view's colonize window), which lists that ship alone as an `expansion_source_fleet_entry`
  (`OpenColoniseView(planet, fleet)`) [V]. Opened from the planet view, the window lists the idle
  colony ships, then the species; a species entry orders a new colony ship (`planet.colonize`, as
  before) [V]. Colonize with a ship selected posts `CFleetColonizePlanetCommand`: the fleet's
  orders cleared, the colonize order given [V]. The colony name popup is not done.
- **The entry's state** (`colonize.check`, the keys of `CPlanet::CanColonize`): owned
  (`COLONIZABLE_HAS_OWNER`), a class never colonizable, an anomaly, unsurveyed, or outside the
  country's borders (`COLONIZABLE_INSIDE_BORDERS`, `_OTHER_BORDERS`: the game's tooltip "Can only
  colonize planets inside our borders.") cross it out [V keys and the game's frame].
- **The order** `colonize_planet_order = { planet progress }`: the ship flies into the planet's
  orbit (its orbit sub-order); in orbit and idle, progress goes up 1 a day; at 10 (hard-coded) it
  lands. Landing: the planet's owner and controller become the country, the colony's
  `colonizing_species` is the ship's `colonization_data.species`, the anomaly is removed,
  `on_colonization_started` fires (from the ship), and the colony ship is killed [V].
- **The colony.** It grows colonists monthly (`engine.pops`, `COLONY_MONTHLY_GROWTH` 3). At
  `COLONY_POPS_REQUIRED` (100) it is placed: the capital buildings removed, the colony shelter
  added, `colonizing_species` cleared, `colonize_date` set, `on_colonized` fired [V]. The shelter
  is always the plain one here [I].
- **Colony ships** carry `colonization_data = { species }`. The engine's `create.ship` now writes the
  owner's founder species for a colonizer, as the game's `create_ship` does [V: the game's save
  after `console Effect create_ship`].

## 8. Land armies and ground combat

Engine: `sim/lua/engine/fleets/armies.lua`.

- **The menu.** A transport's right click on a planet gives "Land Armies" and Enter Orbit [V]. The
  entry is possible when the planet has a colony not being colonized and a ship carries an army
  (the keys of `ListLandableArmies`) [V keys]. On a neutral controller's planet the click asks
  first (`FLEETORDER_LAND_ARMIES_TITLE` / `_DESC`, Yes/No) [V]; on a hostile or allied one it posts
  at once.
- **The order** `land_armies_order = { colony }`: the orbit sub-order, then in orbit every ship with
  `army=` starts landing. Each lands after `LANDING_TIME_DAYS` (10): the army's `colony` is set, its
  `ship` removed, the transport killed [V]. Landing on a hostile controller's planet starts or joins
  its ground combat [V].
- **Ground combat**, daily (store `ground_combat = { colony attackers defenders }`): every living army
  of each side (attackers first) hits a random enemy for random damage (`[BASE_DAMAGE_MIN,
  BASE_DAMAGE_MAX]` x the army type's `damage` x the morale factor 0.15 / 0.25 / 0.75 / 1) and
  morale damage [V formula parts]. An army at 0 health dies. Attackers alone left: the planet's
  controller becomes the attacker (occupation; the owner stays) [V]. Not done: the combat width,
  the targeting weights, the disengage roll, collateral damage, experience, generals, retreat, the
  messages.

## 9. Upgrade

Engine: `sim/lua/engine/fleets/upgrade.lua`.

- **The way in**: the fleet window's and the Fleet Manager's Upgrade, and the starbase menu's
  "Upgrade Fleet to Latest Designs". They give `upgrade_design_at_orbitable_fleet_order = {
  orbitable status queue self_upgrading }` at the nearest shipyard: the fleet's system's own
  starbase with a shipyard module, else the capital's [I].
- **Which ships**: those whose `ship_design_implementation.upgrade` names a newer design (the game
  marks it on them).
- **Cost**: each ship's upgrade starts, in orbit, when its cost can be paid. The cost is the new
  design's less `FLEET_UPGRADE_COMPONENT_COST_REFUND_MULT` (0.9) of the old one's, per resource
  [I: the game's exact part-by-part sum not read].
- **Time**: the new design's build time x (upgrade cost / full cost) x
  `FLEET_UPGRADE_TIME_COST_MULT` (0.5) days [V parts, I order].
- **Done**: the ship's design is the new one, `upgrade` none, its hit points the new design's, and
  `on_ship_upgraded` fires [V].
- In the game the upgrade is an item of the shipyard's construction queue; here the order counts
  it itself [I].
- The check refuses with the game's keys: `NO_UPGRADE_AVAILABLE`,
  `FLEETORDER_UPGRADE_ALREADY_UPGRADING`, `NO_UPGRADE_REACHABLE`.

## 10. Combat

Engine: `sim/lua/engine/fleets/combat.lua`, run every micro tick (10 a day) from `engine.systems`'s
`micro.update`. The RE notes (scratchpad re5) in brief, all [V] unless marked:

- **Start.** For every fleet, the other countries' fleets in its system are checked:
  - they must be hostile (`IsHostile` [I]: a war, the relation's `hostile` flag, or a country type
    with `faction = { hostile = yes }`: space fauna, which have no relation with anyone), or the
    target of its follow-and-attack order;
  - one side must be able to deal damage;
  - they must be within r = max of the two fleets' attack radii x `COMBAT_DETECT_RANGE_MULT`
    (1.05), at least `COMBAT_DETECT_RANGE_MIN` (10), and once fighting are kept up to 2r;
  - two military fleets already fighting are kept without the range test;
  - the fleet's stance is not read.
  The lists (`combat.in_combat_with`) are symmetric: two fleets fight when either finds the other
  and both can fight; a fleet that cannot (in FTL, emptied, not valid for combat) leaves every list
  [I]. A fleet's first combat draws a `targeting` value per ship and fires `on_entering_battle`.
- **The random pool.** When any fleet fights, every tick takes one global draw per ship of the
  store (UpdateShipParallel); otherwise these draws are skipped. The values seed the weapons'
  private streams (`CCrudeRandom` chains: ship, section, weapon; the game's noise function).
- **Weapons** (stats from `weapon_components.csv`): windup and cooldown count micro ticks, at most
  one shot per tick. The target is the best-scored enemy in range (average damage x chance to hit
  x weight; x1.1 for the current target; no draw).
- **The shot** takes one roll: below evasion − tracking it is evaded, below accuracy it hits,
  otherwise it misses. A hit makes a damage roll, then `CalcDamage`: shields absorb first, then
  armour, then hull, with the penetrations and the hull/armour/shield multipliers. Evasion is the
  size's `ship_evasion_add` plus the ship's modifiers, capped at 0.9.
- **Outcome**:
  - a ship with `disable_at_health` (starbases) is disabled at that threshold;
  - a ship at 0 hull is destroyed: removed at the tick's end, its fleet with its last ship, and
    taken out of the other fleets' lists;
  - otherwise a disengage roll is made below the health threshold (evasive: on any damage, the
    chance x the hull damage).
- **End**: a fleet with no enemy left in its list ends its combat (`targeting` and `disengaged`
  cleared).
- **Checked against the game** (s2211, two `NAME_Small_Space_Organism_Blue` amoebas made with
  `console Effect` next to the colony ship): both sides start the combat on the spawn day, and the
  amoebas fire 12 shots at the colony ship in the first 6 days on both. The game hits 5 of them,
  the renderer 9: with the colony ship's evasion (10) under the weapon's tracking (0.5) the
  renderer's chance is the weapon's accuracy (0.75); the game's lower rate is not explained yet.
  The game's colony ship then flees (`evade_hostiles_order`, the evasive stance) and the capital
  starbase fights the amoebas when they wander into range (2211.12.24); the renderer's colony ship
  stays and the amoebas do not move (the evasive stance's pathing and the monsters' roaming are not
  done here).
- **Not done**:
  - combat movement: fleets stay where combat found them, and ranges are the fleets' distances
    [I];
  - the ships' main targets and their draws;
  - missiles, strike craft, point defence;
  - collateral and chain damage, `on_hit`;
  - capture, admiral death;
  - territory and weapon-tag modifiers;
  - regeneration in combat;
  - emergency FTL and MIA;
  - bombardment, the inactivity disengage, debris, war exhaustion;
  - the battle events' other scopes.

  The game's random draws for these are not made, so the stream drifts from the game's once a
  combat runs.

## 11. Test setup: `console Effect`

The headless game's `console Effect WORDS...` (master's `console NAME ARGS`) and the renderer's
`console Effect WORDS...` (`render.windows.console_effect`; also `effect WORDS...`) run the same
script effect in the player's country. A test's colony ship, transport or monster fleet is then
made the same way on both sides. In the renderer's scripts, `fleet_cmd .debug(FID)` prints a
fleet's place and orders.

## 12. Not done yet

- The leader's portrait and trait icons (shared with the leader windows); the ship view's 3D
  preview (a model drawn into the GUI).
- Ship stats: the country's modifiers; ship ranks above Regular; military power of designs.
- Observation posts, hero ships, colonizers, transports, a foreign fleet with communications
  (the 2210 player has none) not checked against the game.
- The buttons marked "not done here" in section 5.
- The right click's other entries: Excavate Site, the special projects, Research Anomalies in
  system, the armadas, Assist Cloaking Detection, the bypasses, rifts, storms and gravity snares,
  megastructures, the scripted actions (common/scripted_actions), Settle (arkships), Explore
  System (no intel), the jump drive's orders.
- `console Effect create_amoeba_country = yes ...` makes a new country in the renderer; the game
  gives the fleet to the existing "Spaceborne Organics" country.
- The outpost's cost misses the country's modifiers (the game: alloys 90, here 100).
- The renderer draws every text after every sprite: a text under a window (a map label) shows
  through it (scene.rs; not the fleet windows' own).
