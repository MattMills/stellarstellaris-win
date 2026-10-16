# The ship designer and the combat view

The ship designer (`interface/ship_designer.gui`, CShipDesigner / CShipDesignerBase) and the combat
view (`interface/combat_view.gui`, CCombatView), as the 4.5.2 Linux build fills them, and how the
renderer does it: `sim/render/lua/render/windows/designer.lua`, `combat.lua` (data and layout),
`sim/render/src/designer.rs` (state, the two runtimes, the ship models), the 3D view as an inset
(`scene::Inset`, `render.rs`). Read in the game's code **[V]** (addresses: the Linux build), or
inferred **[I]**. The combat stats window (`combat_stats_view.gui`, opened from a combat message)
is read (below) but not drawn.

## Opening them, in both

`open_designer` is one command of the protocol (docs/render.md section 9), in the game's headless
driver (`headless/headless.c`) and the renderer (`engine.rs`):

| command | the game (headless.c) | the renderer |
|---|---|---|
| `open_designer` | `CShipDesignerBase::Show()` on `CInGameIdler::AccessShipDesigner()` (idler +0xd98), as the fleet manager's tab does | the designer open, no design loaded |
| `open_designer design ID` | then CShipDesignEntry::Click's work: `LoadDesign(TPdxRef<CShipDesign> ID, owner 0, false)` and the five popups' refresh (designer +0x1a58..+0x1a78, vtable +0x100) | the design loaded |
| `open_designer combat [FLEET]` | the fleet selected: `CInGameIdler::Select` of its CSelectable (CFleet +0x18), as a click; without FLEET the first fleet (by database slot) with `CFleet::HasCombat` | `select fleet` of the first fleet (by id) whose save block has a `combat.in_combat_with` |
| `open_designer close` | `CShipDesignerBase::Hide`, `CCombatView::Hide` (idler +0xb50) | closed, a selected fleet deselected |

The reply names the fleet: `ok open_designer combat 261`. The designer's close button, its
ESCAPE shortcut and the fleet manager's tab close it; a design in the list loads it
(`designer:design:ID`).

Selecting a fleet shows the combat view instead of the fleet view when the fleet is in combat
**[V]** (CInGameIdler::ShowFleetView 0x1c89110: CFleet::HasCombat, then CCombatView's Show,
vtable +0x38); CCombatView::Update lists the *selected* fleets (idler +0xa80, type 1) in combat, so
a fleet must be selected, not merely shown. The renderer: `app.rs` window_items asks
`designer::in_combat` and leaves fleet_view out for such a fleet.

## The ship designer

### What shows **[V]** (CShipDesignerBase::Setup 0x318e2e0, Show 0x3190300, Update 0x3192150, UpdateInfo 0x3193010, UpdateControlsWindow 0x3194450)

- Always: `fleet_manager_tab`, `ship_designer_tab_active`, `creature_designer_tab_inactive` (the
  other two tabs StayHidden), `3d_view` (the viewer), `design_name` = `SHIP_DESIGNER_COUNTRY`,
  `auto_design` down iff the country's `ship_design_collection` has no `auto_gen_design = no`
  (GetAutoGenerateShipDesigns), its label, `designs_list`, `close`; `blocker` and
  `component_paint_help_text` hidden (no popup, no component being painted).
- Opened: no design loaded (Show clears the data when the owner changes): `ship_label` =
  `SHIP_NAME_STATS` ("Specifications"), `controls` and `info/content` hidden, the help texts
  hidden, no sections; the `info` box where the .gui has it (244 x 455 at (-174, 70) of the upper
  right).
