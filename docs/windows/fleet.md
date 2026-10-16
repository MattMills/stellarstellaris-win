# The fleet windows

The renderer's fleet windows: the selected fleet's **fleet_view** (`interface/fleet_view.gui`), a
ship's **ship_view** (`interface/ship_view.gui`) and the **Fleet Manager**
(`interface/fleet_manager_view.gui`), drawn from the game's GUI files with what the save holds.

| file | |
|---|---|
| `sim/render/src/fleetwin.rs` | what is open, `open`, the `fleet:...` clicks, Escape; the derived textures (greyed buttons, filled bars) |
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
| the left bar's Fleet Manager, the fleet view's and ship view's Fleet Manager buttons | `CFleetManagerView::Show` (the view at CInGameIdler+0xd78, ETopBarView 8; `ShowFleetManagerView(template)` = Show + `SelectTemplate`) [V] | `fleet:manager`, `view:fleet_manager` (toggles), `open fleet_manager` |
| close | `header/close`, an entry's `top/deselect`; `CShipView::Close`; `CFleetManagerView::Hide` [V] | `close`, `fleet:close_ship`, `fleet:close_manager`; Escape closes the ship view, then the manager, then the selection |

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

**Not computed:** a design's own strength (NCombatRules::CalcMilitaryPower: the row shows the
fleet's, "169" where the game shows "163/184"); the upgradable count's icon frame (|2) is drawn
as frame 1.

## 5. Not done yet

- The leader's portrait and trait icons (shared with the leader windows); the ship view's 3D
  preview (a model drawn into the GUI).
- Ship stats: the country's modifiers; ship ranks above Regular; military power of designs.
- Observation posts, hero ships, colonizers, transports, a foreign fleet with communications
  (the 2210 player has none) not checked against the game.
- Clicks other than inspect, close, deselect, the fleet manager's buttons, a row's selection:
  the orders and actions log "not done yet".
- The renderer draws every text after every sprite: a text under a window (a map label) shows
  through it (scene.rs; not the fleet windows' own).