- A design loaded: `ship_label` = `LONG_SHIPCLASS_NAME` ("$NAME$-class $SIZE$", the size's
  capitalised family name: `<size>_cap` else `<size>` **[I]**); `controls` shown (the design's name
  in the rename box, `choose_role` with the role's name, the bottom buttons, `upgrade_ship_components`
  down iff the design's `upgrade_ship_components = yes`); `bioship_stage` and its spinner hidden (not
  a growth-stage size); the info box at `info_mecship_pos` (1098, 40) with
  `info_background_mecship_size` 244 x 485 (SetInfoPosAndSize "mecship"); `weapons_help_text` iff
  the design has weapon slots and none filled, `utilities_help_text` the same for utilities;
  `cloaking_values` only with its DLC (hidden in the 2210 save's game).

### The designs list **[V]** (UpdateDesignsList 0x3191260, GetAllDesignsToDisplay 0x317f380)

`new_ship_design_entry` ("New Design") first; then the country's designs (its
`ship_design_collection`, the ids with their generation bits as the store's keys) that it can
build: a designable ship size (`is_designable` not `no`) whose `prerequisites` it has researched
(**[I]**: CanCountryBuildPotential's `potential_country` triggers are not evaluated); auto-generated
designs are listed. Sorted (stable) by the size's definition order (common/ship_sizes in file
order); a `ship_design_header_entry` (the size's capitalised name) where the size changes. Each
`ship_design_entry`: its name (Y), its 3D view (the render target: an inset with the design's
model, smaller than the main view **[I]**), `auto_gen` for an auto-generated design
(`AUTO_GENERATED_BEST` "Auto-Generated" with auto-generation on, else `AUTO_GENERATED_STANDARD`),
`selected` (the orange glow) for the loaded design, `delete` hidden (mouse over only). Heights:
the .gui's (90, 18, 91), no spacing. 2210.01.01: New Design, Corvette: Ripjaw Angler, Defense
Platform: Buoyant Barnacle, as the game.

### The stats **[V]** (SetupInfo 0x318c590, UpdateStat 0x318d5e0, CalcStat 0x31971e0)

From `first_stat_position` (-72, 55) of `info/content`, a `value_title` 25 high, a `value_line` 22:
Production; Build Time, Upkeep, Cost; an empty title; Ship Stats; Ship Size, Naval Capacity Usage,
Power, Hull Points, Armor, Shields, Evasion, Speed, Damage, Sensor Range (growth threshold, growth
speed and rarity only for bio and creature sizes). A value is the stat's `<key>_VALUE`
localisation with VALUE given already formatted (two decimals; size and sensor none), so its
digits flag does not round it ("60.00"); Evasion min(evasion, the cap) with one decimal and %;
Power a whole number with its sign, green or red; Cost and Upkeep each resource's text icon and
amount (CResourceTable::BuildString). Sensor Range's label is `SHIP_STAT_SENSOR_RANGE` without its
`$VALUE$`.

The numbers here (designer.lua `stats`) **[I]**: the ship size's (max_hitpoints, max_speed,
base_buildtime, size_multiplier, its `modifier`, its upkeep), the sections' and components' (the
scripted variables of their own file over the global ones; `modifier` blocks: ship_armor_add,
ship_shield_add, ship_evasion_add, ship_reactor_power_mult ...; power; cost and upkeep), the
weapons' `weapon_components.csv` (the mean damage x accuracy over the cooldown and the mean
wind-up, in days). The country's modifiers are not applied. Against the game's frame of the Ripjaw
Angler (2210.01.01):

| stat | game | here |
|---|---|---|
| Build Time, Cost | 60.00, 110.00 alloys | the same |
| Ship Size, Naval Capacity, Power | 5, 5.00, +35 | the same |
| Hull, Armor, Shields | 200.00, 200.00, 100.00 | the same |
| Evasion, Speed, Damage | 62.3%, 166.22, 8.46 | 60.0%, 160.00, 8.15: the game's are x 1.0389 (a modifier not read) |
| Upkeep | 1.48 energy, 0.57 alloys | 1.55, 0.60: the game's x 0.955 |

### Sections, slots, required components **[V]** (CShipDesigner::UpdateSections 0x317fad0, CSectionInstanceEntry 0x3180790, UpdateRequiredComponents 0x3194130)

A `section_instance_entry` (192 wide) per section slot of the size, in definition order, in the
`sections` box (spacing 10, centred). The section's name (its template key localised:
CORVETTE_MID_S3 "Interceptor") is `change_section`'s text, `NO_SECTION` with none. The slots:
`weapon_slots` from the top and `utility_slots` from the bottom (LOWER_LEFT), 56 a cell,
max(3, ceil(n / 3)) columns centred on the entry's mask column, one `component_slot` per slot of
the section template in its order (its `component_slot` blocks, then the
`small/medium/large/aux_utility_slots` counts: SMALL_UTILITY_1 ...). A slot's frame of
GFX_ship_designer_slot: weapon size + 4, utility size (NComponentUtils::GetComponentSlotIconFrame);
the size enum by the texture's frames **[I]**: small 0, medium 1, large 2, torpedo 3, extra large 4,
titanic 5, planet killer 6, aux 11. The placed component's icon (`icon`, `icon_frame`). Under each
grid its background GFX_ship_designer_grid_<cols>_2 (two rows of cells) **[I: by the frame]**. The
required components: a `required_component_entry` (60 high) per `required_component_set` of the
size, in a column at `required_slots_position` (945, 374) centred on y, the chosen component's
icon. The masks are for bioships only.

### The 3D view **[V]** / **[I]**

The viewer is `3d_view` sized `ship_designer_3d_view_size` (740 x 584). gfx/worldgfx/ship_designer.txt
gives its world: the background `galaxy_background` gfx/map/sky_rim.dds (a YCoCg cube), its
lights and environment map. Here (designer.rs `fill_insets`) the design's model is drawn as a ship
in a system is (system.lua `design_model`: the culture's frame entity, the sections at its
locators, the turrets), from its side, the bow to the right, 14 degrees above, filling the width
**[I: matched to the frame by eye: yaw -75]**, with the ship designer world's camera lights and
environment, the sky behind it. Without a design the sky alone shows, as the game's. Not matched:
the sky's orientation (another part of the cube faces the camera), the game's post effects in the
viewer (its bloom and lens flare: the hull here is cooler and flatter).

The inset (`scene::Inset`): a sprite item of kind "inset" marks a 3D view's place in the GUI
(`add_gui` pushes an empty batch there); the scene's builder fills its view, lights, meshes and
sky; `render.rs` draws it in the GUI pass at that batch, in its rectangle (viewport and scissor),
with its own view uniform, its sky (an LDR sky pipeline, gamma-encoded for a target that is not
sRGB: sky.wgsl `flags.z`) and its meshes, depth tested in the GUI pass's own depth (the GUI's
quads write none).

## The combat view **[V]** (CCombatView::Update 0x2bf3c40, UpdateCombatantEntry 0x2bf3950, CCombatViewFleetEntry::UpdateEntry 0x2bf5a70, CCombatViewShipEntry::UpdateEntry 0x2bfa660, UpdateCombatStats 0x2bf4870)

- The fleets: the selected fleet, then every fleet it is in combat with. A reference country: the
  controller most aligned with the player (GetAlignmentToCountryCached, ties to the lower id); here
  **[I]** the player, then empires, then the others. The fleets whose controller is hostile to it on
  the right, the others on the left; here **[I]** the fleets fighting a reference fleet.
- A `combat_view_fleet_entry` per fleet: its name (GetLocalNamePersistent 0x292a6d0: with
  communications the fleet's name; without, the country type's `pre_communications_fleet_name`
  (Space Amoeba: NO_COMMUNICATIONS_AMOEBA "Alien Vessels"), a station's NO_COMMUNICATIONS_STATION,
  else NO_COMMUNICATIONS_FLEET, `_XENOPHOBE` "Alien Menace" for a xenophobe player); the owner's
  flag (drawn here as the sprite's own frame **[I]**); `emergency_ftl` for the player's own fleets;
  `orders_hero_ship` hidden; its ships from y 140, the entry as high as they reach.
- A `combat_view_ship_entry` (50 high) per ship: its name (with communications the size's and the
  ship's names and "$CLASS$-class"; without, the size's `pre_communications_name` or
  NO_COMMUNICATIONS_VESSEL(_XENOPHOBE)), the hull, armor and shield rings at round(% x 100) (armor
  and shields hidden without any), the ship class icon (GetShipClassIconFrameFromSize: the size's
  `ship_class_icon_frame`, else by class **[I]**), `inspect` disabled before contact (the game greys it
  with its shader: not done here), `destroyed`/`disengaged` hidden. The rings are turned 180 degrees about (41, -37) in the
  .gui: drawn over (41 - w, 37 - h) .. (41, 37), not turned **[I: by the frame]**.
- The bar (`progress`, a progressbarType): the left side's share of both sides' hull points,
  round(100 L / (L + R)) in 1..100; its first texture (green) to the share, its second (red) past it
  (the game's progress.shader cuts them; here the green is squeezed over the red **[I]**); the glow
  at its .gui x + frame x 0.01 x the bar's width.
- The bottom: each side's damage dealt to hull, armor and shields (whole numbers) and its hit
  ratio ("0%" with no shots); a save keeps no combat stats in its fleets' `fleet_stats` **[I]**, so 0.
- The lists clip their entries **[I]**: what starts below the list's bottom is dropped, a
  background crossing it is cut.

2210.01.01 (`open_designer combat`: fleet 261, five Space Amoeba ships, against fleet 33554951,
a Yv'Zorak science ship; the player xenophobe without communications): left "Alien Menace" with one
ship "Alien Menace" (the science class icon), right "Alien Vessels" with five; the bar 16% green;
0 damage, 0%. As the game's frame.

## The combat stats window (combat_stats_view.gui, CCombatStatsView) — read, not drawn

Opened from a combat message (ShowWithMessage 0x2bed930): a won/lost background and title
(`COMBAT_WON` / `COMBAT_LOST`), `combat_location` (the system and date), `our_leader` /
`their_leader` (portrait, name, skill, experience, traits), `fleets_left` / `fleets_right` (flag,
fleet name, ships by class, ships lost), two panels of up to seven stats (damage efficiency, point
defence, hit and evasion ratios).

## Comparisons made (10.5.0.24, 2210.01.01, 1600 x 900; game left, renderer right)

The same command file on both (`headless/view.sh --script`, `stellar-render --script`):
`open_designer`, `open_designer design 2207` (the Ripjaw Angler), `open_designer combat`. The
side-by-sides: `code_working/tmp_sym/render3d/parity/windows/` (designer_empty.png, designer_2207.png, combat_2210.png).

- Designer, no design: the same frame, list, tabs, title, info box, sky in the view.
- Designer, Ripjaw Angler: the same layout, texts, slots, icons and required components; the
  numbers as the table above; the ship from the same side.
- Combat: the same sides, names, entries, icons, bar and stats.

## Not done

- Stats: the country's modifiers (speed, evasion, damage, upkeep), the role's.
- The designer's popups (section, component and size selection, role selection, save menu),
  painting components, renaming, the buttons' actions; the list's scrolling; the creature
  designer.
- The combat view's scrollbar, the owner's flag (the country's), the rings' rotation, the order
  buttons (hero ships), the damage numbers of a running combat (the simulation's combat stats).
- The combat stats window.
- The windows cannot yet be opened by clicking in the game's frames (render-controls' input is
  merged after this: the designer opens from the fleet manager, which another session draws).
